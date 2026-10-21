import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

struct PDFRedactionEngineTests {
    @Test("Base-14 Type1フォント12書体の幅を選択範囲に反映する")
    func base14CoreTextMetricsCoverAllFaces() throws {
        let faces: [(name: String, aWidth: CGFloat)] = [
            ("Helvetica", 667), ("Helvetica-Bold", 722),
            ("Helvetica-Oblique", 667), ("Helvetica-BoldOblique", 722),
            ("Times-Roman", 722), ("Times-Bold", 722),
            ("Times-Italic", 611), ("Times-BoldItalic", 667),
            ("Courier", 600), ("Courier-Bold", 600),
            ("Courier-Oblique", 600), ("Courier-BoldOblique", 600)
        ]
        var urls: [URL] = []
        defer { remove(urls) }

        for face in faces {
            let url = simpleFontPDF(
                baseFont: face.name,
                entries: " /Encoding /WinAnsiEncoding",
                contentStream: "BT /F1 14 Tf 72 50 Td (A) Tj ET"
            )
            urls.append(url)
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0))
            let glyph = try #require(PDFGlyphIndex.makeIndex(for: page).runs.flatMap(\.glyphs).first)
            #expect(abs(glyph.advance - face.aWidth * 14 / 1000) < 0.02, "\(face.name)")
        }
    }

    @Test("StandardEncodingの引用符に対応する字形幅を使う")
    func standardEncodingUsesCurlyQuoteMetrics() throws {
        let url = simpleFontPDF(
            baseFont: "Helvetica",
            contentStream: "BT /F1 14 Tf 72 50 Td (A'B) Tj ET"
        )
        defer { remove([url]) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let glyph = try #require(PDFGlyphIndex.makeIndex(for: page).runs.flatMap(\.glyphs).first { $0.text == "'" })

        // StandardEncodingのコード39はASCII apostropheではなくquoteright（AFM 222 unit）。
        #expect(abs(glyph.advance - 14 * 222 / 1000) < 0.02)
    }

    @Test("Differencesで上書きされたコードへ標準幅を推測適用しない")
    func standardMetricsSkipDifferencesOverrides() throws {
        let url = simpleFontPDF(
            baseFont: "Helvetica",
            entries: " /Encoding << /BaseEncoding /StandardEncoding /Differences [39 /A] >>",
            contentStream: "BT /F1 14 Tf 72 50 Td (') Tj ET"
        )
        defer { remove([url]) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let glyph = try #require(PDFGlyphIndex.makeIndex(for: page).runs.flatMap(\.glyphs).first)

        #expect(abs(glyph.advance - 7) < 0.02)
    }

    @Test("明示Widthsの範囲外はMissingWidthを使う")
    func explicitWidthsUseMissingWidthOutsideDeclaredRange() throws {
        let url = RawPDFBuilder.build(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] "
                + "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding "
                + "/FirstChar 65 /LastChar 65 /Widths [900] /FontDescriptor 6 0 R >>",
            RawPDFBuilder.streamObject(dict: "", streamContent: "BT /F1 14 Tf 72 50 Td (A B) Tj ET"),
            "<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [-166 -225 1000 931] "
                + "/ItalicAngle 0 /Ascent 718 /Descent -207 /CapHeight 718 /StemV 88 /MissingWidth 1000 >>"
        ])
        defer { remove([url]) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let glyphs = PDFGlyphIndex.makeIndex(for: page).runs.flatMap(\.glyphs)

        #expect(glyphs.count == 3)
        #expect(abs(glyphs[0].advance - 12.6) < 0.02) // /Widths: A = 900
        #expect(abs(glyphs[1].advance - 14) < 0.02) // /MissingWidth: space = 1000
        #expect(abs(glyphs[2].advance - 14) < 0.02) // /MissingWidth: B = 1000
    }

    @Test("standard Helvetica metrics keep selected text and redaction bounds aligned")
    func standardHelveticaMetricsKeepRedactionBoundsAligned() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792),
            contentStream: "BT /F1 14 Tf 72 650 Td (SECRET: TEST-REDACT-9357) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first(where: { $0.text.contains("REDACT") }))
        let range = try #require(run.text.range(of: "REDACT"))
        let startIndex = run.text.distance(from: run.text.startIndex, to: range.lowerBound)
        let firstGlyph = run.glyphs[startIndex]
        let target = try #require(index.clusterWithAnchor(
            at: CGPoint(x: firstGlyph.advanceBox.midX, y: firstGlyph.advanceBox.midY),
            pageIndex: 0
        )?.target)

        #expect(target.originalText == "REDACT")
        #expect(abs(target.bounds.minX - 177.014) < 0.02)
        #expect(abs(target.bounds.width - 57.559) < 0.02)
        #expect(abs(firstGlyph.advance - 10.110) < 0.02)
    }

    @Test("rasterized redaction removes extractable text")
    func redactionRemovesExtractableText() throws {
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

    @Test("redaction rasterizes committed text edits before removing the text layer")
    func redactionIncludesCommittedEdits() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (SECRET) Tj ET BT /F1 12 Tf 20 70 Td (EDITME) Tj ET"
        )
        let baseline = temporaryPDF()
        let edited = temporaryPDF()
        let marked = temporaryPDF()
        defer { remove([source, baseline, edited, marked]) }
        let target = TextTarget(
            pageIndex: 0,
            bounds: CGRect(x: 18, y: 66, width: 50, height: 16),
            baseline: 70,
            originalText: "EDITME",
            fontSize: 12,
            fontColor: .black,
            fontKey: "F1",
            fontIsExact: true,
            coverBounds: CGRect(x: 18, y: 66, width: 50, height: 16),
            maxWidth: 90
        )
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let replacement = ReplacementEdit(
            target: target,
            replacement: "UPDATED",
            resolvedFont: font,
            fontIsExact: true
        )
        let markup = PDFMarkupEdit(
            pageIndex: 0,
            tool: .rectangle,
            bounds: CGRect(x: 150, y: 30, width: 60, height: 45)
        )
        let region = PDFRedactionRegion(
            pageIndex: 0,
            bounds: CGRect(x: 18, y: 116, width: 86, height: 18),
            text: "SECRET"
        )

        try PDFRedactionEngine.export(sourceURL: source, regions: [region], to: baseline)
        try PDFRedactionEngine.export(
            sourceURL: source,
            regions: [region],
            edits: [replacement],
            markups: [],
            to: edited
        )
        try PDFRedactionEngine.export(
            sourceURL: source,
            regions: [region],
            edits: [],
            markups: [markup],
            to: marked
        )

        let baselinePage = try #require(PDFDocument(url: baseline)?.page(at: 0))
        let editedPage = try #require(PDFDocument(url: edited)?.page(at: 0))
        let markedPage = try #require(PDFDocument(url: marked)?.page(at: 0))
        let baselineImage = try #require(PDFRedactionEngine.render(page: baselinePage, regions: []))
        let editedImage = try #require(PDFRedactionEngine.render(page: editedPage, regions: []))
        let markedImage = try #require(PDFRedactionEngine.render(page: markedPage, regions: []))
        let baselinePixels = try #require(baselineImage.dataProvider?.data as Data?)
        let editedPixels = try #require(editedImage.dataProvider?.data as Data?)
        let markedPixels = try #require(markedImage.dataProvider?.data as Data?)
        #expect(baselinePixels != editedPixels)
        #expect(baselinePixels != markedPixels)
        let extracted = try runTool("pdftotext", arguments: ["-layout", edited.path, "-"])
        #expect(!extracted.contains("EDITME"))
        #expect(!extracted.contains("SECRET"))
    }

    @Test("redaction preserves deletion of the last managed annotation")
    @MainActor
    func redactionKeepsLastMarkupDeletion() throws {
        let base = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (KEEP) Tj ET"
        )
        let source = temporaryPDF()
        let prepared = temporaryPDF()
        let edited = temporaryPDF()
        defer { remove([base, source, prepared, edited]) }
        let markup = PDFMarkupEdit(
            pageIndex: 0,
            tool: .rectangle,
            bounds: CGRect(x: 120, y: 35, width: 70, height: 50)
        )
        try PDFExportEngine.export(sourceURL: base, edits: [], markups: [markup], to: source)
        let model = EditorModel(initialURL: source)
        let sourceMarkup = try #require(model.activeMarkupEdits.first)
        model.selectMarkup(sourceMarkup.id)
        model.deleteSelectedMarkup()
        model.setMode(.redaction)
        model.addRedactionRegion(
            pageIndex: 0,
            bounds: CGRect(x: 195, y: 10, width: 20, height: 20)
        )
        #expect(model.activeMarkupEdits.isEmpty)
        #expect(model.edits.contains(where: { $0.markupChange != nil }))
        #expect(PDFMarkupEngine.hasManagedAnnotations(in: try #require(PDFDocument(url: source))))

        try PDFExportEngine.export(
            sourceURL: source,
            edits: model.activeReplacements,
            markups: model.activeMarkupEdits,
            to: prepared
        )
        #expect(!PDFMarkupEngine.hasManagedAnnotations(in: try #require(PDFDocument(url: prepared))))

        try PDFRedactionEngine.export(
            sourceURL: source,
            regions: model.redactionRegions,
            edits: model.activeReplacements,
            markups: model.activeMarkupEdits,
            forcePrepareSource: !model.edits.isEmpty,
            to: edited
        )

        let editedPage = try #require(PDFDocument(url: edited)?.page(at: 0))
        #expect(editedPage.annotations.isEmpty)
        let extracted = try runTool("pdftotext", arguments: ["-layout", edited.path, "-"])
        #expect(!extracted.contains("KEEP"))
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
        let insertion = ReplacementEdit(
            insertionOn: 0,
            bounds: CGRect(x: 20, y: 20, width: 60, height: 16),
            text: "CURRENT",
            fontName: "Helvetica",
            fontSize: 12,
            fontColor: .black
        )
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
        #expect(throws: PDFRedactionError.copyingNotAllowed) {
            try PDFRedactionEngine.export(
                sourceURL: noCopy,
                regions: [region],
                edits: [insertion],
                markups: [],
                to: output
            )
        }
        #expect(throws: PDFRedactionError.assemblyNotAllowed) {
            try PDFRedactionEngine.export(
                sourceURL: noAssembly,
                regions: [region],
                edits: [insertion],
                markups: [],
                to: output
            )
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

    @Test("manual redaction rectangles work without selectable text and block unsafe outputs")
    @MainActor
    func manualRectanglesBlockNormalExportAndPrint() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: ""
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        model.setMode(.redaction)
        let bounds = CGRect(x: 40, y: 45, width: 70, height: 38)
        model.addRedactionRegion(pageIndex: 0, bounds: bounds)

        let region = try #require(model.redactionRegions.first)
        #expect(region.bounds == bounds)
        #expect(region.text.isEmpty)
        #expect(!model.canExport)
        #expect(!model.canPrint)
        model.exportFromPanel()
        #expect(model.statusMessage.contains("通常書き出しできません"))
        #expect(!model.resolvePendingPrintInput(.discard))
        #expect(model.redactionRegions.count == 1)
        model.printFromPanel()
        #expect(model.statusMessage.contains("印刷できません"))
        model.showMergeSheet()
        model.showResizeSheet()
        #expect(!model.isShowingMergeSheet)
        #expect(!model.isShowingResizeSheet)
    }

    private func temporaryPDF() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdf-redaction-\(UUID().uuidString).pdf")
    }

    private func simpleFontPDF(baseFont: String, entries: String = "", contentStream: String) -> URL {
        RawPDFBuilder.build(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] "
                + "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /\(baseFont)\(entries) >>",
            RawPDFBuilder.streamObject(dict: "", streamContent: contentStream)
        ])
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
