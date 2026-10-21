import CoreGraphics
import CoreText
import Foundation

/// フォントリソース辞書 (`/Font` 配下の 1 エントリ) から `PDFFontInfo` を組み立てる。
enum PDFFontInfoLoader {
    private struct StandardEncodingInfo {
        let baseEncodingName: String
        let overriddenCodes: Set<Int>
    }

    static func load(from fontDict: CGPDFDictionaryRef) -> PDFFontInfo {
        let subtype = name(in: fontDict, key: "Subtype") ?? ""

        if subtype == "Type0" {
            return loadType0(fontDict)
        }
        return loadSimpleFont(fontDict)
    }

    // MARK: Type0 (CID) フォント

    private static func loadType0(_ fontDict: CGPDFDictionaryRef) -> PDFFontInfo {
        var descendantArray: CGPDFArrayRef?
        var descendantDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetArray(fontDict, "DescendantFonts", &descendantArray), let descendantArray,
              CGPDFArrayGetDictionary(descendantArray, 0, &descendantDict), let descendantDict else {
            return .fallback
        }

        var defaultWidth: CGPDFReal = 1000
        _ = CGPDFDictionaryGetNumber(descendantDict, "DW", &defaultWidth)

        var widths: [Int: CGFloat] = [:]
        var widthsArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(descendantDict, "W", &widthsArray), let widthsArray {
            widths = parseCIDWidths(widthsArray)
        }

        var ascent: CGFloat = 0.88
        var descent: CGFloat = -0.12
        var hasEmbedded = false
        var descriptorDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(descendantDict, "FontDescriptor", &descriptorDict), let descriptorDict {
            var a: CGPDFReal = 0, d: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(descriptorDict, "Ascent", &a) { ascent = a / 1000 }
            if CGPDFDictionaryGetNumber(descriptorDict, "Descent", &d) { descent = d / 1000 }
            hasEmbedded = fontFileStream(in: descriptorDict) != nil
        }

        let toUnicode = loadToUnicode(fontDict)
        let unicodeToCode = invertToUnicode(toUnicode)
        // ToUnicode のキーを CID として扱えるのは Identity-H エンコーディングだけ。
        // それ以外の CMap では文字コードと CID/GID が一致する保証がない。
        let isIdentity = name(in: fontDict, key: "Encoding") == "Identity-H"
            && name(in: descendantDict, key: "Subtype") == "CIDFontType2"
            && isIdentityCIDToGIDMap(descendantDict)

        return PDFFontInfo(
            bytesPerCode: 2,
            widthTable: widths,
            defaultWidth: CGFloat(defaultWidth) / 1000,
            toUnicode: toUnicode,
            explicitToUnicodeCodes: Set(toUnicode.keys),
            ascent: ascent,
            descent: descent,
            hasEmbeddedProgram: hasEmbedded,
            unicodeToCode: unicodeToCode,
            isIdentityCIDToGID: isIdentity
        )
    }

    /// `/W` 配列は `c [w1 w2 ...]` と `cFirst cLast w` の 2 形式が混在し得る。
    private static func parseCIDWidths(_ array: CGPDFArrayRef) -> [Int: CGFloat] {
        var widths: [Int: CGFloat] = [:]
        let count = CGPDFArrayGetCount(array)
        var index = 0
        while index < count {
            var first: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &first) else { index += 1; continue }
            index += 1
            guard index < count else { break }

            var subArray: CGPDFArrayRef?
            if CGPDFArrayGetArray(array, index, &subArray), let subArray {
                let subCount = CGPDFArrayGetCount(subArray)
                for offset in 0..<subCount {
                    var w: CGPDFReal = 0
                    if CGPDFArrayGetNumber(subArray, offset, &w) {
                        widths[Int(first) + offset] = CGFloat(w) / 1000
                    }
                }
                index += 1
            } else {
                var last: CGPDFReal = 0
                guard CGPDFArrayGetNumber(array, index, &last) else { index += 1; continue }
                index += 1
                guard index < count else { break }
                var w: CGPDFReal = 0
                guard CGPDFArrayGetNumber(array, index, &w) else { index += 1; continue }
                index += 1
                let lo = Int(first)
                let hi = Int(last)
                if hi >= lo {
                    for code in lo...hi { widths[code] = CGFloat(w) / 1000 }
                }
            }
        }
        return widths
    }

    // MARK: 単純フォント (Type1 / TrueType)

    private static func loadSimpleFont(_ fontDict: CGPDFDictionaryRef) -> PDFFontInfo {
        var firstChar: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(fontDict, "FirstChar", &firstChar)

        var widths: [Int: CGFloat] = [:]
        var widthsArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(fontDict, "Widths", &widthsArray), let widthsArray {
            let count = CGPDFArrayGetCount(widthsArray)
            for offset in 0..<count {
                var w: CGPDFReal = 0
                if CGPDFArrayGetNumber(widthsArray, offset, &w) {
                    widths[Int(firstChar) + offset] = CGFloat(w) / 1000
                }
            }
        }
        // PDF標準14フォントのうちCoreTextで一致確認できる12書体は、/Widths を省略できます。
        // 一律0.5emで扱うと、PDFKitの実描画と選択・墨消し範囲が行に沿ってずれていきます。
        for (code, width) in standardCoreTextWidths(in: fontDict) where widths[code] == nil {
            widths[code] = width
        }

        var ascent: CGFloat = 0.8
        var descent: CGFloat = -0.2
        var hasEmbedded = false
        var defaultWidth: CGFloat = 0.5
        var descriptorDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(fontDict, "FontDescriptor", &descriptorDict), let descriptorDict {
            var a: CGPDFReal = 0, d: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(descriptorDict, "Ascent", &a) { ascent = a / 1000 }
            if CGPDFDictionaryGetNumber(descriptorDict, "Descent", &d) { descent = d / 1000 }
            var missingWidth: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(descriptorDict, "MissingWidth", &missingWidth) {
                defaultWidth = CGFloat(missingWidth) / 1000
            }
            hasEmbedded = fontFileStream(in: descriptorDict) != nil
        }

        var toUnicode = loadToUnicode(fontDict)
        let explicitToUnicodeCodes = Set(toUnicode.keys)
        if toUnicode.isEmpty {
            // `/ToUnicode` を持たない単純フォントも珍しくない
            // (例: 標準14フォントを MacRomanEncoding/WinAnsiEncoding で使う場合)。
            // 印字可能 ASCII 範囲はどの標準エンコーディングでもコードとほぼ一致するため、
            // 最低限のフォールバックとしてコード自体を文字として扱う。
            for code in 0x20...0x7E {
                toUnicode[code] = String(UnicodeScalar(code)!)
            }
        }

        return PDFFontInfo(
            bytesPerCode: 1,
            widthTable: widths,
            defaultWidth: defaultWidth,
            toUnicode: toUnicode,
            explicitToUnicodeCodes: explicitToUnicodeCodes,
            ascent: ascent,
            descent: descent,
            hasEmbeddedProgram: hasEmbedded,
            // 単純フォントは CID/GID の恒等対応という前提が成り立たないため、
            // GID 直接指定による厳密描画の対象にはしない（cmap 経由の通常経路のみ使う）。
            unicodeToCode: [:],
            isIdentityCIDToGID: false
        )
    }

    // MARK: 共通ヘルパー

    static func fontFileStream(in descriptor: CGPDFDictionaryRef) -> CGPDFStreamRef? {
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(descriptor, "FontFile2", &stream), let stream { return stream }
        if CGPDFDictionaryGetStream(descriptor, "FontFile3", &stream), let stream { return stream }
        if CGPDFDictionaryGetStream(descriptor, "FontFile", &stream), let stream { return stream }
        return nil
    }

    /// 既知の標準エンコーディングを使う標準14 Type1フォントについて、印字可能ASCIIの幅を返す。
    /// CoreTextの標準フォントはPDFのAFM幅に対応する。/Differencesで変更されたコードは除外する。
    private static func standardCoreTextWidths(in fontDict: CGPDFDictionaryRef) -> [Int: CGFloat] {
        guard name(in: fontDict, key: "Subtype") == "Type1",
              !hasExplicitStandardFontMetrics(in: fontDict),
              let baseFontName = name(in: fontDict, key: "BaseFont"),
              let postScriptName = standardCoreTextPostScriptName(baseFontName),
              let encoding = standardEncodingInfo(in: fontDict) else { return [:] }

        let font = CTFontCreateWithName(postScriptName as CFString, 1000, nil)
        guard CTFontCopyPostScriptName(font) as String == postScriptName else { return [:] }

        var widths: [Int: CGFloat] = [:]
        for code in 32...126 where !encoding.overriddenCodes.contains(code) {
            let unicodeCode = encoding.baseEncodingName == "StandardEncoding"
                ? standardEncodingUnicodeCode(for: code)
                : code
            var character = UniChar(unicodeCode)
            var glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { continue }
            var advance = CGSize.zero
            guard CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1) > 0,
                  advance.width.isFinite, advance.width > 0 else { continue }
            widths[code] = advance.width / 1000
        }
        return widths
    }

    /// Base-14の明示メトリクス一式がある場合は、PDFの幅指定とMissingWidthを使い、CoreTextで穴埋めしない。
    private static func hasExplicitStandardFontMetrics(in fontDict: CGPDFDictionaryRef) -> Bool {
        ["FirstChar", "LastChar", "Widths", "FontDescriptor"].contains { key in
            var value: CGPDFObjectRef?
            return CGPDFDictionaryGetObject(fontDict, key, &value)
        }
    }

    private static func standardCoreTextPostScriptName(_ baseFontName: String) -> String? {
        let unprefixedName: String
        let components = baseFontName.split(separator: "+", maxSplits: 1)
        if components.count == 2,
           components[0].count == 6,
           components[0].allSatisfy({ $0 >= "A" && $0 <= "Z" }) {
            unprefixedName = String(components[1])
        } else {
            unprefixedName = baseFontName
        }

        let standard14Names: Set<String> = [
            "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
            "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
            "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"
        ]
        return standard14Names.contains(unprefixedName) ? unprefixedName : nil
    }

    /// /Encoding省略時のType1既定値はStandardEncoding。辞書形式は基底エンコーディングが既知の場合だけ扱う。
    private static func standardEncodingInfo(in fontDict: CGPDFDictionaryRef) -> StandardEncodingInfo? {
        var encodingNamePtr: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(fontDict, "Encoding", &encodingNamePtr), let encodingNamePtr {
            let name = String(cString: encodingNamePtr)
            return supportedStandardEncoding(name)
                ? StandardEncodingInfo(baseEncodingName: name, overriddenCodes: [])
                : nil
        }

        var encodingDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(fontDict, "Encoding", &encodingDict), let encodingDict else {
            return StandardEncodingInfo(baseEncodingName: "StandardEncoding", overriddenCodes: [])
        }

        var baseEncodingName = "StandardEncoding"
        var baseEncodingPtr: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(encodingDict, "BaseEncoding", &baseEncodingPtr), let baseEncodingPtr {
            baseEncodingName = String(cString: baseEncodingPtr)
            guard supportedStandardEncoding(baseEncodingName) else { return nil }
        }

        var differences: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(encodingDict, "Differences", &differences), let differences else {
            return StandardEncodingInfo(baseEncodingName: baseEncodingName, overriddenCodes: [])
        }
        var code: Int?
        var overriddenCodes = Set<Int>()
        for index in 0..<CGPDFArrayGetCount(differences) {
            var integer: CGPDFInteger = 0
            if CGPDFArrayGetInteger(differences, index, &integer) {
                code = Int(integer)
                continue
            }
            var glyphNamePtr: UnsafePointer<Int8>?
            if CGPDFArrayGetName(differences, index, &glyphNamePtr), glyphNamePtr != nil, let current = code {
                if (32...126).contains(current) { overriddenCodes.insert(current) }
                code = current < 255 ? current + 1 : nil
            }
        }
        return StandardEncodingInfo(baseEncodingName: baseEncodingName, overriddenCodes: overriddenCodes)
    }

    private static func standardEncodingUnicodeCode(for code: Int) -> Int {
        switch code {
        case 39: return 0x2019 // quoteright
        case 96: return 0x2018 // quoteleft
        default: return code
        }
    }

    private static func supportedStandardEncoding(_ name: String) -> Bool {
        ["StandardEncoding", "WinAnsiEncoding", "MacRomanEncoding"].contains(name)
    }

    private static func name(in dict: CGPDFDictionaryRef, key: String) -> String? {
        var namePtr: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(dict, key, &namePtr), let namePtr else { return nil }
        return String(cString: namePtr)
    }

    /// `toUnicode` (code → Unicode文字列) を反転し、1 文字にきちんと対応する
    /// エントリだけを Unicode文字 → code として集める（合字/複数文字は除外）。
    private static func invertToUnicode(_ toUnicode: [Int: String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (code, string) in toUnicode where string.count == 1 {
            // 同じ文字に複数のコードが対応する場合は最初に見つかったものを使う。
            if result[string] == nil {
                result[string] = code
            }
        }
        return result
    }

    /// `/CIDToGIDMap` が `/Identity`（省略時の既定も Identity）かどうかを判定する。
    /// ストリーム形式（カスタムマップ）の場合は false を返し、GID 直接指定は行わない。
    private static func isIdentityCIDToGIDMap(_ descendantDict: CGPDFDictionaryRef) -> Bool {
        var namePtr: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(descendantDict, "CIDToGIDMap", &namePtr), let namePtr {
            return String(cString: namePtr) == "Identity"
        }
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(descendantDict, "CIDToGIDMap", &stream), stream != nil {
            return false
        }
        // キー省略時の既定値は Identity。
        return true
    }

    private static func loadToUnicode(_ fontDict: CGPDFDictionaryRef) -> [Int: String] {
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(fontDict, "ToUnicode", &stream), let stream else { return [:] }
        var format: CGPDFDataFormat = .raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return [:] }
        guard let text = String(data: data as Data, encoding: .isoLatin1) else { return [:] }
        return PDFToUnicodeCMapParser.parse(text)
    }
}

/// ToUnicode CMap ストリームの `beginbfchar`/`beginbfrange` を読み取る簡易パーサ。
/// bfrange は単一 dst 形式・配列 dst 形式の両方に対応する。
enum PDFToUnicodeCMapParser {
    private enum Token {
        case hex(String)
        case arrayStart
        case arrayEnd
    }

    static func parse(_ text: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for block in blocks(in: text, begin: "beginbfchar", end: "endbfchar") {
            parseBfChar(block, into: &map)
        }
        for block in blocks(in: text, begin: "beginbfrange", end: "endbfrange") {
            parseBfRange(block, into: &map)
        }
        return map
    }

    private static func blocks(in text: String, begin: String, end: String) -> [String] {
        var result: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while let beginRange = text.range(of: begin, range: searchRange),
              let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) {
            result.append(String(text[beginRange.upperBound..<endRange.lowerBound]))
            searchRange = endRange.upperBound..<text.endIndex
        }
        return result
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c == "<" {
                var j = i + 1
                var hex = ""
                while j < characters.count, characters[j] != ">" {
                    hex.append(characters[j])
                    j += 1
                }
                tokens.append(.hex(hex))
                i = j + 1
            } else if c == "[" {
                tokens.append(.arrayStart)
                i += 1
            } else if c == "]" {
                tokens.append(.arrayEnd)
                i += 1
            } else {
                i += 1
            }
        }
        return tokens
    }

    private static func hexToString(_ hex: String) -> String {
        guard !hex.isEmpty else { return "" }
        var units: [UInt16] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            if let value = UInt16(hex[idx..<next], radix: 16) { units.append(value) }
            idx = next
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func parseBfChar(_ text: String, into map: inout [Int: String]) {
        let tokens = tokenize(text)
        var i = 0
        while i + 1 < tokens.count {
            guard case .hex(let srcHex) = tokens[i], case .hex(let dstHex) = tokens[i + 1] else {
                i += 1
                continue
            }
            if let code = Int(srcHex, radix: 16) {
                map[code] = hexToString(dstHex)
            }
            i += 2
        }
    }

    private static func parseBfRange(_ text: String, into map: inout [Int: String]) {
        let tokens = tokenize(text)
        var i = 0
        while i < tokens.count {
            guard case .hex(let loHex) = tokens[i], i + 1 < tokens.count,
                  case .hex(let hiHex) = tokens[i + 1],
                  let lo = Int(loHex, radix: 16), let hi = Int(hiHex, radix: 16) else {
                i += 1
                continue
            }
            i += 2
            guard i < tokens.count, lo <= hi else { continue }

            switch tokens[i] {
            case .hex(let dstHex):
                let unitCount = max(dstHex.count / 4, 1)
                var units: [Int] = []
                var idx = dstHex.startIndex
                for _ in 0..<unitCount {
                    guard idx < dstHex.endIndex else { break }
                    let next = dstHex.index(idx, offsetBy: 4, limitedBy: dstHex.endIndex) ?? dstHex.endIndex
                    units.append(Int(dstHex[idx..<next], radix: 16) ?? 0)
                    idx = next
                }
                if !units.isEmpty {
                    for code in lo...hi {
                        var adjusted = units
                        adjusted[adjusted.count - 1] += (code - lo)
                        let scalars = adjusted.map { UInt16(truncatingIfNeeded: $0) }
                        map[code] = String(utf16CodeUnits: scalars, count: scalars.count)
                    }
                }
                i += 1
            case .arrayStart:
                i += 1
                var offset = 0
                while i < tokens.count, case .hex(let dstHex) = tokens[i] {
                    map[lo + offset] = hexToString(dstHex)
                    offset += 1
                    i += 1
                }
                if i < tokens.count, case .arrayEnd = tokens[i] { i += 1 }
            case .arrayEnd:
                i += 1
            }
        }
    }
}
