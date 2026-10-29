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
    @Test("文字の直下にある罫線を削らずに同幅の日付を置換する")
    @MainActor
    func sameWidthDateReplacementPreservesAdjacentRule() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 220, height: 100),
            contentStream: """
            0.6 w 30 57.1 m 150 57.1 l S
            BT /F1 12 Tf 1 0 0 1 40 60 Tm (2026-09-30) Tj ET
            """
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let document = try #require(PDFDocument(url: source))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "2026-09-30" })
        let monthStart = try #require(run.text.range(of: "09")).lowerBound.utf16Offset(in: run.text)
        let target = try #require(index.target(
            in: run,
            range: monthStart..<(monthStart + 2),
            pageIndex: 0
        ))
        let ruleFocus = CGRect(x: 30, y: 56.6, width: 120, height: 1.0)
        let sourceRule = try rasterMetrics(page: page, focus: ruleFocus, scale: 8)

        let result = PDFEditEngine.applyReplacement("10", to: page, target: target)
        let output = temporaryPDFURL(prefix: "adjacent-rule")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: source, edits: [result.edit], to: output)

        let exportedPage = try #require(PDFDocument(url: output)?.page(at: 0))
        let exportedRule = try rasterMetrics(page: exportedPage, focus: ruleFocus, scale: 8)
        #expect(target.coverBounds.minY >= target.bounds.minY - 0.001)
        #expect(
            exportedRule.darkPixels >= Int(Double(sourceRule.darkPixels) * 0.95),
            "文字置換の白塗りで隣接する罫線の濃さを失わない"
        )
    }

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
        let previewAnnotation = try #require(
            page.annotations.compactMap { $0 as? ReplacementTextAnnotation }.first
        )
        #expect(!previewAnnotation.shouldDisplay)
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
        let oneX = try previewRasterMetrics(page: page, focus: dateBounds, scale: 1)
        let fourX = try previewRasterMetrics(page: page, focus: dateBounds, scale: 4)
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
        let exportedDocument = try #require(PDFDocument(url: output))
        let exportedPage = try #require(exportedDocument.page(at: 0))
        let raster = try rasterMetrics(page: exportedPage, focus: layout.coverBounds, scale: 4)
        #expect(raster.darkPixels > 0)
        #expect(raster.antialiasPixels > 0)

        model.undoLastEdit()
        let prior = try #require(model.activeReplacements.first)
        #expect(model.activeReplacements.count == 1)
        #expect(prior.lineReplacements.count == 1)
        #expect(page.annotations.count == 1)
    }

    @Test("同じ行に合成された先行置換も現在値から再編集できる")
    @MainActor
    func earlierComposedReplacementCanBeReedited() throws {
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
        model.setCustomFontName("Menlo")
        model.updateEditorText("10")
        model.commitEditorText()
        let firstID = try #require(model.activeReplacements.first?.id)
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
        let firstPlacement = try #require(plan.replacements.first { $0.replacement.id == firstID })
        let hitPoint = CGPoint(
            x: layout.lineStartX + firstPlacement.offsetX + firstPlacement.replacement.renderedWidth / 2,
            y: layout.coverBounds.midY
        )
        #expect(composed.replacementID(at: hitPoint) == firstID)

        model.beginReeditingReplacement(id: firstID)
        #expect(model.replacementText == "10")
        #expect(model.replacementFontChoice == .custom)
        #expect(model.customFontName == "Menlo")
        model.updateEditorText("11")
        model.commitEditorText()

        let revised = try #require(model.activeReplacements.first)
        #expect(revised.lineReplacements.first(where: { $0.id == firstID })?.text == "11")
        #expect(revised.lineReplacements.contains(where: { $0.text == "4" }))
        #expect(page.annotations.count == 1)

        model.undoLastEdit()
        let restored = try #require(model.activeReplacements.first)
        #expect(restored.lineReplacements.first(where: { $0.id == firstID })?.text == "10")
        #expect(restored.lineReplacements.contains(where: { $0.text == "4" }))
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
        let lineFont = try #require(edit.lineFont)
        #expect(PDFEmbeddedFontLoader.missingCharacters(in: date, font: lineFont).isEmpty)
        let suffix = "30日" as CFString
        let suffixFont = CTFontCreateForString(
            lineFont,
            suffix,
            CFRange(location: 0, length: CFStringGetLength(suffix))
        )
        // 置換で押し出された「30日」を一部だけ別書体へフォールバックさせない。
        #expect(CTFontCopyPostScriptName(suffixFont) as String == CTFontCopyPostScriptName(lineFont) as String)
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
        let preview = try previewRasterMetrics(page: page, focus: focus, scale: 4)
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

    @Test("書き出し先で置換文字のUnicode索引が失われた場合も再選択できる")
    @MainActor
    func missingExportedUnicodeMappingGetsInvisibleSearchText() throws {
        PDFEmbeddedFontLoader.registerBundledFonts()
        let source = try SyntheticFixture.build(pageBounds: CGRect(x: 0, y: 0, width: 240, height: 100)) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 100))
        }
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))
        let sourcePage = try #require(document.page(at: 0))
        let bounds = CGRect(x: 42, y: 38, width: 24, height: 20)
        let target = TextTarget(
            pageIndex: 0,
            bounds: bounds,
            baseline: 42,
            originalText: "A",
            fontSize: 16,
            fontColor: .black,
            fontKey: nil,
            fontIsExact: false,
            coverBounds: bounds,
            maxWidth: 120
        )
        let font = CTFontCreateWithName("Noto Sans JP" as CFString, 16, nil)
        let edit = ReplacementEdit(target: target, replacement: "編集", resolvedFont: font, fontIsExact: false)
        let result = try PDFExportEngine.addingSearchableTextForMissingReplacements(
            in: Data(contentsOf: source),
            edits: [edit]
        )
        let resultDocument = try #require(PDFDocument(data: result))
        let resultPage = try #require(resultDocument.page(at: 0))
        #expect(resultPage.string?.contains("編集") == true)
        let index = PDFGlyphIndex.makeIndex(for: resultPage)
        let replacementRun = try #require(index.runs.first { $0.text.contains("編集") })
        #expect(index.cluster(at: CGPoint(x: bounds.midX, y: bounds.midY), pageIndex: 0)?.originalText == "編集")
        let reopenedTarget = try #require(index.target(
            in: replacementRun,
            range: 0..<replacementRun.glyphs.count,
            pageIndex: 0
        ))
        let savedFontName = CTFontCopyPostScriptName(font) as String
        #expect(reopenedTarget.fontPostScriptNameOverride == savedFontName)
        #expect(abs(reopenedTarget.fontSize - CTFontGetSize(font)) < 0.05)
        let secondEditResolution = PDFEditEngine.resolveFont(
            for: reopenedTarget,
            on: resultPage,
            replacement: "改訂"
        )
        #expect(secondEditResolution.isExact)
        #expect(CTFontCopyPostScriptName(secondEditResolution.font) as String == savedFontName)

        let sourceRaster = try rasterMetrics(page: sourcePage, focus: bounds, scale: 4)
        let resultRaster = try rasterMetrics(page: resultPage, focus: bounds, scale: 4)
        #expect(resultRaster.darkPixels == sourceRaster.darkPixels)
        #expect(resultRaster.antialiasPixels == sourceRaster.antialiasPixels)
        #expect(resultRaster.edgeTransitions == sourceRaster.edgeTransitions)
    }

    @Test("埋め込みフォントのUnicode cmapだけではPDFのグリフ対応とみなさない")
    func embeddedCMapIsNotTrustedWithoutPDFCodeMapping() throws {
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

    @Test("単純TrueTypeのDifferencesは文字コード直結より優先する")
    func simpleTrueTypeDifferencesSelectsNamedGlyph() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        var units = Array("AB".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        #expect(CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count))
        #expect(glyphs[0] != glyphs[1])
        var bGlyph = glyphs[1]
        var advance = CGSize.zero
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &bGlyph, &advance, 1)

        let info = PDFFontInfo(
            bytesPerCode: 1,
            widthTable: [65: advance.width / CTFontGetSize(font)],
            defaultWidth: 0.5,
            toUnicode: [65: "B"],
            explicitToUnicodeCodes: [65],
            ascent: 0.8,
            descent: -0.2,
            hasEmbeddedProgram: true,
            unicodeToCode: ["B": 65],
            simpleEncodingGlyphNames: [65: "B"],
            isIdentityCIDToGID: false
        )

        let resolution = try #require(PDFEmbeddedFontLoader.embeddedFontResolution(
            font: font,
            info: info,
            replacementText: "B"
        ))
        #expect(resolution.exactGlyphs?.map(\.glyph) == [glyphs[1]])
        #expect(resolution.exactGlyphs?.map(\.glyph) != [glyphs[0]])
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
        #expect(!textAnnotation.shouldDisplay)
        #expect(!coverAnnotation.shouldDisplay)
        #expect(textAnnotation.bounds.width < page.bounds(for: .mediaBox).width / 2)

        let movedBounds = edit.displayedTextBounds
        let raster = try previewRasterMetrics(page: page, focus: movedBounds, scale: 4)
        #expect(raster.darkPixels > 0)
        #expect(raster.antialiasPixels > 0)

        model.undoLastEdit()
        #expect(page.annotations.isEmpty)
    }

    @Test("置換済み文字をA→B→Cと再編集しrevisionごとにundo/redoできる")
    @MainActor
    func replacementCanBeReeditedWithStableIdentityAndHistory() throws {
        let fixture = try makeStandaloneReplacementFixture(maxWidth: 100)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let model = EditorModel(initialURL: fixture.url)
        let page = try #require(model.document?.page(at: 0))

        model.select(fixture.target)
        model.updateEditorText("B")
        model.commitEditorText()
        let first = try #require(model.activeReplacements.first)
        #expect(first.replacement == "B")
        #expect(page.annotations.count == 1)

        model.beginReeditingReplacement(id: first.id)
        #expect(model.isInlineEditing)
        #expect(model.replacementText == "B")
        model.updateEditorText("C")
        model.commitEditorText()

        let revised = try #require(model.activeReplacements.first)
        #expect(revised.id == first.id)
        #expect(revised.replacement == "C")
        #expect(page.annotations.count == 1)

        model.undoLastEdit()
        #expect(model.activeReplacements.first?.id == first.id)
        #expect(model.activeReplacements.first?.replacement == "B")
        #expect(page.annotations.compactMap { $0 as? ReplacementTextAnnotation }.first?.edit.replacement == "B")
        model.redoLastEdit()
        #expect(model.activeReplacements.first?.replacement == "C")
        #expect(page.annotations.compactMap { $0 as? ReplacementTextAnnotation }.first?.edit.replacement == "C")

        let output = temporaryPDFURL(prefix: "replacement-revision")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: fixture.url, edits: model.activeReplacements, to: output)
        #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains("C") == true)
    }

    @Test("置換のカスタムフォントと出力サイズは同一IDの再編集で維持される")
    @MainActor
    func replacementReeditPreservesCustomFontUntilUserChangesIt() throws {
        let fixture = try makeStandaloneReplacementFixture(maxWidth: 100)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let model = EditorModel(initialURL: fixture.url)
        let menlo = try #require(NSFont(name: "Menlo", size: 14))
        let menloName = menlo.fontName

        model.select(fixture.target)
        model.setCustomFontName("Menlo")
        model.setReplacementFontSize(14)
        model.updateEditorText("B")
        model.commitEditorText()

        let first = try #require(model.activeReplacements.first)
        let firstFont = try #require(first.resolvedFont)
        #expect(first.outputFontSelection == ReplacementFontSelection(
            choice: .custom,
            customFontName: "Menlo"
        ))
        #expect(CTFontCopyPostScriptName(firstFont) as String == menloName)
        #expect(abs(first.fontSize - 14) < 0.01)

        model.beginReeditingReplacement(id: first.id)
        #expect(model.replacementText == "B")
        #expect(model.replacementFontChoice == .custom)
        #expect(model.customFontName == "Menlo")
        #expect(abs(model.replacementFontSize - 14) < 0.01)
        model.updateEditorText("C")
        model.commitEditorText()

        let unchanged = try #require(model.activeReplacements.first)
        #expect(unchanged.id == first.id)
        #expect(CTFontCopyPostScriptName(try #require(unchanged.resolvedFont)) as String == menloName)
        #expect(abs(unchanged.fontSize - 14) < 0.01)

        model.beginReeditingReplacement(id: first.id)
        model.setReplacementFontSize(13)
        model.updateEditorText("D")
        model.commitEditorText()

        let resized = try #require(model.activeReplacements.first)
        #expect(resized.outputFontSelection == ReplacementFontSelection(
            choice: .custom,
            customFontName: "Menlo"
        ))
        #expect(CTFontCopyPostScriptName(try #require(resized.resolvedFont)) as String == menloName)
        #expect(abs(resized.fontSize - 13) < 0.01)

        model.beginReeditingReplacement(id: first.id)
        model.setReplacementFontChoice(.helveticaNeue)
        #expect(abs(model.replacementFontSize - 13) < 0.01)
        model.updateEditorText("E")
        model.commitEditorText()

        let changed = try #require(model.activeReplacements.first)
        let changedFontName = CTFontCopyPostScriptName(try #require(changed.resolvedFont)) as String
        #expect(changed.outputFontSelection.choice == .helveticaNeue)
        #expect(changedFontName != menloName)
        #expect(abs(changed.fontSize - 13) < 0.01)

        model.beginReeditingReplacement(id: first.id)
        model.setCustomFontName("PDFEditor Definitely Missing Font")
        #expect(model.replacementFontPreview?.reason?.contains("利用できない") == true)
        model.updateEditorText("F")
        model.commitEditorText()

        let fallback = try #require(model.activeReplacements.first)
        #expect(fallback.outputFontSelection == ReplacementFontSelection(
            choice: .custom,
            customFontName: "PDFEditor Definitely Missing Font"
        ))
        #expect(CTFontCopyPostScriptName(try #require(fallback.resolvedFont)) as String != "PDFEditor Definitely Missing Font")
        #expect(model.statusMessage.contains("利用できない"))
        model.beginReeditingReplacement(id: first.id)
        #expect(model.replacementFontChoice == .custom)
        #expect(model.customFontName == "PDFEditor Definitely Missing Font")
        #expect(model.replacementFontPreview?.reason?.contains("利用できない") == true)
    }

    @Test("移動済みの置換を再編集しても移動先と履歴を保つ")
    @MainActor
    func movedReplacementCanBeReedited() throws {
        let fixture = try makeStandaloneReplacementFixture(maxWidth: 100)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let model = EditorModel(initialURL: fixture.url)
        let page = try #require(model.document?.page(at: 0))

        model.select(fixture.target)
        model.updateEditorText("B")
        model.commitEditorText()
        let initial = try #require(model.activeReplacements.first)
        model.moveExistingEdit(id: initial.id, by: CGPoint(x: 36, y: 18))
        let moved = try #require(model.activeReplacements.first)
        let destination = try #require(moved.destinationOrigin)

        model.beginReeditingReplacement(id: moved.id)
        #expect(model.replacementText == "B")
        model.updateEditorText("C")
        model.commitEditorText()

        let revised = try #require(model.activeReplacements.first)
        #expect(revised.id == moved.id)
        #expect(revised.replacement == "C")
        #expect(revised.destinationOrigin == destination)
        #expect(page.annotations.compactMap { $0 as? ReplacementCoverAnnotation }.count == 1)
        #expect(page.annotations.compactMap { $0 as? ReplacementTextAnnotation }.count == 1)

        model.undoLastEdit()
        #expect(model.activeReplacements.first?.replacement == "B")
        #expect(model.activeReplacements.first?.destinationOrigin == destination)
    }

    @Test("置換は元サイズを保ち、overflowを拒否し、明示した小さいサイズなら受け入れる")
    @MainActor
    func replacementUsesExplicitFitPolicy() throws {
        let fittingFixture = try makeStandaloneReplacementFixture(maxWidth: 100)
        defer { try? FileManager.default.removeItem(at: fittingFixture.url) }
        let fittingModel = EditorModel(initialURL: fittingFixture.url)
        fittingModel.select(fittingFixture.target)
        fittingModel.updateEditorText("B")
        fittingModel.commitEditorText()
        let fitting = try #require(fittingModel.activeReplacements.first)
        #expect(abs(fitting.fontSize - fittingFixture.target.fontSize) < 0.01)
        #expect(abs(CTFontGetSize(try #require(fitting.resolvedFont)) - fittingFixture.target.fontSize) < 0.01)

        let output = temporaryPDFURL(prefix: "replacement-size-reopen")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(
            sourceURL: fittingFixture.url,
            edits: fittingModel.activeReplacements,
            to: output
        )
        let reopenedDocument = try #require(PDFDocument(url: output))
        let reopenedPage = try #require(reopenedDocument.page(at: 0))
        let reopenedIndex = PDFGlyphIndex.makeIndex(for: reopenedPage)
        let reopenedGlyph = try #require(reopenedIndex.runs
            .flatMap(\.glyphs)
            .filter { $0.text == "B" }
            .max { $0.paintOrder < $1.paintOrder })
        #expect(abs(reopenedGlyph.fontSize - fittingFixture.target.fontSize) < 0.6)

        let tightFixture = try makeStandaloneReplacementFixture(maxWidth: 15)
        defer { try? FileManager.default.removeItem(at: tightFixture.url) }
        let tightModel = EditorModel(initialURL: tightFixture.url)
        let tightPage = try #require(tightModel.document?.page(at: 0))
        tightModel.select(tightFixture.target)
        tightModel.updateEditorText("MM")
        tightModel.commitEditorText()
        #expect(tightModel.activeReplacements.isEmpty)
        #expect(tightPage.annotations.isEmpty)
        #expect(tightModel.noticeMessage?.contains("超えます") == true)
        #expect(tightModel.isInlineEditing == false)
        #expect(tightModel.selectedTarget == tightFixture.target)

        tightModel.setReplacementFontSize(6)
        tightModel.commitEditorText()
        let smaller = try #require(tightModel.activeReplacements.first)
        #expect(smaller.replacement == "MM")
        #expect(abs(smaller.fontSize - 6) < 0.01)
        #expect(tightPage.annotations.count == 1)
    }

    @Test("短い元inkでも同サイズのdescenderとaccentは衝突がなければ置換できる")
    @MainActor
    func actualInkFitAcceptsDescenderAndAccentAtSourceSize() throws {
        let fixture = try makeStandaloneReplacementFixture(maxWidth: 100)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let model = EditorModel(initialURL: fixture.url)

        model.select(fixture.target)
        model.updateEditorText("g")
        model.commitEditorText()
        let descender = try #require(model.activeReplacements.first)
        #expect(abs(descender.fontSize - fixture.target.fontSize) < 0.01)

        model.beginReeditingReplacement(id: descender.id)
        model.updateEditorText("Á")
        model.commitEditorText()
        let accented = try #require(model.activeReplacements.first)
        #expect(accented.replacement == "Á")
        #expect(abs(accented.fontSize - fixture.target.fontSize) < 0.01)
    }

    @Test("大きい置換inkが別行またはページ端に当たる場合は確定を拒否する")
    @MainActor
    func actualInkFitRejectsOtherLineAndPageEdge() throws {
        let collisionFixture = try makeTwoLineReplacementFixture()
        defer { try? FileManager.default.removeItem(at: collisionFixture.url) }
        let collisionModel = EditorModel(initialURL: collisionFixture.url)
        let collisionPage = try #require(collisionModel.document?.page(at: 0))
        #expect(!collisionFixture.target.nearbyTextBounds.isEmpty)

        collisionModel.select(collisionFixture.target)
        collisionModel.setReplacementFontSize(40)
        collisionModel.updateEditorText("Á")
        collisionModel.commitEditorText()
        #expect(collisionModel.activeReplacements.isEmpty)
        #expect(collisionPage.annotations.isEmpty)
        #expect(collisionModel.noticeMessage?.contains("隣接文字またはページ境界") == true)

        let edgeFixture = try makePageEdgeReplacementFixture()
        defer { try? FileManager.default.removeItem(at: edgeFixture.url) }
        let edgeModel = EditorModel(initialURL: edgeFixture.url)
        let edgePage = try #require(edgeModel.document?.page(at: 0))
        edgeModel.select(edgeFixture.target)
        edgeModel.setReplacementFontSize(40)
        edgeModel.updateEditorText("Á")
        edgeModel.commitEditorText()
        #expect(edgeModel.activeReplacements.isEmpty)
        #expect(edgePage.annotations.isEmpty)
        #expect(edgeModel.noticeMessage?.contains("隣接文字またはページ境界") == true)
    }

    @Test("追加済みテキストをA→B→Cと再編集しキャンセル・移動・undo/redoできる")
    @MainActor
    func insertionCanBeReeditedCancelledMovedAndReplayed() throws {
        let source = try makeBlankFixture(pageBounds: CGRect(x: 0, y: 0, width: 300, height: 160))
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        let color = NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.75, alpha: 1)
        let menlo = try #require(NSFont(name: "Menlo", size: 15))

        model.setMode(.insertion)
        model.beginInsertion(pageIndex: 0, point: CGPoint(x: 36, y: 72))
        model.setCustomFontName(menlo.fontName)
        model.setInsertionFontSize(15)
        model.setInsertionFontColor(color)
        model.updateEditorText("A")
        model.commitEditorText()

        let original = try #require(model.activeReplacements.first)
        let id = original.id
        let originalBounds = original.bounds
        let originalAnnotation = try #require(page.annotations.first)
        #expect(original.kind == .insertion)
        #expect(original.outputFontSelection.choice == .custom)
        #expect(original.outputFontSelection.customFontName == menlo.fontName)
        #expect(original.fontName == menlo.fontName)
        #expect(abs(original.fontSize - 15) < 0.01)
        #expect(originalAnnotation.font?.fontName == menlo.fontName)
        #expect(abs((originalAnnotation.font?.pointSize ?? 0) - 15) < 0.01)
        #expect(originalAnnotation.fontColor?.isEqual(color) == true)
        #expect(page.annotations.count == 1)

        model.beginReeditingInsertion(id: id)
        #expect(model.replacementText == "A")
        #expect(model.insertionFontChoice == .custom)
        #expect(model.customFontName == menlo.fontName)
        #expect(abs(model.insertionFontSize - 15) < 0.01)
        #expect(model.insertionFontColor.isEqual(color))
        #expect(model.insertionDraft?.annotation.bounds == originalBounds)
        model.updateEditorText("B")
        model.cancelInsertionEditing()
        #expect(model.activeReplacements.first?.replacement == "A")
        #expect(page.annotations.count == 1)
        #expect(page.annotations.first?.contents == "A")

        model.beginReeditingInsertion(id: id)
        model.updateEditorText("B")
        model.commitEditorText()
        let second = try #require(model.activeReplacements.first)
        #expect(second.id == id)
        #expect(second.replacement == "B")
        #expect(second.bounds == originalBounds)
        #expect(second.outputFontSelection.choice == .custom)
        #expect(second.outputFontSelection.customFontName == menlo.fontName)
        #expect(page.annotations.count == 1)

        model.beginReeditingInsertion(id: id)
        model.updateEditorText("C")
        model.commitEditorText()
        #expect(model.activeReplacements.first?.id == id)
        #expect(model.activeReplacements.first?.replacement == "C")
        #expect(page.annotations.count == 1)

        model.undoLastEdit()
        #expect(model.activeReplacements.first?.replacement == "B")
        #expect(page.annotations.count == 1)
        #expect(page.annotations.first?.contents == "B")
        model.undoLastEdit()
        #expect(model.activeReplacements.first?.replacement == "A")
        #expect(page.annotations.first?.contents == "A")
        model.redoLastEdit()
        model.redoLastEdit()
        #expect(model.activeReplacements.first?.replacement == "C")
        #expect(page.annotations.count == 1)

        let movedBounds = originalBounds.offsetBy(dx: 52, dy: 18)
        let marker = PDFEditEngine.annotationMarkerPrefix + id.uuidString
        model.moveInsertion(marker: marker, pageIndex: 0, bounds: movedBounds)
        #expect(model.activeReplacements.first?.bounds == movedBounds)
        #expect(page.annotations.count == 1)
        #expect(page.annotations.first?.bounds == movedBounds)
        model.undoLastEdit()
        #expect(model.activeReplacements.first?.bounds == originalBounds)
        #expect(page.annotations.first?.bounds == originalBounds)
        model.redoLastEdit()
        #expect(model.activeReplacements.first?.bounds == movedBounds)
        #expect(page.annotations.count == 1)

        model.beginReeditingInsertion(id: id)
        #expect(model.replacementText == "C")
        #expect(model.insertionDraft?.annotation.bounds == movedBounds)
        #expect(model.insertionFontChoice == .custom)
        #expect(model.customFontName == menlo.fontName)
        #expect(abs(model.insertionFontSize - 15) < 0.01)
        model.cancelInsertionEditing()
        #expect(model.activeReplacements.first?.bounds == movedBounds)
        #expect(page.annotations.count == 1)
        #expect(page.annotations.first?.bounds == movedBounds)

        let output = temporaryPDFURL(prefix: "insertion-reedit-size")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFExportEngine.export(sourceURL: source, edits: model.activeReplacements, to: output)
        let reopenedDocument = try #require(PDFDocument(url: output))
        let reopenedPage = try #require(reopenedDocument.page(at: 0))
        let reopenedGlyph = try #require(PDFGlyphIndex.makeIndex(for: reopenedPage).runs
            .flatMap(\.glyphs)
            .filter { $0.text == "C" }
            .max { $0.paintOrder < $1.paintOrder })
        #expect(abs(reopenedGlyph.fontSize - 15) < 0.6)
    }

    @Test("追加テキストは暗黙縮小せずoverflowを拒否し明示した小サイズを受け入れる")
    @MainActor
    func insertionOverflowRequiresExplicitSmallerSize() throws {
        let source = try makeBlankFixture(pageBounds: CGRect(x: 0, y: 0, width: 120, height: 100))
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))

        model.setMode(.insertion)
        model.beginInsertion(pageIndex: 0, point: CGPoint(x: 4, y: 50))
        model.setInsertionFontChoice(.helveticaNeue)
        model.setInsertionFontSize(24)
        model.updateEditorText("MMMMMMMMMMMM")
        model.commitEditorText()
        #expect(model.activeReplacements.isEmpty)
        #expect(model.insertionDraft != nil)
        #expect(page.annotations.count == 1)
        #expect(model.noticeMessage?.contains("入力枠またはページ境界") == true)
        #expect(model.insertionDraft?.annotation.font?.pointSize == 24)

        model.setInsertionFontSize(6)
        model.commitEditorText()
        let accepted = try #require(model.activeReplacements.first)
        #expect(abs(accepted.fontSize - 6) < 0.01)
        #expect(accepted.outputFontSelection.choice == .helveticaNeue)
        #expect(page.annotations.count == 1)

        model.beginReeditingInsertion(id: accepted.id)
        model.setInsertionFontSize(24)
        model.updateEditorText("MMMMMMMMMMMM")
        model.commitEditorText()
        #expect(model.activeReplacements.first?.replacement == "MMMMMMMMMMMM")
        #expect(model.activeReplacements.first?.fontSize == 6)
        #expect(model.insertionDraft != nil)
        #expect(model.noticeMessage?.contains("小さくしてください") == true)
        model.cancelInsertionEditing()
        #expect(page.annotations.count == 1)
        #expect(page.annotations.first?.font?.pointSize == 6)
    }

    @Test("追加文字の長い再編集は空き幅へ広がり、編集中のUndoは下書きを片付ける")
    @MainActor
    func insertionReeditCanGrowAndUndoWhileDrafting() throws {
        let source = try makeBlankFixture(pageBounds: CGRect(x: 0, y: 0, width: 300, height: 160))
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))

        model.setMode(.insertion)
        model.beginInsertion(pageIndex: 0, point: CGPoint(x: 36, y: 72))
        model.setInsertionFontChoice(.menlo)
        model.setInsertionFontSize(14)
        model.updateEditorText("A")
        model.commitEditorText()
        let original = try #require(model.activeReplacements.first)

        model.beginReeditingInsertion(id: original.id)
        model.updateEditorText("ABCDEFGHIJKL")
        let grownBounds = try #require(model.insertionDraft?.annotation.bounds)
        #expect(grownBounds.width > original.bounds.width)
        #expect(abs(grownBounds.minX - original.bounds.minX) < 0.01)
        model.commitEditorText()
        #expect(model.activeReplacements.first?.replacement == "ABCDEFGHIJKL")
        #expect(model.activeReplacements.first?.bounds == grownBounds)
        #expect(page.annotations.count == 1)

        model.undoLastEdit()
        #expect(model.activeReplacements.first?.replacement == "A")
        #expect(page.annotations.first?.bounds == original.bounds)
        model.beginReeditingInsertion(id: original.id)
        model.updateEditorText("draft")
        model.undoLastEdit()
        #expect(model.insertionDraft == nil)
        #expect(model.activeReplacements.isEmpty)
        #expect(page.annotations.isEmpty)
        model.redoLastEdit()
        #expect(model.activeReplacements.first?.replacement == "A")
        #expect(page.annotations.count == 1)
    }

    @Test("利用できない追加書体は要求選択と実出力フォールバックを分けて保持する")
    @MainActor
    func insertionUnavailableCustomFontPreservesRequestedChoiceAndResolvedFace() throws {
        let source = try makeBlankFixture(pageBounds: CGRect(x: 0, y: 0, width: 240, height: 120))
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        let page = try #require(model.document?.page(at: 0))
        let missingFontName = "PDFEditor-Missing-Font-For-Acceptance-Test"

        model.setMode(.insertion)
        model.beginInsertion(pageIndex: 0, point: CGPoint(x: 30, y: 60))
        let resolvedFallbackName = try #require(model.insertionDraft?.automaticFontName)
        model.setCustomFontName(missingFontName)
        model.setInsertionFontSize(13)
        model.updateEditorText("fallback")
        #expect(model.insertionFontPreviewReason?.contains("利用できない") == true)
        model.commitEditorText()

        let edit = try #require(model.activeReplacements.first)
        #expect(edit.outputFontSelection.choice == .custom)
        #expect(edit.outputFontSelection.customFontName == missingFontName)
        #expect(edit.fontName == resolvedFallbackName)
        #expect(abs(edit.fontSize - 13) < 0.01)
        #expect(page.annotations.first?.font?.fontName
            == NSFont(name: resolvedFallbackName, size: 13)?.fontName)

        model.beginReeditingInsertion(id: edit.id)
        #expect(model.insertionFontChoice == .custom)
        #expect(model.customFontName == missingFontName)
        #expect(model.effectiveInsertionFontName == resolvedFallbackName)
        #expect(model.insertionFontPreviewReason?.contains("利用できない") == true)
        #expect(abs(model.insertionFontSize - 13) < 0.01)
        model.cancelInsertionEditing()
        #expect(page.annotations.count == 1)
    }

    private func makeStandaloneReplacementFixture(maxWidth: CGFloat) throws -> (url: URL, target: TextTarget) {
        let font = NSFont(name: "Helvetica", size: 16) ?? .systemFont(ofSize: 16)
        let url = try SyntheticFixture.build(pageBounds: CGRect(x: 0, y: 0, width: 240, height: 120)) { context in
            SyntheticFixture.drawLine(
                [SyntheticFixture.GlyphSpec(character: "A", font: font)],
                startX: 36,
                baseline: 64,
                gap: 0,
                in: context
            )
        }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "A" })
        let scanned = try #require(index.target(in: run, range: 0..<1, pageIndex: 0))
        let target = TextTarget(
            pageIndex: scanned.pageIndex,
            bounds: scanned.bounds,
            baseline: scanned.baseline,
            originalText: scanned.originalText,
            fontSize: scanned.fontSize,
            fontColor: scanned.fontColor,
            fontKey: scanned.fontKey,
            fontIsExact: scanned.fontIsExact,
            coverBounds: scanned.coverBounds,
            maxWidth: maxWidth,
            lineLayout: nil,
            hasExplicitSourceMapping: scanned.hasExplicitSourceMapping,
            fontPostScriptNameOverride: scanned.fontPostScriptNameOverride,
            nearbyTextBounds: scanned.nearbyTextBounds
        )
        return (url, target)
    }

    private func makeBlankFixture(pageBounds: CGRect) throws -> URL {
        try SyntheticFixture.build(pageBounds: pageBounds) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(pageBounds)
        }
    }

    private func makeTwoLineReplacementFixture() throws -> (url: URL, target: TextTarget) {
        let font = NSFont(name: "Helvetica", size: 16) ?? .systemFont(ofSize: 16)
        let url = try SyntheticFixture.build(pageBounds: CGRect(x: 0, y: 0, width: 240, height: 120)) { context in
            SyntheticFixture.drawLine(
                [SyntheticFixture.GlyphSpec(character: "A", font: font)],
                startX: 36,
                baseline: 42,
                gap: 0,
                in: context
            )
            SyntheticFixture.drawLine(
                [SyntheticFixture.GlyphSpec(character: "X", font: font)],
                startX: 36,
                baseline: 70,
                gap: 0,
                in: context
            )
        }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "A" })
        return (url, try #require(index.target(in: run, range: 0..<1, pageIndex: 0)))
    }

    private func makePageEdgeReplacementFixture() throws -> (url: URL, target: TextTarget) {
        let font = NSFont(name: "Helvetica", size: 16) ?? .systemFont(ofSize: 16)
        let url = try SyntheticFixture.build(pageBounds: CGRect(x: 0, y: 0, width: 240, height: 120)) { context in
            SyntheticFixture.drawLine(
                [SyntheticFixture.GlyphSpec(character: "A", font: font)],
                startX: 36,
                baseline: 104,
                gap: 0,
                in: context
            )
        }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let index = PDFGlyphIndex.makeIndex(for: page)
        let run = try #require(index.runs.first { $0.text == "A" })
        return (url, try #require(index.target(in: run, range: 0..<1, pageIndex: 0)))
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
        return measure(bitmap: bitmap, mediaBox: mediaBox, focus: focus)
    }

    private func previewRasterMetrics(page: PDFPage, focus: CGRect, scale: CGFloat) throws -> RasterMetrics {
        let mediaBox = page.bounds(for: .mediaBox)
        let width = max(Int(ceil(mediaBox.width * scale)), 1)
        let height = max(Int(ceil(mediaBox.height * scale)), 1)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        ReplacementPreviewRenderer.draw(on: page, in: context)
        let image = try #require(context.makeImage())
        return measure(bitmap: NSBitmapImageRep(cgImage: image), mediaBox: mediaBox, focus: focus)
    }

    private func measure(bitmap: NSBitmapImageRep, mediaBox: CGRect, focus: CGRect) -> RasterMetrics {
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
