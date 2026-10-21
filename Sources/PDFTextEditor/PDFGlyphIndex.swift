import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// ページの content stream を走査して得た 1 グリフ分の情報。
struct ScannedGlyph {
    /// ToUnicode 経由で得た Unicode 文字列。解決できない場合は空文字列。
    let text: String
    /// ページ座標系での送り幅ボックス（x=ペン位置、width=送り幅、
    /// y/height はフォントの ascent/descent から求めた高さ）。
    let advanceBox: CGRect
    /// ページ座標系でのベースライン y 座標。
    let baseline: CGFloat
    /// content stream 上でのフォントリソース名（例 "/F6" は "F6" として保持）。
    let fontKey: String
    /// Tm/CTM のスケールを畳み込んだ実効フォントサイズ。
    let fontSize: CGFloat
    /// このグリフを描いた後にペンが進む距離（ページ座標系）。
    let advance: CGFloat
    /// 塗り色（`g`/`rg`/`k`/`cs`+`sc`/`scn` から追跡）。解決できない色空間は黒。
    let fillColor: NSColor
}

/// 同一ベースライン・同一フォント・同一サイズで視覚的に連続するグリフの並び。
struct ScannedRun {
    var glyphs: [ScannedGlyph]
    var text: String
    var box: CGRect
    var baseline: CGFloat
    var fontKey: String
    var fontSize: CGFloat
}

/// 文字種クラスタ判定に使う大まかな文字種。
enum CharacterClass: Equatable {
    case digit
    case latin
    case kanaKanji
    case space
    case symbol

    static func classify(_ character: Character) -> CharacterClass {
        if character.isWhitespace { return .space }
        if character.isNumber { return .digit }
        if let scalar = character.unicodeScalars.first {
            if ("a"..."z").contains(character) || ("A"..."Z").contains(character) {
                return .latin
            }
            let value = scalar.value
            let isKanaKanji =
                (0x3040...0x30FF).contains(value) ||   // ひらがな・カタカナ
                (0x31F0...0x31FF).contains(value) ||   // カタカナ拡張
                (0xFF66...0xFF9F).contains(value) ||   // 半角カナ
                (0x4E00...0x9FFF).contains(value) ||   // CJK統合漢字
                (0x3400...0x4DBF).contains(value) ||   // CJK拡張A
                (0x2E80...0x2EFF).contains(value) ||   // CJK部首補助
                (0x2F00...0x2FDF).contains(value)      // 康熙部首
            // 実データ(wkhtmltopdf 生成 PDF)の ToUnicode は「⽇」(U+2F47) のような
            // 部首(Radical)コードポイントへ変換していることがあり、標準の統合漢字
            // 範囲だけでは判定できない。両方の部首ブロックも かな・漢字 として扱う。
            if isKanaKanji { return .kanaKanji }
        }
        return .symbol
    }
}

/// 新しい `TextTarget`。PDFKit の選択機構を使わず、`PageTextIndex` から直接組み立てる。
struct TextTarget: Equatable {
    let pageIndex: Int
    /// 選択グリフ列の advance box そのもの（膨張させない）。
    let bounds: CGRect
    let baseline: CGFloat
    let originalText: String
    let fontSize: CGFloat
    let fontColor: NSColor
    /// content stream 上のフォントリソース名。
    let fontKey: String?
    /// 埋め込みフォントを再現できているか（暫定値。最終判定は置換文字列確定後に行う）。
    let fontIsExact: Bool
    /// 隣接グリフの advance box を越えない消去矩形。
    let coverBounds: CGRect
    /// 右隣のグリフまでの使用可能幅。
    let maxWidth: CGFloat
    /// 未埋め込みフォントで置換する際、同じ PDF テキスト run の後続文字を右へ移し、
    /// 文字数増加分を行末の空きへ逃がすための情報。
    let lineLayout: TextRunLayout?

    init(
        pageIndex: Int,
        bounds: CGRect,
        baseline: CGFloat,
        originalText: String,
        fontSize: CGFloat,
        fontColor: NSColor,
        fontKey: String?,
        fontIsExact: Bool,
        coverBounds: CGRect,
        maxWidth: CGFloat,
        lineLayout: TextRunLayout? = nil
    ) {
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.baseline = baseline
        self.originalText = originalText
        self.fontSize = fontSize
        self.fontColor = fontColor
        self.fontKey = fontKey
        self.fontIsExact = fontIsExact
        self.coverBounds = coverBounds
        self.maxWidth = maxWidth
        self.lineLayout = lineLayout
    }
}

struct TextRunLayout: Equatable {
    struct Glyph: Equatable {
        let text: String
        let offsetX: CGFloat
        let advance: CGFloat
    }

    let glyphs: [Glyph]
    let selectedRange: Range<Int>
    let lineStartX: CGFloat
    let lineWidth: CGFloat
    let maxWidth: CGFloat
    let coverBounds: CGRect

    var selectedStartX: CGFloat {
        glyphs[selectedRange.lowerBound].offsetX
    }

    func text(replacingWith replacement: String) -> String {
        let prefix = glyphs[..<selectedRange.lowerBound].map(\.text).joined()
        let suffix = glyphs[selectedRange.upperBound...].map(\.text).joined()
        return prefix + replacement + suffix
    }
}

/// 1 ページ分の走査結果。クリック/ドラッグ判定はすべてここを介して行う。
struct PageTextIndex {
    let runs: [ScannedRun]
    /// ページの MediaBox。同一行に右（左）隣の run が無いときの `maxWidth`/gap の
    /// 上限に使う。手組みで作ったテスト用の `PageTextIndex` などでは `.zero` のままで良く、
    /// その場合は従来どおりの汎用フォールバック値を使う。
    var pageBounds: CGRect = .zero

    /// クリック点にちょうど乗っているグリフを探す。
    func run(at point: CGPoint) -> (run: ScannedRun, glyphIndex: Int)? {
        for run in runs {
            for (glyphIndex, glyph) in run.glyphs.enumerated() where glyph.advanceBox.contains(point) {
                return (run, glyphIndex)
            }
        }
        return nil
    }

    /// クリック点から文字種クラスタを初期選択として求める。
    /// 直接ヒットが無い場合は `max(3pt, 0.6 × フォントサイズ)` 以内で最も近いグリフを採用する。
    func cluster(at point: CGPoint, pageIndex: Int) -> TextTarget? {
        clusterWithAnchor(at: point, pageIndex: pageIndex)?.target
    }

    /// `cluster(at:pageIndex:)` と同じ判定を行うが、後続のドラッグ伸縮のために
    /// アンカーとなった run とグリフ index も一緒に返す。
    func clusterWithAnchor(
        at point: CGPoint,
        pageIndex: Int
    ) -> (target: TextTarget, run: ScannedRun, anchorGlyphIndex: Int)? {
        guard let hit = closestHit(at: point) else { return nil }
        let range = characterClassRange(in: hit.run, around: hit.glyphIndex)
        guard let resolved = target(in: hit.run, range: range, pageIndex: pageIndex) else { return nil }
        return (resolved, hit.run, hit.glyphIndex)
    }

    /// ドラッグ用: 指定の run の中で x 座標に最も近いグリフの index を返す。
    func nearestGlyphIndex(in run: ScannedRun, x: CGFloat) -> Int {
        guard !run.glyphs.isEmpty else { return 0 }
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, glyph) in run.glyphs.enumerated() {
            let distance: CGFloat
            if x < glyph.advanceBox.minX {
                distance = glyph.advanceBox.minX - x
            } else if x > glyph.advanceBox.maxX {
                distance = x - glyph.advanceBox.maxX
            } else {
                distance = 0
            }
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// 指定した run の指定範囲のグリフから `TextTarget` を組み立てる。
    /// ドラッグでの範囲伸縮にも、クリックでの初期クラスタにも使う共通経路。
    func target(in run: ScannedRun, range: Range<Int>, pageIndex: Int) -> TextTarget? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= run.glyphs.count else { return nil }
        let clusterGlyphs = Array(run.glyphs[range])
        guard let first = clusterGlyphs.first else { return nil }

        var bounds = first.advanceBox
        for glyph in clusterGlyphs.dropFirst() { bounds = bounds.union(glyph.advanceBox) }

        let text = clusterGlyphs.map(\.text).joined()
        let baseline = first.baseline
        let fontSize = first.fontSize
        let fontKey = first.fontKey
        let fontColor = first.fillColor

        // 同一行（ベースライン差が 0.3×fontSize 以内）にある全 run を対象に、
        // 選択範囲の左右で最も近いグリフを探す。run の分割条件は
        // 「同一行・同一フォント・同一サイズかつ gap <= 0.25×fontSize」なので、
        // run 内だけを見ると隣の run（次の列など）が数ポイント先にあっても
        // 気づけず、はみ出して重なってしまう。
        let sameLineRuns = runs.filter { abs($0.baseline - baseline) <= 0.3 * max($0.fontSize, fontSize) }

        var nearestLeftEnd: CGFloat?
        var nearestRightStart: CGFloat?
        for lineRun in sameLineRuns {
            for glyph in lineRun.glyphs {
                if glyph.advanceBox.maxX <= bounds.minX {
                    nearestLeftEnd = max(nearestLeftEnd ?? -.greatestFiniteMagnitude, glyph.advanceBox.maxX)
                }
                if glyph.advanceBox.minX >= bounds.maxX {
                    nearestRightStart = min(nearestRightStart ?? .greatestFiniteMagnitude, glyph.advanceBox.minX)
                }
            }
        }
        // 選択範囲自身のグリフは `bounds` の内側にあるため、上の 2 条件
        // （<= bounds.minX / >= bounds.maxX）には該当せず、自然に除外される。

        let hasPageBounds = pageBounds.width > 0 && pageBounds.height > 0

        let leftGap: CGFloat
        if let nearestLeftEnd {
            leftGap = max(bounds.minX - nearestLeftEnd, 0)
        } else if hasPageBounds {
            leftGap = max(bounds.minX - pageBounds.minX, 0)
        } else {
            leftGap = 2.0
        }
        let rightGap: CGFloat
        if let nearestRightStart {
            rightGap = max(nearestRightStart - bounds.maxX, 0)
        } else if hasPageBounds {
            rightGap = max(pageBounds.maxX - bounds.maxX, 0)
        } else {
            rightGap = 2.0
        }

        // 隣接グリフの advance box を絶対に越えないための水平マージン（design §2.3:
        // gap の半分、上限 1.0pt）。gap 側の割り算が非負である限り、
        // 隣接グリフの advance box を越えることはない。
        let horizontalMargin: CGFloat = 1.0
        var coverMinX = bounds.minX - min(leftGap / 2, horizontalMargin)
        var coverMaxX = bounds.maxX + min(rightGap / 2, horizontalMargin)

        // gap は `max(..., 0)` で下限を切っているため、隣接グリフの advance box が
        // 選択範囲とわずかに重なっている場合（/W 由来の宣言幅と実際のペン送りが
        // 0.03pt 程度食い違うことがある）は gap が 0 に潰れ、マージンが 0 でも
        // `bounds` 自体が隣に重なったままになる。不変条件「隣接グリフの
        // advance box を越えない」を式の上で保証するため、最後に必ずクランプする。
        if let nearestLeftEnd { coverMinX = max(coverMinX, nearestLeftEnd) }
        if let nearestRightStart { coverMaxX = min(coverMaxX, nearestRightStart) }
        if coverMaxX < coverMinX { coverMaxX = coverMinX }
        var coverMinY = bounds.minY - 0.05 * fontSize
        var coverMaxY = bounds.maxY + 0.05 * fontSize

        // 上下の行の box を越えないようクランプする。
        for other in runs where other.fontKey != run.fontKey || abs(other.baseline - run.baseline) > 0.01 || other.box != run.box {
            guard abs(other.baseline - baseline) > 0.3 * max(fontSize, other.fontSize) else { continue }
            let horizontallyOverlaps = other.box.maxX > coverMinX && other.box.minX < coverMaxX
            guard horizontallyOverlaps else { continue }
            if other.box.minY >= bounds.maxY {
                coverMaxY = min(coverMaxY, other.box.minY)
            } else if other.box.maxY <= bounds.minY {
                coverMinY = max(coverMinY, other.box.maxY)
            }
        }
        if coverMaxY < coverMinY { coverMaxY = coverMinY }

        let coverBounds = CGRect(x: coverMinX, y: coverMinY, width: coverMaxX - coverMinX, height: coverMaxY - coverMinY)

        let maxWidth: CGFloat
        if let nearestRightStart {
            maxWidth = max(nearestRightStart - bounds.minX, bounds.width)
        } else if hasPageBounds {
            maxWidth = max(pageBounds.maxX - bounds.minX, bounds.width)
        } else {
            maxWidth = max(bounds.width * 4, 200)
        }

        let lineLayout = makeLineLayout(
            for: run,
            selectedRange: range,
            sameLineRuns: sameLineRuns,
            pageBounds: pageBounds,
            coverMinY: coverMinY,
            coverMaxY: coverMaxY
        )

        return TextTarget(
            pageIndex: pageIndex,
            bounds: bounds,
            baseline: baseline,
            originalText: text,
            fontSize: fontSize,
            fontColor: fontColor,
            fontKey: fontKey,
            fontIsExact: fontHasEmbeddedProgram[fontKey] ?? false,
            coverBounds: coverBounds,
            maxWidth: maxWidth,
            lineLayout: lineLayout
        )
    }

    private func makeLineLayout(
        for run: ScannedRun,
        selectedRange: Range<Int>,
        sameLineRuns: [ScannedRun],
        pageBounds: CGRect,
        coverMinY: CGFloat,
        coverMaxY: CGFloat
    ) -> TextRunLayout? {
        guard !run.glyphs.isEmpty,
              selectedRange.lowerBound >= 0,
              selectedRange.upperBound <= run.glyphs.count,
              run.glyphs.allSatisfy({ !$0.text.isEmpty && $0.advance >= 0 }),
              zip(run.glyphs, run.glyphs.dropFirst()).allSatisfy({ $0.advanceBox.minX <= $1.advanceBox.minX })
        else { return nil }

        let lineStartX = run.glyphs.map(\.advanceBox.minX).min() ?? run.box.minX
        let lineEndX = run.glyphs.map(\.advanceBox.maxX).max() ?? run.box.maxX
        let lineWidth = lineEndX - lineStartX
        guard lineWidth > 0 else { return nil }

        var rightBoundary = CGFloat.greatestFiniteMagnitude
        for otherRun in sameLineRuns where !isSameRun(otherRun, run) {
            for glyph in otherRun.glyphs where glyph.advanceBox.minX > lineStartX {
                rightBoundary = min(rightBoundary, glyph.advanceBox.minX)
            }
        }
        if rightBoundary == .greatestFiniteMagnitude {
            rightBoundary = pageBounds.width > 0 ? pageBounds.maxX : lineStartX + max(lineWidth * 4, 200)
        }
        let maxWidth = rightBoundary - lineStartX
        guard maxWidth >= lineWidth else { return nil }
        let glyphs = run.glyphs.map {
            TextRunLayout.Glyph(
                text: $0.text,
                offsetX: $0.advanceBox.minX - lineStartX,
                advance: $0.advance
            )
        }
        let coverBounds = CGRect(
            x: lineStartX,
            y: coverMinY,
            width: lineWidth,
            height: max(coverMaxY - coverMinY, 0)
        )
        return TextRunLayout(
            glyphs: glyphs,
            selectedRange: selectedRange,
            lineStartX: lineStartX,
            lineWidth: lineWidth,
            maxWidth: maxWidth,
            coverBounds: coverBounds
        )
    }

    private func isSameRun(_ lhs: ScannedRun, _ rhs: ScannedRun) -> Bool {
        lhs.fontKey == rhs.fontKey
            && lhs.text == rhs.text
            && lhs.box == rhs.box
            && abs(lhs.baseline - rhs.baseline) < 0.01
    }

    /// フォントキーごとに「埋め込みフォントプログラムが存在したか」を保持する
    /// （実際の置換文字列に対する厳密なグリフ網羅チェックは `PDFEmbeddedFontLoader` が別途行う）。
    var fontHasEmbeddedProgram: [String: Bool] = [:]

    private func closestHit(at point: CGPoint) -> (run: ScannedRun, glyphIndex: Int)? {
        if let hit = run(at: point) { return hit }

        var best: (run: ScannedRun, glyphIndex: Int, distance: CGFloat)?
        for run in runs {
            let verticalDistance = distance(point.y, to: run.box.minY, run.box.maxY)
            let threshold = max(3.0, 0.6 * run.fontSize)
            guard verticalDistance <= threshold else { continue }
            for (glyphIndex, glyph) in run.glyphs.enumerated() {
                let horizontalDistance = distance(point.x, to: glyph.advanceBox.minX, glyph.advanceBox.maxX)
                let total = hypot(horizontalDistance, verticalDistance)
                guard total <= threshold else { continue }
                if best == nil || total < best!.distance {
                    best = (run, glyphIndex, total)
                }
            }
        }
        return best.map { ($0.run, $0.glyphIndex) }
    }

    private func distance(_ value: CGFloat, to lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        if value < lower { return lower - value }
        if value > upper { return value - upper }
        return 0
    }

    /// ',' '.' の両側が数字かどうかを見て、桁区切りとして数字クラスタへ橋渡しできるか判定する。
    private func isDigitBridgingSeparator(_ glyphs: [ScannedGlyph], at i: Int) -> Bool {
        guard glyphs.indices.contains(i), let character = glyphs[i].text.first,
              character == "," || character == "." else { return false }
        guard glyphs.indices.contains(i - 1), glyphs.indices.contains(i + 1),
              let prev = glyphs[i - 1].text.first, let next = glyphs[i + 1].text.first else { return false }
        return CharacterClass.classify(prev) == .digit && CharacterClass.classify(next) == .digit
    }

    private func characterClassRange(in run: ScannedRun, around index: Int) -> Range<Int> {
        let glyphs = run.glyphs
        guard glyphs.indices.contains(index), let anchorChar = glyphs[index].text.first else {
            return index..<(index + 1)
        }
        var targetClass = CharacterClass.classify(anchorChar)
        // アンカー自体が桁区切りの ',' '.' で、両側が数字なら数字クラスタとして扱う
        // （例: "10,079" の ',' をクリックしても "10,079" 全体が選ばれる）。
        if targetClass != .digit, isDigitBridgingSeparator(glyphs, at: index) {
            targetClass = .digit
        }

        // 数字クラスタは桁区切りの ',' '.' をまたいでよい（例: "10,079" を 1 つの
        // クラスタとして扱う）。ただし橋渡しする記号の両側が数字であることを要求し、
        // 注文番号 "############-01" の '-' のような単なる区切りとは区別する。
        func matches(_ i: Int) -> Bool {
            guard glyphs.indices.contains(i), let character = glyphs[i].text.first else { return false }
            if CharacterClass.classify(character) == targetClass { return true }
            guard targetClass == .digit else { return false }
            return isDigitBridgingSeparator(glyphs, at: i)
        }

        var start = index
        while start > 0, matches(start - 1) { start -= 1 }
        var end = index
        while end + 1 < glyphs.count, matches(end + 1) { end += 1 }
        return start..<(end + 1)
    }
}

/// content stream 走査のエントリポイント。
enum PDFGlyphIndex {
    nonisolated(unsafe) private static let cache = NSMapTable<PDFPage, PageTextIndexBox>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// ページ単位でキャッシュされた `PageTextIndex` を返す。
    static func makeIndex(for page: PDFPage) -> PageTextIndex {
        if let box = cache.object(forKey: page) {
            return box.index
        }
        let index = buildIndex(for: page)
        cache.setObject(PageTextIndexBox(index: index), forKey: page)
        return index
    }

    /// 指定ページの Resources/Font 辞書から、フォントリソース名に対応する
    /// `CGPDFDictionaryRef` を取得する。`PDFEmbeddedFontLoader` からも使われる。
    static func fontDictionary(for fontKey: String, page: PDFPage) -> CGPDFDictionaryRef? {
        guard let cgPage = cgPage(for: page), let pageDict = cgPage.dictionary else { return nil }
        var resourcesDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resourcesDict), let resourcesDict else { return nil }
        var fontsDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resourcesDict, "Font", &fontsDict), let fontsDict else { return nil }
        var fontDict: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(fontsDict, fontKey, &fontDict)
        return fontDict
    }

    private static func cgPage(for page: PDFPage) -> CGPDFPage? {
        guard let document = page.document, let cgDocument = document.documentRef else { return nil }
        let pageIndex = document.index(for: page)
        return cgDocument.page(at: pageIndex + 1)
    }

    private static func buildIndex(for page: PDFPage) -> PageTextIndex {
        guard let cgPage = cgPage(for: page), let pageDict = cgPage.dictionary else {
            return PageTextIndex(runs: [])
        }
        var resourcesDict: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(pageDict, "Resources", &resourcesDict)
        var fontsDict: CGPDFDictionaryRef?
        if let resourcesDict {
            _ = CGPDFDictionaryGetDictionary(resourcesDict, "Font", &fontsDict)
        }

        let state = GlyphScanState(
            resourceLookup: { name in
                guard let fontsDict else { return nil }
                var dict: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(fontsDict, name, &dict)
                return dict
            },
            colorSpaceLookup: { name in
                colorSpaceComponentCount(name: name, resourcesDict: resourcesDict)
            }
        )

        let contentStream = CGPDFContentStreamCreateWithPage(cgPage)
        guard let operatorTable = makeOperatorTable() else {
            CGPDFContentStreamRelease(contentStream)
            return PageTextIndex(runs: [])
        }
        let unmanagedState = Unmanaged.passUnretained(state)
        guard let scanner = CGPDFScannerCreate(contentStream, operatorTable, unmanagedState.toOpaque()) as CGPDFScannerRef? else {
            CGPDFContentStreamRelease(contentStream)
            CGPDFOperatorTableRelease(operatorTable)
            return PageTextIndex(runs: [])
        }
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contentStream)
        CGPDFOperatorTableRelease(operatorTable)

        let runs = groupIntoRuns(glyphs: state.glyphs)
        var hasEmbedded: [String: Bool] = [:]
        for (key, info) in state.fonts { hasEmbedded[key] = info.hasEmbeddedProgram }
        var index = PageTextIndex(runs: runs, fontHasEmbeddedProgram: hasEmbedded)
        index.pageBounds = cgPage.getBoxRect(.mediaBox)
        return index
    }
}

/// 塗り色空間名から成分数を推測する。`DeviceGray`/`DeviceRGB`/`DeviceCMYK` は
/// 直接判定し、それ以外はページの `/Resources/ColorSpace` を辿って解決する
/// （`ICCBased` は `/N`、`DeviceN` は名前配列の要素数、`Indexed`/`Separation` は 1）。
/// 解決できない場合は DeviceRGB(3) を安全側の既定値とする。
private func colorSpaceComponentCount(name: String, resourcesDict: CGPDFDictionaryRef?) -> Int {
    switch name {
    case "DeviceGray", "CalGray", "G": return 1
    case "DeviceRGB", "CalRGB", "RGB": return 3
    case "DeviceCMYK", "CMYK": return 4
    case "Pattern": return 0
    default:
        guard let resourcesDict else { return 3 }
        var csDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resourcesDict, "ColorSpace", &csDict), let csDict else { return 3 }
        var csArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(csDict, name, &csArray), let csArray, CGPDFArrayGetCount(csArray) >= 1 {
            var familyPtr: UnsafePointer<Int8>?
            _ = CGPDFArrayGetName(csArray, 0, &familyPtr)
            let family = familyPtr.map { String(cString: $0) } ?? ""
            switch family {
            case "ICCBased":
                var stream: CGPDFStreamRef?
                if CGPDFArrayGetStream(csArray, 1, &stream), let stream, let streamDict = CGPDFStreamGetDictionary(stream) {
                    var n: CGPDFInteger = 3
                    _ = CGPDFDictionaryGetInteger(streamDict, "N", &n)
                    return Int(n)
                }
                return 3
            case "CalGray": return 1
            case "CalRGB", "Lab": return 3
            case "Indexed", "Separation": return 1
            case "DeviceN":
                var namesArray: CGPDFArrayRef?
                if CGPDFArrayGetArray(csArray, 1, &namesArray), let namesArray {
                    return max(CGPDFArrayGetCount(namesArray), 1)
                }
                return 1
            default: return 3
            }
        }
        // 別名への直接参照（レアケース）。
        var directNamePtr: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(csDict, name, &directNamePtr), let directNamePtr {
            return colorSpaceComponentCount(name: String(cString: directNamePtr), resourcesDict: resourcesDict)
        }
        return 3
    }
}

private final class PageTextIndexBox {
    let index: PageTextIndex
    init(index: PageTextIndex) { self.index = index }
}

// MARK: - 走査状態とフォント情報

/// フォント辞書から読み取った、幅・Unicode 変換・ascent/descent を保持する軽量情報。
struct PDFFontInfo {
    var bytesPerCode: Int
    var widthTable: [Int: CGFloat]
    var defaultWidth: CGFloat
    var toUnicode: [Int: String]
    var ascent: CGFloat
    var descent: CGFloat
    var hasEmbeddedProgram: Bool
    /// `toUnicode` を反転した Unicode文字 → コード のマップ（1 文字対応分のみ）。
    /// このサンプル PDF のようにサブセット埋め込みフォントが `cmap` テーブルを
    /// 持たない場合、`CTFontGetGlyphsForCharacters` は常に失敗する。
    /// しかし元 PDF 自身がその文字を ToUnicode で宣言済みということは、
    /// そのコード = GID の位置に実在するグリフがある証拠なので、
    /// 置換文字列の全文字がこのマップに載っていれば cmap を介さず直接
    /// 元の GID でグリフを描画できる（真に「元 PDF と同じフォントそのもの」）。
    var unicodeToCode: [String: Int]
    /// Type0/CIDFontType2 で `/CIDToGIDMap` が `/Identity`（または省略= 既定 Identity）
    /// の場合のみ true。true のときだけ code をそのまま GID として使ってよい。
    var isIdentityCIDToGID: Bool

    func width(for code: Int) -> CGFloat { widthTable[code] ?? defaultWidth }

    static let fallback = PDFFontInfo(
        bytesPerCode: 1,
        widthTable: [:],
        defaultWidth: 0.5,
        toUnicode: [:],
        ascent: 0.8,
        descent: -0.2,
        hasEmbeddedProgram: false,
        unicodeToCode: [:],
        isIdentityCIDToGID: false
    )
}

final class GlyphScanState {
    private struct TextGraphicsState {
        let fontKey: String
        let fontSize: CGFloat
        let charSpacing: CGFloat
        let wordSpacing: CGFloat
        let horizontalScale: CGFloat
        let leading: CGFloat
        let textRise: CGFloat
    }

    var ctmStack: [CGAffineTransform] = [.identity]
    var ctm: CGAffineTransform { ctmStack[ctmStack.count - 1] }

    /// 塗り色の gstate スタック（`q`/`Q` に連動して push/pop する）。
    /// PDF の既定色は DeviceGray 0 = 黒。
    var fillColorStack: [NSColor] = [.black]
    /// 現在選択中の塗り色空間の成分数（`sc`/`scn` が読む数値の個数）。
    var fillColorSpaceComponentsStack: [Int] = [1]

    var tm: CGAffineTransform = .identity
    var tlm: CGAffineTransform = .identity
    var fontKey: String = ""
    var fontSize: CGFloat = 0
    var charSpacing: CGFloat = 0
    var wordSpacing: CGFloat = 0
    var horizontalScale: CGFloat = 1
    var leading: CGFloat = 0
    var textRise: CGFloat = 0
    private var textGraphicsStateStack: [TextGraphicsState] = []

    var fonts: [String: PDFFontInfo] = [:]
    var glyphs: [ScannedGlyph] = []

    /// `BDC`/`BMC` 〜 `EMC` のネストスタック。各要素は
    /// 「そのスパン（BDC の場合のみ、空の `/ActualText` を持つ）がスキップ対象か」を表す。
    var markedContentStack: [Bool] = []
    /// スキップ対象スパンの中に何重ネストしているか。0 のときだけグリフを記録する。
    /// このサンプル PDF は「アクセシビリティ用の空 ActualText marked content 内で
    /// 同じ文字列をわずかにずらして再描画する」wkhtmltopdf の癖があり
    /// （実測: 請求書タイトル・表ヘッダ等で確認）、そのまま拾うと
    /// 同一文字が重複したクラスタになる。一方、タグ付き PDF（Word/InDesign 等）の
    /// 本文は BDC/EMC の中にあっても `/ActualText` を持たない通常のケースなので、
    /// marked content 内かどうかではなく「空の ActualText スパンか」だけで判定する。
    var skippingMarkedContentCount = 0

    let resourceLookup: (String) -> CGPDFDictionaryRef?
    let colorSpaceLookup: (String) -> Int

    init(
        resourceLookup: @escaping (String) -> CGPDFDictionaryRef?,
        colorSpaceLookup: @escaping (String) -> Int
    ) {
        self.resourceLookup = resourceLookup
        self.colorSpaceLookup = colorSpaceLookup
    }

    func fontInfo(for key: String) -> PDFFontInfo {
        if let cached = fonts[key] { return cached }
        guard let dict = resourceLookup(key) else {
            fonts[key] = .fallback
            return .fallback
        }
        let info = PDFFontInfoLoader.load(from: dict)
        fonts[key] = info
        return info
    }

    func pushGraphicsState() {
        ctmStack.append(ctm)
        fillColorStack.append(fillColorStack[fillColorStack.count - 1])
        fillColorSpaceComponentsStack.append(fillColorSpaceComponentsStack[fillColorSpaceComponentsStack.count - 1])
        textGraphicsStateStack.append(TextGraphicsState(
            fontKey: fontKey,
            fontSize: fontSize,
            charSpacing: charSpacing,
            wordSpacing: wordSpacing,
            horizontalScale: horizontalScale,
            leading: leading,
            textRise: textRise
        ))
    }

    func popGraphicsState() {
        if ctmStack.count > 1 { ctmStack.removeLast() }
        if fillColorStack.count > 1 { fillColorStack.removeLast() }
        if fillColorSpaceComponentsStack.count > 1 { fillColorSpaceComponentsStack.removeLast() }
        if let saved = textGraphicsStateStack.popLast() {
            fontKey = saved.fontKey
            fontSize = saved.fontSize
            charSpacing = saved.charSpacing
            wordSpacing = saved.wordSpacing
            horizontalScale = saved.horizontalScale
            leading = saved.leading
            textRise = saved.textRise
        }
    }
}

private func groupIntoRuns(glyphs: [ScannedGlyph]) -> [ScannedRun] {
    guard !glyphs.isEmpty else { return [] }

    let sorted = glyphs.sorted { lhs, rhs in
        if abs(lhs.baseline - rhs.baseline) > 0.01 {
            return lhs.baseline > rhs.baseline
        }
        return lhs.advanceBox.minX < rhs.advanceBox.minX
    }

    var lines: [[ScannedGlyph]] = []
    for glyph in sorted {
        if let lastIndex = lines.indices.last,
           let representative = lines[lastIndex].first,
           abs(glyph.baseline - representative.baseline) <= 0.3 * max(glyph.fontSize, representative.fontSize) {
            lines[lastIndex].append(glyph)
        } else {
            lines.append([glyph])
        }
    }

    var runs: [ScannedRun] = []
    for line in lines {
        let byX = line.sorted { $0.advanceBox.minX < $1.advanceBox.minX }
        var current: [ScannedGlyph] = []
        for glyph in byX {
            if let last = current.last {
                let gap = glyph.advanceBox.minX - (last.advanceBox.minX + last.advance)
                let sameFont = glyph.fontKey == last.fontKey
                let sameSize = abs(glyph.fontSize - last.fontSize) < 0.05
                if sameFont, sameSize, gap <= 0.25 * glyph.fontSize {
                    current.append(glyph)
                    continue
                }
                runs.append(makeRun(current))
                current = []
            }
            current.append(glyph)
        }
        if !current.isEmpty { runs.append(makeRun(current)) }
    }
    return runs
}

private func makeRun(_ glyphs: [ScannedGlyph]) -> ScannedRun {
    var box = glyphs[0].advanceBox
    for glyph in glyphs.dropFirst() { box = box.union(glyph.advanceBox) }
    return ScannedRun(
        glyphs: glyphs,
        text: glyphs.map(\.text).joined(),
        box: box,
        baseline: glyphs[0].baseline,
        fontKey: glyphs[0].fontKey,
        fontSize: glyphs[0].fontSize
    )
}
