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
        #expect(PDFDocument(url: estimate.temporaryURL)?.pageCount == 1)
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
