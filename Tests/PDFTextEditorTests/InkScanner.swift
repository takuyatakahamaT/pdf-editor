import CoreGraphics
import PDFKit

/// テスト専用: 書き出し済み PDF の content stream から `re`/`m`/`l`/`c`/`f` を追跡し、
/// 各塗り操作のバウンディングボックスをページ座標系で集める。
/// `PDFTextRenderer.draw` は「白い矩形を re+f で塗る → グリフ輪郭を m/l/c+f で塗る」
/// という順序で描くため、`fills` の要素順がそのまま「消去矩形 → 置換文字の描画範囲」になる。
enum InkScanner {
    struct Fill {
        let bounds: CGRect
        let isPlainRect: Bool
        let etCountAtFill: Int
    }

    static func scan(page: PDFPage) -> [Fill] {
        guard let document = page.document, let cgDocument = document.documentRef else { return [] }
        let pageIndex = document.index(for: page)
        guard let cgPage = cgDocument.page(at: pageIndex + 1) else { return [] }

        let state = InkScanState()
        let contentStream = CGPDFContentStreamCreateWithPage(cgPage)
        guard let table = CGPDFOperatorTableCreate() else {
            CGPDFContentStreamRelease(contentStream)
            return []
        }
        CGPDFOperatorTableSetCallback(table, "q", inkPush)
        CGPDFOperatorTableSetCallback(table, "Q", inkPop)
        CGPDFOperatorTableSetCallback(table, "cm", inkConcat)
        CGPDFOperatorTableSetCallback(table, "re", inkRect)
        CGPDFOperatorTableSetCallback(table, "m", inkMoveTo)
        CGPDFOperatorTableSetCallback(table, "l", inkLineTo)
        CGPDFOperatorTableSetCallback(table, "c", inkCurveTo)
        CGPDFOperatorTableSetCallback(table, "f", inkFill)
        CGPDFOperatorTableSetCallback(table, "f*", inkFill)
        // `n`/`S`/`s` はパスを構築するだけで塗らずに終了する演算子
        // (元ページのクリップ設定 `re W n` など)。ここで蓄積した点をクリアしないと、
        // 次の本当の塗り (置換の白矩形など) のバウンディングボックスに
        // 混ざってしまう。
        CGPDFOperatorTableSetCallback(table, "n", inkEndPathWithoutPainting)
        CGPDFOperatorTableSetCallback(table, "S", inkEndPathWithoutPainting)
        CGPDFOperatorTableSetCallback(table, "s", inkEndPathWithoutPainting)
        CGPDFOperatorTableSetCallback(table, "ET", inkEndText)

        let unmanaged = Unmanaged.passUnretained(state)
        guard let scanner = CGPDFScannerCreate(contentStream, table, unmanaged.toOpaque()) as CGPDFScannerRef? else {
            CGPDFContentStreamRelease(contentStream)
            CGPDFOperatorTableRelease(table)
            return []
        }
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contentStream)
        CGPDFOperatorTableRelease(table)

        // `page.draw(with:to:)` が描く元のページ本体には、置換とは無関係な塗り
        // (背景矩形など) が含まれ得る。`PDFTextRenderer.draw` が追記するのは
        // 常に最後の `ET` より後なので、そこより後の塗りだけを対象にする
        // (scripts/verify-edit.py と同じ切り分け方)。
        return state.fills.filter { $0.etCountAtFill == state.etCount }
    }
}

private final class InkScanState {
    var ctmStack: [CGAffineTransform] = [.identity]
    var ctm: CGAffineTransform { ctmStack[ctmStack.count - 1] }
    var currentPoints: [CGPoint] = []
    var currentIsRectOnly = true
    var fills: [InkScanner.Fill] = []
    var etCount = 0

    func pushPoint(_ point: CGPoint) {
        currentPoints.append(point.applying(ctm))
    }
}

private func inkEndText(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    inkState(info)?.etCount += 1
}

private func inkEndPathWithoutPainting(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = inkState(info) else { return }
    state.currentPoints = []
    state.currentIsRectOnly = true
}

private func inkState(_ info: UnsafeMutableRawPointer?) -> InkScanState? {
    guard let info else { return nil }
    return Unmanaged<InkScanState>.fromOpaque(info).takeUnretainedValue()
}

private func inkPush(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = inkState(info) else { return }
    state.ctmStack.append(state.ctm)
}

private func inkPop(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = inkState(info) else { return }
    if state.ctmStack.count > 1 { state.ctmStack.removeLast() }
}

private func inkConcat(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = inkState(info) else { return }
    var f: CGPDFReal = 0, e: CGPDFReal = 0, d: CGPDFReal = 0, c: CGPDFReal = 0, b: CGPDFReal = 0, a: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &f), CGPDFScannerPopNumber(scanner, &e),
          CGPDFScannerPopNumber(scanner, &d), CGPDFScannerPopNumber(scanner, &c),
          CGPDFScannerPopNumber(scanner, &b), CGPDFScannerPopNumber(scanner, &a) else { return }
    let m = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
    state.ctmStack[state.ctmStack.count - 1] = m.concatenating(state.ctm)
}

private func inkRect(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = inkState(info) else { return }
    var h: CGPDFReal = 0, w: CGPDFReal = 0, y: CGPDFReal = 0, x: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &h), CGPDFScannerPopNumber(scanner, &w),
          CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
    state.pushPoint(CGPoint(x: x, y: y))
    state.pushPoint(CGPoint(x: x + w, y: y))
    state.pushPoint(CGPoint(x: x + w, y: y + h))
    state.pushPoint(CGPoint(x: x, y: y + h))
}

private func inkMoveTo(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = inkState(info) else { return }
    var y: CGPDFReal = 0, x: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
    state.currentIsRectOnly = false
    state.pushPoint(CGPoint(x: x, y: y))
}

private func inkLineTo(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = inkState(info) else { return }
    var y: CGPDFReal = 0, x: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
    state.currentIsRectOnly = false
    state.pushPoint(CGPoint(x: x, y: y))
}

private func inkCurveTo(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = inkState(info) else { return }
    var y3: CGPDFReal = 0, x3: CGPDFReal = 0, y2: CGPDFReal = 0, x2: CGPDFReal = 0, y1: CGPDFReal = 0, x1: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &y3), CGPDFScannerPopNumber(scanner, &x3),
          CGPDFScannerPopNumber(scanner, &y2), CGPDFScannerPopNumber(scanner, &x2),
          CGPDFScannerPopNumber(scanner, &y1), CGPDFScannerPopNumber(scanner, &x1) else { return }
    state.currentIsRectOnly = false
    state.pushPoint(CGPoint(x: x1, y: y1))
    state.pushPoint(CGPoint(x: x2, y: y2))
    state.pushPoint(CGPoint(x: x3, y: y3))
}

private func inkFill(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = inkState(info) else { return }
    defer {
        state.currentPoints = []
        state.currentIsRectOnly = true
    }
    guard !state.currentPoints.isEmpty else { return }
    let xs = state.currentPoints.map(\.x)
    let ys = state.currentPoints.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
    let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    state.fills.append(InkScanner.Fill(bounds: bounds, isPlainRect: state.currentIsRectOnly, etCountAtFill: state.etCount))
}
