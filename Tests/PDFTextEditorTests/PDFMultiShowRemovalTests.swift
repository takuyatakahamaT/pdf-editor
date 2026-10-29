import AppKit
import CoreText
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite("複数showの原文除去", .serialized)
struct PDFMultiShowRemovalTests {
    private var hasPDFium: Bool {
        let environment = ProcessInfo.processInfo.environment
        return (environment["PDFIUM_LIBRARY_PATH"] ?? environment["PDFIUM_PATH"])
            .map { FileManager.default.fileExists(atPath: $0) } == true
    }

    private func fixture(extra: String = "", clip: String? = nil) -> URL {
        let cmap = """
        /CIDInit /ProcSet findresource begin 12 dict begin begincmap
        /CMapName /MultiShow def /CMapType 2 def
        1 begincodespacerange <00> <FF> endcodespacerange
        95 beginbfchar
        \((32...126).map { String(format: "<%02X><%04X>", $0, $0) }.joined(separator: "\n"))
        endbfchar endcmap CMapName currentdict /CMap defineresource pop end end
        """
        return RawPDFBuilder.build(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            RawPDFBuilder.streamObject(dict: "", streamContent:
                "0.8 g 10 35 220 35 re f 0 G 1 w 10 35 m 230 35 l S 0 g "
                + (clip.map { "q \($0) " } ?? "")
                + "BT /F1 14 Tf 1 0 0 1 20 48 Tm (AB) Tj (CD) Tj ET "
                + (clip == nil ? "" : "Q ")
                + "BT /F1 14 Tf 1 0 0 1 20 20 Tm (UNCHANGED) Tj ET \(extra)"),
            RawPDFBuilder.streamObject(dict: "", streamContent: cmap)
        ])
    }

    private func target(in document: PDFDocument, range: Range<Int>) throws -> TextTarget {
        let index = PDFGlyphIndex.makeIndex(for: try #require(document.page(at: 0)))
        let run = try #require(index.runs.first { $0.text == "ABCD" })
        return try #require(index.target(in: run, range: range, pageIndex: 0))
    }

    @Test("二つのobjectの部分範囲を除去し選択外glyphの原点を保つ")
    func partialObjectsPreserveOutsideGlyphs() throws {
        guard hasPDFium else { return }
        let source = fixture()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("multi-show-partial-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let selected = try target(in: document, range: 1..<3)
        #expect(!selected.sourceIsPlainTextObject)
        var deletion = ReplacementEdit(deleting: selected)
        deletion.storage = .internalPDFium
        #expect(PDFInternalTextEditEngine.eligibility(sourceURL: source, edit: deletion) == .supported)
        try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [deletion], to: output)
        try PDFInternalTextEditEngine.verifyFinalOutput(sourceURL: source, outputURL: output, edits: [deletion])
        let saved = try #require(PDFDocument(url: output))
        defer { withExtendedLifetime(saved) {} }
        let original = PDFGlyphIndex.makeIndex(for: try #require(document.page(at: 0))).runs.flatMap(\.glyphs)
        let actual = PDFGlyphIndex.makeIndex(for: try #require(saved.page(at: 0))).runs.flatMap(\.glyphs)
        for text in ["A", "D"] {
            let before = try #require(original.first { $0.text == text && $0.baseline > 40 })
            let after = try #require(actual.first { $0.text == text && $0.baseline > 40 })
            #expect(abs(before.advanceBox.minX - after.advanceBox.minX) < 0.02)
            #expect(abs(before.baseline - after.baseline) < 0.02)
            #expect(abs(before.fontSize - after.fontSize) < 0.02)
        }
        #expect(actual.filter { $0.baseline > 40 }.map(\.text).joined() == "AD")
        #expect(saved.page(at: 0)?.string?.contains("UNCHANGED") == true)
    }

    @Test("複数showを一つの編集で透明再描画し前景と対象外文字を検証する",
          arguments: ["EF", "東京"])
    func reconstructedReplacement(replacement: String) throws {
        guard hasPDFium else { return }
        let source = fixture()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("multi-show-foreground-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let selected = try target(in: document, range: 0..<4)
        let font = CTFontCreateWithName((replacement == "東京" ? "HiraginoSans-W3" : "Helvetica") as CFString, 14, nil)
        var edit = ReplacementEdit(target: selected, replacement: replacement, resolvedFont: font, fontIsExact: false)
        edit.storage = PDFTextEditPlanner.storage(sourceURL: source, edit: edit)
        #expect(edit.storage == .reconstructed)
        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        let saved = try #require(PDFDocument(url: output))
        #expect(saved.page(at: 0)?.string?.contains(replacement) == true)
        #expect(saved.page(at: 0)?.string?.contains("ABCD") == false)
        #expect(saved.page(at: 0)?.string?.contains("UNCHANGED") == true)
        try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: output, edits: [edit])
    }

    @Test("複数showの重なりがある選択は出力を保持して拒否する")
    func ambiguousSelectionIsRejected() throws {
        guard hasPDFium else { return }
        let source = fixture()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("multi-show-rejected-\(UUID()).pdf")
        let sentinel = Data("保存済みの出力".utf8)
        try sentinel.write(to: output)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let selected = try target(in: document, range: 0..<4)
        let ambiguous = TextTarget(
            pageIndex: 0, bounds: selected.bounds, baseline: selected.baseline,
            originalText: selected.originalText, fontSize: selected.fontSize, fontColor: selected.fontColor,
            fontKey: selected.fontKey, fontIsExact: selected.fontIsExact,
            coverBounds: selected.coverBounds, maxWidth: selected.maxWidth,
            hasExplicitSourceMapping: true, sourceGlyphBounds: selected.sourceGlyphBounds,
            sourceSelectionIsAmbiguous: true, sourceIsPlainTextObject: false
        )
        var edit = ReplacementEdit(deleting: ambiguous)
        edit.storage = .internalPDFium
        #expect(throws: (any Error).self) {
            try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [edit], to: output)
        }
        #expect(try Data(contentsOf: output) == sentinel)
    }

    @Test("glyphを十分含むrect clipだけを中立候補としPDFiumとも照合する",
          arguments: [
            "0 0 240 100 re W n",
            "10 10 210 80 re W n 15 15 190 70 re W n",
            "q 0 0 m 240 0 l 240 100 l 0 100 l h W n Q 10 10 210 80 re W n"
          ])
    func neutralRectangleClip(clip: String) throws {
        guard hasPDFium else { return }
        let source = fixture(clip: clip)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let selected = try target(in: document, range: 0..<4)
        #expect(PDFInternalTextEditEngine.eligibility(
            sourceURL: source, edit: ReplacementEdit(deleting: selected).sourceRemoval()
        ) == .supported)
    }

    @Test("glyphに接するrect・非rect・複数path・過去の未知clipを拒否する",
          arguments: [
            "20 45 5 10 re W n",
            "0 0 m 240 0 l 240 100 l 0 100 l h W n",
            "0 0 240 100 re 0 0 220 90 re W n",
            "0 0 m 240 0 l 240 100 l 0 100 l h W n 0 0 240 100 re W n",
            "20 45 5 10 re W n 0 0 240 100 re W n"
          ])
    func rejectsNonNeutralClip(clip: String) throws {
        guard hasPDFium else { return }
        let source = fixture(clip: clip)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let selected = try target(in: document, range: 0..<4)
        #expect(PDFInternalTextEditEngine.eligibility(
            sourceURL: source, edit: ReplacementEdit(deleting: selected).sourceRemoval()
        ) != .supported)
    }

    @Test("指定実文書の選択範囲をshowごとへ確定して除去する",
          .enabled(if: ProcessInfo.processInfo.environment["PDF_EDITOR_INTEGRATION_PDF"] != nil))
    func realDocumentSourceRemoval() throws {
        guard hasPDFium else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["PDF_EDITOR_INTEGRATION_PDF"],
              let text = environment["PDF_EDITOR_INTEGRATION_TEXT"] else { return }
        let source = URL(fileURLWithPath: sourcePath)
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let index = PDFGlyphIndex.makeIndex(for: try #require(document.page(at: 0)))
        let run = try #require(index.runs.first { $0.text.contains(text) })
        let characters = Array(run.text), needle = Array(text)
        let start = try #require((0...(characters.count - needle.count)).first {
            Array(characters[$0..<($0 + needle.count)]) == needle
        })
        let target = try #require(index.target(in: run, range: start..<(start + needle.count), pageIndex: 0))
        let removal = ReplacementEdit(deleting: target).sourceRemoval()
        #expect(PDFInternalTextEditEngine.eligibility(sourceURL: source, edit: removal) == .supported)
        if let replacement = environment["PDF_EDITOR_INTEGRATION_REPLACEMENT"],
           let outputPath = environment["PDF_EDITOR_INTEGRATION_OUTPUT"] {
            let page = try #require(document.page(at: 0))
            let resolution = PDFEditEngine.resolveFont(for: target, on: page, replacement: replacement)
            var edit = ReplacementEdit(target: target, replacement: replacement, resolvedFont: resolution.font,
                                       fontIsExact: resolution.isExact, exactGlyphs: resolution.exactGlyphs)
            edit.storage = PDFTextEditPlanner.storage(sourceURL: source, edit: edit)
            #expect(edit.storage.isInternal)
            let output = URL(fileURLWithPath: outputPath)
            try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
            try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: output, edits: [edit])
        }
    }
}
