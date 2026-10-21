import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

/// 実データを使わず、選択→置換/移動→PDFKitプレビュー/書き出しを通す受け入れテスト。
@Suite("PDF editing acceptance")
struct PDFEditingAcceptanceTests {
    @Test("9を10に置換すると後続の日付を押し出し、元のフォントと鮮明さを保つ")
    @MainActor
    func replacementReflowsDateAndKeepsVectorRendering() throws {
        let fixture = try makeDateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let model = EditorModel(initialURL: fixture.url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.glyphs.map(\.text).joined() == fixture.date })
        let digitIndex = try #require(run.glyphs.firstIndex { $0.text == fixture.replacedDigit })
        let target = try #require(index.target(
            in: run,
            range: digitIndex..<(digitIndex + 1),
            pageIndex: 0
        ))
        #expect(target.originalText == "9")
        #expect(target.lineLayout?.glyphs.map(\.text).joined() == fixture.date)

        model.select(target)
        model.updateEditorText("10")
        model.commitEditorText()

        let edit = try #require(model.activeReplacements.first)
        let layout = try #require(edit.lineLayout)
        let font = try #require(edit.resolvedFont)
        let replacementWidth = edit.exactGlyphs.map { glyphs in
            glyphs.reduce(CGFloat.zero) { $0 + $1.emWidth } * CTFontGetSize(font)
        }
        let plan = PDFTextRenderer.reflowPlan(
            text: "10",
            font: font,
            layout: layout,
            replacementWidth: replacementWidth
        )

        #expect(edit.replacement == "10")
        #expect(CTFontCopyFamilyName(font) as String == "Helvetica")
        #expect(abs(CTFontGetSize(font) - target.fontSize) < 0.51)
        #expect(plan.shift > 0)
        #expect(plan.outputEnd > layout.lineWidth)
        #expect(plan.outputEnd <= layout.maxWidth)
        #expect(plan.scale == 1)
        #expect(layout.glyphs[layout.selectedRange.upperBound].text == "-")

        let dateBounds = CGRect(
            x: layout.lineStartX + layout.selectedStartX,
            y: layout.coverBounds.minY,
            width: plan.outputEnd - layout.selectedStartX,
            height: layout.coverBounds.height
        )
        let oneX = try rasterMetrics(page: page, focus: dateBounds, scale: 1)
        let fourX = try rasterMetrics(page: page, focus: dateBounds, scale: 4)
        #expect(fourX.pixelWidth >= oneX.pixelWidth * 3)
        #expect(fourX.darkPixels > 0)
        #expect(fourX.antialiasPixels > 0)
        // ベクター描画は拡大率に応じて輪郭のサンプルが増える。低解像度画像の
        // 拡大で起きる階段状の同じ画素ブロックを検出する。
        #expect(fourX.edgeTransitions > oneX.edgeTransitions * 2)

        let output = temporaryPDFURL(prefix: "date-acceptance")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: fixture.url, edits: model.activeReplacements, to: output)
        let exportedDocument = try #require(PDFDocument(url: output))
        let exportedPage = try #require(exportedDocument.page(at: 0))
        let exportedRaster = try rasterMetrics(page: exportedPage, focus: dateBounds, scale: 4)
        #expect(exportedRaster.darkPixels > 0)
        #expect(exportedRaster.antialiasPixels > 0)

        model.undoLastEdit()
        #expect(page.annotations.isEmpty)
        #expect(model.activeReplacements.isEmpty)
    }

    @Test("同じ日付行の2箇所を置換しても先の幅変更と後続編集を合成する")
    @MainActor
    func multipleDateReplacementsComposeAndUndo() throws {
        let fixture = try makeDateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let model = EditorModel(initialURL: fixture.url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.glyphs.map(\.text).joined() == fixture.date })
        let firstIndex = try #require(run.glyphs.firstIndex { $0.text == "9" })
        let secondIndex = try #require(run.glyphs.firstIndex { $0.text == "3" })
        let firstTarget = try #require(index.target(in: run, range: firstIndex..<(firstIndex + 1), pageIndex: 0))
        let secondTarget = try #require(index.target(in: run, range: secondIndex..<(secondIndex + 1), pageIndex: 0))

        model.select(firstTarget)
        model.updateEditorText("10")
        model.commitEditorText()
        model.select(secondTarget)
        model.updateEditorText("4")
        model.commitEditorText()

        let composed = try #require(model.activeReplacements.first)
        let layout = try #require(composed.lineLayout)
        let plan = try #require(PDFTextRenderer.composedReflowPlan(
            layout: layout,
            replacements: composed.lineReplacements,
            startingAt: composed.lineCompositionStart
        ))
        let later = try #require(plan.replacements.first { $0.replacement.text == "4" })
        #expect(model.activeReplacements.count == 1)
        #expect(composed.composesLineEdits)
        #expect(composed.lineReplacements.count == 2)
        #expect(later.offsetX > layout.glyphs[secondIndex].offsetX)
        #expect(plan.scale == 1)

        let output = temporaryPDFURL(prefix: "multi-date-acceptance")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: fixture.url, edits: model.activeReplacements, to: output)
        let exportedPage = try #require(PDFDocument(url: output)?.page(at: 0))
        let raster = try rasterMetrics(page: exportedPage, focus: layout.coverBounds, scale: 4)
        #expect(raster.darkPixels > 0)
        #expect(raster.antialiasPixels > 0)

        model.undoLastEdit()
        let prior = try #require(model.activeReplacements.first)
        #expect(model.activeReplacements.count == 1)
        #expect(prior.lineReplacements.count == 1)
        #expect(page.annotations.count == 1)
    }

    @Test("日本語の日付で9を10に置換してもサイズとベクター描画を保つ")
    @MainActor
    func japaneseDateReplacementReflowsWithoutRasterizing() throws {
        PDFEmbeddedFontLoader.registerBundledFonts()
        let font = try #require(NSFont(name: "Noto Sans JP", size: 16))
        let date = "2026年9月30日"
        let url = try SyntheticFixture.build(pageBounds: CGRect(x: 0, y: 0, width: 480, height: 140)) { context in
            let attributed = NSAttributedString(
                string: date,
                attributes: [.font: font, .foregroundColor: NSColor.black]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 36, y: 76)
            CTLineDraw(line, context)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EditorModel(initialURL: url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.glyphs.count == date.count })
        // Quartz が生成する CJK ToUnicode は macOS によって欠落することがある。
        // フィクスチャの既知の文字列をレイアウトへ戻し、実PDFのグリフ位置と
        // フォント辞書を使って置換・再配置・書き出しまで検証する。
        let originalGlyphs = Array(date).map(String.init)
        let digitIndex = try #require(originalGlyphs.firstIndex(of: "9"))
        let lineStartX = try #require(run.glyphs.first).advanceBox.minX
        let lineEndX = try #require(run.glyphs.last).advanceBox.maxX
        let layoutGlyphs = zip(originalGlyphs, run.glyphs).map { text, glyph in
            TextRunLayout.Glyph(
                text: text,
                offsetX: glyph.advanceBox.minX - lineStartX,
                advance: glyph.advance
            )
        }
        let lineLayout = TextRunLayout(
            glyphs: layoutGlyphs,
            selectedRange: digitIndex..<(digitIndex + 1),
            lineStartX: lineStartX,
            lineWidth: lineEndX - lineStartX,
            maxWidth: page.bounds(for: .mediaBox).maxX - lineStartX,
            coverBounds: run.box
        )
        let digit = run.glyphs[digitIndex]
        let target = TextTarget(
            pageIndex: 0,
            bounds: digit.advanceBox,
            baseline: digit.baseline,
            originalText: "9",
            fontSize: digit.fontSize,
            fontColor: digit.fillColor,
            fontKey: digit.fontKey,
            fontIsExact: true,
            coverBounds: digit.advanceBox,
            maxWidth: page.bounds(for: .mediaBox).maxX - lineStartX,
            lineLayout: lineLayout
        )
        model.select(target)
        model.updateEditorText("10")
        model.commitEditorText()

        let edit = try #require(model.activeReplacements.first)
        let resolvedFont = try #require(edit.resolvedFont)
        let plan = PDFTextRenderer.reflowPlan(text: "10", font: resolvedFont, layout: lineLayout)
        #expect(edit.replacement == "10")
        #expect(CTFontGetSize(resolvedFont) == digit.fontSize)
        #expect(plan.shift > 0)
        #expect(plan.outputEnd > lineLayout.lineWidth)
        #expect(plan.outputEnd <= lineLayout.maxWidth)
        #expect(plan.scale == 1)

        let focus = CGRect(
            x: lineStartX,
            y: lineLayout.coverBounds.minY,
            width: plan.outputEnd,
            height: lineLayout.coverBounds.height
        )
        let preview = try rasterMetrics(page: page, focus: focus, scale: 4)
        #expect(preview.darkPixels > 0)
        #expect(preview.antialiasPixels > 0)
        #expect(preview.edgeTransitions > 100)

        let output = temporaryPDFURL(prefix: "japanese-date-acceptance")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: url, edits: model.activeReplacements, to: output)
        let exportedDocument = try #require(PDFDocument(url: output))
        let exportedPage = try #require(exportedDocument.page(at: 0))
        let exported = try rasterMetrics(page: exportedPage, focus: focus, scale: 4)
        #expect(exported.darkPixels > 0)
        #expect(exported.antialiasPixels > 0)

        model.undoLastEdit()
        #expect(page.annotations.isEmpty)
    }

    @Test("埋め込みフォントのUnicode cmapだけではPDFのグリフ対応とみなさない")
    func embeddedCMapIsNotTrustedWithoutIdentityMapping() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let units = Array("10".utf16)
        var cmapGlyphs = [CGGlyph](repeating: 0, count: units.count)
        #expect(CTFontGetGlyphsForCharacters(font, units, &cmapGlyphs, units.count))
        #expect(cmapGlyphs.allSatisfy { $0 != 0 })

        let simpleSubsetInfo = PDFFontInfo(
            bytesPerCode: 1,
            widthTable: [:],
            defaultWidth: 0.5,
            toUnicode: [0x31: "1", 0x30: "0"],
            ascent: 0.8,
            descent: -0.2,
            hasEmbeddedProgram: true,
            unicodeToCode: [:],
            isIdentityCIDToGID: false
        )
        let rejectedResolution = PDFEmbeddedFontLoader.embeddedFontResolution(
            font: font,
            info: simpleSubsetInfo,
            replacementText: "10"
        )
        #expect(rejectedResolution?.isExact == nil)

        let identityInfo = PDFFontInfo(
            bytesPerCode: 2,
            widthTable: [49: 0.5, 48: 0.5],
            defaultWidth: 1,
            toUnicode: [49: "1", 48: "0"],
            ascent: 0.8,
            descent: -0.2,
            hasEmbeddedProgram: true,
            unicodeToCode: ["1": 49, "0": 48],
            isIdentityCIDToGID: true
        )
        let exactResolution = try #require(PDFEmbeddedFontLoader.embeddedFontResolution(
            font: font,
            info: identityInfo,
            replacementText: "10"
        ))
        #expect(exactResolution.isExact)
        #expect(exactResolution.exactGlyphs?.map(\.glyph) == [49, 48])
    }

    @Test("元PDFと同名の端末フォントは代替フォント扱いにしない")
    @MainActor
    func installedSourceFontIsReportedAsExact() throws {
        let url = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 300, height: 100),
            contentStream: "BT /F1 12 Tf 1 0 0 1 24 48 Tm (2026-9-30) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "2026-9-30" })
        let digitIndex = try #require(run.glyphs.firstIndex { $0.text == "9" })
        let target = try #require(index.target(in: run, range: digitIndex..<(digitIndex + 1), pageIndex: 0))

        let result = PDFEditEngine.applyReplacement("10", to: page, target: target)

        #expect(result.fontIsExact)
        #expect(CTFontCopyFamilyName(try #require(result.edit.resolvedFont)) as String == "Helvetica")
    }

    @Test("移動プレビューの文字注釈は文字サイズに沿った小さな範囲を使う")
    @MainActor
    func movedTextUsesTightVectorAnnotationBounds() throws {
        let fixture = try makeDateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let model = EditorModel(initialURL: fixture.url)
        let page = try #require(model.document?.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.glyphs.map(\.text).joined() == fixture.date })
        let target = try #require(index.target(in: run, range: 0..<run.glyphs.count, pageIndex: 0))
        model.select(target)
        model.moveSelection(by: CGPoint(x: 40, y: 12))

        let edit = try #require(model.activeReplacements.first)
        let textAnnotation = try #require(page.annotations.compactMap { $0 as? ReplacementTextAnnotation }.first)
        let coverAnnotation = try #require(page.annotations.compactMap { $0 as? ReplacementCoverAnnotation }.first)
        #expect(page.annotations.count == 2)
        #expect(textAnnotation.bounds == edit.displayedTextBounds)
        #expect(coverAnnotation.bounds == edit.coverBounds)
        #expect(textAnnotation.bounds.width < page.bounds(for: .mediaBox).width / 2)

        let movedBounds = edit.displayedTextBounds
        let raster = try rasterMetrics(page: page, focus: movedBounds, scale: 4)
        #expect(raster.darkPixels > 0)
        #expect(raster.antialiasPixels > 0)

        model.undoLastEdit()
        #expect(page.annotations.isEmpty)
    }

    private func makeDateFixture() throws -> (url: URL, date: String, replacedDigit: String) {
        let font = NSFont(name: "Helvetica", size: 16) ?? .systemFont(ofSize: 16)
        // Quartz が生成した CJK ToUnicode は一部の macOS で「年」を欠落させるため、
        // 受け入れ経路では数字だけの同じ日付構造を使い、漢字混在は別の契約テストで見る。
        let date = "2026-9-30"
        let url = try SyntheticFixture.build(pageBounds: CGRect(x: 0, y: 0, width: 480, height: 140)) { context in
            SyntheticFixture.drawLine(
                date.map { SyntheticFixture.GlyphSpec(character: $0, font: font) },
                startX: 36,
                baseline: 76,
                gap: 0,
                in: context
            )
        }
        return (url, date, "9")
    }

    private struct RasterMetrics {
        let pixelWidth: Int
        let darkPixels: Int
        let antialiasPixels: Int
        let edgeTransitions: Int
    }

    private func rasterMetrics(page: PDFPage, focus: CGRect, scale: CGFloat) throws -> RasterMetrics {
        let mediaBox = page.bounds(for: .mediaBox)
        let size = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let sx = CGFloat(bitmap.pixelsWide) / mediaBox.width
        let sy = CGFloat(bitmap.pixelsHigh) / mediaBox.height
        let x0 = max(0, Int((focus.minX - mediaBox.minX) * sx))
        let x1 = min(bitmap.pixelsWide, Int(ceil((focus.maxX - mediaBox.minX) * sx)))
        let y0 = max(0, Int((mediaBox.maxY - focus.maxY) * sy))
        let y1 = min(bitmap.pixelsHigh, Int(ceil((mediaBox.maxY - focus.minY) * sy)))
        var luminance = Array(repeating: Array(repeating: 1.0, count: max(x1 - x0, 0)), count: max(y1 - y0, 0))
        var darkPixels = 0
        var antialiasPixels = 0

        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let rgb = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let value = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
                luminance[y - y0][x - x0] = value
                if value < 0.4 { darkPixels += 1 }
                if (0.4..<0.98).contains(value) { antialiasPixels += 1 }
            }
        }

        var edgeTransitions = 0
        if luminance.count > 0, luminance[0].count > 1 {
            for row in luminance {
                for x in 1..<row.count where abs(row[x] - row[x - 1]) > 0.2 {
                    edgeTransitions += 1
                }
            }
        }
        if luminance.count > 1, luminance[0].count > 0 {
            for y in 1..<luminance.count {
                for x in luminance[y].indices where abs(luminance[y][x] - luminance[y - 1][x]) > 0.2 {
                    edgeTransitions += 1
                }
            }
        }

        return RasterMetrics(
            pixelWidth: bitmap.pixelsWide,
            darkPixels: darkPixels,
            antialiasPixels: antialiasPixels,
            edgeTransitions: edgeTransitions
        )
    }

    private func temporaryPDFURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
    }
}
