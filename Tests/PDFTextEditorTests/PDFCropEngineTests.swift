import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

struct PDFCropEngineTests {
    @Test("page range accepts all, single pages, and comma-separated ranges")
    func parsesPageRanges() throws {
        #expect(try PDFCropEngine.pageIndices(from: "すべて", pageCount: 5) == [0, 1, 2, 3, 4])
        #expect(try PDFCropEngine.pageIndices(from: "1, 3-4, 4", pageCount: 5) == [0, 2, 3])
        #expect(try PDFCropEngine.pageIndices(from: " 2 - 3 ", pageCount: 5) == [1, 2])
        #expect(throws: PDFCropError.invalidPageRange) {
            try PDFCropEngine.pageIndices(from: "1,,3", pageCount: 5)
        }
        #expect(throws: PDFCropError.invalidPageRange) {
            try PDFCropEngine.pageIndices(from: "4-2", pageCount: 5)
        }
        #expect(throws: PDFCropError.pageOutOfRange) {
            try PDFCropEngine.pageIndices(from: "6", pageCount: 5)
        }
    }

    @Test("crop changes selected CropBoxes only and preserves source, text, and annotations")
    func cropsSelectedPages() throws {
        let rawURL = RawPDFBuilder.multiPagePDF(pages: [
            (CGRect(x: 0, y: 0, width: 600, height: 800), "BT /F1 24 Tf 1 0 0 1 40 700 Tm (FIRST) Tj ET"),
            (CGRect(x: 10, y: 20, width: 500, height: 700), "BT /F1 24 Tf 1 0 0 1 40 600 Tm (MIDDLE) Tj ET"),
            (CGRect(x: 0, y: 0, width: 400, height: 600), "BT /F1 24 Tf 1 0 0 1 40 500 Tm (LAST) Tj ET")
        ])
        let sourceURL = temporaryURL("source")
        let outputURL = temporaryURL("cropped")
        defer { remove([rawURL, sourceURL, outputURL]) }
        let sourceDocument = try #require(PDFDocument(url: rawURL))
        let note = PDFAnnotation(bounds: CGRect(x: 30, y: 50, width: 40, height: 40), forType: .text, withProperties: nil)
        note.contents = "keep this note"
        sourceDocument.page(at: 1)?.addAnnotation(note)
        #expect(sourceDocument.write(to: sourceURL))
        let originalBytes = try Data(contentsOf: sourceURL)

        let margins = PDFCropMargins(topMM: 10, rightMM: 5, bottomMM: 8, leftMM: 4)
        try PDFCropEngine.crop(
            sourceURL: sourceURL,
            to: outputURL,
            margins: margins,
            pageSpecification: "2"
        )

        let output = try #require(PDFDocument(url: outputURL))
        let original = try #require(PDFDocument(url: sourceURL))
        #expect(output.pageCount == 3)
        for index in [0, 2] {
            #expect(output.page(at: index)?.bounds(for: .cropBox) == original.page(at: index)?.bounds(for: .cropBox))
        }
        let croppedPage = try #require(output.page(at: 1))
        let originalPage = try #require(original.page(at: 1))
        let expected = try margins.cropBox(from: originalPage.bounds(for: .cropBox))
        let actual = croppedPage.bounds(for: .cropBox)
        #expect(abs(actual.minX - expected.minX) < 0.1)
        #expect(abs(actual.minY - expected.minY) < 0.1)
        #expect(abs(actual.width - expected.width) < 0.1)
        #expect(abs(actual.height - expected.height) < 0.1)
        #expect(croppedPage.bounds(for: .mediaBox) == originalPage.bounds(for: .mediaBox))
        #expect(croppedPage.string?.contains("MIDDLE") == true)
        let originalAnnotations = originalPage.annotations.map { $0.contents ?? "" }.sorted()
        let croppedAnnotations = croppedPage.annotations.map { $0.contents ?? "" }.sorted()
        #expect(originalAnnotations.contains("keep this note"))
        #expect(croppedAnnotations == originalAnnotations)
        #expect(try Data(contentsOf: sourceURL) == originalBytes)
    }

    @Test("preview shows before and after without changing the source page")
    func previewDoesNotMutateDocument() throws {
        let sourceURL = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 500, height: 700),
            contentStream: "BT /F1 24 Tf 1 0 0 1 40 600 Tm (PREVIEW) Tj ET"
        )
        defer { remove([sourceURL]) }
        let document = try #require(PDFDocument(url: sourceURL))
        let page = try #require(document.page(at: 0))
        let originalBounds = page.bounds(for: .cropBox)
        let preview = try PDFCropEngine.preview(
            document: document,
            pageIndex: 0,
            margins: PDFCropMargins(topMM: 10, rightMM: 10, bottomMM: 10, leftMM: 10)
        )
        #expect(preview.originalImage.size.width > 0)
        #expect(preview.croppedImage.size.width > 0)
        #expect(preview.croppedBounds != preview.originalBounds)
        #expect(page.bounds(for: .cropBox) == originalBounds)
    }

    @Test("invalid crop and source aliases do not create or overwrite output")
    func rejectsUnsafeCrop() throws {
        let sourceURL = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 200, height: 300),
            contentStream: ""
        )
        let hardLinkURL = temporaryURL("hard-link")
        let outputURL = temporaryURL("invalid-crop")
        defer { remove([sourceURL, hardLinkURL, outputURL]) }
        try FileManager.default.linkItem(at: sourceURL, to: hardLinkURL)

        #expect(throws: PDFCropError.outputMatchesInput) {
            try PDFCropEngine.crop(
                sourceURL: sourceURL,
                to: hardLinkURL,
                margins: .zero,
                pageSpecification: "all"
            )
        }
        #expect(throws: PDFCropError.cropOutsidePage) {
            try PDFCropEngine.crop(
                sourceURL: sourceURL,
                to: outputURL,
                margins: PDFCropMargins(topMM: 100, rightMM: 0, bottomMM: 100, leftMM: 0),
                pageSpecification: "all"
            )
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
