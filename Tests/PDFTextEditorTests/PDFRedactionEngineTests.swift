import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

struct PDFRedactionEngineTests {
    @Test("rasterized redaction removes text from PDFKit and independent pdftotext extraction")
    func redactionRemovesSelectableAndExtractableText() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (CONFIDENTIAL) Tj ET"
        )
        let output = temporaryPDF()
        defer { remove([source, output]) }
        let preparedSource = try #require(PDFDocument(url: source))
        preparedSource.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "CONFIDENTIAL TITLE",
            PDFDocumentAttribute.authorAttribute: "Private Author"
        ]
        try #require(preparedSource.page(at: 0)).rotation = 90
        #expect(preparedSource.write(to: source))
        let sourceBytes = try Data(contentsOf: source)
        let region = PDFRedactionRegion(
            pageIndex: 0,
            bounds: CGRect(x: 18, y: 116, width: 86, height: 18),
            text: "CONFIDENTIAL"
        )
        #expect(PDFRedactionEngine.redactionBounds(for: region, in: CGRect(x: 0, y: 0, width: 240, height: 160))
            == CGRect(x: 16, y: 114, width: 90, height: 22))
        try PDFRedactionEngine.export(sourceURL: source, regions: [region], to: output)

        let redacted = try #require(PDFDocument(url: output))
        #expect(redacted.pageCount == 1)
        let redactedPage = try #require(redacted.page(at: 0))
        #expect((redactedPage.string ?? "").isEmpty)
        #expect(redactedPage.annotations.isEmpty)
        #expect(redactedPage.rotation == 90)
        #expect(redactedPage.bounds(for: .mediaBox).size == CGSize(width: 240, height: 160))
        #expect(redacted.documentAttributes?[PDFDocumentAttribute.titleAttribute] == nil)
        #expect(redacted.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(try Data(contentsOf: source) == sourceBytes)

        let extracted = try runTool("pdftotext", arguments: ["-layout", output.path, "-"])
        #expect(!extracted.contains("CONFIDENTIAL"))
        let metadata = try runTool("pdfinfo", arguments: [output.path])
        #expect(!metadata.contains("CONFIDENTIAL TITLE"))
        #expect(!metadata.contains("Private Author"))
    }

    @Test("redaction preserves the crop box and removes content hidden outside it")
    func cropBoxHidesAreNotRevealed() throws {
        let cropBox = CGRect(x: 50, y: 40, width: 140, height: 80)
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            cropBox: cropBox,
            contentStream: "BT /F1 12 Tf 20 130 Td (HIDDEN) Tj ET BT /F1 12 Tf 70 70 Td (VISIBLE) Tj ET"
        )
        let output = temporaryPDF()
        defer { remove([source, output]) }
        let region = PDFRedactionRegion(
            pageIndex: 0,
            bounds: CGRect(x: 68, y: 66, width: 56, height: 18),
            text: "VISIBLE"
        )
        let sourceDocument = try #require(PDFDocument(url: source))
        let sourcePage = try #require(sourceDocument.page(at: 0))
        sourcePage.setBounds(sourcePage.bounds(for: .mediaBox), for: .cropBox)
        let expandedSourceImage = try #require(PDFRedactionEngine.render(page: sourcePage, regions: []))
        #expect(containsInk(in: expandedSourceImage, leftOf: Int(cropBox.minX * 4)))

        try PDFRedactionEngine.export(sourceURL: source, regions: [region], to: output)

        let outputDocument = try #require(PDFDocument(url: output))
        let outputPage = try #require(outputDocument.page(at: 0))
        #expect(outputPage.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 240, height: 160))
        #expect(outputPage.bounds(for: .cropBox) == cropBox)

        // Expanding the crop box must reveal only white pixels outside the former visible area.
        outputPage.setBounds(outputPage.bounds(for: .mediaBox), for: .cropBox)
        let expandedImage = try #require(PDFRedactionEngine.render(page: outputPage, regions: []))
        let leftMarginPixels = Int(cropBox.minX * 4)
        #expect(containsInk(in: expandedImage, xRange: Int(118 * 4)..<Int(122 * 4)))
        #expect(!containsInk(in: expandedImage, leftOf: leftMarginPixels))
    }

    @Test("redaction refuses source aliases and invalid or empty ranges")
    func rejectsUnsafeOutputAndRegions() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (SECRET) Tj ET"
        )
        let hardLink = temporaryPDF()
        defer { remove([source, hardLink]) }
        try FileManager.default.linkItem(at: source, to: hardLink)
        let originalBytes = try Data(contentsOf: source)
        let region = PDFRedactionRegion(pageIndex: 0, bounds: CGRect(x: 10, y: 10, width: 20, height: 10), text: "SECRET")
        let emptyOutput = temporaryPDF()
        let invalidOutput = temporaryPDF()
        defer { remove([emptyOutput, invalidOutput]) }

        #expect(throws: PDFRedactionError.sameFile) {
            try PDFRedactionEngine.export(sourceURL: source, regions: [region], to: hardLink)
        }
        #expect(throws: PDFRedactionError.noRegions) {
            try PDFRedactionEngine.export(sourceURL: source, regions: [], to: emptyOutput)
        }
        #expect(throws: PDFRedactionError.invalidRegion) {
            try PDFRedactionEngine.export(
                sourceURL: source,
                regions: [PDFRedactionRegion(pageIndex: 4, bounds: CGRect(x: 10, y: 10, width: 20, height: 10), text: "SECRET")],
                to: invalidOutput
            )
        }
        #expect(try Data(contentsOf: source) == originalBytes)
    }

    @Test("redaction respects password and PDF access restrictions")
    func respectsDocumentPermissions() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (SECRET) Tj ET"
        )
        let locked = temporaryPDF()
        let noCopy = temporaryPDF()
        let noAssembly = temporaryPDF()
        let output = temporaryPDF()
        defer { remove([source, locked, noCopy, noAssembly, output]) }
        let region = PDFRedactionRegion(pageIndex: 0, bounds: CGRect(x: 10, y: 10, width: 20, height: 10), text: "SECRET")
        let sourceDocument = try #require(PDFDocument(url: source))

        #expect(sourceDocument.write(to: locked, withOptions: [
            .ownerPasswordOption: "owner-password",
            .userPasswordOption: "user-password"
        ]))
        #expect(sourceDocument.write(to: noCopy, withOptions: [
            .ownerPasswordOption: "owner-password",
            .accessPermissionsOption: NSNumber(value: PDFAccessPermissions.allowsDocumentAssembly.rawValue)
        ]))
        #expect(sourceDocument.write(to: noAssembly, withOptions: [
            .ownerPasswordOption: "owner-password",
            .accessPermissionsOption: NSNumber(value: PDFAccessPermissions.allowsContentCopying.rawValue)
        ]))

        #expect(throws: PDFRedactionError.lockedSource) {
            try PDFRedactionEngine.export(sourceURL: locked, regions: [region], to: output)
        }
        #expect(throws: PDFRedactionError.copyingNotAllowed) {
            try PDFRedactionEngine.export(sourceURL: noCopy, regions: [region], to: output)
        }
        #expect(throws: PDFRedactionError.assemblyNotAllowed) {
            try PDFRedactionEngine.export(sourceURL: noAssembly, regions: [region], to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("redaction selection previews can be removed before applying")
    @MainActor
    func modelCanStageAndRemoveRegions() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (SECRET) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        model.setMode(.redaction)
        let page = try #require(model.document?.page(at: 0))
        let target = try #require(PDFGlyphIndex.makeIndex(for: page)
            .clusterWithAnchor(at: CGPoint(x: 22, y: 122), pageIndex: 0)?.target)
        model.select(target)
        model.addSelectedRedactionRegion()
        let region = try #require(model.redactionRegions.first)
        #expect(model.hasPendingEditorInput)
        #expect(region.text.isEmpty == false)
        model.removeRedactionRegion(id: region.id)
        #expect(model.redactionRegions.isEmpty)
        #expect(!model.hasPendingEditorInput)
    }

    private func temporaryPDF() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdf-redaction-\(UUID().uuidString).pdf")
    }

    private func runTool(_ command: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let result = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PDFRedactionEngineTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        return result
    }

    private func containsInk(in image: CGImage, leftOf xLimit: Int) -> Bool {
        containsInk(in: image, xRange: 0..<min(xLimit, image.width))
    }

    private func containsInk(in image: CGImage, xRange: Range<Int>) -> Bool {
        guard let data = image.dataProvider?.data as Data? else { return false }
        let pixels = xRange.clamped(to: 0..<image.width)
        return (0..<image.height).contains { y in
            pixels.contains { x in
                let pixel = y * image.bytesPerRow + x * 4
                return data[pixel] < 245 || data[pixel + 1] < 245 || data[pixel + 2] < 245
            }
        }
    }

    private func remove(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
