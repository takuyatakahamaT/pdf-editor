import AppKit
import CoreGraphics
import CoreText
import PDFKit

/// 画面プレビュー用のページオーバーレイと書き出し（`PDFExportEngine`）が共有する描画経路。
/// 段落レイアウトや折り返しは一切使わず、1 行の `CTLine` を
/// ベースライン固定で描く。置換時は同じ行の後続文字を動かして空き幅を作る。
/// 置換文字は指定point sizeのまま描く。収まらない候補は確定前に拒否し、
/// rendererが暗黙に縮小・変形・clipすることはない。
enum PDFTextRenderer {
    static func draw(_ edit: ReplacementEdit, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        if edit.destinationOrigin != nil {
            drawMoved(edit, in: context)
            return
        }

        if let lineLayout = edit.lineLayout,
           !edit.replacement.isEmpty {
            let font = edit.resolvedFont ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
            if edit.composesLineEdits {
                drawComposedReflow(edit, layout: lineLayout, in: context)
                return
            }
            drawReflow(edit, layout: lineLayout, font: font, in: context)
            return
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(edit.coverBounds)

        guard !edit.replacement.isEmpty else { return }

        if let font = edit.resolvedFont, let exactGlyphs = edit.exactGlyphs, !exactGlyphs.isEmpty {
            // 元 PDF の GID を直接指定できる場合は、cmap を経由せず
            // 真に同じグリフで描く（§2.2: 埋め込みサブセットに cmap が
            // 無いケースでも、ToUnicode から分かる GID をそのまま使う）。
            drawExactGlyphs(exactGlyphs, font: font, edit: edit, in: context)
            return
        }

        let baseFont = edit.resolvedFont ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
        let plan = renderPlan(text: edit.replacement, font: baseFont, color: edit.fontColor, maxWidth: edit.maxWidth)

        context.translateBy(x: edit.bounds.minX, y: edit.baseline)
        context.setFillColor(edit.fontColor.cgColor)
        drawGlyphOutlines(for: plan.line, in: context)
    }

    private static func drawMoved(_ edit: ReplacementEdit, in context: CGContext) {
        drawMovedCover(edit, in: context)
        drawMovedText(edit, in: context)
    }

    static func drawMovedCover(_ edit: ReplacementEdit, in context: CGContext) {
        context.setFillColor(NSColor.white.cgColor)
        context.fill(edit.coverBounds)
    }

    static func drawMovedText(_ edit: ReplacementEdit, in context: CGContext) {
        guard let destination = edit.destinationOrigin else { return }
        guard !edit.replacement.isEmpty else { return }
        let font = edit.resolvedFont ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
        let line = makeLine(text: edit.replacement, font: font, color: edit.fontColor)
        context.saveGState()
        context.translateBy(x: destination.x, y: destination.y)
        if let exactGlyphs = edit.exactGlyphs, !exactGlyphs.isEmpty {
            drawUnscaledExactGlyphs(exactGlyphs, font: font, color: edit.fontColor, in: context)
        } else {
            drawGlyphOutlines(for: line, in: context)
        }
        context.restoreGState()
    }

    /// GID を直接指定して描く経路。幅は元 PDF の `/Widths`/`/W` 由来の値
    /// (`emWidth`) を使い、CTLine の文字ベース計測には頼らない。
    private static func drawExactGlyphs(
        _ glyphs: [(glyph: CGGlyph, emWidth: CGFloat)],
        font: CTFont,
        edit: ReplacementEdit,
        in context: CGContext
    ) {
        context.translateBy(x: edit.bounds.minX, y: edit.baseline)
        context.setFillColor(edit.fontColor.cgColor)

        var x: CGFloat = 0
        var glyphIDs: [CGGlyph] = []
        var positions: [CGPoint] = []
        for (glyph, emWidth) in glyphs {
            glyphIDs.append(glyph)
            positions.append(CGPoint(x: x, y: 0))
            x += emWidth * CTFontGetSize(font)
        }
        context.textMatrix = .identity
        context.setTextDrawingMode(.fill)
        CTFontDrawGlyphs(font, glyphIDs, positions, glyphIDs.count, context)
    }

    private static func drawReflow(
        _ edit: ReplacementEdit,
        layout: TextRunLayout,
        font: CTFont,
        in context: CGContext
    ) {
        let exactWidth = edit.exactGlyphs.map { glyphs in
            glyphs.reduce(CGFloat.zero) { $0 + $1.emWidth } * CTFontGetSize(font)
        }
        let plan = reflowPlan(
            text: edit.replacement,
            font: font,
            layout: layout,
            color: edit.fontColor,
            replacementWidth: exactWidth
        )
        guard plan.outputEnd > 0, layout.maxWidth > 0 else {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(edit.coverBounds)
            return
        }

        // 後続の文字を右へ送って幅を確保する。収まりを確認済みなので縮小しない。
        // 後続グリフが送り幅の左へ張り出す書体でも欠けないよう、
        // 幅差にかかわらず後続部分は消去して同じフォントで再描画する。
        // 近接する罫線は layout.coverBounds の縦範囲を文字ボックスに
        // 限定することで保護する。
        let coverEnd = min(max(layout.lineWidth, plan.outputEnd), layout.maxWidth)
        var cover = layout.coverBounds
        cover.origin.x = layout.lineStartX + layout.selectedStartX
        cover.size.width = max(coverEnd - layout.selectedStartX, 0)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(cover)

        context.saveGState()
        context.translateBy(x: layout.lineStartX + layout.selectedStartX, y: edit.baseline)

        if let exactGlyphs = edit.exactGlyphs, !exactGlyphs.isEmpty {
            context.saveGState()
            drawUnscaledExactGlyphs(exactGlyphs, font: font, color: edit.fontColor, in: context)
            context.restoreGState()
        } else {
            drawLine(plan.line, at: 0, in: context)
        }
        let lineFont = edit.lineFont ?? font
        for glyph in layout.glyphs[layout.selectedRange.upperBound...] {
            let glyphText = glyph.text as CFString
            let drawableFont = CTFontCreateForString(lineFont, glyphText, CFRange(location: 0, length: CFStringGetLength(glyphText)))
            drawText(glyph.text, font: drawableFont, color: edit.fontColor, at: glyph.offsetX - layout.selectedStartX + plan.shift, in: context)
        }
        context.restoreGState()
    }

    struct ComposedReplacementPlacement {
        let replacement: TextRunReplacement
        let offsetX: CGFloat
    }

    struct ComposedGlyphPlacement {
        let glyph: TextRunLayout.Glyph
        let offsetX: CGFloat
    }

    struct ComposedReflowPlan {
        let replacements: [ComposedReplacementPlacement]
        let glyphs: [ComposedGlyphPlacement]
        let startX: CGFloat
        let outputEnd: CGFloat
        let scale: CGFloat
    }

    static func composedReflowPlan(
        layout: TextRunLayout,
        replacements: [TextRunReplacement],
        startingAt requestedStartIndex: Int? = nil
    ) -> ComposedReflowPlan? {
        let ordered = replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard !ordered.isEmpty,
              ordered.allSatisfy({ !$0.range.isEmpty && $0.range.upperBound <= layout.glyphs.count }),
              zip(ordered, ordered.dropFirst()).allSatisfy({ $0.range.upperBound <= $1.range.lowerBound }) else {
            return nil
        }

        let startIndex = requestedStartIndex ?? ordered[0].range.lowerBound
        guard startIndex >= 0, startIndex <= ordered[0].range.lowerBound,
              startIndex < layout.glyphs.count else { return nil }
        let startX = layout.glyphs[startIndex].offsetX
        var replacementPlacements: [ComposedReplacementPlacement] = []
        var glyphPlacements: [ComposedGlyphPlacement] = []
        var outputEnd = startX
        var shift: CGFloat = 0
        var replacementIndex = 0
        var glyphIndex = startIndex

        while glyphIndex < layout.glyphs.count {
            if replacementIndex < ordered.count,
               ordered[replacementIndex].range.lowerBound == glyphIndex {
                let replacement = ordered[replacementIndex]
                let originalWidth = layout.glyphs[replacement.range].reduce(CGFloat.zero) { $0 + $1.advance }
                let offsetX = layout.glyphs[glyphIndex].offsetX + shift
                replacementPlacements.append(ComposedReplacementPlacement(replacement: replacement, offsetX: offsetX))
                outputEnd = max(outputEnd, offsetX + replacement.renderedWidth)
                shift += replacement.renderedWidth - originalWidth
                glyphIndex = replacement.range.upperBound
                replacementIndex += 1
            } else {
                let glyph = layout.glyphs[glyphIndex]
                let offsetX = glyph.offsetX + shift
                glyphPlacements.append(ComposedGlyphPlacement(glyph: glyph, offsetX: offsetX))
                outputEnd = max(outputEnd, offsetX + glyph.advance)
                glyphIndex += 1
            }
        }

        return ComposedReflowPlan(replacements: replacementPlacements, glyphs: glyphPlacements,
                                  startX: startX, outputEnd: outputEnd, scale: 1)
    }

    private static func drawComposedReflow(
        _ edit: ReplacementEdit,
        layout: TextRunLayout,
        in context: CGContext
    ) {
        guard let plan = composedReflowPlan(layout: layout, replacements: edit.lineReplacements,
                                            startingAt: edit.lineCompositionStart),
              plan.outputEnd > plan.startX else {
            let font = edit.resolvedFont ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
            drawReflow(edit, layout: layout, font: font, in: context)
            return
        }

        let coverEnd = min(max(layout.lineWidth, plan.outputEnd), layout.maxWidth)
        var cover = layout.coverBounds
        cover.origin.x = layout.lineStartX + plan.startX
        cover.size.width = max(coverEnd - plan.startX, 0)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(cover)

        context.saveGState()
        context.translateBy(x: layout.lineStartX + plan.startX, y: edit.baseline)

        for placement in plan.replacements {
            context.saveGState()
            context.translateBy(x: placement.offsetX - plan.startX, y: 0)
            if let exactGlyphs = placement.replacement.exactGlyphs, !exactGlyphs.isEmpty {
                drawUnscaledExactGlyphs(exactGlyphs, font: placement.replacement.font,
                                        color: placement.replacement.color, in: context)
            } else {
                let line = makeLine(text: placement.replacement.text, font: placement.replacement.font,
                                    color: placement.replacement.color)
                drawGlyphOutlines(for: line, in: context)
            }
            context.restoreGState()
        }

        let sourceFont = edit.lineFont ?? edit.resolvedFont
            ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
        for placement in plan.glyphs {
            let glyphText = placement.glyph.text as CFString
            let drawableFont = CTFontCreateForString(
                sourceFont, glyphText, CFRange(location: 0, length: CFStringGetLength(glyphText))
            )
            drawText(placement.glyph.text, font: drawableFont, color: edit.fontColor,
                     at: placement.offsetX - plan.startX, in: context)
        }
        context.restoreGState()
    }

    private static func drawText(
        _ text: String,
        font: CTFont,
        color: NSColor,
        at offsetX: CGFloat,
        in context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let line = makeLine(text: text, font: font, color: color)
        context.saveGState()
        context.translateBy(x: offsetX, y: 0)
        drawGlyphOutlines(for: line, in: context)
        context.restoreGState()
    }

    private static func drawLine(_ line: CTLine, at offsetX: CGFloat, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: offsetX, y: 0)
        drawGlyphOutlines(for: line, in: context)
        context.restoreGState()
    }

    struct ReflowPlan {
        let line: CTLine
        let shift: CGFloat
        let outputEnd: CGFloat
        let scale: CGFloat
    }

    static func reflowPlan(
        text: String,
        font: CTFont,
        layout: TextRunLayout,
        color: NSColor = .black,
        replacementWidth: CGFloat? = nil
    ) -> ReflowPlan {
        let line = makeLine(text: text, font: font, color: color)
        let replacementWidth = replacementWidth ?? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let selectedAdvance = layout.glyphs[layout.selectedRange].reduce(CGFloat.zero) { $0 + $1.advance }
        let shift = replacementWidth - selectedAdvance
        let prefixEnd = layout.glyphs[..<layout.selectedRange.lowerBound]
            .map { $0.offsetX + $0.advance }
            .max() ?? 0
        let suffixEnd = layout.glyphs[layout.selectedRange.upperBound...]
            .map { $0.offsetX + $0.advance }
            .max()
        let outputEnd = max(
            prefixEnd,
            max(layout.selectedStartX + replacementWidth, (suffixEnd ?? 0) + shift)
        )
        return ReflowPlan(line: line, shift: shift, outputEnd: outputEnd, scale: 1)
    }

    private static func drawUnscaledExactGlyphs(
        _ glyphs: [(glyph: CGGlyph, emWidth: CGFloat)],
        font: CTFont,
        color: NSColor,
        in context: CGContext
    ) {
        var x: CGFloat = 0
        var glyphIDs: [CGGlyph] = []
        var positions: [CGPoint] = []
        for (glyph, emWidth) in glyphs {
            glyphIDs.append(glyph)
            positions.append(CGPoint(x: x, y: 0))
            x += emWidth * CTFontGetSize(font)
        }
        context.setFillColor(color.cgColor)
        context.textMatrix = .identity
        context.setTextDrawingMode(.fill)
        CTFontDrawGlyphs(font, glyphIDs, positions, glyphIDs.count, context)
    }

    /// CoreText の通常のグリフ描画を使う。PDF context では文字をベクターとして残し、
    /// PDFView のプレビューでは小さい文字のヒンティングを保つ。
    static func drawGlyphOutlines(for line: CTLine, in context: CGContext) {
        context.textMatrix = .identity
        context.setTextDrawingMode(.fill)
        CTLineDraw(line, context)
    }

    struct RenderPlan {
        let line: CTLine
        let fontSize: CGFloat
        let scale: CGFloat
    }

    static func renderPlan(text: String, font: CTFont, color: NSColor, maxWidth: CGFloat) -> RenderPlan {
        let line = makeLine(text: text, font: font, color: color)
        return RenderPlan(line: line, fontSize: CTFontGetSize(font), scale: 1)
    }

    struct FitResult {
        let fits: Bool
        let overflow: CGFloat
    }

    static func fitResult(for edit: ReplacementEdit, in pageBounds: CGRect) -> FitResult {
        let requiredEnd: CGFloat
        let availableEnd: CGFloat
        if let destination = edit.destinationOrigin {
            requiredEnd = destination.x + renderedWidth(of: edit)
            availableEnd = pageBounds.maxX
        } else if let layout = edit.lineLayout {
            if edit.composesLineEdits,
               let plan = composedReflowPlan(
                   layout: layout,
                   replacements: edit.lineReplacements,
                   startingAt: edit.lineCompositionStart
               ) {
                requiredEnd = plan.outputEnd
            } else {
                let font = edit.resolvedFont
                    ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
                let exactWidth = edit.exactGlyphs.map { glyphs in
                    glyphs.reduce(CGFloat.zero) { $0 + $1.emWidth } * CTFontGetSize(font)
                }
                requiredEnd = reflowPlan(
                    text: edit.replacement,
                    font: font,
                    layout: layout,
                    color: edit.fontColor,
                    replacementWidth: exactWidth
                ).outputEnd
            }
            availableEnd = layout.maxWidth
        } else {
            requiredEnd = renderedWidth(of: edit)
            availableEnd = min(edit.maxWidth, pageBounds.maxX - edit.bounds.minX)
        }
        let horizontalOverflow = max(requiredEnd - availableEnd, 0)
        let inkBounds = renderedInkBounds(for: edit)
        let pageOverflow = inkBounds.reduce(CGFloat.zero) { result, bounds in
            max(
                result,
                pageBounds.minX - bounds.minX,
                bounds.maxX - pageBounds.maxX,
                pageBounds.minY - bounds.minY,
                bounds.maxY - pageBounds.maxY
            )
        }
        let collisionOverflow = inkBounds.reduce(CGFloat.zero) { result, ink in
            let intersections = edit.sourceNearbyTextBounds.map { ink.intersection($0) }
                .filter { !$0.isNull && $0.width > 0.25 && $0.height > 0.25 }
            return max(result, intersections.map { min($0.width, $0.height) }.max() ?? 0)
        }
        let overflow = max(horizontalOverflow, pageOverflow, collisionOverflow, 0)
        return FitResult(fits: overflow <= 0.25, overflow: overflow)
    }

    static func renderedInkBounds(for edit: ReplacementEdit) -> [CGRect] {
        if let destination = edit.destinationOrigin {
            let font = edit.resolvedFont
                ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
            return inkBounds(
                text: edit.replacement,
                font: font,
                exactGlyphs: edit.exactGlyphs,
                origin: destination
            ).map { [$0] } ?? []
        }
        if edit.composesLineEdits, let layout = edit.lineLayout,
           let plan = composedReflowPlan(
               layout: layout,
               replacements: edit.lineReplacements,
               startingAt: edit.lineCompositionStart
           ) {
            return plan.replacements.compactMap { placement in
                inkBounds(
                    text: placement.replacement.text,
                    font: placement.replacement.font,
                    exactGlyphs: placement.replacement.exactGlyphs,
                    origin: CGPoint(
                        x: layout.lineStartX + placement.offsetX,
                        y: edit.baseline
                    )
                )
            }
        }
        let font = edit.resolvedFont
            ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
        let x = edit.lineLayout.map { $0.lineStartX + $0.selectedStartX } ?? edit.bounds.minX
        return inkBounds(
            text: edit.replacement,
            font: font,
            exactGlyphs: edit.exactGlyphs,
            origin: CGPoint(x: x, y: edit.baseline)
        ).map { [$0] } ?? []
    }

    private static func inkBounds(
        text: String,
        font: CTFont,
        exactGlyphs: [(glyph: CGGlyph, emWidth: CGFloat)]?,
        origin: CGPoint
    ) -> CGRect? {
        if let exactGlyphs, !exactGlyphs.isEmpty {
            var glyphs = exactGlyphs.map(\.glyph)
            var glyphBounds = [CGRect](repeating: .zero, count: glyphs.count)
            CTFontGetBoundingRectsForGlyphs(font, .default, &glyphs, &glyphBounds, glyphs.count)
            var x = origin.x
            var bounds = CGRect.null
            for (index, item) in exactGlyphs.enumerated() {
                bounds = bounds.union(glyphBounds[index].offsetBy(dx: x, dy: origin.y))
                x += item.emWidth * CTFontGetSize(font)
            }
            return bounds.isNull || bounds.isEmpty ? nil : bounds
        }
        let line = makeLine(text: text, font: font, color: .black)
        let bounds = CTLineGetImageBounds(line, nil).offsetBy(dx: origin.x, dy: origin.y)
        return bounds.isNull || bounds.isEmpty ? nil : bounds
    }

    private static func renderedWidth(of edit: ReplacementEdit) -> CGFloat {
        let font = edit.resolvedFont
            ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
        if let exactGlyphs = edit.exactGlyphs, !exactGlyphs.isEmpty {
            return exactGlyphs.reduce(CGFloat.zero) { $0 + $1.emWidth } * CTFontGetSize(font)
        }
        let line = makeLine(text: edit.replacement, font: font, color: edit.fontColor)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func makeLine(text: String, font: CTFont, color: NSColor) -> CTLine {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
            ]
        )
        return CTLineCreateWithAttributedString(attributed)
    }
}

/// 置換の状態とヒットテスト範囲をページに保持する注釈。
/// 画面では PDFKit の注釈キャッシュを避けるため、`ReplacementPreviewPageOverlayView` が描画する。
/// 書き出しでは `PDFExportEngine` が同じ `PDFTextRenderer` を直接呼ぶ。
final class ReplacementTextAnnotation: PDFAnnotation {
    let edit: ReplacementEdit
    private let drawsMovedTextOnly: Bool

    init(edit: ReplacementEdit, drawsMovedTextOnly: Bool = false) {
        self.edit = edit
        self.drawsMovedTextOnly = drawsMovedTextOnly
        let bounds = drawsMovedTextOnly ? edit.displayedTextBounds : edit.annotationBounds
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        color = .clear
        interiorColor = nil
        shouldDisplay = false
        let border = PDFBorder()
        border.lineWidth = 0
        self.border = border
        userName = PDFEditEngine.annotationMarkerPrefix + "replacement:" + edit.id.uuidString
    }

    required init?(coder: NSCoder) {
        // このアプリでは常にプログラムから直接生成するため、コーディング経由の復元は行わない。
        nil
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        drawPreview(in: context)
    }

    func drawPreview(in context: CGContext) {
        if drawsMovedTextOnly, edit.destinationOrigin != nil {
            PDFTextRenderer.drawMovedText(edit, in: context)
        } else {
            PDFTextRenderer.draw(edit, in: context)
        }
    }
}

/// 移動後の文字注釈とは分離して、元の位置だけを白で覆う。
/// 独立範囲で持つことで元位置のヒットテスト範囲と移動先のテキスト範囲を分ける。
final class ReplacementCoverAnnotation: PDFAnnotation {
    private let edit: ReplacementEdit

    init(edit: ReplacementEdit) {
        self.edit = edit
        super.init(bounds: edit.coverBounds, forType: .square, withProperties: nil)
        color = .clear
        interiorColor = nil
        shouldDisplay = false
        let border = PDFBorder()
        border.lineWidth = 0
        self.border = border
        userName = PDFEditEngine.annotationMarkerPrefix + "cover:" + edit.id.uuidString
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        drawPreview(in: context)
    }

    func drawPreview(in context: CGContext) {
        PDFTextRenderer.drawMovedCover(edit, in: context)
    }
}
