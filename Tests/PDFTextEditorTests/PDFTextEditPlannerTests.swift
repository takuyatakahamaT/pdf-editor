import AppKit
import CoreText
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite("文字編集計画と背景保持", .serialized)
struct PDFTextEditPlannerTests {
    private func fixture(extra: String = "") -> URL {
        let cmap = """
        /CIDInit /ProcSet findresource begin 12 dict begin begincmap
        /CMapName /Test def /CMapType 2 def
        1 begincodespacerange <00> <FF> endcodespacerange
        4 beginbfchar
        <41> <0041>
        <42> <0042>
        <43> <0043>
        <44> <0044>
        endbfchar
        endcmap CMapName currentdict /CMap defineresource pop end end
        """
        return RawPDFBuilder.build(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            RawPDFBuilder.streamObject(dict: "", streamContent:
                "0.8 g 10 35 220 35 re f 0 G 1 w 10 35 m 230 35 l S 0 g BT /F1 14 Tf 1 0 0 1 20 48 Tm (ABCD) Tj ET " + extra),
            RawPDFBuilder.streamObject(dict: "", streamContent: cmap)
        ])
    }

    private var hasPDFium: Bool {
        ProcessInfo.processInfo.environment["PDFIUM_LIBRARY_PATH"].map {
            FileManager.default.fileExists(atPath: $0)
        } ?? false
    }

    @Test("元subsetに無い日本語を透明再描画し灰色背景と罫線を保つ",
          arguments: ["HiraginoSans-W3", "NotoSansJP-Regular"])
    func japaneseReplacementPreservesBackground(fontName: String) throws {
        guard hasPDFium else { return }
        PDFEmbeddedFontLoader.registerBundledFonts()
        let source = fixture()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("planner-ja-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "ABCD" })
        let target = try #require(index.target(in: run, range: 0..<4, pageIndex: 0))
        let font = CTFontCreateWithName(fontName as CFString, 14, nil)
        var edit = ReplacementEdit(target: target, replacement: "東京", resolvedFont: font, fontIsExact: false)
        edit.storage = PDFTextEditPlanner.storage(sourceURL: source, edit: edit)
        #expect(edit.storage == .reconstructed)
        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("東京"))
        #expect(!text.contains("ABCD"))
        try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: output, edits: [edit])
        let preview = try PDFTextEditPlanner.previewDocument(sourceURL: source, edits: [edit])
        #expect(preview.page(at: 0)?.string?.contains("東京") == true)

        let reopened = try #require(PDFDocument(url: output))
        defer { withExtendedLifetime(reopened) {} }
        let reopenedPage = try #require(reopened.page(at: 0))
        let reopenedIndex = PDFGlyphIndex.makeIndex(for: reopenedPage)
        let reopenedRun = try #require(reopenedIndex.runs.first { $0.text == "東京" })
        #expect(reopenedRun.glyphs.allSatisfy { $0.isVisible })
        let reopenedTarget = try #require(reopenedIndex.target(in: reopenedRun, range: 0..<2, pageIndex: 0))
        let resolution = PDFEditEngine.resolveFont(for: reopenedTarget, on: reopenedPage, replacement: "大阪")
        var subsequent = ReplacementEdit(
            target: reopenedTarget, replacement: "大阪", resolvedFont: resolution.font,
            fontIsExact: resolution.isExact, exactGlyphs: resolution.exactGlyphs
        )
        subsequent.storage = PDFTextEditPlanner.storage(sourceURL: output, edit: subsequent)
        #expect(subsequent.storage.isInternal)
        let secondPreview = try PDFTextEditPlanner.previewDocument(sourceURL: output, edits: [subsequent])
        #expect(secondPreview.page(at: 0)?.string?.contains("大阪") == true)
        #expect(secondPreview.page(at: 0)?.string?.contains("東京") == false)
    }

    @Test("対象外の罫線欠損は画像差分で拒否する")
    func rejectsRuleDamage() throws {
        let source = fixture()
        let damaged = fixture(extra: "1 g 150 34 50 3 re f")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: damaged) }
        #expect(throws: (any Error).self) {
            try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: damaged, edits: [])
        }
    }

    @Test("書体やサイズを変更しても透明再描画で保存する")
    func changedTypefaceUsesForeground() throws {
        guard hasPDFium else { return }
        let source = fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "ABCD" })
        let target = try #require(index.target(in: run, range: 0..<4, pageIndex: 0))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil)
        var edit = ReplacementEdit(
            target: target, replacement: "Edit", resolvedFont: font, fontIsExact: true,
            outputFontSelection: ReplacementFontSelection(choice: .custom, customFontName: "Helvetica-Bold")
        )
        edit.storage = PDFTextEditPlanner.storage(sourceURL: source, edit: edit)
        #expect(edit.storage == .reconstructed)
        let preview = try PDFTextEditPlanner.previewDocument(sourceURL: source, edits: [edit])
        #expect(preview.page(at: 0)?.string?.contains("Edit") == true)
    }

    @Test("編集済み文字を削除しても前の文字を残さずundoで復元する")
    @MainActor
    func deletingReeditedReplacement() throws {
        guard hasPDFium else { return }
        let source = fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "ABCD" })
        let target = try #require(index.target(in: run, range: 0..<4, pageIndex: 0))
        model.select(target)
        model.updateEditorText("東京")
        model.commitEditorText()
        let editedID = try #require(model.activeReplacements.first?.id)
        model.beginReeditingReplacement(id: editedID)
        model.deleteSelection()
        #expect(model.activeReplacements.count == 1)
        #expect(model.activeReplacements.first?.replacement.isEmpty == true)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("ABCD") != true)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("東京") != true)
        model.undoLastEdit()
        #expect(model.activeReplacements.first?.replacement == "東京")
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains("東京") == true)
    }

    @Test("指定した実文書の編集・保存・再読込を確認する",
          .enabled(if: ProcessInfo.processInfo.environment["PDF_EDITOR_INTEGRATION_PDF"] != nil))
    @MainActor
    func realDocumentReplacement() throws {
        guard hasPDFium else { return }
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment["PDF_EDITOR_INTEGRATION_PDF"]))
        let oldText = try #require(environment["PDF_EDITOR_INTEGRATION_TEXT"])
        let newText = try #require(environment["PDF_EDITOR_INTEGRATION_REPLACEMENT"])
        let output = URL(fileURLWithPath: try #require(environment["PDF_EDITOR_INTEGRATION_OUTPUT"]))
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text.contains(oldText) })
        let characters = Array(run.text)
        let needle = Array(oldText)
        let start = try #require((0...(characters.count - needle.count)).first {
            Array(characters[$0..<($0 + needle.count)]) == needle
        })
        let target = try #require(index.target(in: run, range: start..<(start + needle.count), pageIndex: 0))
        model.select(target)
        model.updateEditorText(newText)
        model.commitEditorText()
        let edit = try #require(model.activeReplacements.first)
        #expect(edit.storage.isInternal)
        #expect(model.displayedDocument?.page(at: 0)?.string?.contains(newText) == true)
        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains(newText) == true)
        try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: output, edits: [edit])
        if newText == "東京" {
            let reopened = try #require(PDFDocument(url: output))
            defer { withExtendedLifetime(reopened) {} }
            let page = try #require(reopened.page(at: 0))
            let index = PDFGlyphIndex.makeIndex(for: page)
            let run = try #require(index.runs.first { $0.text == newText })
            let target = try #require(index.target(in: run, range: 0..<2, pageIndex: 0))
            let resolution = PDFEditEngine.resolveFont(for: target, on: page, replacement: "大阪")
            var second = ReplacementEdit(target: target, replacement: "大阪", resolvedFont: resolution.font,
                                         fontIsExact: resolution.isExact, exactGlyphs: resolution.exactGlyphs)
            second.storage = PDFTextEditPlanner.storage(sourceURL: output, edit: second)
            #expect(second.storage.isInternal)
            let preview = try PDFTextEditPlanner.previewDocument(sourceURL: output, edits: [second])
            #expect(preview.page(at: 0)?.string?.contains("大阪") == true)
            #expect(preview.page(at: 0)?.string?.contains("東京") == false)
        }
    }
}
