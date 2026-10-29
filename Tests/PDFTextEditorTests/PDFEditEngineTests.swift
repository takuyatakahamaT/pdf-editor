import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite("PDF edit engine")
struct PDFEditEngineTests {
    @Test("selecting text keeps replacement ready for direct editing")
    @MainActor
    func selectingTextRequestsInputFocus() {
        let model = EditorModel(initialURL: nil)
        let target = TextTarget(
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 20, width: 80, height: 16),
            baseline: 20,
            originalText: "請求書",
            fontSize: 12,
            fontColor: .black,
            fontKey: nil,
            fontIsExact: false,
            coverBounds: CGRect(x: 9, y: 19, width: 82, height: 18),
            maxWidth: 200
        )

        #expect(model.replacementFocusRequest == 0)

        model.select(target)

        #expect(model.selectedTarget == target)
        #expect(model.replacementText == "請求書")
        #expect(model.replacementFocusRequest == 0)
        model.beginInlineEditing()
        #expect(model.isInlineEditing)
    }

    @Test("replacement adds a single self-drawing annotation")
    @MainActor
    func addsExpectedAnnotation() throws {
        let page = try #require(PDFPage(image: testImage()))
        let target = TextTarget(
            pageIndex: 0,
            bounds: CGRect(x: 80, y: 120, width: 140, height: 20),
            baseline: 120,
            originalText: "旧テキスト",
            fontSize: 12,
            fontColor: .black,
            fontKey: nil,
            fontIsExact: false,
            coverBounds: CGRect(x: 79, y: 118, width: 142, height: 24),
            maxWidth: 200
        )

        let result = PDFEditEngine.applyReplacement("新テキスト", to: page, target: target)

        #expect(page.annotations.count == 1)
        #expect(result.annotation.type == "Square")
        #expect(result.annotation is ReplacementTextAnnotation)
        #expect(result.edit.replacement == "新テキスト")
        #expect(result.edit.kind == .replacement)
        // このページには埋め込みフォント情報が無いためフォールバックフォントになる。
        #expect(result.fontIsExact == false)
    }

    @Test("deleting a dragged range covers both parentheses without drawing new text")
    @MainActor
    func deletionCoversWholeRange() throws {
        let url = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 300, height: 100),
            contentStream: "BT /F1 14 Tf 1 0 0 1 30 50 Tm (A\\(12\\)B) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text.contains("(12)") })
        let open = try #require(run.glyphs.firstIndex { $0.text == "(" })
        let close = try #require(run.glyphs.firstIndex { $0.text == ")" })
        let target = try #require(index.target(in: run, range: open..<(close + 1), pageIndex: 0))
        #expect(target.originalText == "(12)")
        #expect(index.cluster(at: CGPoint(x: run.glyphs[close].advanceBox.midX, y: run.glyphs[close].advanceBox.midY), pageIndex: 0)?.originalText == ")")

        let model = EditorModel(initialURL: url)
        model.select(target)
        model.deleteSelection()
        #expect(model.edits.count == 1)
        #expect(model.edits[0].replacement?.replacement.isEmpty == true)
        #expect(model.edits[0].replacement?.resolvedFont == nil)
        #expect(model.selectedTarget == nil)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-text-bench-delete-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try PDFExportEngine.export(sourceURL: url, edits: model.edits.compactMap(\.replacement), to: outputURL)
        let outputDocument = try #require(PDFDocument(url: outputURL))
        let outputPage = try #require(outputDocument.page(at: 0))
        let fills = InkScanner.scan(page: outputPage)
        #expect(fills.count == 1)
        let cover = try #require(fills.first)
        #expect(cover.isPlainRect)
        #expect(abs(cover.bounds.minX - target.coverBounds.minX) < 0.01)
        #expect(abs(cover.bounds.maxX - target.coverBounds.maxX) < 0.01)
    }

    @Test("text spacing set inside q/Q does not shift later text")
    func textSpacingRestoresWithGraphicsState() throws {
        let content = """
        q BT /F1 1 Tf 10 0 0 10 30 70 Tm -0.0357 Tc (AB) Tj ET Q
        q BT /F1 1 Tf 10 0 0 10 30 40 Tm (AB) Tj ET Q
        """
        let url = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            contentStream: content
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let second = try #require(index.runs.first { $0.text == "AB" && $0.baseline < 50 })
        let a = try #require(second.glyphs.first)
        let b = try #require(second.glyphs.last)
        #expect(abs(b.advanceBox.minX - a.advanceBox.minX - a.advanceBox.width) < 0.01)
    }

    @Test("insertion text keeps its existing bounded-box fitting behavior")
    func insertionFitsLongTextInsideItsBox() {
        let font = PDFEditEngine.fittedFont(
            named: nil,
            preferredSize: 18,
            text: "かなり長い置換後テキスト",
            bounds: CGRect(x: 0, y: 0, width: 90, height: 22)
        )

        #expect(font.pointSize < 18)
        #expect(font.pointSize >= 6)
    }

    @Test("unavailable MS Gothic keeps a Japanese Gothic fallback for numeric replacement")
    func unavailableMSGothicKeepsJapaneseGothicFamily() {
        PDFEmbeddedFontLoader.registerBundledFonts()
        let fallbackNames = PDFEmbeddedFontLoader.fallbackFontNames(
            for: "AAAAAA+MS-Gothic",
            replacementText: "11"
        )

        #expect(fallbackNames.first == "Noto Sans JP")
        #expect(CTFontCopyFamilyName(CTFontCreateWithName("Noto Sans JP" as CFString, 12, nil)) as String == "Noto Sans JP")
    }

    @Test("application font resources are preferred before the SwiftPM fallback")
    func applicationFontResourcesArePreferred() {
        var requestedPackageFallback = false
        let fontURL = PDFEmbeddedFontLoader.bundledFontURL(mainBundle: .module) {
            requestedPackageFallback = true
            return .main
        }

        #expect(fontURL?.lastPathComponent == "NotoSansJP-Regular.otf")
        #expect(!requestedPackageFallback)
    }

    @Test("local Office Japanese fonts are registered when their font files are available")
    func registersLocalOfficeJapaneseFontsWhenAvailable() {
        let gothicFont = "/Applications/Microsoft Word.app/Contents/Resources/DFonts/msgothic.ttc"
        let minchoFont = "/Applications/Microsoft Word.app/Contents/Resources/DFonts/msmincho.ttc"
        guard FileManager.default.fileExists(atPath: gothicFont),
              FileManager.default.fileExists(atPath: minchoFont) else { return }

        let families = PDFEmbeddedFontLoader.registerLocalFontFamilies()
        #expect(families.contains { $0.replacingOccurrences(of: " ", with: "").lowercased() == "msgothic" })
        #expect(families.contains { $0.replacingOccurrences(of: " ", with: "").lowercased() == "msmincho" })
        #expect(PDFEmbeddedFontLoader.availableFont(named: "MS Gothic", size: 12) != nil)
        #expect(PDFEmbeddedFontLoader.availableFont(named: "MS Mincho", size: 12) != nil)
    }

    @Test("local Office MS Mincho preserves a subset PDF font's family, size, and width")
    func localMSMinchoMatchesSubsetPDFMetrics() throws {
        let officeFont = "/Applications/Microsoft Word.app/Contents/Resources/DFonts/msmincho.ttc"
        guard FileManager.default.fileExists(atPath: officeFont) else { return }

        let url = type0FontFixture(
            encoding: "Identity-H",
            descendantSubtype: "CIDFontType0",
            baseFont: "ABCDEF+MS-Mincho"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let dictionary = try #require(PDFGlyphIndex.fontDictionary(for: "F1", page: page))
        let fontSize: CGFloat = 9.4395
        let resolution = PDFEmbeddedFontLoader.resolveFont(
            fontDict: dictionary,
            size: fontSize,
            replacementText: "11",
            supportingText: "2026年11月30日",
            selectedWidth: 9.45
        )
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "11",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): resolution.font]
        ))
        let renderedWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        #expect(resolution.isExact)
        #expect(resolution.reason == nil)
        #expect(CTFontCopyFamilyName(resolution.font) as String == "MS Mincho")
        #expect(abs(CTFontGetSize(resolution.font) - fontSize) < 0.001)
        #expect(abs(renderedWidth - 9.4395) < 0.02)
    }

    @Test("valid embedded glyph IDs do not require a visible outline")
    func validEmbeddedGlyphIDAllowsWhitespaceWithoutOutline() {
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 12, nil)
        var characters = Array(" ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        #expect(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count))
        #expect(glyphs[0] > 0)
        #expect(PDFEmbeddedFontLoader.isValidGlyphID(Int(glyphs[0]), in: font))
    }

    @Test("line reflow stops before a differently colored suffix")
    func lineReflowPreservesDifferentlyColoredSuffix() throws {
        let url = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            contentStream: "BT /F1 12 Tf 1 0 0 1 20 50 Tm (A) Tj 1 0 0 rg (B) Tj 0 g (C) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "ABC" })
        let target = try #require(index.target(in: run, range: 0..<1, pageIndex: 0))
        let layout = try #require(target.lineLayout)

        #expect(layout.glyphs.map(\.text) == ["A"])
        #expect(layout.maxWidth <= run.glyphs[1].advanceBox.minX - layout.lineStartX + 0.01)
    }

    @Test("embedded-font replacement reflows instead of shrinking when it exceeds the selection width")
    func widerEmbeddedFontReplacementRequestsLineReflow() {
        #expect(PDFEmbeddedFontLoader.replacementNeedsLineReflow(replacementWidth: 18, selectedWidth: 9))
        #expect(!PDFEmbeddedFontLoader.replacementNeedsLineReflow(replacementWidth: 9, selectedWidth: 9))
        #expect(!PDFEmbeddedFontLoader.replacementNeedsLineReflow(replacementWidth: 18, selectedWidth: nil))
    }

    @Test("Type0 font reports subset, descendant and Identity-H safely")
    func type0FontDescriptionAndIdentityMapping() throws {
        let url = type0FontFixture(encoding: "Identity-H")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let dictionary = try #require(PDFGlyphIndex.fontDictionary(for: "F1", page: page))
        let description = PDFEmbeddedFontLoader.describe(fontDict: dictionary)
        #expect(description.pdfName == "ABCDEF+MS-Gothic")
        #expect(description.subtype == "Type0")
        #expect(description.descendantSubtype == "CIDFontType2")
        #expect(description.encoding == "Identity-H")
        #expect(description.isSubset)
        #expect(!description.hasEmbeddedProgram)
        #expect(PDFFontInfoLoader.load(from: dictionary).isIdentityCIDToGID)

        let otherURL = type0FontFixture(encoding: "UniJIS-UTF16-H")
        defer { try? FileManager.default.removeItem(at: otherURL) }
        let otherDocument = try #require(PDFDocument(url: otherURL))
        let otherPage = try #require(otherDocument.page(at: 0))
        let otherDictionary = try #require(PDFGlyphIndex.fontDictionary(for: "F1", page: otherPage))
        #expect(!PDFFontInfoLoader.load(from: otherDictionary).isIdentityCIDToGID)

        let cidType0URL = type0FontFixture(encoding: "Identity-H", descendantSubtype: "CIDFontType0")
        defer { try? FileManager.default.removeItem(at: cidType0URL) }
        let cidType0Document = try #require(PDFDocument(url: cidType0URL))
        let cidType0Page = try #require(cidType0Document.page(at: 0))
        let cidType0Dictionary = try #require(PDFGlyphIndex.fontDictionary(for: "F1", page: cidType0Page))
        #expect(!PDFFontInfoLoader.load(from: cidType0Dictionary).isIdentityCIDToGID)
    }

    @Test("selected replacement previews explicit local font before commit")
    @MainActor
    func replacementFontChoicePreviewsResolvedFamily() throws {
        let url = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 300, height: 100),
            contentStream: "BT /F1 12 Tf 1 0 0 1 30 50 Tm (12) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(initialURL: url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "12" })
        let target = try #require(index.target(in: run, range: 0..<2, pageIndex: 0))
        model.select(target)
        #expect(model.selectedFontDescription?.pdfName == "Helvetica")
        model.setReplacementFontChoice(.helveticaNeue)
        model.updateEditorText("123")
        #expect(model.replacementFontPreview?.familyName == "Helvetica Neue")
        #expect(model.replacementFontPreview?.reason == nil)
        model.applyReplacement()
        #expect(model.edits.first?.replacement?.resolvedFont != nil)
    }

    private func type0FontFixture(
        encoding: String,
        descendantSubtype: String = "CIDFontType2",
        baseFont: String = "ABCDEF+MS-Gothic"
    ) -> URL {
        RawPDFBuilder.build(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type0 /BaseFont /\(baseFont) /Encoding /\(encoding) /DescendantFonts [5 0 R] >>",
            "<< /Type /Font /Subtype /\(descendantSubtype) /BaseFont /\(baseFont) /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 1000 >>",
            RawPDFBuilder.streamObject(dict: "", streamContent: "")
        ])
    }

    @Test("standalone replacement render keeps the requested point size when space is tight")
    func replacementRenderDoesNotShrinkWhenTight() {
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 12, nil)
        let originalLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: "8",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        let originalWidth = CGFloat(CTLineGetTypographicBounds(originalLine, nil, nil, nil))
        let plan = PDFTextRenderer.renderPlan(
            text: "88",
            font: font,
            color: .black,
            maxWidth: originalWidth
        )

        #expect(plan.fontSize == 12)
        #expect(plan.scale == 1)
    }

    @Test("standalone replacement render never silently scales very long text")
    func replacementRenderDoesNotScaleVeryLongText() {
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 12, nil)
        let originalLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: "8",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        let originalWidth = CGFloat(CTLineGetTypographicBounds(originalLine, nil, nil, nil))
        let plan = PDFTextRenderer.renderPlan(
            text: "888888",
            font: font,
            color: .black,
            maxWidth: originalWidth
        )

        #expect(plan.fontSize == 12)
        #expect(plan.scale == 1)
    }

    @Test("replacement expands the run by shifting following glyphs")
    func replacementReflowsFollowingGlyphsIntoAvailableSpace() {
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 12, nil)
        let layout = TextRunLayout(
            glyphs: [
                .init(text: "9", offsetX: 0, advance: 6),
                .init(text: "月", offsetX: 6, advance: 12),
                .init(text: "3", offsetX: 18, advance: 6),
                .init(text: "0", offsetX: 24, advance: 6),
                .init(text: "日", offsetX: 30, advance: 12)
            ],
            selectedRange: 0..<1,
            lineStartX: 100,
            lineWidth: 42,
            maxWidth: 120,
            coverBounds: CGRect(x: 100, y: 0, width: 42, height: 14)
        )

        let plan = PDFTextRenderer.reflowPlan(text: "11", font: font, layout: layout)

        #expect(plan.shift > 0)
        #expect(plan.outputEnd > layout.lineWidth)
        #expect(plan.scale == 1)
        let embeddedPlan = PDFTextRenderer.reflowPlan(
            text: "11", font: font, layout: layout, replacementWidth: 14
        )
        #expect(embeddedPlan.shift == 8)
        #expect(embeddedPlan.outputEnd > layout.lineWidth)
    }

    @Test("同じ行の複数置換は先の幅変更を後の文字へ累積する")
    func composedReplacementsAccumulateEarlierWidthChanges() throws {
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 12, nil)
        let layout = TextRunLayout(
            glyphs: [
                .init(text: "A", offsetX: 0, advance: 8),
                .init(text: "B", offsetX: 8, advance: 8),
                .init(text: "C", offsetX: 16, advance: 8),
                .init(text: "D", offsetX: 24, advance: 8)
            ],
            selectedRange: 0..<1,
            lineStartX: 100,
            lineWidth: 32,
            maxWidth: 100,
            coverBounds: CGRect(x: 100, y: 0, width: 32, height: 14)
        )
        let edits = [
            TextRunReplacement(range: 0..<1, text: "LONG", font: font, color: .black, exactGlyphs: nil),
            TextRunReplacement(range: 2..<3, text: "X", font: font, color: .black, exactGlyphs: nil)
        ]

        let plan = try #require(PDFTextRenderer.composedReflowPlan(layout: layout, replacements: edits))

        #expect(plan.replacements.count == 2)
        #expect(plan.replacements[0].offsetX == 0)
        #expect(plan.replacements[1].offsetX > layout.glyphs[2].offsetX)
        #expect(plan.glyphs.first?.offsetX ?? 0 > layout.glyphs[1].offsetX)
        #expect(plan.scale == 1)
    }

    @Test("line reflow stops at a different font resource")
    func replacementDoesNotReflowAcrossFontResources() throws {
        let baseline: CGFloat = 60
        func makeRun(_ pieces: [(String, CGFloat, CGFloat)], key: String) -> ScannedRun {
            let glyphs = pieces.map { text, x, width in
                ScannedGlyph(text: text,
                             advanceBox: CGRect(x: x, y: 57, width: width, height: 13),
                             baseline: baseline, fontKey: key, fontSize: 12,
                             advance: width, fillColor: .black)
            }
            let box = glyphs.map(\.advanceBox).reduce(CGRect.null) { $0.union($1) }
            return ScannedRun(glyphs: glyphs, text: glyphs.map(\.text).joined(), box: box,
                              baseline: baseline, fontKey: key, fontSize: 12)
        }
        let digit = makeRun([("9", 100, 7)], key: "F1")
        let remainder = makeRun([("月", 107, 12), ("3", 119, 7), ("0", 126, 7), ("日", 133, 12)], key: "F2")
        let nextColumn = makeRun([("他", 190, 12)], key: "F3")
        let index = PageTextIndex(runs: [digit, remainder, nextColumn],
                                  pageBounds: CGRect(x: 0, y: 0, width: 260, height: 120))
        let target = try #require(index.target(in: digit, range: 0..<1, pageIndex: 0))
        let layout = try #require(target.lineLayout)
        #expect(layout.glyphs.map(\.text).joined() == "9")
        #expect(layout.selectedRange == 0..<1)
        #expect(layout.lineStartX + layout.maxWidth == 107)
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 12, nil)
        let plan = PDFTextRenderer.reflowPlan(text: "11", font: font, layout: layout)
        #expect(plan.shift > 0)
        #expect(plan.scale == 1)
        #expect(plan.outputEnd > layout.maxWidth)
    }

    @Test("line reflow keeps later glyphs with a different fill color out of the selected run")
    func replacementDoesNotReflowAcrossFillColorRuns() throws {
        let baseline: CGFloat = 60
        func makeRun(_ text: String, x: CGFloat, color: NSColor) -> ScannedRun {
            let width: CGFloat = 8
            let glyph = ScannedGlyph(text: text,
                                     advanceBox: CGRect(x: x, y: 57, width: width, height: 13),
                                     baseline: baseline, fontKey: "F1", fontSize: 12,
                                     advance: width, fillColor: color)
            return ScannedRun(glyphs: [glyph], text: text, box: glyph.advanceBox,
                              baseline: baseline, fontKey: "F1", fontSize: 12)
        }
        let selected = makeRun("9", x: 100, color: .black)
        let differentlyColored = makeRun("月", x: 108, color: .red)
        let index = PageTextIndex(runs: [selected, differentlyColored],
                                  pageBounds: CGRect(x: 0, y: 0, width: 260, height: 120))

        let target = try #require(index.target(in: selected, range: 0..<1, pageIndex: 0))
        let layout = try #require(target.lineLayout)

        #expect(layout.glyphs.map(\.text).joined() == "9")
        #expect(layout.lineStartX + layout.lineWidth == 108)
        #expect(layout.lineStartX + layout.maxWidth == 108)
    }

    @Test("moved replacement bounds include the full replacement width")
    func movedReplacementBoundsIncludeRenderedText() {
        let target = TextTarget(
            pageIndex: 0,
            bounds: CGRect(x: 40, y: 50, width: 6, height: 12),
            baseline: 52,
            originalText: "9",
            fontSize: 12,
            fontColor: .black,
            fontKey: nil,
            fontIsExact: false,
            coverBounds: CGRect(x: 40, y: 50, width: 6, height: 12),
            maxWidth: 200
        )
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 12, nil)
        let edit = ReplacementEdit(target: target, replacement: "11111111", resolvedFont: font,
                                   fontIsExact: false)

        #expect(edit.displayedTextBounds.width > target.bounds.width)
        #expect(edit.displayedTextBounds.minX == target.bounds.minX)
        let movedEdit = edit.movingSelection(to: CGPoint(x: 80, y: 70))
        #expect(movedEdit.displayedTextBounds.width > target.bounds.width)
        #expect(movedEdit.annotationBounds.contains(movedEdit.displayedTextBounds))
    }

    @Test("insertion creates one movable free-text annotation")
    func createsInsertionAnnotation() throws {
        let page = try #require(PDFPage(image: testImage()))
        let pageBounds = page.bounds(for: .mediaBox)
        let bounds = PDFEditEngine.insertionBounds(
            at: CGPoint(x: pageBounds.maxX - 5, y: pageBounds.maxY - 5),
            text: "追加テキスト",
            fontName: "Hiragino Sans",
            fontSize: 14,
            pageBounds: pageBounds
        )
        let annotation = PDFEditEngine.makeInsertionAnnotation(
            bounds: bounds,
            text: "追加テキスト",
            fontName: "Hiragino Sans",
            fontSize: 14,
            fontColor: .black
        )
        page.addAnnotation(annotation)

        #expect(pageBounds.contains(bounds))
        #expect(page.annotations.count == 1)
        #expect(annotation.type == "FreeText")
        #expect(annotation.userName == PDFEditEngine.draftMarker)
        #expect(annotation.contents == "追加テキスト")
    }

    @Test("moving selected PDF text updates preview, export, and undo")
    @MainActor
    func movingOriginalTextRoundTrips() throws {
        let fixtureURL = try SyntheticFixture.build(pageBounds: CGRect(x: 0, y: 0, width: 300, height: 160)) { context in
            let font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
            SyntheticFixture.drawLine("A04B".map { .init(character: $0, font: font) },
                                      startX: 80, baseline: 60, gap: 0, in: context)
        }
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let model = EditorModel(initialURL: fixtureURL)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first)
        let digit = try #require(run.glyphs.firstIndex { $0.text == "4" })
        let target = try #require(index.target(in: run, range: digit..<(digit + 1), pageIndex: 0))
        model.select(target)
        model.moveSelection(by: CGPoint(x: 30, y: 20))

        let applied = try #require(model.edits.last)
        let replacement = try #require(applied.replacement)
        let destination = try #require(replacement.destinationOrigin)
        #expect(destination.x == target.bounds.minX + 30)
        #expect(destination.y == target.baseline + 20)
        #expect(page.annotations.count == 2)
        #expect(replacement.annotationBounds.contains(destination))
        let movedText = try #require(page.annotations.compactMap { $0 as? ReplacementTextAnnotation }.first)
        let movedCover = try #require(page.annotations.compactMap { $0 as? ReplacementCoverAnnotation }.first)
        #expect(movedText.bounds == replacement.displayedTextBounds)
        #expect(movedCover.bounds == replacement.coverBounds)

        model.moveExistingEdit(id: replacement.id, by: CGPoint(x: 12, y: -5))
        #expect(page.annotations.count == 2)
        #expect(model.activeReplacements.count == 1)
        let movedAgain = try #require(model.activeReplacements.first?.destinationOrigin)
        #expect(movedAgain.x == destination.x + 12)
        #expect(movedAgain.y == destination.y - 5)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-move-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: fixtureURL, edits: model.activeReplacements, to: output)
        let exportedDocument = try #require(PDFDocument(url: output))
        let exported = try #require(exportedDocument.page(at: 0))
        #expect(exported.string?.contains("4") == true)

        model.undoLastEdit()
        #expect(page.annotations.count == 2)
        #expect(model.activeReplacements.first?.destinationOrigin == destination)
        model.undoLastEdit()
        #expect(page.annotations.isEmpty)
        #expect(model.edits.isEmpty)
    }

    @Test("automatic font resolution always returns an installed font")
    func resolvesAvailableFont() throws {
        let page = try #require(PDFPage(image: testImage()))
        let resolution = PDFFontResolver.resolve(on: page, at: CGPoint(x: 100, y: 100))

        #expect(NSFont(name: resolution.resolvedName, size: resolution.size) != nil)
        #expect(resolution.size >= 6)
        #expect(resolution.size <= 72)
    }

    private func testImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 595, height: 842))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 595, height: 842)).fill()
        image.unlockFocus()
        return image
    }
}

// MARK: - PageTextIndex / クラスタ判定（合成フィクスチャ）

@Suite("PageTextIndex geometry (synthetic wkhtmltopdf-style fixture)")
struct PageTextIndexGeometryTests {
    /// ラテン文字＋数字を「1 グリフずつ独立した Tj」で 1 行描画した PDF。
    private func makeLatinDigitFixture() throws -> (url: URL, baseline: CGFloat, font: NSFont) {
        let pageBounds = CGRect(x: 0, y: 0, width: 300, height: 150)
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let baseline: CGFloat = 100
        let url = try SyntheticFixture.build(pageBounds: pageBounds) { context in
            _ = SyntheticFixture.drawLine(
                "A04B".map { SyntheticFixture.GlyphSpec(character: $0, font: font) },
                startX: 20,
                baseline: baseline,
                gap: 1.0,
                in: context
            )
        }
        return (url, baseline, font)
    }

    /// 漢字（部首コードポイント含む）＋数字を「1 グリフずつ独立した Tj」で描画した PDF。
    /// wkhtmltopdf 生成 PDF の ToUnicode に見られる、漢字に挟まれた数字を再現する。
    /// PDF ファイル生成を経由せず、`ScannedGlyph`/`ScannedRun` を直接組み立てる。
    /// wkhtmltopdf 生成 PDF の ToUnicode が「年 04 ⽉」のように標準漢字と
    /// 部首コードポイント(U+2E80-2FDF)を混在させる特徴を再現しつつ、
    /// PDF 生成系(Quartz の ToUnicode 省略等)の不確実性を避けて
    /// クラスタ判定・coverBounds の計算ロジックそのものを検証する。
    private func makeKanjiDigitRun(baseline: CGFloat, size: CGFloat) -> ScannedRun {
        func glyph(_ text: String, x: CGFloat, emWidth: CGFloat) -> ScannedGlyph {
            let width = emWidth * size
            return ScannedGlyph(
                text: text,
                advanceBox: CGRect(x: x, y: baseline - 0.12 * size, width: width, height: size),
                baseline: baseline,
                fontKey: "F1",
                fontSize: size,
                advance: width,
                fillColor: .black
            )
        }
        var x: CGFloat = 20
        var glyphs: [ScannedGlyph] = []
        // "年"(標準漢字 U+5E74) 0 4 "⽉"(部首補助 U+2F49)
        for (text, emWidth) in [("年", 0.992), ("0", 0.625), ("4", 0.625), ("⽉", 0.992)] {
            let g = glyph(text, x: x, emWidth: emWidth)
            glyphs.append(g)
            x += emWidth * size
        }
        var box = glyphs[0].advanceBox
        for g in glyphs.dropFirst() { box = box.union(g.advanceBox) }
        return ScannedRun(glyphs: glyphs, text: glyphs.map(\.text).joined(), box: box, baseline: baseline, fontKey: "F1", fontSize: size)
    }

    @Test("digit run surrounded by latin resolves to just the digits, without bleeding into neighbors")
    @MainActor
    func latinDigitClusterDoesNotBleed() throws {
        let fixture = try makeLatinDigitFixture()
        let document = try #require(PDFDocument(url: fixture.url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)

        #expect(!index.runs.isEmpty)
        let run = try #require(index.runs.first)
        #expect(run.text == "A04B")

        let digitGlyphIndex = try #require(run.glyphs.firstIndex { $0.text == "4" })
        let point = CGPoint(
            x: run.glyphs[digitGlyphIndex].advanceBox.midX,
            y: run.glyphs[digitGlyphIndex].advanceBox.midY
        )

        let target = try #require(index.cluster(at: point, pageIndex: 0))
        #expect(target.originalText == "04")
        #expect(abs(target.baseline - fixture.baseline) < 0.01)

        let aGlyph = try #require(run.glyphs.first { $0.text == "A" })
        let bGlyph = try #require(run.glyphs.first { $0.text == "B" })

        // A-3 の修正: 消去矩形は隣接グリフの advance box を絶対に越えない。
        #expect(target.coverBounds.minX >= aGlyph.advanceBox.maxX - 0.001)
        #expect(target.coverBounds.maxX <= bGlyph.advanceBox.minX + 0.001)
        #expect(target.bounds.minX >= aGlyph.advanceBox.maxX)
        #expect(target.bounds.maxX <= bGlyph.advanceBox.minX)

        // maxWidth は右隣のグリフの手前まで。
        #expect(target.maxWidth <= bGlyph.advanceBox.minX - target.bounds.minX + 0.001)

        try? FileManager.default.removeItem(at: fixture.url)
    }

    @Test("digit run surrounded by kanji (including radical code points) clusters and avoids neighbors")
    func kanjiDigitClusterDoesNotBleed() throws {
        let baseline: CGFloat = 60
        let run = makeKanjiDigitRun(baseline: baseline, size: 14)
        let index = PageTextIndex(runs: [run])

        let digitGlyphIndex = try #require(run.glyphs.firstIndex { $0.text == "4" })
        let point = CGPoint(
            x: run.glyphs[digitGlyphIndex].advanceBox.midX,
            y: run.glyphs[digitGlyphIndex].advanceBox.midY
        )

        let target = try #require(index.cluster(at: point, pageIndex: 0))
        #expect(target.originalText == "04")

        let yearGlyph = try #require(run.glyphs.first { $0.text == "年" })
        let monthGlyph = try #require(run.glyphs.first { $0.text == "⽉" })
        #expect(target.coverBounds.minX >= yearGlyph.advanceBox.maxX - 0.001)
        #expect(target.coverBounds.maxX <= monthGlyph.advanceBox.minX + 0.001)
        #expect(target.bounds.minX >= yearGlyph.advanceBox.maxX)
        #expect(target.bounds.maxX <= monthGlyph.advanceBox.minX)
    }

    @Test("standalone kanji click resolves to a single-character cluster (does not merge across digits)")
    func kanjiAloneDoesNotMergeWithDigits() throws {
        let baseline: CGFloat = 60
        let run = makeKanjiDigitRun(baseline: baseline, size: 14)
        let index = PageTextIndex(runs: [run])

        let yearGlyph = try #require(run.glyphs.first { $0.text == "年" })
        let point = CGPoint(x: yearGlyph.advanceBox.midX, y: yearGlyph.advanceBox.midY)
        let target = try #require(index.cluster(at: point, pageIndex: 0))
        #expect(target.originalText == "年")
    }

    @Test("clicking directly on a thousands-separator comma still selects the whole number")
    func clickingOnCommaSelectsWholeDigitCluster() throws {
        let baseline: CGFloat = 60
        let size: CGFloat = 12
        func glyph(_ text: String, x: CGFloat, width: CGFloat) -> ScannedGlyph {
            ScannedGlyph(
                text: text,
                advanceBox: CGRect(x: x, y: baseline - 2, width: width, height: size),
                baseline: baseline, fontKey: "F1", fontSize: size, advance: width, fillColor: .black
            )
        }
        // 桁区切りを含む架空の金額を 1 グリフずつ配置する。
        let texts = ["1", "2", ",", "3", "4", "5"]
        var x: CGFloat = 100
        var glyphs: [ScannedGlyph] = []
        for text in texts {
            glyphs.append(glyph(text, x: x, width: 6))
            x += 6
        }
        var box = glyphs[0].advanceBox
        for g in glyphs.dropFirst() { box = box.union(g.advanceBox) }
        let run = ScannedRun(glyphs: glyphs, text: texts.joined(), box: box, baseline: baseline, fontKey: "F1", fontSize: size)
        let index = PageTextIndex(runs: [run])

        let commaGlyph = try #require(run.glyphs.first { $0.text == "," })
        let point = CGPoint(x: commaGlyph.advanceBox.midX, y: commaGlyph.advanceBox.midY)
        let target = try #require(index.cluster(at: point, pageIndex: 0))
        #expect(target.originalText == "12,345")
    }

    @Test("maxWidth does not bleed into the next column's run on the same line")
    func maxWidthDoesNotBleedIntoNextColumn() throws {
        let baseline: CGFloat = 60
        let size: CGFloat = 12

        func glyph(_ text: String, x: CGFloat, width: CGFloat, fontKey: String) -> ScannedGlyph {
            ScannedGlyph(
                text: text,
                advanceBox: CGRect(x: x, y: baseline - 2, width: width, height: size),
                baseline: baseline,
                fontKey: fontKey,
                fontSize: size,
                advance: width,
                fillColor: .black
            )
        }

        // 隣の列との間隔が約 3.6pt のケースを模す。
        // 2 つの run はフォントキーを分けて、run 分割の境界をまたぐケースを再現する。
        let g0 = glyph("0", x: 100, width: 7, fontKey: "F1")
        let g1 = glyph("1", x: 107, width: 7, fontKey: "F1")
        let runA = ScannedRun(
            glyphs: [g0, g1], text: "01",
            box: g0.advanceBox.union(g1.advanceBox),
            baseline: baseline, fontKey: "F1", fontSize: size
        )

        let gapToNextColumn: CGFloat = 3.6
        let nextColumnStartX = runA.box.maxX + gapToNextColumn
        let g2 = glyph("2", x: nextColumnStartX, width: 7, fontKey: "F2")
        let g3 = glyph("0", x: nextColumnStartX + 7, width: 7, fontKey: "F2")
        let runB = ScannedRun(
            glyphs: [g2, g3], text: "20",
            box: g2.advanceBox.union(g3.advanceBox),
            baseline: baseline, fontKey: "F2", fontSize: size
        )

        let index = PageTextIndex(runs: [runA, runB])
        let target = try #require(index.cluster(at: CGPoint(x: g1.advanceBox.midX, y: baseline), pageIndex: 0))
        #expect(target.originalText == "01")

        // maxWidth は次の列 (runB) の手前までで、それを越えて隣の列に重ならない。
        #expect(target.bounds.minX + target.maxWidth <= runB.box.minX + 0.01)
        #expect(target.coverBounds.maxX <= runB.box.minX)
    }

    @Test("fill color is tracked from g/rg/k operators instead of defaulting to black")
    @MainActor
    func fillColorIsTrackedFromContentStream() throws {
        // 黒固定デグレの回帰テスト: rg(赤) で描いた文字は赤として取得できること。
        let content = """
        BT
        /F1 12 Tf
        1 0 0 1 72 100 Tm
        0 0 0 rg
        (black) Tj
        ET
        BT
        /F1 12 Tf
        1 0 0 1 72 80 Tm
        1 0 0 rg
        (red) Tj
        ET
        """
        let url = RawPDFBuilder.singlePagePDF(pageBounds: CGRect(x: 0, y: 0, width: 300, height: 150), contentStream: content)
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)

        let redRun = try #require(index.runs.first { $0.text == "red" })
        let target = try #require(index.cluster(
            at: CGPoint(x: redRun.glyphs[0].advanceBox.midX, y: redRun.baseline),
            pageIndex: 0
        ))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (target.fontColor.usingColorSpace(.deviceRGB) ?? target.fontColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r > 0.9)
        #expect(g < 0.1)
        #expect(b < 0.1)

        let blackRun = try #require(index.runs.first { $0.text == "black" })
        let blackTarget = try #require(index.cluster(
            at: CGPoint(x: blackRun.glyphs[0].advanceBox.midX, y: blackRun.baseline),
            pageIndex: 0
        ))
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        (blackTarget.fontColor.usingColorSpace(.deviceRGB) ?? blackTarget.fontColor).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        #expect(br < 0.1)
        #expect(bg < 0.1)
        #expect(bb < 0.1)

        try? FileManager.default.removeItem(at: url)
    }

    @Test("tagged content inside ordinary BDC/EMC (no ActualText) is still extracted")
    @MainActor
    func taggedContentIsExtracted() throws {
        // Word/InDesign や一部の Chrome 出力のようなタグ付き PDF を模す:
        // 本文が /P <</MCID 0>> BDC ... EMC の中にある（ActualText は無い）。
        let content = """
        BT
        /F1 12 Tf
        1 0 0 1 72 100 Tm
        /P <</MCID 0>> BDC
        (Tagged body text 12345) Tj
        EMC
        ET
        BT
        /F1 12 Tf
        1 0 0 1 72 80 Tm
        (Untagged line 67890) Tj
        ET
        """
        let url = RawPDFBuilder.singlePagePDF(pageBounds: CGRect(x: 0, y: 0, width: 300, height: 150), contentStream: content)
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)

        let allText = index.runs.map(\.text).joined(separator: "|")
        #expect(allText.contains("Tagged body text 12345"), "タグ付き本文が読めていない: \(allText)")
        #expect(allText.contains("Untagged line 67890"))

        try? FileManager.default.removeItem(at: url)
    }

    @Test("duplicate drawing inside an empty /ActualText span is suppressed")
    @MainActor
    func duplicateActualTextSpanIsSuppressed() throws {
        // サンプル PDF の「請求書」タイトル等と同じパターン: 同じ文字列を、
        // 空の /ActualText を持つ marked content の中でもう一度描画する。
        let content = """
        BT
        /F1 12 Tf
        1 0 0 1 72 100 Tm
        (AB) Tj
        1 0 0 1 71.5 100 Tm
        /Span <</ActualText <> >> BDC
        (AB) Tj
        EMC
        ET
        """
        let url = RawPDFBuilder.singlePagePDF(pageBounds: CGRect(x: 0, y: 0, width: 300, height: 150), contentStream: content)
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)

        let totalGlyphs = index.runs.reduce(0) { $0 + $1.glyphs.count }
        #expect(totalGlyphs == 2, "重複描画が除去されていない (runs=\(index.runs.map(\.text)))")
        #expect(index.runs.contains { $0.text == "AB" })

        try? FileManager.default.removeItem(at: url)
    }

    @Test("clicking near but not exactly on a glyph still resolves the nearest character")
    @MainActor
    func nearMissClickResolvesNearestGlyph() throws {
        let fixture = try makeLatinDigitFixture()
        let document = try #require(PDFDocument(url: fixture.url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first)
        let bGlyph = try #require(run.glyphs.first { $0.text == "B" })

        // グリフのすぐ上（2pt）をクリック。
        let point = CGPoint(x: bGlyph.advanceBox.midX, y: bGlyph.advanceBox.maxY + 2)
        let target = index.cluster(at: point, pageIndex: 0)
        #expect(target?.originalText == "B")

        try? FileManager.default.removeItem(at: fixture.url)
    }

    @Test("clicking far from any glyph returns nil")
    @MainActor
    func farClickReturnsNil() throws {
        let fixture = try makeLatinDigitFixture()
        let document = try #require(PDFDocument(url: fixture.url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)

        let target = index.cluster(at: CGPoint(x: 250, y: 20), pageIndex: 0)
        #expect(target == nil)

        try? FileManager.default.removeItem(at: fixture.url)
    }

    @Test("replacement render reflows the same run without wrapping or crossing the next run")
    @MainActor
    func replacementRenderStaysOnOneLineWithSameBaseline() throws {
        let fixture = try makeLatinDigitFixture()
        let document = try #require(PDFDocument(url: fixture.url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first)
        let digitGlyphIndex = try #require(run.glyphs.firstIndex { $0.text == "4" })
        let point = CGPoint(
            x: run.glyphs[digitGlyphIndex].advanceBox.midX,
            y: run.glyphs[digitGlyphIndex].advanceBox.midY
        )
        let target = try #require(index.cluster(at: point, pageIndex: 0))

        let fallbackFont = CTFontCreateWithName("HelveticaNeue" as CFString, target.fontSize, nil)
        let edit = ReplacementEdit(
            target: target,
            replacement: "9999",
            resolvedFont: fallbackFont,
            fontIsExact: false
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-text-bench-fixture-out-\(UUID().uuidString).pdf")
        try PDFExportEngine.export(sourceURL: fixture.url, edits: [edit], to: outputURL)

        let outputDocument = try #require(PDFDocument(url: outputURL))
        let outputPage = try #require(outputDocument.page(at: 0))
        // 通常の CoreText 文字描画は PDF のテキスト演算子になるため、
        // 輪郭パス専用の InkScanner では検出されない。文字抽出と再配置計算を検証する。
        #expect(outputPage.string?.contains("9999") == true)
        let lineLayout = try #require(target.lineLayout)
        let plan = PDFTextRenderer.reflowPlan(text: "9999", font: fallbackFont, layout: lineLayout)
        #expect(plan.shift > 0)
        #expect(plan.outputEnd > lineLayout.lineWidth)
        #expect(plan.outputEnd <= lineLayout.maxWidth)
        #expect(plan.scale == 1)

        try? FileManager.default.removeItem(at: fixture.url)
        try? FileManager.default.removeItem(at: outputURL)
    }
}
