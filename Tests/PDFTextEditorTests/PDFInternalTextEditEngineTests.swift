import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite("PDFium内部テキスト置換（生成PDF）", .serialized)
struct PDFInternalTextEditEngineTests {
    private let pageBounds = CGRect(x: 0, y: 0, width: 240, height: 100)

    private let asciiToUnicode = """
        /CIDInit /ProcSet findresource begin
        12 dict begin begincmap
        /CMapName /InternalEditLatin def
        /CMapType 2 def
        1 begincodespacerange <00> <FF> endcodespacerange
        5 beginbfchar
        <41> <0041>
        <42> <0042>
        <43> <0043>
        <44> <0044>
        <45> <0045>
        endbfchar
        endcmap CMapName currentdict /CMap defineresource pop end end
        """

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
        #expect(model.statusMessage.contains("PDF内部の単一text object"))
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

    @Test("複数要素TJ・marked content・clip・分割show・重複objectを内部置換しない")
    @MainActor
    func splitAndAmbiguousSelectionsAreUnsupported() throws {
        guard pdfiumIsConfigured() else { return }
        let split = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj [(B) 0 (C)] TJ ET")
        let tjArray = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm [(A) 0 (B)] TJ ET")
        let marked = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm /Span BMC (A) Tj EMC ET")
        let clipped = fixture(content: "q 0 0 100 100 re W n BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET Q")
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
        guard case .overlay(let splitReason) = splitEdit.storage else {
            Issue.record("分割show operationが内部置換として扱われました。")
            return
        }
        #expect(splitReason.contains("複数show"))

        let tjModel = try replacementModel(source: tjArray, replacement: "BC")
        guard case .overlay(let tjReason) = try #require(tjModel.activeReplacements.first).storage else {
            Issue.record("TJが内部置換として扱われました。")
            return
        }
        #expect(tjReason.contains("調整付きTJ"))

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
        #expect(!forced.storage.isInternal)
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

    @Test("埋込フォントに明示ToUnicode逆引きがない文字はoverlayへ留める")
    @MainActor
    func embeddedFontWithoutProvenReplacementMappingIsUnsupported() throws {
        guard pdfiumIsConfigured() else { return }
        let source = try embeddedTrueTypeFixture(mappedReplacement: "")
        defer { try? FileManager.default.removeItem(at: source) }

        let model = try replacementModel(source: source, replacement: "1")
        let edit = try #require(model.activeReplacements.first)
        guard case .overlay(let reason) = edit.storage else {
            Issue.record("明示ToUnicode逆引きのない文字が内部置換として扱われました。")
            return
        }
        #expect(reason.contains("ToUnicode") || reason.contains("glyph"))
        #expect(model.statusMessage.contains("白帯"))
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
