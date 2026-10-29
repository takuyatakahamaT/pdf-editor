import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite("混合編集の設計境界（生成PDF）")
struct PDFHybridEditingBoundaryTests {
    private let pageBounds = CGRect(x: 0, y: 0, width: 240, height: 100)

    private func cidFixture(content: String, toUnicode: String?, customCIDMap: Bool = false) -> URL {
        var font = "<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+SyntheticJP "
            + "/Encoding /Identity-H /DescendantFonts [5 0 R]"
        if toUnicode != nil { font += " /ToUnicode 7 0 R" }
        font += " >>"
        let cidMap = customCIDMap ? "/CIDToGIDMap 8 0 R" : "/CIDToGIDMap /Identity"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] "
                + "/Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>",
            font,
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+SyntheticJP "
                + "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> "
                + "/DW 1000 /W [1 [1000 1000 1000 1000]] \(cidMap) >>",
            RawPDFBuilder.streamObject(dict: "", streamContent: content)
        ]
        if let toUnicode {
            objects.append(RawPDFBuilder.streamObject(dict: "", streamContent: toUnicode))
        }
        if customCIDMap {
            if toUnicode == nil {
                objects.append(RawPDFBuilder.streamObject(dict: "", streamContent: ""))
            }
            objects.append(RawPDFBuilder.streamObject(dict: "", streamContent: "ABCDEFGH"))
        }
        return RawPDFBuilder.build(objects: objects)
    }

    private func simpleFontFixture(content: String, toUnicode: String? = nil) -> URL {
        var font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding"
        if toUnicode != nil { font += " /ToUnicode 6 0 R" }
        font += " >>"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] "
                + "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            font,
            RawPDFBuilder.streamObject(dict: "", streamContent: content)
        ]
        if let toUnicode {
            objects.append(RawPDFBuilder.streamObject(dict: "", streamContent: toUnicode))
        }
        return RawPDFBuilder.build(objects: objects)
    }

    private func formXObjectFixture() -> URL {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] "
                + "/Resources << /Font << /PageFont 4 0 R >> /XObject << /Widget 6 0 R >> >> "
                + "/Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            RawPDFBuilder.streamObject(dict: "", streamContent: "q 1 0 0 1 70 25 cm /Widget Do Q"),
            RawPDFBuilder.streamObject(
                dict: "/Type /XObject /Subtype /Form /FormType 1 /BBox [0 0 100 50] "
                    + "/Matrix [1 0 0 1 10 5] /Resources << /Font << /Inside 4 0 R >> >>",
                streamContent: "BT /Inside 18 Tf 1 0 0 1 4 20 Tm (ABC) Tj ET"
            )
        ]
        return RawPDFBuilder.build(objects: objects)
    }

    private let asciiAToUnicodeMap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin begincmap
        /CMapName /SyntheticLatin def
        /CMapType 2 def
        1 begincodespacerange <00> <FF> endcodespacerange
        1 beginbfchar
        <41> <0041>
        endbfchar
        endcmap CMapName currentdict /CMap defineresource pop end end
        """

    private let japaneseMap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin begincmap
        /CMapName /SyntheticJP def
        /CMapType 2 def
        1 begincodespacerange <0000> <FFFF> endcodespacerange
        3 beginbfchar
        <0001> <65E5>
        <0002> <672C>
        <0003> <8A9E>
        endbfchar
        endcmap CMapName currentdict /CMap defineresource pop end end
        """

    @Test("Form XObject内の文字を変換後の位置から選択し、内側のフォントを解決する")
    @MainActor
    func formXObjectTextIsIndexedAtTransformedPagePosition() throws {
        let url = formXObjectFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(initialURL: url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "ABC" })
        let firstGlyph = try #require(run.glyphs.first)

        #expect(abs(firstGlyph.baseline - 50) < 0.01)
        #expect(abs(firstGlyph.advanceBox.minX - 84) < 0.01)
        #expect(run.fontKey == "Widget\u{1F}Inside")
        let fontDictionary = try #require(PDFGlyphIndex.fontDictionary(for: run.fontKey, page: page))
        #expect(PDFEmbeddedFontLoader.describe(fontDict: fontDictionary).pdfName == "Helvetica")

        let target = try #require(index.cluster(
            at: CGPoint(x: firstGlyph.advanceBox.midX, y: firstGlyph.advanceBox.midY),
            pageIndex: 0
        ))
        #expect(target.originalText == "ABC")
        model.select(target)
        model.updateEditorText("XYZ")
        model.commitEditorText()
        #expect(model.activeReplacements.first?.replacement == "XYZ")

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-text-bench-form-xobject-edit-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: url, edits: model.activeReplacements, to: output)
        let exportedPage = try #require(PDFDocument(url: output)?.page(at: 0))
        #expect(exportedPage.string?.contains("XYZ") == true)
    }

    @Test("重なった置換文字は元文字ではなく最後に描かれたUnicodeグリフを選ぶ")
    @MainActor
    func overlappingReplacementPrefersLatestMappedGlyph() throws {
        let url = simpleFontFixture(content: """
        BT /F1 16 Tf 1 0 0 1 50 40 Tm (9) Tj ET
        BT /F1 16 Tf 1 0 0 1 50 40 Tm (10) Tj ET
        BT /F1 16 Tf 3 Tr 1 0 0 1 50 40 Tm (10) Tj ET
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let hit = try #require(index.run(at: CGPoint(x: 50.5, y: 42)))
        let glyph = hit.run.glyphs[hit.glyphIndex]
        let originalOrder = index.runs.flatMap(\.glyphs).first { $0.text == "9" }?.paintOrder ?? Int.max

        #expect(glyph.text == "1")
        #expect(glyph.textRenderingMode == 3)
        #expect(glyph.paintOrder > originalOrder)
        #expect(hit.run.text != "9")
    }

    @Test("日本語の明示ToUnicodeとsubset名を読めても、元page objectは特定されない")
    func japaneseSubsetMetadata() throws {
        let url = cidFixture(
            content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm <000100020003> Tj ET",
            toUnicode: japaneseMap
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let font = try #require(PDFGlyphIndex.fontDictionary(for: "F1", page: page))
        let description = PDFEmbeddedFontLoader.describe(fontDict: font)
        let info = PDFFontInfoLoader.load(from: font)
        let index = PDFGlyphIndex.makeIndex(for: page)

        #expect(description.isSubset)
        #expect(description.descendantSubtype == "CIDFontType2")
        #expect(info.isIdentityCIDToGID)
        #expect(index.runs.flatMap(\.glyphs).map(\.text).joined() == "日本語")
        // 現行のtargetにstream/operator/SDK page objectのIDはない。
        #expect(index.runs.first?.text == "日本語")
    }

    @Test("同梱日本語フォントから生成した埋め込みサブセットを読める")
    func embeddedJapaneseSubsetFixture() throws {
        PDFEmbeddedFontLoader.registerBundledFonts()
        let font = try #require(NSFont(name: "Noto Sans JP", size: 14))
        let url = try SyntheticFixture.build(pageBounds: pageBounds) { context in
            SyntheticFixture.drawLine(
                "日本語".map { .init(character: $0, font: font) },
                startX: 20,
                baseline: 50,
                gap: 0,
                in: context
            )
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let glyphs = index.runs.flatMap(\.glyphs)
        let fontKey = try #require(glyphs.first?.fontKey)
        let fontDictionary = try #require(PDFGlyphIndex.fontDictionary(for: fontKey, page: page))
        let description = PDFEmbeddedFontLoader.describe(fontDict: fontDictionary)

        #expect(description.isSubset)
        #expect(description.hasEmbeddedProgram)
        #expect(glyphs.count == 3)
        // Quartzのこの書き出しは埋め込みsubsetを作る一方、ToUnicodeを出力しない。
        #expect(glyphs.allSatisfy { $0.text.isEmpty })
    }

    @Test("非Identity CIDToGIDMapは元グリフの直接指定に使えない")
    func nonIdentityCIDMap() throws {
        let url = cidFixture(
            content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm <0001> Tj ET",
            toUnicode: japaneseMap,
            customCIDMap: true
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let font = try #require(PDFGlyphIndex.fontDictionary(for: "F1", page: page))
        let info = PDFFontInfoLoader.load(from: font)
        #expect(info.toUnicode[1] == "日")
        #expect(!info.isIdentityCIDToGID)
    }

    @Test("1コードが複数文字になるToUnicodeは逆引き対象に入らない")
    func multiCharacterToUnicode() throws {
        let map = "1 begincodespacerange <0000> <FFFF> endcodespacerange "
            + "1 beginbfchar <0001> <00660069> endbfchar"
        let url = cidFixture(
            content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm <0001> Tj ET",
            toUnicode: map
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let font = try #require(PDFGlyphIndex.fontDictionary(for: "F1", page: page))
        let info = PDFFontInfoLoader.load(from: font)
        let glyph = try #require(PDFGlyphIndex.makeIndex(for: page).runs.first?.glyphs.first)
        #expect(glyph.text == "fi")
        #expect(info.unicodeToCode["fi"] == nil)
    }

    @Test("分割Tj/TJは見た目では一つのrunにまとまる")
    func fragmentedShowOperations() throws {
        let url = RawPDFBuilder.singlePagePDF(
            pageBounds: pageBounds,
            contentStream: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj [(B) 0 (C)] TJ ET"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "ABC" })
        let target = try #require(index.target(in: run, range: 0..<3, pageIndex: 0))
        #expect(target.originalText == "ABC")
        #expect(target.lineLayout != nil)
        // 元の3つのshow operandに戻すprovenanceはTextTargetに保持されない。
    }

    @Test("ToUnicodeがない選択は空文字となり、警告付きoverlayを書き出して画像化できる")
    @MainActor
    func unmappedOverlayStatusAndRasterization() throws {
        let url = cidFixture(
            content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm <0004> Tj ET",
            toUnicode: nil
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(initialURL: url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first)
        #expect(run.glyphs.count == 1)
        #expect(run.glyphs[0].text.isEmpty)
        let target = try #require(index.target(in: run, range: 0..<1, pageIndex: 0))
        #expect(target.originalText.isEmpty)
        #expect(target.lineLayout == nil)

        model.select(target)
        model.replacementText = "代替"
        model.applyReplacement()
        #expect(model.edits.count == 1)
        #expect(model.statusMessage.contains("白い重ね描き"))
        #expect(model.statusMessage.contains("元の文字データはPDF内に残ります"))
        #expect(model.statusMessage.contains("墨消しには使えません"))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-hybrid-boundary-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: url, edits: model.activeReplacements, to: output)
        let exported = try #require(PDFDocument(url: output))
        #expect(exported.pageCount == 1)
        let cgDocument = try #require(CGPDFDocument(output as CFURL))
        let cgPage = try #require(cgDocument.page(at: 1))
        let context = try #require(CGContext(
            data: nil, width: 480, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: 2, y: 2)
        context.drawPDFPage(cgPage)
        #expect(context.makeImage() != nil)
    }

    @Test("ASCII補完で読めてもoverlayの原文残存を警告する")
    @MainActor
    func asciiFallbackReplacementStatus() throws {
        let url = simpleFontFixture(
            content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(initialURL: url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first)
        let target = try #require(index.target(in: run, range: 0..<1, pageIndex: 0))
        #expect(target.originalText == "A")
        #expect(!target.hasExplicitSourceMapping)
        model.select(target)
        model.replacementText = "B"
        model.applyReplacement()
        #expect(model.edits.count == 1)
        #expect(model.statusMessage.contains("元の文字データはPDF内に残ります"))
        #expect(model.statusMessage.contains("墨消しには使えません"))
    }

    @Test("ToUnicodeで全グリフを解決できてもoverlayの原文残存を警告する")
    @MainActor
    func explicitToUnicodeReplacementStatus() throws {
        let url = simpleFontFixture(
            content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET",
            toUnicode: asciiAToUnicodeMap
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(initialURL: url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first)
        let target = try #require(index.target(in: run, range: 0..<1, pageIndex: 0))

        #expect(target.originalText == "A")
        #expect(target.hasExplicitSourceMapping)
        model.select(target)
        model.replacementText = "B"
        model.applyReplacement()
        #expect(model.edits.count == 1)
        #expect(model.statusMessage.contains("元の文字データはPDF内に残ります"))
        #expect(model.statusMessage.contains("墨消しには使えません"))
    }

    @Test("選択内にToUnicode未対応グリフが混ざっても同じoverlay警告を出す")
    @MainActor
    func mixedExplicitAndFallbackSelectionWarns() throws {
        let url = simpleFontFixture(
            content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (AB) Tj ET",
            toUnicode: asciiAToUnicodeMap
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(initialURL: url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first)
        let target = try #require(index.target(in: run, range: 0..<2, pageIndex: 0))

        #expect(run.glyphs.map(\.hasExplicitToUnicodeMapping) == [true, false])
        #expect(target.originalText == "A")
        #expect(!target.hasExplicitSourceMapping)
        model.select(target)
        model.replacementText = "CD"
        model.applyReplacement()
        #expect(model.edits.count == 1)
        #expect(model.statusMessage.contains("元の文字データはPDF内に残ります"))
        #expect(model.statusMessage.contains("墨消しには使えません"))
    }
}
