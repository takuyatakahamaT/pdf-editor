import AppKit
import CoreText
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite("文字数が増える置換", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PDFIUM_LIBRARY_PATH"] != nil))
struct PDFLongerReplacementTests {
    @Test("背景を保つ編集方式でも1文字を2文字に置換し後続文字を送れる", arguments: [(0, false), (1, false), (0, true)])
    @MainActor
    func longerReplacementReflowsWithoutLosingBackground(selectedIndex: Int, splitShows: Bool) throws {
        let source = fixture(splitShows: splitShows)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text.hasPrefix("AB") })
        let target = try #require(index.target(in: run, range: selectedIndex..<(selectedIndex + 1), pageIndex: 0))
        let replacement = target.originalText + target.originalText
        var candidate = PDFEditEngine.prepareReplacement(replacement, on: page, target: target).edit
        candidate.storage = PDFTextEditPlanner.storage(sourceURL: source, edit: candidate)
        #expect(candidate.storage == .reconstructed)
        #expect(target.lineLayout?.glyphs.map(\.text).joined() == "ABCD")

        model.select(target)
        model.updateEditorText(replacement)
        model.commitEditorText()

        #expect(model.noticeMessage == nil)
        let edit = try #require(model.activeReplacements.first)
        #expect(edit.replacement == replacement)
        #expect(abs(edit.fontSize - target.fontSize) < 0.01)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("longer-replacement-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        let reopened = try #require(PDFDocument(url: output))
        let savedPage = try #require(reopened.page(at: 0))
        let expected = selectedIndex == 0 ? "AABCD" : "ABBCD"
        #expect(savedPage.string?.filter { !$0.isWhitespace } == expected)
        let savedIndex = PDFGlyphIndex.makeIndex(for: savedPage)
        let originalD = try #require(run.glyphs.first { $0.text == "D" })
        let savedD = try #require(savedIndex.runs.flatMap(\.glyphs).first { $0.text == "D" })
        #expect(savedD.advanceBox.minX > originalD.advanceBox.minX + 5)
        #expect(abs(savedD.fontSize - originalD.fontSize) < 0.05)
        let sourceBackground = try backgroundLevel(on: page, y: 45.5)
        #expect(sourceBackground > 0.7 && sourceBackground < 0.9)
        #expect(abs(sourceBackground - (try backgroundLevel(on: savedPage, y: 45.5))) < 0.02)
        #expect(abs((try backgroundLevel(on: page, y: 35)) - (try backgroundLevel(on: savedPage, y: 35))) < 0.02)
        try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: output, edits: [edit])
        #expect(model.previewDocument?.page(at: 0)?.string?.filter { !$0.isWhitespace } == expected)
        model.beginReeditingReplacement(id: edit.id)
        model.updateEditorText(replacement + target.originalText)
        model.commitEditorText()
        #expect(model.activeReplacements.count == 1)
        #expect(model.activeReplacements.first?.replacement.count == 3)
        model.undoLastEdit()
        #expect(model.activeReplacements.first?.replacement == replacement)
        model.redoLastEdit()
        #expect(model.activeReplacements.first?.replacement.count == 3)
        model.undoLastEdit()
        model.undoLastEdit()
        #expect(model.activeReplacements.isEmpty)
    }

    @Test("文字数を増やしてもページ端や次の列を越える場合は元の編集を壊さず拒否する", arguments: [false, true])
    @MainActor
    func longerReplacementRespectsPageAndColumnBoundary(nextColumn: Bool) throws {
        let source = fixture(pageWidth: nextColumn ? 240 : 66, nextColumn: nextColumn)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "ABCD" })
        let target = try #require(index.target(in: run, range: 0..<1, pageIndex: 0))
        model.select(target)
        model.updateEditorText(nextColumn ? "AAAA" : "AA")
        model.commitEditorText()
        #expect(model.activeReplacements.isEmpty)
        #expect(page.annotations.isEmpty)
        #expect(model.noticeMessage?.contains("範囲を超えています") == true)
        #expect(model.replacementText == (nextColumn ? "AAAA" : "AA"))
    }

    @Test("日付・金額など任意の文字数増加を同じ幅差ロジックで保存する",
          arguments: [("10/1X", 3..<4, "10", "10/10X"), ("500X", 0..<3, "50,000", "50,000X")])
    @MainActor
    func arbitraryGrowingTextReflows(
        sourceText: String, selectedRange: Range<Int>, replacement: String, expected: String
    ) throws {
        let source = fixture(text: sourceText)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == sourceText })
        let target = try #require(index.target(in: run, range: selectedRange, pageIndex: 0))
        let originalFontSize = target.fontSize

        model.select(target)
        model.updateEditorText(replacement)
        model.commitEditorText()

        #expect(model.noticeMessage == nil)
        let edit = try #require(model.activeReplacements.first)
        #expect(edit.storage == .reconstructed)
        #expect(abs(edit.fontSize - originalFontSize) < 0.01)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbitrary-growing-text-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        let savedPage = try #require(PDFDocument(url: output)?.page(at: 0))
        #expect(savedPage.string?.filter { !$0.isWhitespace } == expected)
    }

    @Test("短い置換で後続文字を左へ詰めても元領域を破損扱いしない")
    func shorterReplacementAllowsOriginalSuffixRegion() throws {
        let source = fixture()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("shorter-replacement-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try #require(PDFDocument(url: source))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "ABCD" })
        let target = try #require(index.target(in: run, range: 0..<2, pageIndex: 0))
        let selection = ReplacementFontSelection(choice: .custom, customFontName: "Helvetica-Bold")
        var edit = PDFEditEngine.prepareReplacement(
            "I", on: page, target: target, preferredFontName: "Helvetica-Bold",
            outputFontSelection: selection
        ).edit
        edit.storage = PDFTextEditPlanner.storage(sourceURL: source, edit: edit)

        #expect(edit.storage == .reconstructed)
        #expect((PDFTextRenderer.foregroundReflowPlan(for: edit)?.reflow.shift ?? 0) < 0)
        try PDFExportEngine.export(sourceURL: source, edits: [edit], to: output)
        let savedPage = try #require(PDFDocument(url: output)?.page(at: 0))
        #expect(savedPage.string?.filter { !$0.isWhitespace } == "ICD")
        try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: output, edits: [edit])
    }

    private func backgroundLevel(on page: PDFPage, y: CGFloat) throws -> Double {
        let image = page.thumbnail(of: CGSize(width: 960, height: 400), for: .mediaBox)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let color = try #require(bitmap.colorAt(x: 180, y: Int((100 - y) * 4))?.usingColorSpace(.deviceRGB))
        return Double(color.redComponent)
    }

    private func fixture(
        pageWidth: Int = 240, nextColumn: Bool = false, splitShows: Bool = false, text: String = "ABCD"
    ) -> URL {
        let cmap = """
        /CIDInit /ProcSet findresource begin 12 dict begin begincmap
        /CMapName /Longer def /CMapType 2 def
        1 begincodespacerange <00> <FF> endcodespacerange
        95 beginbfchar
        \((32...126).map { String(format: "<%02X> <%04X>", $0, $0) }.joined(separator: "\n"))
        endbfchar
        endcmap CMapName currentdict /CMap defineresource pop end end
        """
        let textShows = splitShows ? "(AB) Tj (CD) Tj" : "(\(text)) Tj"
        return RawPDFBuilder.build(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageWidth) 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            RawPDFBuilder.streamObject(dict: "", streamContent:
                "0.8 g 10 35 220 35 re f 0 G 1 w 10 35 m 230 35 l S 0 g BT /F1 14 Tf 1 0 0 1 20 48 Tm \(textShows) ET"
                    + (nextColumn ? " BT /F1 14 Tf 1 0 0 1 80 48 Tm (D) Tj ET" : "")),
            RawPDFBuilder.streamObject(dict: "", streamContent: cmap)
        ])
    }
}
