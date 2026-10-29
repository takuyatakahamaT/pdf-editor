import AppKit
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
        3 beginbfchar
        <41> <0041>
        <42> <0042>
        <43> <0043>
        endbfchar
        endcmap CMapName currentdict /CMap defineresource pop end end
        """

    private func fixture(content: String) -> URL {
        RawPDFBuilder.build(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] "
                + "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            RawPDFBuilder.streamObject(dict: "", streamContent: content),
            RawPDFBuilder.streamObject(dict: "", streamContent: asciiToUnicode)
        ])
    }

    private func pdfiumIsConfigured() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["PDFIUM_LIBRARY_PATH"] ?? environment["PDFIUM_PATH"]
        return path.map { FileManager.default.fileExists(atPath: $0) } == true
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
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let model = try replacementModel(source: source, replacement: "B")
        let edit = try #require(model.activeReplacements.first)
        #expect(edit.storage == .internalPDFium)
        #expect(model.statusMessage.contains("PDF内部の単一text object"))
        // プレビュー中は元PDFを変えず、annotationだけで置換表示する。
        #expect(model.document?.page(at: 0)?.string?.contains("A") == true)
        #expect(try Data(contentsOf: source) == sourceData)

        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        let reopened = try #require(PDFDocument(url: output))
        #expect(reopened.page(at: 0)?.string?.contains("B") == true)
        #expect(reopened.page(at: 0)?.string?.contains("A") == false)
        #expect(PDFDocument(url: source)?.page(at: 0)?.string?.contains("A") == true)
        #expect(try Data(contentsOf: source) == sourceData)
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

    @Test("TJ・marked content・分割show・重複objectを内部置換しない")
    @MainActor
    func splitAndAmbiguousSelectionsAreUnsupported() throws {
        guard pdfiumIsConfigured() else { return }
        let split = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj [(B) 0 (C)] TJ ET")
        let tjArray = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm [(A)] TJ ET")
        let marked = fixture(content: "BT /F1 14 Tf 1 0 0 1 20 50 Tm /Span BMC (A) Tj EMC ET")
        let ambiguous = fixture(content: """
            BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET
            BT /F1 14 Tf 1 0 0 1 20 50 Tm (A) Tj ET
            """)
        defer {
            try? FileManager.default.removeItem(at: split)
            try? FileManager.default.removeItem(at: tjArray)
            try? FileManager.default.removeItem(at: marked)
            try? FileManager.default.removeItem(at: ambiguous)
        }

        let splitModel = try replacementModel(source: split, replacement: "XYZ")
        let splitEdit = try #require(splitModel.activeReplacements.first)
        guard case .overlay(let splitReason) = splitEdit.storage else {
            Issue.record("分割show operationが内部置換として扱われました。")
            return
        }
        #expect(splitReason.contains("複数show"))

        let tjModel = try replacementModel(source: tjArray, replacement: "B")
        guard case .overlay(let tjReason) = try #require(tjModel.activeReplacements.first).storage else {
            Issue.record("TJが内部置換として扱われました。")
            return
        }
        #expect(tjReason.contains("単一Tj"))

        let markedModel = try replacementModel(source: marked, replacement: "B")
        guard case .overlay(let markedReason) = try #require(markedModel.activeReplacements.first).storage else {
            Issue.record("marked contentが内部置換として扱われました。")
            return
        }
        #expect(markedReason.contains("marked content"))

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
}
