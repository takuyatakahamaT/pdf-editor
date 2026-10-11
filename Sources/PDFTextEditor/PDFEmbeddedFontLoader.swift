import CoreGraphics
import CoreText
import Foundation

/// `/FontDescriptor` の `FontFile`/`FontFile2`/`FontFile3` から元 PDF と同じフォントを復元する。
/// 復元できない、または置換文字列のグリフを引けない場合は既定のフォールバック順で代替する。
enum PDFEmbeddedFontLoader {
    struct Resolution {
        let font: CTFont
        /// 元の埋め込みフォントで置換文字列の全グリフを表現できた場合のみ true。
        let isExact: Bool
        /// 元 PDF の CID をそのまま GID として直接指定できる場合のみ非 nil。
        /// `replacement` の各文字に対応する (GID, 送り幅[em]) の並び。
        /// これが取れるときは `font` の `cmap` を経由せず直接そのグリフを描く
        /// (このサンプル PDF のように埋め込みサブセットに `cmap` が無く
        /// `CTFontGetGlyphsForCharacters` が原理的に使えないケースを救う)。
        let exactGlyphs: [(glyph: CGGlyph, emWidth: CGFloat)]?
    }

    static func resolveFont(
        fontDict: CGPDFDictionaryRef,
        size: CGFloat,
        replacementText: String
    ) -> Resolution {
        let info = PDFFontInfoLoader.load(from: fontDict)

        if let embedded = loadEmbeddedFont(fontDict: fontDict, size: size) {
            if info.isIdentityCIDToGID,
               let exact = exactGlyphs(for: replacementText, using: info) {
                return Resolution(font: embedded, isExact: true, exactGlyphs: exact)
            }
            if coversAllCharacters(of: replacementText, font: embedded) {
                return Resolution(font: embedded, isExact: true, exactGlyphs: nil)
            }
        }

        if let baseFontName = readBaseFontName(fontDict) {
            let cleaned = strippingSubsetPrefix(baseFontName)
            let installed = CTFontCreateWithName(cleaned as CFString, size, nil)
            if coversAllCharacters(of: replacementText, font: installed) {
                return Resolution(font: installed, isExact: false, exactGlyphs: nil)
            }
        }

        let containsJapanese = replacementText.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3040...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value) || (0xFF66...0xFF9F).contains(value)
        }
        let fallbackName = containsJapanese ? "Hiragino Sans" : "Helvetica Neue"
        let fallback = CTFontCreateWithName(fallbackName as CFString, size, nil)
        return Resolution(font: fallback, isExact: false, exactGlyphs: nil)
    }

    /// 置換文字列の全文字が、元 PDF の ToUnicode から反転した Unicode→CID マップに
    /// 載っているかを確認し、載っていれば (GID, 送り幅) の並びを返す。
    /// 1 文字でも載っていなければ nil（通常の cmap 経由の経路へフォールバックする）。
    private static func exactGlyphs(
        for text: String,
        using info: PDFFontInfo
    ) -> [(glyph: CGGlyph, emWidth: CGFloat)]? {
        guard !text.isEmpty else { return [] }
        var result: [(CGGlyph, CGFloat)] = []
        for character in text {
            guard let code = info.unicodeToCode[String(character)] else { return nil }
            result.append((CGGlyph(code), info.width(for: code)))
        }
        return result
    }

    /// 元の FontDescriptor に埋め込みフォントプログラムが存在するかどうかだけを判定する
    /// （置換文字列に対するグリフ網羅チェックはしない、軽量な事前チェック用）。
    static func fontHasEmbeddedProgram(fontDict: CGPDFDictionaryRef) -> Bool {
        guard let descriptor = descriptorDictionary(from: fontDict) else { return false }
        return PDFFontInfoLoader.fontFileStream(in: descriptor) != nil
    }

    static func loadEmbeddedFont(fontDict: CGPDFDictionaryRef, size: CGFloat) -> CTFont? {
        guard let descriptor = descriptorDictionary(from: fontDict) else { return nil }
        guard let stream = PDFFontInfoLoader.fontFileStream(in: descriptor) else { return nil }
        var format: CGPDFDataFormat = .raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
        guard let provider = CGDataProvider(data: data) else { return nil }
        guard let cgFont = CGFont(provider) else { return nil }
        return CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
    }

    // MARK: - ヘルパー

    private static func descriptorDictionary(from fontDict: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var subtypePtr: UnsafePointer<Int8>?
        _ = CGPDFDictionaryGetName(fontDict, "Subtype", &subtypePtr)
        let subtype = subtypePtr.map { String(cString: $0) } ?? ""

        var descriptor: CGPDFDictionaryRef?
        if subtype == "Type0" {
            var descendantArray: CGPDFArrayRef?
            var descendantDict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(fontDict, "DescendantFonts", &descendantArray), let descendantArray,
               CGPDFArrayGetDictionary(descendantArray, 0, &descendantDict), let descendantDict {
                _ = CGPDFDictionaryGetDictionary(descendantDict, "FontDescriptor", &descriptor)
            }
        } else {
            _ = CGPDFDictionaryGetDictionary(fontDict, "FontDescriptor", &descriptor)
        }
        return descriptor
    }

    private static func readBaseFontName(_ fontDict: CGPDFDictionaryRef) -> String? {
        var namePtr: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(fontDict, "BaseFont", &namePtr), let namePtr else { return nil }
        return String(cString: namePtr)
    }

    /// サブセットフォントの接頭辞 (`ABCDEF+FontName`) を取り除く。
    private static func strippingSubsetPrefix(_ name: String) -> String {
        guard name.count > 7 else { return name }
        let plusIndex = name.index(name.startIndex, offsetBy: 6)
        guard name[plusIndex] == "+" else { return name }
        let prefix = name[name.startIndex..<plusIndex]
        guard prefix.allSatisfy({ $0.isASCII && $0.isUppercase && $0.isLetter }) else { return name }
        return String(name[name.index(after: plusIndex)...])
    }

    private static func coversAllCharacters(of text: String, font: CTFont) -> Bool {
        guard !text.isEmpty else { return true }
        let units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
    }
}
