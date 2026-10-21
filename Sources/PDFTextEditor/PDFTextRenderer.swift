import AppKit
import CoreGraphics
import CoreText
import PDFKit

/// プレビュー（`ReplacementTextAnnotation.draw(with:in:)`）と書き出し
/// （`PDFExportEngine`）の両方から呼ばれる、置換テキストの唯一の描画経路。
/// 段落レイアウトや折り返しは一切使わず、1 行の `CTLine` を
/// ベースライン固定で描く。置換時は同じ行の後続文字を動かして空き幅を作る。
/// 行内に空きがない場合も、横だけを細くせず縦横比を保って縮小する。
enum PDFTextRenderer {
    static func draw(_ edit: ReplacementEdit, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        if !edit.fontIsExact,
           let lineLayout = edit.lineLayout,
           !edit.replacement.isEmpty {
            let font = edit.resolvedFont ?? CTFontCreateWithName("Helvetica" as CFString, edit.fontSize, nil)
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
        if plan.scale != 1 {
            context.scaleBy(x: plan.scale, y: plan.scale)
        }
        context.setFillColor(edit.fontColor.cgColor)
        drawGlyphOutlines(for: plan.line, in: context)
    }

    /// GID を直接指定して描く経路。幅は元 PDF の `/Widths`/`/W` 由来の値
    /// (`emWidth`) を使い、CTLine の文字ベース計測には頼らない。
    private static func drawExactGlyphs(
        _ glyphs: [(glyph: CGGlyph, emWidth: CGFloat)],
        font: CTFont,
        edit: ReplacementEdit,
        in context: CGContext
    ) {
        var currentFont = font
        var fontSize = CTFontGetSize(font)

        func totalWidth(at size: CGFloat) -> CGFloat {
            glyphs.reduce(0) { $0 + $1.emWidth } * size
        }

        var scale: CGFloat = 1
        while true {
            let width = totalWidth(at: fontSize)
            if width <= edit.maxWidth || width <= 0 {
                break
            }
            if fontSize <= 6 {
                scale = min(edit.maxWidth / width, 1)
                break
            }
            let newSize = max(fontSize - 0.5, 6)
            guard let cgFont = CTFontCopyGraphicsFont(currentFont, nil) as CGFont? else { break }
            currentFont = CTFontCreateWithGraphicsFont(cgFont, newSize, nil, nil)
            fontSize = newSize
        }

        context.translateBy(x: edit.bounds.minX, y: edit.baseline)
        if scale != 1 {
            context.scaleBy(x: scale, y: scale)
        }
        context.setFillColor(edit.fontColor.cgColor)

        var x: CGFloat = 0
        for (glyph, emWidth) in glyphs {
            if let path = CTFontCreatePathForGlyph(currentFont, glyph, nil) {
                var transform = CGAffineTransform(translationX: x, y: 0)
                if let positioned = path.copy(using: &transform) {
                    context.addPath(positioned)
                }
            }
            x += emWidth * fontSize
        }
        context.fillPath()
    }

    private static func drawReflow(
        _ edit: ReplacementEdit,
        layout: TextRunLayout,
        font: CTFont,
        in context: CGContext
    ) {
        let plan = reflowPlan(text: edit.replacement, font: font, layout: layout, color: edit.fontColor)
        guard plan.outputEnd > 0, layout.maxWidth > 0 else {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(edit.coverBounds)
            return
        }

        // 後続の文字を右へ送って幅を確保する。ページ上の次の文字に当たる場合だけ
        // 縦横比を保ったまま全体を縮め、横方向だけを押しつぶさない。
        let coverWidth = min(max(layout.lineWidth, plan.outputEnd), layout.maxWidth)
        var cover = layout.coverBounds
        cover.size.width = coverWidth
        context.setFillColor(NSColor.white.cgColor)
        context.fill(cover)

        context.saveGState()
        context.translateBy(x: layout.lineStartX, y: edit.baseline)
        context.scaleBy(x: plan.scale, y: plan.scale)

        for glyph in layout.glyphs[..<layout.selectedRange.lowerBound] {
            drawText(glyph.text, font: font, color: edit.fontColor, at: glyph.offsetX, in: context)
        }
        drawLine(plan.line, at: layout.selectedStartX, in: context)
        for glyph in layout.glyphs[layout.selectedRange.upperBound...] {
            drawText(glyph.text, font: font, color: edit.fontColor, at: glyph.offsetX + plan.shift, in: context)
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
        color: NSColor = .black
    ) -> ReflowPlan {
        let line = makeLine(text: text, font: font, color: color)
        let replacementWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
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
        let scale = outputEnd > layout.maxWidth && outputEnd > 0
            ? layout.maxWidth / outputEnd
            : 1
        return ReflowPlan(line: line, shift: shift, outputEnd: outputEnd, scale: scale)
    }

    /// テキスト追加モードなど、置換以外の用途で単純に 1 行を描く場合に使う共通の輪郭描画。
    static func drawGlyphOutlines(for line: CTLine, in context: CGContext) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let fontValue = attributes[kCTFontAttributeName as String] else { continue }
            let runFont = fontValue as! CTFont

            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = Array(repeating: CGGlyph(), count: count)
            var positions = Array(repeating: CGPoint.zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

            for index in 0..<count {
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                var transform = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                if let positionedPath = path.copy(using: &transform) {
                    context.addPath(positionedPath)
                }
            }
        }
        context.fillPath()
    }

    struct RenderPlan {
        let line: CTLine
        let fontSize: CGFloat
        let scale: CGFloat
    }

    static func renderPlan(text: String, font: CTFont, color: NSColor, maxWidth: CGFloat) -> RenderPlan {
        var currentFont = font
        while true {
            let line = makeLine(text: text, font: currentFont, color: color)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let currentSize = CTFontGetSize(currentFont)

            if width <= maxWidth || width <= 0 {
                return RenderPlan(line: line, fontSize: currentSize, scale: 1)
            }
            if currentSize <= 6 {
                return RenderPlan(line: line, fontSize: currentSize, scale: min(maxWidth / width, 1))
            }
            let newSize = max(currentSize - 0.5, 6)
            currentFont = CTFontCreateCopyWithAttributes(currentFont, newSize, nil, nil)
        }
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

/// 置換のプレビュー annotation。従来の `PDFAnnotation(.freeText)` は自動折り返しを
/// 起こすため置換には使わない（テキスト追加モードは引き続き freeText を使う）。
/// `draw(with:in:)` の中で `PDFTextRenderer.draw` を呼ぶことで、
/// 画面プレビューと書き出し (`PDFExportEngine`) が完全に同じ描画コードを通る。
final class ReplacementTextAnnotation: PDFAnnotation {
    let edit: ReplacementEdit

    init(edit: ReplacementEdit) {
        self.edit = edit
        super.init(bounds: edit.annotationBounds, forType: .square, withProperties: nil)
        color = .clear
        interiorColor = nil
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
        PDFTextRenderer.draw(edit, in: context)
    }
}
