import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

struct PDFCompressionEngineTests {
    @Test("Compression estimate uses a real PDF and saves without changing the source")
    func estimateAndSave() throws {
        guard let helperPath = ProcessInfo.processInfo.environment["PDF_COMPRESS_PATH"] else { return }
        let sourceURL = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 200, height: 300),
            contentStream: ""
        )
        let sourceDocument = try #require(PDFDocument(url: sourceURL))
        let sourcePage = try #require(sourceDocument.page(at: 0))
        let managedMarkup = PDFMarkupEdit(
            pageIndex: 0,
            tool: .note,
            bounds: CGRect(x: 20, y: 30, width: 80, height: 24),
            text: "editable note"
        )
        sourcePage.addAnnotation(PDFMarkupEngine.makeAnnotation(for: managedMarkup))
        #expect(sourceDocument.write(to: sourceURL))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-compress-test-destination-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destination)
        }
        let original = try Data(contentsOf: sourceURL)
        let estimate = try PDFCompressionEngine.estimate(
            sourceURL: sourceURL,
            originalURL: sourceURL,
            quality: 95,
            helperURL: URL(fileURLWithPath: helperPath)
        )
        defer { try? FileManager.default.removeItem(at: estimate.temporaryURL) }
        #expect(estimate.sourceBytes == original.count)
        #expect(estimate.outputBytes == (try Data(contentsOf: estimate.temporaryURL)).count)
        let compressed = try #require(PDFDocument(url: estimate.temporaryURL))
        #expect(compressed.pageCount == 1)
        let compressedPage = try #require(compressed.page(at: 0))
        let compressedMarkup = try #require(PDFMarkupEngine.edits(in: compressed).first)
        #expect(compressedMarkup.id == managedMarkup.id)
        #expect(compressedMarkup.text == "editable note")
        #expect(compressedPage.annotations.count == 1)
        try PDFCompressionEngine.save(estimate, to: destination, protecting: sourceURL)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: estimate.temporaryURL))
        #expect(try Data(contentsOf: sourceURL) == original)

        let lossless = try PDFCompressionEngine.estimate(
            sourceURL: sourceURL,
            originalURL: sourceURL,
            quality: 0,
            helperURL: URL(fileURLWithPath: helperPath)
        )
        defer { try? FileManager.default.removeItem(at: lossless.temporaryURL) }
        #expect(PDFDocument(url: lossless.temporaryURL)?.pageCount == 1)
    }

    @Test("Save rejects an existing hard-link to the original")
    func rejectsOriginalAlias() throws {
        let sourceURL = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 200, height: 300),
            contentStream: ""
        )
        let aliasURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-compress-test-alias-\(UUID().uuidString).pdf")
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-compress-test-result-\(UUID().uuidString).pdf")
        defer {
            for url in [sourceURL, aliasURL, resultURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try FileManager.default.linkItem(at: sourceURL, to: aliasURL)
        try FileManager.default.copyItem(at: sourceURL, to: resultURL)
        let resultSize = try #require((try FileManager.default.attributesOfItem(atPath: resultURL.path)[.size] as? NSNumber)?.int64Value)
        let estimate = PDFCompressionEstimate(temporaryURL: resultURL, sourceBytes: resultSize, outputBytes: resultSize)
        #expect(throws: PDFCompressionError.outputMatchesInput) {
            try PDFCompressionEngine.save(estimate, to: aliasURL, protecting: sourceURL)
        }
    }
}
