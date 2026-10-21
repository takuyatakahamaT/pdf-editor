import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

struct PDFPageResizeEngineTests {
    @Test("B5 resize preserves source, text, and page geometry")
    func resizeToB5() throws {
        guard let helperPath = ProcessInfo.processInfo.environment["PDFCPU_PATH"] else { return }
        let rawURL = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 1_820, height: 2_570),
            contentStream: "BT /F1 72 Tf 1 0 0 1 180 360 Tm (B5 SAMPLE) Tj ET"
        )
        let sourceURL = temporaryURL("source")
        let outputURL = temporaryURL("resized")
        defer { remove([rawURL, sourceURL, outputURL]) }
        let source = try #require(PDFDocument(url: rawURL))
        let page = try #require(source.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 182, y: 257, width: 182, height: 257),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = "test note"
        page.addAnnotation(annotation)
        let managedMarkup = PDFMarkupEdit(
            pageIndex: 0,
            tool: .note,
            bounds: CGRect(x: 500, y: 700, width: 120, height: 40),
            text: "editable note"
        )
        page.addAnnotation(PDFMarkupEngine.makeAnnotation(for: managedMarkup))
        #expect(source.write(to: sourceURL))
        let sourceBytes = try Data(contentsOf: sourceURL)

        try PDFPageResizeEngine.resize(
            sourceURL: sourceURL,
            to: outputURL,
            size: .jisB5,
            helperURL: URL(fileURLWithPath: helperPath)
        )

        let result = try #require(PDFDocument(url: outputURL))
        let resultPage = try #require(result.page(at: 0))
        let bounds = resultPage.bounds(for: .mediaBox)
        #expect(abs(bounds.width - PDFPageSize.jisB5.widthPoints) < 0.1)
        #expect(abs(bounds.height - PDFPageSize.jisB5.heightPoints) < 0.1)
        #expect(resultPage.string?.contains("B5 SAMPLE") == true)
        #expect(resultPage.annotations.count == 2)
        let restoredMarkup = try #require(PDFMarkupEngine.edits(in: result).first)
        #expect(restoredMarkup.id == managedMarkup.id)
        #expect(restoredMarkup.text == "editable note")
        let annotationBounds = try #require(resultPage.annotations.first?.bounds)
        #expect(abs(annotationBounds.minX - 182 * PDFPageSize.jisB5.widthPoints / 1_820) < 0.5)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        let a5 = PDFPageSize(widthMM: 148, heightMM: 210)
        try PDFPageResizeEngine.resize(
            sourceURL: sourceURL,
            to: outputURL,
            size: a5,
            helperURL: URL(fileURLWithPath: helperPath)
        )
        let replacedPage = try #require(PDFDocument(url: outputURL)?.page(at: 0))
        #expect(abs(replacedPage.bounds(for: .mediaBox).width - a5.widthPoints) < 0.1)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    }

    @Test("resize rejects source aliases and invalid dimensions")
    func rejectsUnsafeOutput() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 200, height: 300),
            contentStream: ""
        )
        let hardLink = temporaryURL("hard-link")
        defer { remove([source, hardLink]) }
        try FileManager.default.linkItem(at: source, to: hardLink)
        let original = try Data(contentsOf: source)

        #expect(throws: PDFPageResizeError.outputMatchesInput) {
            try PDFPageResizeEngine.resize(sourceURL: source, to: hardLink, size: .jisB5)
        }
        #expect(throws: PDFPageResizeError.invalidSize) {
            try PDFPageResizeEngine.resize(
                sourceURL: source,
                to: temporaryURL("invalid"),
                size: PDFPageSize(widthMM: 0, heightMM: 257)
            )
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test("resize reports a password-locked source")
    func rejectsLockedSource() throws {
        let sourceURL = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 200, height: 300),
            contentStream: ""
        )
        let lockedURL = temporaryURL("locked")
        let outputURL = temporaryURL("locked-output")
        defer { remove([sourceURL, lockedURL, outputURL]) }
        let document = try #require(PDFDocument(url: sourceURL))
        #expect(document.write(to: lockedURL, withOptions: [
            .ownerPasswordOption: "owner-password",
            .userPasswordOption: "user-password"
        ]))

        #expect(throws: PDFPageResizeError.lockedSource) {
            try PDFPageResizeEngine.resize(sourceURL: lockedURL, to: outputURL, size: .jisB5)
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-\(name)-\(UUID().uuidString).pdf")
    }

    private func remove(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
