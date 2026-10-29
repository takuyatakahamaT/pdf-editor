import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite("PDFium内部テキスト置換（生成PDF）", .serialized)
struct PDFInternalTextEditEngineTests {
    private let pageBounds = CGRect(x: 0, y: 0, width: 240, height: 100)

    private var asciiToUnicode: String { """
        /CIDInit /ProcSet findresource begin
        12 dict begin begincmap
        /CMapName /InternalEditLatin def
        /CMapType 2 def
        1 begincodespacerange <00> <FF> endcodespacerange
        95 beginbfchar
        \((32...126).map { String(format: "<%02X> <%04X>", $0, $0) }.joined(separator: "\n"))
        endbfchar
        endcmap CMapName currentdict /CMap defineresource pop end end
        """ }

    private func fixture(content: String, withLink: Bool = false) -> URL {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] "
                + "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R "
                + (withLink ? "/Annots [7 0 R] >>" : ">>"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            RawPDFBuilder.streamObject(dict: "", streamContent: content),
            RawPDFBuilder.streamObject(dict: "", streamContent: asciiToUnicode)
        ]
        if withLink {
            objects.append("<< /Type /Annot /Subtype /Link /Rect [150 40 190 60] /Border [0 0 0] "
                + "/A << /S /URI /URI (https://example.com) >> >>")
        }
        return RawPDFBuilder.build(objects: objects)
    }

    private func pdfiumIsConfigured() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["PDFIUM_LIBRARY_PATH"] ?? environment["PDFIUM_PATH"]
        return path.map { FileManager.default.fileExists(atPath: $0) } == true
    }

    private func rangeEdit(source: URL, text: String, range: Range<Int>, replacement: String, occurrence: Int = 0) throws -> ReplacementEdit {
        let document = try #require(PDFDocument(url: source))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let matchingRuns = index.runs.filter { $0.text == text }
        let run = try #require(matchingRuns.indices.contains(occurrence) ? matchingRuns[occurrence] : nil)
        let target = try #require(index.target(in: run, range: range, pageIndex: 0))
        var edit: ReplacementEdit
        if replacement.isEmpty {
            edit = ReplacementEdit(deleting: target)
        } else {
            let font = PDFEditEngine.resolveFont(for: target, on: page, replacement: replacement)
            edit = ReplacementEdit(target: target, replacement: replacement, resolvedFont: font.font, fontIsExact: font.isExact, exactGlyphs: font.exactGlyphs)
        }
        edit.storage = .internalPDFium
        return edit
    }

    @Test("日付の部分選択を灰背景と罫線上で置換し、同値の別位置と未選択glyphを保持する")
    func partialDateAndRepeatedSource() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: """
            0.8 g 10 35 200 35 re f 0 G 0.5 w 10 35 200 35 re S
            0 g BT /F1 14 Tf 1 0 0 1 20 50 Tm (2026/10/29) Tj ET
            BT /F1 14 Tf 1 0 0 1 20 20 Tm (2026/10/29) Tj ET
            """)
        let output = source.deletingLastPathComponent().appendingPathComponent("partial-date-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let edit = try rangeEdit(source: source, text: "2026/10/29", range: 8..<10, replacement: "28")
        #expect(PDFInternalTextEditEngine.eligibility(sourceURL: source, edit: edit) == .supported)
        try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [edit], to: output)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("2026/10/28"))
        #expect(text.contains("2026/10/29"))
        try PDFInternalTextEditEngine.verifyFinalOutput(sourceURL: source, outputURL: output, edits: [edit])
    }

    @Test("調整付きTJの部分編集とquote演算子を実originで保存する")
    func adjustedTJAndQuote() throws {
        guard pdfiumIsConfigured() else { return }
        for content in [
            "BT /F1 14 Tf 1 0 0 1 20 50 Tm [(AB) -35 (CD)] TJ ET",
            "BT /F1 14 Tf 0 TL 1 0 0 1 20 50 Tm (ABCD) ' ET",
            "BT /F1 14 Tf 0 TL 1 0 0 1 20 50 Tm 0 0 (ABCD) \" ET"
        ] {
            let source = fixture(content: content)
            let output = source.deletingLastPathComponent().appendingPathComponent("adjusted-tj-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
            let edit = try rangeEdit(source: source, text: "ABCD", range: 1..<2, replacement: "E")
            try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [edit], to: output)
            #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains("AECD") == true)
        }
    }

    @Test("選択文字だけを内部削除し、object全体削除にも対応する")
    func removeSelectedCharacters() throws {
        guard pdfiumIsConfigured() else { return }
        for range in [1..<3, 0..<4] {
            let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm [(AB) -35 (CD)] TJ ET")
            let output = source.deletingLastPathComponent().appendingPathComponent("remove-range-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
            let edit = try rangeEdit(source: source, text: "ABCD", range: range, replacement: "")
            try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [edit], to: output)
            let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
            #expect(!text.contains("B") && !text.contains("C"))
            if range == 1..<3 { #expect(text.contains("A") && text.contains("D")) }
        }
    }

    @Test("同一objectの重複範囲編集を拒否し既存出力を保持する")
    func collidingPartialEditsKeepExistingOutput() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (ABCD) Tj ET")
        let output = source.deletingLastPathComponent().appendingPathComponent("colliding-ranges-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let sentinel = Data("existing output".utf8)
        try sentinel.write(to: output)
        let first = try rangeEdit(source: source, text: "ABCD", range: 0..<1, replacement: "E")
        let second = try rangeEdit(source: source, text: "ABCD", range: 0..<2, replacement: "E")
        #expect(throws: (any Error).self) { try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [first, second], to: output) }
        #expect(try Data(contentsOf: output) == sentinel)
    }

    @Test("同一objectの別範囲への編集と削除を元originで同時保存する")
    func combineDisjointRangesInOneObject() throws {
        guard pdfiumIsConfigured() else { return }
        for replacements in [("B", "D"), ("", "D"), ("", "")] {
            let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm [(AB) -35 (CDE)] TJ ET")
            let output = source.deletingLastPathComponent().appendingPathComponent("combined-ranges-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
            let first = try rangeEdit(source: source, text: "ABCDE", range: 0..<1, replacement: replacements.0)
            let second = try rangeEdit(source: source, text: "ABCDE", range: 2..<3, replacement: replacements.1)
            try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [first, second], to: output)
            let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
            let expected = replacements.0 + "B" + replacements.1 + "DE"
            #expect(text.replacingOccurrences(of: " ", with: "").contains(expected))
            try PDFInternalTextEditEngine.verifyFinalOutput(sourceURL: source, outputURL: output, edits: [first, second])
        }
    }

    @Test("部分編集で選択外の実spaceも元originへ保持する")
    func preservesUnselectedSpaces() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (AB CD) Tj ET")
        let output = source.deletingLastPathComponent().appendingPathComponent("retained-space-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let edit = try rangeEdit(source: source, text: "AB CD", range: 1..<2, replacement: "E")
        try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [edit], to: output)
        #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains("AE CD") == true)
        let removal = try rangeEdit(source: source, text: "AB CD", range: 0..<5, replacement: "")
        try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [removal], to: output)
        let removedText = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
        #expect(removedText.isEmpty)
    }

    @Test("1 Tfと一様scaleで記録された文字を実効サイズのまま部分・全体編集する")
    func uniformlyScaledTextObject() throws {
        guard pdfiumIsConfigured() else { return }
        for (range, replacement, expected) in [(1..<2, "E", "AECD"), (0..<4, "ABCE", "ABCE")] {
            let source = fixture(content: "BT /F1 1 Tf 14 0 0 14 20 50 Tm (ABCD) Tj ET")
            let output = source.deletingLastPathComponent().appendingPathComponent("uniform-scale-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
            let edit = try rangeEdit(source: source, text: "ABCD", range: range, replacement: replacement)
            try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [edit], to: output)
            #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains(expected) == true)
        }
    }

    @Test("同一objectで元fontの置換と日本語の透明再描画を混ぜても両方を検証する")
    func combinesNativeAndReconstructedRanges() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (ABCDE) Tj ET")
        let output = source.deletingLastPathComponent().appendingPathComponent("mixed-ranges-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let first = try rangeEdit(source: source, text: "ABCDE", range: 0..<1, replacement: "B")
        var second = try rangeEdit(source: source, text: "ABCDE", range: 2..<5, replacement: "東京")
        second.storage = PDFTextEditPlanner.storage(sourceURL: source, edit: second)
        #expect(second.storage == .reconstructed)
        try PDFExportEngine.export(sourceURL: source, edits: [first, second], to: output)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("BB"))
        #expect(text.contains("東京"))
        #expect(!text.contains("CDE"))
    }

    @Test("同一objectの別範囲を再編集してもundo/redoで両方の編集を保持する")
    @MainActor
    func modelKeepsDisjointEditsThroughUndoRedo() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (ABCDE) Tj ET")
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "ABCDE" })
        for (range, replacement) in [(0..<1, "B"), (2..<3, "D")] {
            let target = try #require(index.target(in: run, range: range, pageIndex: 0))
            model.select(target)
            model.updateEditorText(replacement)
            model.commitEditorText()
        }
        #expect(model.activeReplacements.count == 2)
        #expect(model.activeReplacements.allSatisfy { $0.storage == .internalPDFium })
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("BBDDE") == true)
        model.undoLastEdit()
        #expect(model.activeReplacements.count == 1)
        model.redoLastEdit()
        #expect(model.activeReplacements.count == 2)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("BBDDE") == true)
    }

    @Test("日本語の埋込fontでも日付の部分置換と削除を内部保存する")
    func japanesePartialDate() throws {
        guard pdfiumIsConfigured() else { return }
        let fontURL = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
        let fontData = try Data(contentsOf: fontURL)
        let provider = try #require(CGDataProvider(url: fontURL as CFURL))
        let graphicsFont = try #require(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 1000, nil, nil)
        let characters = Array("年月日".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        #expect(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
        let mapping = zip(glyphs, characters).map { String(format: "<%04X> <%04X>", $0.0, $0.1) }.joined(separator: "\n")
        let widths = glyphs.map { glyph -> String in
            var glyph = glyph
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            return "\(glyph) [\(Int(advance.width.rounded()))]"
        }.joined(separator: " ")
        let hex = (glyphs + glyphs).map { String(format: "%04X", $0) }.joined()
        let cmap = """
            /CIDInit /ProcSet findresource begin 12 dict begin begincmap
            /CMapName /JapanesePartial def /CMapType 2 def
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            3 beginbfchar \(mapping) endbfchar
            endcmap CMapName currentdict /CMap defineresource pop end end
            """
        let bbox = CTFontGetBoundingBox(font)
        let content = "0.8 g 10 35 220 35 re f 0 G 10 35 220 35 re S 0 g BT /F1 14 Tf 1 0 0 1 20 50 Tm <\(hex)> Tj ET"
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 9 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type0 /BaseFont /ArialUnicodeMS /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 8 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ArialUnicodeMS /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /CIDToGIDMap /Identity /DW 1000 /W [\(widths)] >>".utf8),
            Data("<< /Type /FontDescriptor /FontName /ArialUnicodeMS /Flags 4 /FontBBox [\(Int(bbox.minX)) \(Int(bbox.minY)) \(Int(bbox.maxX)) \(Int(bbox.maxY))] /ItalicAngle 0 /Ascent \(Int(CTFontGetAscent(font))) /Descent \(-Int(CTFontGetDescent(font))) /CapHeight 700 /StemV 80 /FontFile2 7 0 R >>".utf8),
            RawPDFBuilder.streamObject(dict: "/Length1 \(fontData.count)", streamData: fontData),
            RawPDFBuilder.streamObject(dict: "", streamData: Data(cmap.utf8)),
            RawPDFBuilder.streamObject(dict: "", streamData: Data(content.utf8))
        ]
        let source = RawPDFBuilder.build(objects: objects)
        defer { try? FileManager.default.removeItem(at: source) }
        for replacement in ["日", ""] {
            let output = source.deletingLastPathComponent().appendingPathComponent("japanese-partial-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: output) }
            let edit = try rangeEdit(source: source, text: "年月日年月日", range: 1..<2, replacement: replacement)
            try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [edit], to: output)
            let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
            #expect(text.replacingOccurrences(of: " ", with: "").contains(replacement.isEmpty ? "年日年月日" : "年日日年月日"))
        }
    }

    private func embeddedTrueTypeFixture(
        sourceText: String = "DETAILS",
        mappedReplacement: String = "1"
    ) throws -> URL {
        let fontURL = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        let fontData = try Data(contentsOf: fontURL)
        guard let provider = CGDataProvider(url: fontURL as CFURL),
              let graphicsFont = CGFont(provider) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 1000, nil, nil)
        let widths = (0...255).map { code -> String in
            var character = UniChar(code)
            var glyph: CGGlyph = 0
            var advance = CGSize.zero
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0,
                  CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1) > 0 else {
                return "0"
            }
            return String(format: "%.0f", advance.width)
        }.joined(separator: " ")
        func toUnicodeCMap(for text: String, name: String) -> String {
            let mappedCharacters = Set(text).sorted()
            let entries = mappedCharacters.map { character -> String in
                let scalar = character.unicodeScalars.first!.value
                return String(format: "<%02X> <%04X>", scalar, scalar)
            }.joined(separator: "\n")
            return """
                /CIDInit /ProcSet findresource begin
                12 dict begin begincmap
                /CMapName /\(name) def
                /CMapType 2 def
                1 begincodespacerange <00> <FF> endcodespacerange
                \(mappedCharacters.count) beginbfchar
                \(entries)
                endbfchar
                endcmap CMapName currentdict /CMap defineresource pop end end
                """
        }
        let toUnicode = toUnicodeCMap(for: sourceText, name: "EmbeddedSource")
        let donorToUnicode = toUnicodeCMap(for: mappedReplacement, name: "EmbeddedDonor")
        let sourceHex = sourceText.utf8.map { String(format: "%02X", $0) }.joined()
        let content = """
            0.82 g 10 35 180 30 re f
            0 G 0.7 w 10 35 180 30 re S
            0 g BT /F1 9 Tf 1 0 0 1 20 49 Tm <\(sourceHex)> Tj ET
            BT /F2 9 Tf 3 Tr 1 0 0 1 220 10 Tm <31> Tj ET
            """
        let bbox = CTFontGetBoundingBox(font)
        let descriptor = """
            << /Type /FontDescriptor /FontName /ArialMT /Flags 32
            /FontBBox [\(Int(bbox.minX)) \(Int(bbox.minY)) \(Int(bbox.maxX)) \(Int(bbox.maxY))]
            /ItalicAngle 0 /Ascent \(Int(CTFontGetAscent(font))) /Descent \(-Int(CTFontGetDescent(font)))
            /CapHeight \(Int(CTFontGetCapHeight(font))) /StemV 80 /MissingWidth 500 /FontFile2 7 0 R >>
            """
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] "
                + "/Resources << /Font << /F1 4 0 R /F2 9 0 R >> >> /Contents 8 0 R >>").utf8),
            Data(("<< /Type /Font /Subtype /TrueType /BaseFont /ABCDEF+ArialMT /Encoding /WinAnsiEncoding "
                + "/FirstChar 0 /LastChar 255 /Widths [\(widths)] "
                + "/FontDescriptor 5 0 R /ToUnicode 6 0 R >>").utf8),
            Data(descriptor.utf8),
            RawPDFBuilder.streamObject(dict: "", streamData: Data(toUnicode.utf8)),
            RawPDFBuilder.streamObject(dict: "/Length1 \(fontData.count)", streamData: fontData),
            RawPDFBuilder.streamObject(dict: "", streamData: Data(content.utf8)),
            Data(("<< /Type /Font /Subtype /TrueType /BaseFont /GHIJKL+ArialMT /Encoding /WinAnsiEncoding "
                + "/FirstChar 0 /LastChar 255 /Widths [\(widths)] "
                + "/FontDescriptor 5 0 R /ToUnicode 10 0 R >>").utf8),
            RawPDFBuilder.streamObject(dict: "", streamData: Data(donorToUnicode.utf8))
        ]
        return RawPDFBuilder.build(objects: objects)
    }

    @MainActor
    private func replacementModel(source: URL, replacement: String) throws -> EditorModel {
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { !$0.text.isEmpty })
        let target = try #require(index.target(in: run, range: 0..<run.glyphs.count, pageIndex: 0))
        model.select(target)
        model.updateEditorText(replacement)
        model.commitEditorText()
        return model
    }

    @Test("単一object全体を保存・再読込し、原文を現在の抽出結果から除く")
    @MainActor
    func supportedWholeObjectSaveAndReopen() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET")
        let sourceData = try Data(contentsOf: source)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-supported-\(UUID().uuidString).pdf")
        let reopenedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-reopened-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: reopenedOutput)
        }

        let model = try replacementModel(source: source, replacement: "B")
        let edit = try #require(model.activeReplacements.first)
        #expect(edit.storage == .internalPDFium)
        // 元PDFを変えず、画面には保存と同じ内部編集PDFを表示する。
        #expect(model.document?.page(at: 0)?.string?.contains("A") == true)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("B") == true)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("A") == false)
        #expect(try Data(contentsOf: source) == sourceData)

        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        let reopened = try #require(PDFDocument(url: output))
        #expect(reopened.page(at: 0)?.string?.contains("B") == true)
        #expect(reopened.page(at: 0)?.string?.contains("A") == false)
        #expect(PDFDocument(url: source)?.page(at: 0)?.string?.contains("A") == true)
        #expect(try Data(contentsOf: source) == sourceData)

        let reopenedModel = try replacementModel(source: output, replacement: "E")
        let reopenedEdit = try #require(reopenedModel.activeReplacements.first)
        #expect(reopenedEdit.storage == .internalPDFium)
        try PDFExportEngine.export(sourceURL: output, edits: [reopenedEdit], to: reopenedOutput)
        let editedAgain = try #require(PDFDocument(url: reopenedOutput)?.page(at: 0)?.string)
        #expect(editedAgain.contains("E"))
        #expect(!editedAgain.contains("B"))
    }

    @Test("別々の文字objectを同時に内部置換し、元のリンクを保持する")
    @MainActor
    func multipleInternalEditsPreserveLink() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(
            content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET "
                + "BT /F1 14 Tf 1 0 0 1 20 20 Tm (C) Tj ET",
            withLink: true
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-multiple-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        for (oldText, newText) in [("A", "E"), ("C", "D")] {
            let index = PDFGlyphIndex.makeIndex(for: page)
            let run = try #require(index.runs.first { $0.text == oldText })
            let target = try #require(index.target(in: run, range: 0..<run.glyphs.count, pageIndex: 0))
            model.select(target)
            model.updateEditorText(newText)
            model.commitEditorText()
        }
        let edits = model.activeReplacements
        #expect(edits.count == 2)
        #expect(edits.allSatisfy { $0.storage == .internalPDFium })
        try PDFExportEngine.export(sourceURL: source, edits: edits, to: output)
        let outputPage = try #require(PDFDocument(url: output)?.page(at: 0))
        let text = try #require(outputPage.string)
        #expect(text.contains("E") && text.contains("D"))
        #expect(!text.contains("A") && !text.contains("C"))
        #expect(outputPage.annotations.contains { $0.type == "Link" })
    }

    @Test("別の場所の原文と同じ置換文字でも位置で検証して内部保存する")
    @MainActor
    func conflictingInternalEditSetFallsBackBeforeCommit() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(
            content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET "
                + "BT /F1 14 Tf 1 0 0 1 20 20 Tm (C) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))

        for (oldText, newText) in [("A", "B"), ("C", "A")] {
            let index = PDFGlyphIndex.makeIndex(for: page)
            let run = try #require(index.runs.first { $0.text == oldText })
            let target = try #require(index.target(in: run, range: 0..<run.glyphs.count, pageIndex: 0))
            model.select(target)
            model.updateEditorText(newText)
            model.commitEditorText()
        }

        let edits = model.activeReplacements
        #expect(edits.count == 2)
        #expect(edits.allSatisfy { $0.storage == .internalPDFium })
        #expect(model.displayedDocument != nil)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("B") == true)
    }

    @Test("内部置換プレビューへ追加テキストのドラフトと再編集を同期する")
    @MainActor
    func insertionDraftStaysVisibleOnInternalPreview() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET")
        defer { try? FileManager.default.removeItem(at: source) }
        let model = try replacementModel(source: source, replacement: "B")

        model.setMode(.insertion)
        model.beginInsertion(pageIndex: 0, point: CGPoint(x: 80, y: 50))
        model.updateEditorText("draft")
        var draft = try #require(model.displayedDocument?.page(at: 0)?.annotations.first {
            $0.userName == PDFEditEngine.draftMarker
        })
        #expect(draft.contents == "draft")

        model.commitEditorText()
        let insertion = try #require(model.activeReplacements.first { $0.kind == .insertion })
        model.beginReeditingInsertion(id: insertion.id)
        model.updateEditorText("updated")
        draft = try #require(model.displayedDocument?.page(at: 0)?.annotations.first {
            $0.userName == PDFEditEngine.draftMarker
        })
        #expect(draft.contents == "updated")
        #expect(model.displayedDocument?.page(at: 0)?.annotations.contains {
            $0.userName == PDFEditEngine.annotationMarkerPrefix + insertion.id.uuidString
        } == false)

        model.cancelInsertionEditing()
        #expect(model.displayedDocument?.page(at: 0)?.annotations.contains {
            $0.userName == PDFEditEngine.annotationMarkerPrefix + insertion.id.uuidString
        } == true)
        #expect(model.displayedDocument?.page(at: 0)?.annotations.contains {
            $0.userName == PDFEditEngine.draftMarker
        } == false)
    }

    @Test("同じ選択を再編集しても内部状態とundo/redoを保つ")
    @MainActor
    func reeditingPreservesInternalStateAndUndoRedo() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-reedit-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let model = try replacementModel(source: source, replacement: "B")
        let first = try #require(model.activeReplacements.first)
        model.beginReeditingReplacement(id: first.id)
        model.updateEditorText("V")
        model.commitEditorText()
        #expect(model.activeReplacements.first?.replacement == "V")
        #expect(model.activeReplacements.first?.storage == .internalPDFium)

        model.undoLastEdit()
        #expect(model.activeReplacements.first?.replacement == "B")
        #expect(model.activeReplacements.first?.storage == .internalPDFium)
        model.redoLastEdit()
        let redone = try #require(model.activeReplacements.first)
        #expect(redone.replacement == "V")
        #expect(redone.storage == .internalPDFium)

        try PDFExportEngine.export(sourceURL: source, edits: [redone], to: output)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("V"))
        #expect(!text.contains("A"))
    }

    @Test("内部置換を移動するとoverlayへ切り替えて書き出せる")
    @MainActor
    func movingInternalReplacementUsesOverlay() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-moved-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let model = try replacementModel(source: source, replacement: "B")
        let first = try #require(model.activeReplacements.first)
        #expect(first.storage == .internalPDFium)
        model.moveExistingEdit(id: first.id, by: CGPoint(x: 20, y: 10))
        let moved = try #require(model.activeReplacements.first)
        #expect(moved.destinationOrigin != nil)
        #expect(!moved.storage.isInternal)
        try PDFExportEngine.export(sourceURL: source, edits: [moved], to: output)
        #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains("B") == true)
    }

    @Test("調整TJと分割showを内部編集し、marked content・clip・重複objectは拒否する")
    @MainActor
    func splitAndAmbiguousSelectionsAreUnsupported() throws {
        guard pdfiumIsConfigured() else { return }
        let split = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj [(B) 0 (C)] TJ ET")
        let tjArray = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm [(A) 0 (B)] TJ ET")
        let marked = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm /Span BMC (A) Tj EMC ET")
        let clipped = fixture(content: "q 20 45 5 10 re W n BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET Q")
        let ambiguous = fixture(content: """
            BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET
            BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET
            """)
        defer {
            try? FileManager.default.removeItem(at: split)
            try? FileManager.default.removeItem(at: tjArray)
            try? FileManager.default.removeItem(at: marked)
            try? FileManager.default.removeItem(at: clipped)
            try? FileManager.default.removeItem(at: ambiguous)
        }

        let splitModel = try replacementModel(source: split, replacement: "XYZ")
        let splitEdit = try #require(splitModel.activeReplacements.first)
        #expect(splitEdit.storage == .reconstructed)

        let tjEdit = try rangeEdit(source: tjArray, text: "AB", range: 0..<2, replacement: "EA")
        #expect(PDFInternalTextEditEngine.eligibility(sourceURL: tjArray, edit: tjEdit) == .supported)

        let markedModel = try replacementModel(source: marked, replacement: "B")
        guard case .overlay(let markedReason) = try #require(markedModel.activeReplacements.first).storage else {
            Issue.record("marked contentが内部置換として扱われました。")
            return
        }
        #expect(markedReason.contains("marked content"))

        let clippedModel = try replacementModel(source: clipped, replacement: "B")
        guard case .overlay = try #require(clippedModel.activeReplacements.first).storage else {
            Issue.record("clip付きobjectが内部置換として扱われました。")
            return
        }

        let ambiguousModel = try replacementModel(source: ambiguous, replacement: "B")
        let ambiguousEdit = try #require(ambiguousModel.activeReplacements.first)
        guard case .overlay(let ambiguousReason) = ambiguousEdit.storage else {
            Issue.record("重複objectが内部置換として扱われました。")
            return
        }
        #expect(ambiguousReason.contains("複数") || ambiguousReason.contains("曖昧"))
    }

    @Test("glyph非対応を強制しても既存出力を変更しない")
    @MainActor
    func failedGlyphCoverageLeavesOutputUnchanged() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-unchanged-\(UUID().uuidString).pdf")
        let sentinel = Data("既存出力".utf8)
        try sentinel.write(to: output)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let model = try replacementModel(source: source, replacement: "Ā")
        var forced = try #require(model.activeReplacements.first)
        #expect(forced.storage == .reconstructed)
        forced.storage = .internalPDFium
        #expect(throws: Error.self) {
            try PDFExportEngine.export(sourceURL: source, edits: [forced], to: output)
        }
        #expect(try Data(contentsOf: output) == sentinel)
        #expect(PDFDocument(url: source)?.page(at: 0)?.string?.contains("A") == true)
    }

    @Test("背景や罫線に重なる文字は内部置換のプレビューと出力を食い違わせない")
    @MainActor
    func nonTextOverlapPreservesBackgroundAndRule() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "0.8 g 10 42 40 20 re f 0 G 10 42 40 20 re S 0 g BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-background-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let model = try replacementModel(source: source, replacement: "B")
        let edit = try #require(model.activeReplacements.first)
        #expect(edit.storage == .internalPDFium)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("B") == true)
        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        let page = try #require(PDFDocument(url: output)?.page(at: 0))
        #expect(page.string?.contains("B") == true)
        #expect(page.string?.contains("A") == false)
    }

    @Test("灰色背景上の埋込TrueType単一Tjを長文から1文字へ置換する")
    @MainActor
    func embeddedFontShorteningUsesIdenticalPreviewAndExportPath() throws {
        guard pdfiumIsConfigured() else { return }
        let source = try embeddedTrueTypeFixture()
        let sourceData = try Data(contentsOf: source)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-embedded-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let model = try replacementModel(source: source, replacement: "1")
        let edit = try #require(model.activeReplacements.first)
        #expect(edit.storage == .internalPDFium)
        #expect(model.document?.page(at: 0)?.string?.contains("DETAILS") == true)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("1") == true)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("DETAILS") == false)

        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        let reopened = try #require(PDFDocument(url: output))
        #expect(reopened.page(at: 0)?.string?.contains("1") == true)
        #expect(reopened.page(at: 0)?.string?.contains("DETAILS") == false)
        #expect(try Data(contentsOf: source) == sourceData)
    }

    @Test("埋込フォントに明示ToUnicode逆引きがない文字を元fontへ推測で設定しない")
    @MainActor
    func embeddedFontWithoutProvenReplacementMappingIsUnsupported() throws {
        guard pdfiumIsConfigured() else { return }
        let source = try embeddedTrueTypeFixture(mappedReplacement: "")
        defer { try? FileManager.default.removeItem(at: source) }

        let edit = try rangeEdit(source: source, text: "DETAILS", range: 0..<7, replacement: "1")
        guard case .unsupported(let reason) = PDFInternalTextEditEngine.eligibility(sourceURL: source, edit: edit) else {
            Issue.record("明示ToUnicode逆引きのない文字が元fontへの内部置換として扱われました。")
            return
        }
        #expect(reason.contains("ToUnicode") || reason.contains("glyph"))
    }

    @Test("ToUnicode推定だけでは内部置換へ昇格しない")
    @MainActor
    func inferredUnicodeIsOverlayOnly() throws {
        guard pdfiumIsConfigured() else { return }
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: pageBounds,
            contentStream: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let model = try replacementModel(source: source, replacement: "B")
        let edit = try #require(model.activeReplacements.first)
        guard case .overlay(let reason) = edit.storage else {
            Issue.record("ToUnicode推定だけの選択が内部置換として扱われました。")
            return
        }
        #expect(reason.contains("ToUnicode"))
    }

    @Test("内部置換とoverlay追加を別段で保存し、最終出力も検証する")
    @MainActor
    func mixedInternalAndOverlayExport() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-mixed-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let model = try replacementModel(source: source, replacement: "B")
        let internalEdit = try #require(model.activeReplacements.first)
        let insertion = ReplacementEdit(
            insertionOn: 0,
            bounds: CGRect(x: 80, y: 45, width: 30, height: 20),
            text: "Z",
            fontName: "Helvetica",
            fontSize: 14,
            fontColor: .black
        )
        let markup = PDFMarkupEdit(
            pageIndex: 0,
            tool: .note,
            bounds: CGRect(x: 150, y: 45, width: 20, height: 20),
            text: "内部置換と併存"
        )

        try PDFExportEngine.export(
            sourceURL: source,
            edits: [internalEdit, insertion],
            markups: [markup],
            to: output
        )
        let page = try #require(PDFDocument(url: output)?.page(at: 0))
        let text = try #require(page.string)
        #expect(text.contains("B"))
        #expect(text.contains("Z"))
        #expect(!text.contains("A"))
        #expect(page.annotations.contains { $0.contents == "内部置換と併存" })
    }

    @Test("Quartz日本語CFFの可視glyphから全文字コードのUnicodeを証明する")
    func visibleJapaneseUnicodeMappings() throws {
        guard pdfiumIsConfigured() else { return }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-visible-unicode-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = pageBounds
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 14, nil)
        for (text, y) in [("東京", CGFloat(65)), ("京都", CGFloat(35))] {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 20, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), context)
        }
        context.endPDFPage()
        context.closePDF()
        // hidden層に別の文字が同じ位置に存在しても、可視fontの対応に混ぜない。
        let layered = try PDFOCRLayerWriter.add(linesByPage: [0: [PDFOCRLine(
            pageIndex: 0, text: "大阪", confidence: 1,
            bounds: CGRect(x: 20 / 240.0, y: 65 / 100.0, width: 28 / 240.0, height: 14 / 100.0)
        )]], to: data as Data)
        try layered.write(to: source)
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let index = PDFGlyphIndex.makeIndex(for: try #require(document.page(at: 0)))
        let visible = index.runs.flatMap(\.glyphs).filter(\.isVisible)
        #expect(visible.count == 4)
        #expect(visible.allSatisfy { $0.text.isEmpty && !$0.hasExplicitToUnicodeMapping })
        let mappings = try PDFInternalTextEditEngine.visibleUnicodeMappings(sourceURL: source)
        let fontKey = try #require(visible.first?.fontKey)
        let mapping = try #require(mappings[0]?[fontKey])
        let codes = try visible.map { try #require($0.sourceCharacterCode) }
        #expect(codes.map { mapping[$0] ?? "" }.joined() == "東京京都")
        #expect(Set(mapping.values) == Set(["東", "京", "都"]))
        #expect(mappings[0]?.count == 1)

        let mappingTarget = TextTarget(
            pageIndex: 0, bounds: CGRect(x: 20, y: 63, width: 28, height: 14),
            baseline: 65, originalText: "", fontSize: 14, fontColor: .black,
            fontKey: fontKey, fontIsExact: false,
            coverBounds: CGRect(x: 20, y: 63, width: 28, height: 14), maxWidth: 100
        )
        var foreground = ReplacementEdit(
            target: mappingTarget, replacement: "東京", resolvedFont: font, fontIsExact: false
        )
        foreground.storage = .reconstructed
        // hidden検索層を足す前のQuartz出力を修復し、元CFFからの部分削除も確認する。
        let repaired = try PDFVisibleTextUnicodeWriter.addingMappings(in: data as Data, edits: [foreground])
        try repaired.write(to: source)
        let repairedDocument = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(repairedDocument) {} }
        let repairedIndex = PDFGlyphIndex.makeIndex(for: try #require(repairedDocument.page(at: 0)))
        let repairedRun = try #require(repairedIndex.runs.first { $0.text == "東京" })
        let deletionTarget = try #require(repairedIndex.target(in: repairedRun, range: 0..<1, pageIndex: 0))
        var deletion = ReplacementEdit(deleting: deletionTarget)
        deletion.storage = .internalPDFium
        #expect(PDFInternalTextEditEngine.eligibility(sourceURL: source, edit: deletion) == .supported)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-cff-deletion-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [deletion], to: output)
        let savedText = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
        #expect(!savedText.contains("東"))
        #expect(savedText.contains("京"))
        #expect(savedText.contains("京都"))
    }

    @Test("同位置に重なる可視glyphのUnicode対応を推測しない")
    func ambiguousVisibleUnicodeMappings() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET "
            + "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET")
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(try PDFInternalTextEditEngine.visibleUnicodeMappings(sourceURL: source).isEmpty)
    }

    @Test("非表示文字の対応を可視fontのUnicode補完へ返さない")
    func hiddenUnicodeMappingsAreExcluded() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 3 Tr 1 0 0 1 20 50 Tm (ABCD) Tj ET")
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(try PDFInternalTextEditEngine.visibleUnicodeMappings(sourceURL: source).isEmpty)
    }

    @Test("内部置換とoverlayが重なる保存は元の出力を保持して拒否する")
    @MainActor
    func overlappingEditPathsAreRejected() throws {
        guard pdfiumIsConfigured() else { return }
        let source = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfium-internal-overlap-\(UUID().uuidString).pdf")
        let sentinel = Data("既存出力".utf8)
        try sentinel.write(to: output)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let model = try replacementModel(source: source, replacement: "B")
        let internalEdit = try #require(model.activeReplacements.first)
        let insertion = ReplacementEdit(
            insertionOn: 0,
            bounds: CGRect(x: 20, y: 48, width: 15, height: 16),
            text: "Z",
            fontName: "Helvetica",
            fontSize: 14,
            fontColor: .black
        )
        do {
            try PDFExportEngine.export(sourceURL: source, edits: [internalEdit, insertion], to: output)
            Issue.record("重なる編集を保存しました。")
        } catch PDFExportError.overlappingEditPaths {
            #expect(try Data(contentsOf: output) == sentinel)
        } catch {
            Issue.record("重なり以外のエラーでした: \(error)")
        }
    }

}
