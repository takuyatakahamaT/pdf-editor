import AppKit
import CoreText
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite(.serialized)
struct PDFOCREngineTests {
    @Test("separate OCR stream is searchable and removable without source embedding")
    func separateLayerRoundTrip() throws {
        let source = try makeImagePDF()
        defer { try? FileManager.default.removeItem(at: source) }
        let sourceData = try Data(contentsOf: source)
        let line = PDFOCRLine(pageIndex: 0, text: "日本語 OCR",
                              confidence: 0.9,
                              bounds: CGRect(x: 0.1, y: 0.3, width: 0.6, height: 0.2))
        let layered = try PDFOCRLayerWriter.add(linesByPage: [0: [line]], to: sourceData)
        #expect(PDFOCRLayerWriter.hasLayer(in: layered))
        #expect(layered.count < sourceData.count * 2)
        let layeredDoc = try #require(PDFDocument(data: layered))
        #expect(layeredDoc.findString("日本語", withOptions: []).count == 1)
        #expect(layeredDoc.findString("OCR", withOptions: []).count == 1)
        #expect(PDFSearchEngine.search(document: layeredDoc, query: "日本語").count == 1)
        #expect(layeredDoc.findString("日本語", withOptions: []).first?.string == "日本語")
        let glyphs = PDFGlyphIndex.makeIndex(for: try #require(layeredDoc.page(at: 0)))
            .runs.flatMap(\.glyphs)
        #expect(glyphs.map(\.text).joined().contains("日本語 OCR"))
        let stripped = try PDFOCRLayerWriter.removingLayer(from: layered)
        let strippedDoc = try #require(PDFDocument(data: stripped))
        #expect(strippedDoc.findString("日本語", withOptions: []).isEmpty)
        #expect(strippedDoc.findString("OCR", withOptions: []).isEmpty)
        #expect(raster(try #require(layeredDoc.page(at: 0))) ==
                raster(try #require(strippedDoc.page(at: 0))))
        let layeredURL = temporaryPDF()
        let cleanURL = temporaryPDF()
        defer {
            try? FileManager.default.removeItem(at: layeredURL)
            try? FileManager.default.removeItem(at: cleanURL)
        }
        try layered.write(to: layeredURL)
        try PDFOCREngine.removeLayer(sourceURL: layeredURL, outputURL: cleanURL)
        let cleanBytes = try Data(contentsOf: cleanURL)
        #expect(!PDFOCRLayerWriter.hasLayer(in: cleanBytes))
        #expect(!String(decoding: cleanBytes, as: UTF8.self).contains("PDFTextEditorOCRStream"))
        let cleanDoc = try #require(PDFDocument(url: cleanURL))
        #expect(cleanDoc.findString("日本語", withOptions: []).isEmpty)
        #expect(raster(try #require(cleanDoc.page(at: 0))) ==
                raster(try #require(layeredDoc.page(at: 0))))
    }

    @Test("OCR adds searchable selectable text, preserves page image and source bytes")
    func searchableLayerAndPreservation() throws {
        let source = try makeImagePDF()
        defer { try? FileManager.default.removeItem(at: source) }
        let originalBytes = try Data(contentsOf: source)
        let before = try #require(PDFDocument(url: source))
        let beforePage = try #require(before.page(at: 0))
        #expect((beforePage.string ?? "").isEmpty)
        let beforeImage = raster(beforePage)
        let output = temporaryPDF()
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try PDFOCREngine.recognize(sourceURL: source, outputURL: output,
                                                selectedPages: [0], languages: ["en-US"],
                                                recognizePage: { _, pageIndex, _ in
            [PDFOCRLine(pageIndex: pageIndex, text: "CLEAR OCR SAMPLE", confidence: 0.93,
                        bounds: CGRect(x: 0.05, y: 0.3, width: 0.9, height: 0.35))]
        })
        #expect(result.processedPages == [0])
        #expect(try Data(contentsOf: source) == originalBytes)
        let after = try #require(PDFDocument(url: output))
        let page = try #require(after.page(at: 0))
        #expect(PDFOCREngine.hasLayer(url: output))
        let outputBytes = try Data(contentsOf: output)
        #expect(outputBytes.starts(with: originalBytes))
        #expect(page.bounds(for: .mediaBox) == beforePage.bounds(for: .mediaBox))
        #expect(page.rotation == beforePage.rotation)
        #expect(raster(page) == beforeImage)
        let recognized = try #require(page.string?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(recognized.count >= 3)
        let word = try #require(recognized.split(whereSeparator: \.isWhitespace).first.map(String.init))
        #expect(!PDFSearchEngine.search(document: after, query: word).isEmpty)
        let selection = try #require(after.findString(word, withOptions: [.caseInsensitive]).first)
        #expect(selection.string?.isEmpty == false)
    }

    @Test("range leaves other pages intact; rerun replaces layer; removal restores source")
    func rangeRerunAndRemoval() throws {
        let source = try makeImagePDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let originalBytes = try Data(contentsOf: source)
        let first = temporaryPDF()
        let second = temporaryPDF()
        let restored = temporaryPDF()
        defer {
            for url in [first, second, restored] { try? FileManager.default.removeItem(at: url) }
        }
        let sourceDoc = try #require(PDFDocument(url: source))
        let selected = try PDFCropEngine.pageIndices(from: "2", pageCount: sourceDoc.pageCount)
        let fakeRecognition: (PDFPage, Int, [String]) throws -> [PDFOCRLine] = { _, pageIndex, _ in
            [PDFOCRLine(pageIndex: pageIndex, text: "Synthetic OCR page \(pageIndex + 1)",
                        confidence: 0.91, bounds: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.3))]
        }
        let firstResult = try PDFOCREngine.recognize(sourceURL: source, outputURL: first,
                                                     selectedPages: selected, languages: ["en-US"],
                                                     recognizePage: fakeRecognition)
        #expect(firstResult.processedPages == [1])
        let once = try #require(PDFDocument(url: first))
        let untouchedText = once.page(at: 0)?.string ?? ""
        #expect(untouchedText.isEmpty)
        let onceText = try #require(once.page(at: 1)?.string)
        #expect(!onceText.isEmpty)
        _ = try PDFOCREngine.recognize(sourceURL: first, outputURL: second,
                                       selectedPages: selected, languages: ["en-US"],
                                       recognizePage: fakeRecognition)
        let twice = try #require(PDFDocument(url: second))
        let twiceText = try #require(twice.page(at: 1)?.string)
        #expect(twiceText.count <= onceText.count * 2)
        let word = try #require(onceText.split(whereSeparator: \.isWhitespace).first.map(String.init))
        #expect(twice.findString(word, withOptions: [.caseInsensitive]).count == 1)
        try PDFOCREngine.removeLayer(sourceURL: second, outputURL: restored)
        #expect(try Data(contentsOf: source) == originalBytes)
        let restoredDoc = try #require(PDFDocument(url: restored))
        #expect(restoredDoc.findString(word, withOptions: []).isEmpty)
        for index in 0..<sourceDoc.pageCount {
            let originalPage = try #require(sourceDoc.page(at: index))
            let restoredPage = try #require(restoredDoc.page(at: index))
            #expect(originalPage.bounds(for: .mediaBox) == restoredPage.bounds(for: .mediaBox))
            #expect(originalPage.rotation == restoredPage.rotation)
            #expect(raster(originalPage) == raster(restoredPage))
        }
    }

    @Test("Japanese recognition results are stored and searchable")
    func japaneseRecognitionLayer() throws {
        let source = try makeImagePDF(text: "日本語の資料", fontName: "Hiragino Sans")
        let output = temporaryPDF()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        _ = try PDFOCREngine.recognize(sourceURL: source, outputURL: output,
                                       selectedPages: [0], languages: ["ja-JP"],
                                       recognizePage: { _, pageIndex, languages in
            #expect(languages == ["ja-JP"])
            return [PDFOCRLine(pageIndex: pageIndex, text: "日本語の資料", confidence: 0.88,
                               bounds: CGRect(x: 0.08, y: 0.3, width: 0.84, height: 0.35))]
        })
        let document = try #require(PDFDocument(url: output))
        let text = try #require(document.page(at: 0)?.string)
        #expect(text.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) ||
            (0x4e00...0x9fff).contains($0.value) })
        #expect(!PDFSearchEngine.search(document: document,
                                        query: String(text.prefix(2))).isEmpty)
    }

    @Test("Vision can recognize Japanese scan when explicitly enabled",
          .enabled(if: ProcessInfo.processInfo.environment["PDF_EDITOR_RUN_VISION_OCR_TESTS"] == "1",
                   "Set PDF_EDITOR_RUN_VISION_OCR_TESTS=1 to exercise the on-device Vision model."))
    func japaneseVisionIntegration() throws {
        let source = try makeImagePDF(text: "日本語の資料", fontName: "Hiragino Sans")
        let output = temporaryPDF()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        _ = try PDFOCREngine.recognize(sourceURL: source, outputURL: output,
                                       selectedPages: [0], languages: ["ja-JP"])
        let document = try #require(PDFDocument(url: output))
        let text = try #require(document.page(at: 0)?.string)
        #expect(text.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) ||
            (0x4e00...0x9fff).contains($0.value) })
    }

    @Test("recognition failure leaves the source unchanged and creates no output")
    func recognitionFailurePreservesSource() throws {
        let source = try makeImagePDF()
        defer { try? FileManager.default.removeItem(at: source) }
        let before = try Data(contentsOf: source)
        let output = temporaryPDF()
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(throws: PDFOCRError.recognitionFailed) {
            try PDFOCREngine.recognize(sourceURL: source, outputURL: output,
                                       selectedPages: [0], languages: ["en-US"],
                                       recognizePage: { _, _, _ in throw PDFOCRError.recognitionFailed })
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private func makeImagePDF(pageCount: Int = 1,
                              text: String = "CLEAR OCR SAMPLE",
                              fontName: String = "Helvetica-Bold") throws -> URL {
        let bitmap = CGContext(data: nil, width: 1200, height: 500,
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 1200, height: 500))
        let font = CTFontCreateWithName(fontName as CFString, 105, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.black]
        ))
        bitmap.textPosition = CGPoint(x: 35, y: 205)
        CTLineDraw(line, bitmap)
        let image = bitmap.makeImage()!
        let url = temporaryPDF()
        var box = CGRect(x: 0, y: 0, width: 600, height: 250)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PDFOCRError.cannotRender
        }
        for _ in 0..<pageCount {
            pdf.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
            pdf.draw(image, in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return url
    }

    private func temporaryPDF() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdf-ocr-test-\(UUID().uuidString).pdf")
    }

    private func raster(_ page: PDFPage) -> Data {
        let bitmap = CGContext(data: nil, width: 600, height: 250,
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 600, height: 250))
        page.draw(with: .mediaBox, to: bitmap)
        return bitmap.data.map { Data(bytes: $0, count: 600 * 250 * 4) } ?? Data()
    }
}
