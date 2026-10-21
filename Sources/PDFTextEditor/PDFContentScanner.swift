import AppKit
import CoreGraphics
import Foundation

// MARK: - CGPDFScanner オペレータテーブル
//
// `PDFGlyphIndex` が生成する `GlyphScanState` を `info` として渡し、
// content stream 中の演算子を 1 つずつコールバックで受け取る。
// CGPDFOperatorCallback は @convention(c) の関数ポインタでなければならないため、
// 捕獲のないトップレベル関数として実装する（scanner 引数は非 Optional）。

func makeOperatorTable() -> CGPDFOperatorTableRef? {
    guard let table = CGPDFOperatorTableCreate() else { return nil }
    CGPDFOperatorTableSetCallback(table, "q", opPushGState)
    CGPDFOperatorTableSetCallback(table, "Q", opPopGState)
    CGPDFOperatorTableSetCallback(table, "cm", opConcatCTM)
    CGPDFOperatorTableSetCallback(table, "Do", opInvokeXObject)
    CGPDFOperatorTableSetCallback(table, "BT", opBeginText)
    CGPDFOperatorTableSetCallback(table, "Tf", opSetFont)
    CGPDFOperatorTableSetCallback(table, "Tm", opSetTextMatrix)
    CGPDFOperatorTableSetCallback(table, "Td", opMoveTextPosition)
    CGPDFOperatorTableSetCallback(table, "TD", opMoveTextPositionSetLeading)
    CGPDFOperatorTableSetCallback(table, "T*", opNextLine)
    CGPDFOperatorTableSetCallback(table, "TL", opSetLeading)
    CGPDFOperatorTableSetCallback(table, "Tc", opSetCharSpacing)
    CGPDFOperatorTableSetCallback(table, "Tw", opSetWordSpacing)
    CGPDFOperatorTableSetCallback(table, "Tz", opSetHorizontalScale)
    CGPDFOperatorTableSetCallback(table, "Ts", opSetTextRise)
    CGPDFOperatorTableSetCallback(table, "Tr", opSetTextRenderingMode)
    CGPDFOperatorTableSetCallback(table, "Tj", opShowText)
    CGPDFOperatorTableSetCallback(table, "TJ", opShowTextArray)
    CGPDFOperatorTableSetCallback(table, "'", opNextLineShowText)
    CGPDFOperatorTableSetCallback(table, "\"", opNextLineShowTextWithSpacing)
    CGPDFOperatorTableSetCallback(table, "BDC", opBeginMarkedContentDict)
    CGPDFOperatorTableSetCallback(table, "BMC", opBeginMarkedContentSimple)
    CGPDFOperatorTableSetCallback(table, "EMC", opEndMarkedContent)
    CGPDFOperatorTableSetCallback(table, "g", opSetGray)
    CGPDFOperatorTableSetCallback(table, "rg", opSetRGB)
    CGPDFOperatorTableSetCallback(table, "k", opSetCMYK)
    CGPDFOperatorTableSetCallback(table, "cs", opSetFillColorSpace)
    CGPDFOperatorTableSetCallback(table, "sc", opSetFillColorN)
    CGPDFOperatorTableSetCallback(table, "scn", opSetFillColorN)
    return table
}

private func state(from info: UnsafeMutableRawPointer?) -> GlyphScanState? {
    guard let info else { return nil }
    return Unmanaged<GlyphScanState>.fromOpaque(info).takeUnretainedValue()
}

private func opPushGState(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    state(from: info)?.pushGraphicsState()
}

private func opPopGState(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    state(from: info)?.popGraphicsState()
}

private func opConcatCTM(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var f: CGPDFReal = 0, e: CGPDFReal = 0, d: CGPDFReal = 0, c: CGPDFReal = 0, b: CGPDFReal = 0, a: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &f), CGPDFScannerPopNumber(scanner, &e),
          CGPDFScannerPopNumber(scanner, &d), CGPDFScannerPopNumber(scanner, &c),
          CGPDFScannerPopNumber(scanner, &b), CGPDFScannerPopNumber(scanner, &a) else { return }
    let m = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
    state.ctmStack[state.ctmStack.count - 1] = m.concatenating(state.ctm)
}

/// Form XObjectの本文も同じグリフ索引へ追加する。画像XObjectは編集対象の文字を
/// 持たないため無視し、Formだけを有限の深さで再帰走査する。
private func opInvokeXObject(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var resourceNamePtr: UnsafePointer<Int8>?
    guard CGPDFScannerPopName(scanner, &resourceNamePtr), let resourceNamePtr else { return }
    let resourceName = String(cString: resourceNamePtr)
    let parentStream = CGPDFScannerGetContentStream(scanner)
    let object = resourceName.withCString {
        CGPDFContentStreamGetResource(parentStream, "XObject", $0)
    }
    guard let object, CGPDFObjectGetType(object) == .stream else { return }
    var formStream: CGPDFStreamRef?
    guard CGPDFObjectGetValue(object, .stream, &formStream), let formStream,
          let formDictionary = CGPDFStreamGetDictionary(formStream) else { return }

    var subtypePtr: UnsafePointer<Int8>?
    guard CGPDFDictionaryGetName(formDictionary, "Subtype", &subtypePtr),
          subtypePtr.map({ String(cString: $0) }) == "Form" else { return }
    var formResources: CGPDFDictionaryRef?
    _ = CGPDFDictionaryGetDictionary(formDictionary, "Resources", &formResources)
    guard state.enterForm(named: resourceName, resources: formResources) else { return }
    defer { state.leaveForm() }

    let savedTextMatrix = state.tm
    let savedTextLineMatrix = state.tlm
    let savedMarkedContentStack = state.markedContentStack
    let savedSkippingMarkedContentCount = state.skippingMarkedContentCount
    state.pushGraphicsState()
    defer {
        state.popGraphicsState()
        state.tm = savedTextMatrix
        state.tlm = savedTextLineMatrix
        state.markedContentStack = savedMarkedContentStack
        state.skippingMarkedContentCount = savedSkippingMarkedContentCount
    }

    let formMatrix = formTransformationMatrix(formDictionary)
    state.ctmStack[state.ctmStack.count - 1] = formMatrix.concatenating(state.ctm)

    guard let formResources = state.activeResources else { return }
    let contentStream = CGPDFContentStreamCreateWithStream(formStream, formResources, parentStream)
    defer { CGPDFContentStreamRelease(contentStream) }
    guard let operatorTable = makeOperatorTable() else { return }
    defer { CGPDFOperatorTableRelease(operatorTable) }
    guard let formScanner = CGPDFScannerCreate(
        contentStream,
        operatorTable,
        Unmanaged.passUnretained(state).toOpaque()
    ) as CGPDFScannerRef? else { return }
    defer { CGPDFScannerRelease(formScanner) }
    _ = CGPDFScannerScan(formScanner)
}

private func formTransformationMatrix(_ dictionary: CGPDFDictionaryRef) -> CGAffineTransform {
    var matrixArray: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dictionary, "Matrix", &matrixArray), let matrixArray,
          CGPDFArrayGetCount(matrixArray) == 6 else { return .identity }
    var values = [CGPDFReal](repeating: 0, count: 6)
    for index in values.indices {
        guard CGPDFArrayGetNumber(matrixArray, index, &values[index]) else { return .identity }
    }
    return CGAffineTransform(
        a: values[0], b: values[1], c: values[2], d: values[3],
        tx: values[4], ty: values[5]
    )
}

/// `BDC`: `tag properties BDC`。オペランドはタグ→プロパティの順で積まれるため、
/// pop は逆順（プロパティが先、タグが後）になる。
/// プロパティが空文字列の `/ActualText` を持つ辞書のときだけ「スキップ対象スパン」と
/// みなす（このサンプル PDF で確認した wkhtmltopdf の重複描画パターン）。
/// プロパティが `/Properties` リソース経由の名前参照の場合は辞書を取得できないため、
/// 安全側に倒してスキップしない。
private func opBeginMarkedContentDict(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var propsDict: CGPDFDictionaryRef?
    var shouldSkip = false
    if CGPDFScannerPopDictionary(scanner, &propsDict), let propsDict {
        shouldSkip = isEmptyActualTextSpan(propsDict)
    } else {
        var propsName: UnsafePointer<Int8>?
        _ = CGPDFScannerPopName(scanner, &propsName)
    }
    // タグ名 (先に積まれた方) は使わないが、スタックから読み捨てておく。
    var tagName: UnsafePointer<Int8>?
    _ = CGPDFScannerPopName(scanner, &tagName)

    state.markedContentStack.append(shouldSkip)
    if shouldSkip { state.skippingMarkedContentCount += 1 }
}

/// `BMC`: `tag BMC`。プロパティを持たないので常にスキップ対象にはしない。
private func opBeginMarkedContentSimple(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var tagName: UnsafePointer<Int8>?
    _ = CGPDFScannerPopName(scanner, &tagName)
    state.markedContentStack.append(false)
}

private func opEndMarkedContent(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    guard let wasSkipping = state.markedContentStack.popLast() else { return }
    if wasSkipping, state.skippingMarkedContentCount > 0 {
        state.skippingMarkedContentCount -= 1
    }
}

/// `/ActualText` が存在し、かつ長さ 0 の文字列かどうかを判定する。
private func isEmptyActualTextSpan(_ dict: CGPDFDictionaryRef) -> Bool {
    var stringRef: CGPDFStringRef?
    guard CGPDFDictionaryGetString(dict, "ActualText", &stringRef), let stringRef else { return false }
    return CGPDFStringGetLength(stringRef) == 0
}

private func opBeginText(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    state.tm = .identity
    state.tlm = .identity
}

private func opSetFont(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var size: CGPDFReal = 0
    var namePtr: UnsafePointer<Int8>?
    guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &namePtr), let namePtr else { return }
    state.fontSize = size
    let resourceName = String(cString: namePtr)
    state.fontKey = state.fontResourceKey(for: resourceName)
    let contentStream = CGPDFScannerGetContentStream(scanner)
    let object = resourceName.withCString {
        CGPDFContentStreamGetResource(contentStream, "Font", $0)
    }
    if let object, CGPDFObjectGetType(object) == .dictionary {
        var dictionary: CGPDFDictionaryRef?
        if CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary {
            state.fontDictionaries[state.fontKey] = dictionary
        }
    }
}

private func opSetTextMatrix(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var f: CGPDFReal = 0, e: CGPDFReal = 0, d: CGPDFReal = 0, c: CGPDFReal = 0, b: CGPDFReal = 0, a: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &f), CGPDFScannerPopNumber(scanner, &e),
          CGPDFScannerPopNumber(scanner, &d), CGPDFScannerPopNumber(scanner, &c),
          CGPDFScannerPopNumber(scanner, &b), CGPDFScannerPopNumber(scanner, &a) else { return }
    let m = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
    state.tm = m
    state.tlm = m
}

private func opMoveTextPosition(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var ty: CGPDFReal = 0, tx: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &ty), CGPDFScannerPopNumber(scanner, &tx) else { return }
    let translate = CGAffineTransform(translationX: tx, y: ty)
    state.tlm = translate.concatenating(state.tlm)
    state.tm = state.tlm
}

private func opMoveTextPositionSetLeading(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var ty: CGPDFReal = 0, tx: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &ty), CGPDFScannerPopNumber(scanner, &tx) else { return }
    state.leading = -ty
    let translate = CGAffineTransform(translationX: tx, y: ty)
    state.tlm = translate.concatenating(state.tlm)
    state.tm = state.tlm
}

private func opNextLine(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    advanceToNextLine(state)
}

private func advanceToNextLine(_ state: GlyphScanState) {
    let translate = CGAffineTransform(translationX: 0, y: -state.leading)
    state.tlm = translate.concatenating(state.tlm)
    state.tm = state.tlm
}

private func opSetLeading(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var value: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &value) else { return }
    state.leading = value
}

private func opSetCharSpacing(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var value: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &value) else { return }
    state.charSpacing = value
}

private func opSetWordSpacing(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var value: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &value) else { return }
    state.wordSpacing = value
}

private func opSetHorizontalScale(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var value: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &value) else { return }
    state.horizontalScale = value / 100
}

private func opSetTextRise(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var value: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &value) else { return }
    state.textRise = value
}

private func opSetTextRenderingMode(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var mode: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &mode), mode.isFinite else { return }
    state.textRenderingMode = min(max(Int(mode), 0), 7)
}

private func opShowText(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var stringRef: CGPDFStringRef?
    guard CGPDFScannerPopString(scanner, &stringRef), let stringRef else { return }
    showString(stringRef, state: state)
}

private func opNextLineShowText(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var stringRef: CGPDFStringRef?
    guard CGPDFScannerPopString(scanner, &stringRef), let stringRef else { return }
    advanceToNextLine(state)
    showString(stringRef, state: state)
}

private func opNextLineShowTextWithSpacing(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var stringRef: CGPDFStringRef?
    var ac: CGPDFReal = 0, aw: CGPDFReal = 0
    guard CGPDFScannerPopString(scanner, &stringRef), let stringRef,
          CGPDFScannerPopNumber(scanner, &ac), CGPDFScannerPopNumber(scanner, &aw) else { return }
    state.wordSpacing = aw
    state.charSpacing = ac
    advanceToNextLine(state)
    showString(stringRef, state: state)
}

private func opShowTextArray(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var array: CGPDFArrayRef?
    guard CGPDFScannerPopArray(scanner, &array), let array else { return }
    let count = CGPDFArrayGetCount(array)
    for index in 0..<count {
        var stringRef: CGPDFStringRef?
        if CGPDFArrayGetString(array, index, &stringRef), let stringRef {
            showString(stringRef, state: state)
            continue
        }
        var number: CGPDFReal = 0
        if CGPDFArrayGetNumber(array, index, &number) {
            let adjust = -number / 1000 * state.fontSize * state.horizontalScale
            state.tm = CGAffineTransform(translationX: adjust, y: 0).concatenating(state.tm)
        }
    }
}

/// 1 つの PDF 文字列 (Tj/TJ/'/") をグリフへ分解し、`state.glyphs` に追記する。
private func showString(_ stringRef: CGPDFStringRef, state: GlyphScanState) {
    guard let bytePtr = CGPDFStringGetBytePtr(stringRef) else { return }
    let length = CGPDFStringGetLength(stringRef)
    let info = state.fontInfo(for: state.fontKey)
    let bytesPerCode = max(info.bytesPerCode, 1)

    var offset = 0
    while offset + bytesPerCode <= length {
        var code = 0
        for k in 0..<bytesPerCode {
            code = (code << 8) | Int(bytePtr[offset + k])
        }
        offset += bytesPerCode

        let paintOrder = state.nextPaintOrder
        state.nextPaintOrder += 1

        let w0 = info.width(for: code)
        let unicode = info.toUnicode[code] ?? ""

        let scaleMatrix = CGAffineTransform(
            a: state.fontSize * state.horizontalScale, b: 0,
            c: 0, d: state.fontSize,
            tx: 0, ty: state.textRise
        )
        let trm = scaleMatrix.concatenating(state.tm).concatenating(state.ctm)

        let corners = [
            CGPoint(x: 0, y: info.descent),
            CGPoint(x: w0, y: info.descent),
            CGPoint(x: w0, y: info.ascent),
            CGPoint(x: 0, y: info.ascent)
        ].map { $0.applying(trm) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let box = CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)

        let originBefore = CGPoint.zero.applying(trm)
        let effectiveSize = hypot(trm.c, trm.d)

        let isSingleByteSpace = bytesPerCode == 1 && code == 32
        let tx = (w0 * state.fontSize + state.charSpacing + (isSingleByteSpace ? state.wordSpacing : 0)) * state.horizontalScale
        state.tm = CGAffineTransform(translationX: tx, y: 0).concatenating(state.tm)

        let advanceMatrix = scaleMatrix.concatenating(state.tm).concatenating(state.ctm)
        let originAfter = CGPoint.zero.applying(advanceMatrix)
        let advance = hypot(originAfter.x - originBefore.x, originAfter.y - originBefore.y)

        // 空の /ActualText を持つ marked content スパン内の描画は、アクセシビリティ用の
        // 重複描画（例: 同じ文字列をわずかにずらして再描画する wkhtmltopdf の癖）を
        // 拾わないようスキップする。ペン位置(state.tm)は通常どおり進めるため、
        // 後続のグリフ位置計算には影響しない。タグ付き PDF の本文自体（BDC の
        // プロパティに空の ActualText が無い、通常のケース）は素通りで記録する。
        if state.skippingMarkedContentCount == 0 {
            state.glyphs.append(ScannedGlyph(
                text: unicode,
                advanceBox: box,
                baseline: originBefore.y,
                fontKey: state.fontKey,
                fontSize: effectiveSize,
                advance: advance,
                fillColor: state.fillColorStack.last ?? .black,
                hasExplicitToUnicodeMapping: info.explicitToUnicodeCodes.contains(code),
                textRenderingMode: state.textRenderingMode,
                paintOrder: paintOrder
            ))
        }
    }
}

private func opSetGray(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var gray: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &gray) else { return }
    state.fillColorStack[state.fillColorStack.count - 1] = NSColor(white: gray, alpha: 1)
    state.fillColorSpaceComponentsStack[state.fillColorSpaceComponentsStack.count - 1] = 1
}

private func opSetRGB(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var b: CGPDFReal = 0, g: CGPDFReal = 0, r: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &b), CGPDFScannerPopNumber(scanner, &g),
          CGPDFScannerPopNumber(scanner, &r) else { return }
    state.fillColorStack[state.fillColorStack.count - 1] = NSColor(red: r, green: g, blue: b, alpha: 1)
    state.fillColorSpaceComponentsStack[state.fillColorSpaceComponentsStack.count - 1] = 3
}

private func opSetCMYK(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var k: CGPDFReal = 0, y: CGPDFReal = 0, m: CGPDFReal = 0, c: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &k), CGPDFScannerPopNumber(scanner, &y),
          CGPDFScannerPopNumber(scanner, &m), CGPDFScannerPopNumber(scanner, &c) else { return }
    state.fillColorStack[state.fillColorStack.count - 1] = NSColor(deviceCyan: c, magenta: m, yellow: y, black: k, alpha: 1)
    state.fillColorSpaceComponentsStack[state.fillColorSpaceComponentsStack.count - 1] = 4
}

/// `cs`: 塗り色空間の選択。以後の `sc`/`scn` が読むべき成分数を決めておく。
private func opSetFillColorSpace(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var namePtr: UnsafePointer<Int8>?
    guard CGPDFScannerPopName(scanner, &namePtr), let namePtr else { return }
    let name = String(cString: namePtr)
    state.fillColorSpaceComponentsStack[state.fillColorSpaceComponentsStack.count - 1] =
        state.colorSpaceLookup(name)
}

/// `sc`/`scn`: 現在の塗り色空間の成分数だけ数値を pop して色を決める。
/// `scn` はパターン名が続くことがあるため、まず名前としての pop を試み、
/// 成功した場合（パターン塗り）は色を変えずに抜ける。
private func opSetFillColorN(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(from: info) else { return }
    var patternName: UnsafePointer<Int8>?
    if CGPDFScannerPopName(scanner, &patternName) {
        // パターン塗り。下地の色成分があっても正確な見た目までは再現しないため、
        // 直前の塗り色をそのまま使う（安全側のフォールバック）。
        return
    }
    let n = state.fillColorSpaceComponentsStack.last ?? 1
    guard n > 0, n <= 4 else { return }
    var reversed: [CGFloat] = []
    for _ in 0..<n {
        var v: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &v) else { return }
        reversed.append(v)
    }
    let values = reversed.reversed()
    let color: NSColor
    switch values.count {
    case 1:
        color = NSColor(white: values.first!, alpha: 1)
    case 3:
        let v = Array(values)
        color = NSColor(red: v[0], green: v[1], blue: v[2], alpha: 1)
    case 4:
        let v = Array(values)
        color = NSColor(deviceCyan: v[0], magenta: v[1], yellow: v[2], black: v[3], alpha: 1)
    default:
        // 未対応の色空間（Indexed/Separation/DeviceN 等）は成分の意味を
        // 正確に解釈できないため、直前の色を維持する。
        return
    }
    state.fillColorStack[state.fillColorStack.count - 1] = color
}
