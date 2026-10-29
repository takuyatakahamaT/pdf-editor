import AppKit
import CoreGraphics
import PDFKit

/// 構造検証では検出できない、対象外の罫線・背景・文字の変化を保存確定前に検出。
/// 同じCoreGraphicsレンダラーで比較し、表示倍率/ビューのキャッシュに依存させない。
enum PDFVisualIntegrityValidator {
    static func verify(
        sourceURL: URL, outputURL: URL, edits: [ReplacementEdit], markups: [PDFMarkupEdit] = []
    ) throws {
        guard let source = CGPDFDocument(sourceURL as CFURL),
              let output = CGPDFDocument(outputURL as CFURL),
              source.numberOfPages == output.numberOfPages else {
            throw PDFExportError.unreadableSource
        }
        for number in 1...source.numberOfPages {
            guard let before = source.page(at: number), let after = output.page(at: number) else {
                throw PDFExportError.unreadableSource
            }
            let pageEdits = edits.filter { $0.pageIndex == number - 1 }
            let pageMarkups = markups.filter { $0.pageIndex == number - 1 }
            let allowed = pageEdits.map { edit in
                let sourceInk = edit.sourceGlyphBounds.reduce(edit.bounds) { $0.union($1) }
                let ink = PDFTextRenderer.renderedInkBounds(for: edit).reduce(sourceInk) { $0.union($1) }
                // 従来の行再配置だけは後続文字の移動領域を含める。
                return (edit.storage.isInternal ? ink : ink.union(edit.annotationBounds))
                    .insetBy(dx: -1, dy: -1)
            } + pageMarkups.map { $0.bounds.insetBy(dx: -2, dy: -2) }
            try compare(before, after, allowing: allowed)
        }
    }

    private static func compare(_ before: CGPDFPage, _ after: CGPDFPage, allowing regions: [CGRect]) throws {
        let bounds = before.getBoxRect(.mediaBox)
        guard bounds == after.getBoxRect(.mediaBox), bounds.width > 0, bounds.height > 0 else {
            throw PDFInternalTextEditError.failed("保存後のページ寸法が変わりました。")
        }
        // 各ページ最大約16MB、長辺2048px。巨大図面でもメモリを有限に保つ。
        let scale = min(2, 2048 / max(bounds.width, bounds.height))
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        let stride = width * 4
        func raster(_ page: CGPDFPage) throws -> Data {
            var bytes = Data(count: stride * height)
            try bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { throw PDFExportError.cannotCreateContext }
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                context.drawPDFPage(page)
            }
            return bytes
        }
        let source = try raster(before)
        let output = try raster(after)
        var changed = 0
        var compared = 0
        source.withUnsafeBytes { (lhs: UnsafeRawBufferPointer) in
            output.withUnsafeBytes { (rhs: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    for x in 0..<width {
                        // bitmapの先頭行は上端、PDFの原点は下端。
                        let point = CGPoint(x: bounds.minX + (CGFloat(x) + 0.5) / scale,
                                            y: bounds.minY + (CGFloat(height - y) - 0.5) / scale)
                        if regions.contains(where: { $0.contains(point) }) { continue }
                        compared += 1
                        let offset = y * stride + x * 4
                        if (0..<3).contains(where: { abs(Int(lhs[offset + $0]) - Int(rhs[offset + $0])) > 12 }) {
                            changed += 1
                        }
                    }
                }
            }
        }
        // 再エンコードに伴うアンチエイリアスの微差だけ許容する。
        guard changed <= max(3, Int(Double(compared) * 0.0001)) else {
            throw PDFInternalTextEditError.failed("変更箇所以外の見た目を保てなかったため保存を中止しました。")
        }
    }
}
