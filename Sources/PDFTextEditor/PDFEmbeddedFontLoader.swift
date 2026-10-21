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
        replacementText: String,
        supportingText: String? = nil
    ) -> Resolution {
        let info = PDFFontInfoLoader.load(from: fontDict)
        let requiredText = supportingText ?? replacementText

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
            if let installed = installedFont(named: cleaned, size: size),
               coversAllCharacters(of: requiredText, font: installed) {
                return Resolution(font: installed, isExact: false, exactGlyphs: nil)
            }
        }

        let fallbackNames = fallbackFontNames(
            for: readBaseFontName(fontDict),
            replacementText: requiredText
        )
        for fallbackName in fallbackNames {
            guard let fallback = installedFont(named: fallbackName, size: size),
                  coversAllCharacters(of: requiredText, font: fallback) else { continue }
            return Resolution(font: fallback, isExact: false, exactGlyphs: nil)
        }

        let fallbackName = fallbackNames.first ?? "Helvetica Neue"
        let fallback = installedFont(named: fallbackName, size: size)
            ?? CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        return Resolution(font: fallback, isExact: false, exactGlyphs: nil)
    }

    /// 未導入フォントを代替するときは置換後の文字種だけで判断せず、元PDFの書体名を優先する。
    /// たとえば `MS-Gothic` の数字も Helvetica ではなく、近い日本語ゴシックで描画する。
    static func fallbackFontNames(for baseFontName: String?, replacementText: String) -> [String] {
        let normalizedName = baseFontName
            .map(strippingSubsetPrefix)
            .map(normalizedFontName) ?? ""

        if ["mincho", "ming", "ryumin", "kozmin", "heiseimin"].contains(where: normalizedName.contains) {
            return ["Hiragino Mincho ProN", "Hiragino Sans", "Helvetica Neue"]
        }
        if ["gothic", "kaku", "kozgo", "heiseigo", "ryogothic"].contains(where: normalizedName.contains) {
            return ["Noto Sans JP", "Hiragino Sans", "Helvetica Neue"]
        }
        if normalizedName.contains("courier") || normalizedName.contains("mono") {
            return ["Menlo", "Helvetica Neue", "Hiragino Sans"]
        }
        if normalizedName.contains("times") || normalizedName.contains("serif") {
            return ["Times New Roman", "Hiragino Mincho ProN", "Hiragino Sans"]
        }
        if normalizedName.contains("arial") || normalizedName.contains("helvetica") || normalizedName.contains("sans") {
            return ["Helvetica Neue", "Hiragino Sans"]
        }

        return containsJapanese(replacementText)
            ? ["Noto Sans JP", "Hiragino Sans", "Hiragino Mincho ProN", "Helvetica Neue"]
            : ["Helvetica Neue", "Hiragino Sans"]
    }

    /// アプリに同梱した OFL フォントをこのプロセス内だけで登録する。
    /// ユーザーのフォント設定やシステム全体のフォント一覧は変更しない。
    static func registerBundledFonts() {
        _ = bundledFontsRegistered
    }

    /// 利用者が選んだフォントファイルをアプリ終了までの間だけ登録する。
    /// Windowsフォントなど、アプリへの再配布が許されない書体は同梱せず、利用者が
    /// 別途利用できるフォントファイルを持っている場合に限って読み込めるようにする。
    static func registerFontFile(at url: URL) throws -> [String] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        guard !descriptors.isEmpty else { throw FontFileRegistrationError.invalidFontFile }

        let families = Array(Set(descriptors.compactMap { descriptor in
            CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
        })).sorted()
        guard !families.isEmpty else { throw FontFileRegistrationError.invalidFontFile }

        var unmanagedError: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError) else {
            // CoreText は同じフォントを二度登録すると失敗を返すことがある。
            // すでにプロセスから利用できる場合は、重複をユーザー向けエラーにしない。
            if families.allSatisfy(fontFamilyIsAvailable) {
                return families
            }
            let message: String
            if let unmanagedError {
                message = CFErrorCopyDescription(unmanagedError.takeRetainedValue()) as String
            } else {
                message = "フォントを登録できませんでした。"
            }
            throw FontFileRegistrationError.registrationFailed(message)
        }
        return families
    }

    private static func fontFamilyIsAvailable(_ family: String) -> Bool {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        let requestedName = normalizedFontName(family)
        return [
            CTFontCopyFamilyName(font) as String,
            CTFontCopyPostScriptName(font) as String
        ].contains(where: { normalizedFontName($0) == requestedName })
    }

    private enum FontFileRegistrationError: LocalizedError {
        case invalidFontFile
        case registrationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidFontFile:
                return "対応するフォントファイルを選んでください。"
            case let .registrationFailed(message):
                return message
            }
        }
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

    /// `CTFontCreateWithName` は未知の名前でも別フォントを返すため、要求した書体と
    /// 実際に返った書体の family / PostScript 名が一致する場合だけ採用する。
    private static func installedFont(named name: String, size: CGFloat) -> CTFont? {
        _ = bundledFontsRegistered
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let requestedName = normalizedFontName(name)
        let actualNames = [
            CTFontCopyFamilyName(font) as String,
            CTFontCopyPostScriptName(font) as String
        ]
        guard actualNames.contains(where: { normalizedFontName($0) == requestedName }) else { return nil }
        return font
    }

    private static func normalizedFontName(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static let bundledFontsRegistered: Void = {
        guard let fontURL = Bundle.module.url(
            forResource: "NotoSansJP-Regular",
            withExtension: "otf",
            subdirectory: "Fonts"
        ) else { return }
        _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }()

    private static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3040...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value) || (0xFF66...0xFF9F).contains(value)
        }
    }

    private static func coversAllCharacters(of text: String, font: CTFont) -> Bool {
        guard !text.isEmpty else { return true }
        let units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
            && glyphs.allSatisfy { $0 != 0 }
    }
}
