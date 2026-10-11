import AppKit
import CoreGraphics
import CoreText
import PDFKit

/// プレビュー（`ReplacementTextAnnotation.draw(with:in:)`）と書き出し
/// （`PDFExportEngine`）の両方から呼ばれる、置換テキストの唯一の描画経路。
/// 段落レイアウトや折り返しは一切使わず、1 行の `CTLine` を
/// ベースライン固定で描く。幅が収まらない場合のみ水平圧縮→ポイントサイズ縮小を行う。
enum PDFTextRenderer {
    static func draw(_ edit: ReplacementEdit, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

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
        if plan.scaleX != 1 {
            context.scaleBy(x: plan.scaleX, y: 1)
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

        var scaleX: CGFloat = 1
        while true {
            let width = totalWidth(at: fontSize)
            if width <= edit.maxWidth || width <= 0 {
                scaleX = 1
                break
            }
            if fontSize <= 6 {
                scaleX = max(edit.maxWidth / width, 0.75)
                break
            }
            if width * 0.75 <= edit.maxWidth {
                scaleX = edit.maxWidth / width
                break
            }
            let newSize = max(fontSize - 0.5, 6)
            guard let cgFont = CTFontCopyGraphicsFont(currentFont, nil) as CGFont? else { break }
            currentFont = CTFontCreateWithGraphicsFont(cgFont, newSize, nil, nil)
            fontSize = newSize
        }

        context.translateBy(x: edit.bounds.minX, y: edit.baseline)
        if scaleX != 1 {
            context.scaleBy(x: scaleX, y: 1)
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

    private struct RenderPlan {
        let line: CTLine
        let scaleX: CGFloat
    }

    private static func renderPlan(text: String, font: CTFont, color: NSColor, maxWidth: CGFloat) -> RenderPlan {
        var currentFont = font
        while true {
            let line = makeLine(text: text, font: currentFont, color: color)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let currentSize = CTFontGetSize(currentFont)

            if width <= maxWidth || width <= 0 {
                return RenderPlan(line: line, scaleX: 1)
            }
            if currentSize <= 6 {
                let scaleX = max(maxWidth / width, 0.75)
                return RenderPlan(line: line, scaleX: scaleX)
            }
            if width * 0.75 <= maxWidth {
                return RenderPlan(line: line, scaleX: maxWidth / width)
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
        super.init(bounds: edit.coverBounds, forType: .square, withProperties: nil)
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
