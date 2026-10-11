import AppKit
import CoreGraphics
import CoreText
import Foundation

/// wkhtmltopdf のような「1 グリフずつ独立した Tj + Td」の PDF を、実際に
/// `CGContext`(PDF consumer) へ 1 文字ずつ描画することで生成する。
/// 本物の Quartz PDF 書き出しを経由するため、フォント埋め込み・ToUnicode の
/// CMap も OS が実際の書き出しで生成するものと同じになる。
enum SyntheticFixture {
    struct GlyphSpec {
        let character: Character
        let font: NSFont
    }

    enum FixtureError: Error {
        case cannotCreateContext
    }

    /// 1 行分のグリフを、指定のベースライン上に指定の字間 (gap) を空けて連続配置する。
    /// 戻り値は各グリフの実際の x 開始位置（コンテンツストリームへ書き込んだ値）。
    @discardableResult
    static func drawLine(
        _ glyphs: [GlyphSpec],
        startX: CGFloat,
        baseline: CGFloat,
        gap: CGFloat,
        in context: CGContext
    ) -> [CGFloat] {
        var x = startX
        var positions: [CGFloat] = []
        for glyph in glyphs {
            positions.append(x)
            let attributed = NSAttributedString(
                string: String(glyph.character),
                attributes: [.font: glyph.font, .foregroundColor: NSColor.black]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            x += width + gap
        }
        return positions
    }

    /// 空の PDF ページを開始し、`draw` クロージャ内で `drawLine` を呼んでもらう。
    static func build(pageBounds: CGRect, draw: (CGContext) -> Void) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-text-bench-fixture-\(UUID().uuidString).pdf")
        var box = pageBounds
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw FixtureError.cannotCreateContext
        }
        let pageInfo = [kCGPDFContextMediaBox as String: pageBounds] as CFDictionary
        context.beginPDFPage(pageInfo)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}
