import CoreGraphics
import CoreText
import Foundation

/// `/FontDescriptor` の `FontFile`/`FontFile2`/`FontFile3` から元 PDF と同じフォントを復元する。
/// 復元できない、または置換文字列のグリフを引けない場合は既定のフォールバック順で代替する。
enum PDFEmbeddedFontLoader {
    struct FontDescription {
        let pdfName: String?
        let subtype: String?
        let descendantSubtype: String?
        let encoding: String?
        let isSubset: Bool
        let hasEmbeddedProgram: Bool
        let installedFamily: String?
    }

    struct Resolution {
        let font: CTFont
        /// 元PDFと同じフォント名の端末フォント、またはPDFの文字コード→GID対応で
        /// 置換文字列の全グリフを描けた場合のみ true。
        let isExact: Bool
        /// ToUnicode と CID→GID / TrueType cmap から GID を確定できる場合のみ非 nil。
        /// `replacement` の各文字に対応する (GID, 送り幅[em]) の並び。
        /// これが取れるときは `font` の `cmap` を経由せず直接そのグリフを描く
        /// (このサンプル PDF のように埋め込みサブセットに `cmap` が無く
        /// `CTFontGetGlyphsForCharacters` が原理的に使えないケースを救う)。
        let exactGlyphs: [(glyph: CGGlyph, emWidth: CGFloat)]?
        let reason: String?

        var familyName: String { CTFontCopyFamilyName(font) as String }
    }

    static func describe(
        fontDict: CGPDFDictionaryRef,
        postScriptNameOverride: String? = nil
    ) -> FontDescription {
        let pdfName = postScriptNameOverride ?? readBaseFontName(fontDict)
        let installed = pdfName.flatMap { installedFont(named: strippingSubsetPrefix($0), size: 12) }
        var subtypeName: UnsafePointer<Int8>?
        var descendantSubtypeName: UnsafePointer<Int8>?
        var encodingName: UnsafePointer<Int8>?
        _ = CGPDFDictionaryGetName(fontDict, "Subtype", &subtypeName)
        _ = CGPDFDictionaryGetName(fontDict, "Encoding", &encodingName)
        if let subtypeName, String(cString: subtypeName) == "Type0" {
            var descendants: CGPDFArrayRef?
            var descendant: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(fontDict, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant {
                _ = CGPDFDictionaryGetName(descendant, "Subtype", &descendantSubtypeName)
            }
        }
        return FontDescription(
            pdfName: pdfName,
            subtype: subtypeName.map { String(cString: $0) },
            descendantSubtype: descendantSubtypeName.map { String(cString: $0) },
            encoding: encodingName.map { String(cString: $0) },
            isSubset: pdfName.map { strippingSubsetPrefix($0) != $0 } ?? false,
            hasEmbeddedProgram: fontHasEmbeddedProgram(fontDict: fontDict),
            installedFamily: installed.map { CTFontCopyFamilyName($0) as String }
        )
    }

    static func resolveFont(
        fontDict: CGPDFDictionaryRef,
        size: CGFloat,
        replacementText: String,
        supportingText: String? = nil,
        preferredFontName: String? = nil
    ) -> Resolution {
        let info = PDFFontInfoLoader.load(from: fontDict)
        let requiredText = supportingText ?? replacementText

        if let preferredFontName {
            if let chosen = installedFont(named: preferredFontName, size: size) {
                let missing = missingCharacters(in: requiredText, font: chosen)
                if missing.isEmpty {
                    return Resolution(font: chosen, isExact: false, exactGlyphs: nil, reason: nil)
                }
                return fallbackResolution(
                    fontDict: fontDict, size: size, requiredText: requiredText,
                    reason: "指定フォント「\(preferredFontName)」に \(missing.joined(separator: "")) のグリフがないため代替します。"
                )
            }
            return fallbackResolution(
                fontDict: fontDict, size: size, requiredText: requiredText,
                reason: "指定フォント「\(preferredFontName)」がこのMacで利用できないため代替します。"
            )
        }

        if let embedded = loadEmbeddedFont(fontDict: fontDict, size: size) {
            // Type0/Identity-H は code=GID、単純 TrueType は埋込 cmap で
            // code→GID を確定できた場合だけ厳密描画する。
            if let exact = embeddedFontResolution(
                font: embedded,
                info: info,
                replacementText: replacementText
            ) {
                return exact
            }

            let requiresExactSubsetMapping = info.isIdentityCIDToGID
                || (info.bytesPerCode == 1 && !info.explicitToUnicodeCodes.isEmpty)
            if !requiresExactSubsetMapping,
               coversAllCharacters(of: requiredText, font: embedded) {
                return Resolution(font: embedded, isExact: true, exactGlyphs: nil, reason: nil)
            }
        }

        return fallbackResolution(
            fontDict: fontDict, size: size, requiredText: requiredText,
            reason: fontHasEmbeddedProgram(fontDict: fontDict)
                ? "PDF内の埋め込みフォントに入力文字のグリフがないため代替します。"
                : "PDFに利用可能なフォント本体が埋め込まれていないため代替します。"
        )
    }

    private static func fallbackResolution(
        fontDict: CGPDFDictionaryRef,
        size: CGFloat,
        requiredText: String,
        reason: String
    ) -> Resolution {
        if let baseFontName = readBaseFontName(fontDict) {
            let cleaned = strippingSubsetPrefix(baseFontName)
            if let installed = installedFont(named: cleaned, size: size),
               coversAllCharacters(of: requiredText, font: installed) {
                return Resolution(font: installed, isExact: true, exactGlyphs: nil, reason: nil)
            }
        }

        let fallbackNames = fallbackFontNames(
            for: readBaseFontName(fontDict),
            replacementText: requiredText
        )
        for fallbackName in fallbackNames {
            guard let fallback = installedFont(named: fallbackName, size: size),
                  coversAllCharacters(of: requiredText, font: fallback) else { continue }
            return Resolution(font: fallback, isExact: false, exactGlyphs: nil, reason: reason)
        }

        let fallbackName = fallbackNames.first ?? "Helvetica Neue"
        let fallback = installedFont(named: fallbackName, size: size)
            ?? CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        return Resolution(font: fallback, isExact: false, exactGlyphs: nil,
                          reason: reason + " 対応する全グリフを持つフォントも見つかりません。")
    }

    /// 行の再描画に使う、Unicode文字列を直接描けるフォントを選ぶ。
    /// 埋め込みサブセットは ToUnicode→CID→GID で選択文字だけ描ける場合があるが、
    /// CoreText の文字列描画では同じ対応表を使えず、行末の未編集文字が別書体へ
    /// フォールバックすることがある。未編集部分の再描画には埋め込みGID経路を使わず、
    /// 元フォント名に一致し、行全体を Unicode で描けるローカルフォントを使う。
    static func unicodeFontForLine(fontDict: CGPDFDictionaryRef, size: CGFloat, text: String) -> CTFont {
        fallbackResolution(
            fontDict: fontDict,
            size: size,
            requiredText: text,
            reason: "行の文字を描けるローカルフォントが見つかりません。"
        ).font
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
    /// Microsoft Office にある MS Gothic / MS Mincho も、配布用にコピーせず
    /// このプロセス内だけで登録する。
    /// ユーザーのフォント設定やシステム全体のフォント一覧は変更しない。
    static func registerBundledFonts() {
        _ = bundledFontsRegistered
        _ = localMicrosoftJapaneseFontsRegistered
    }

    /// この Mac にある Microsoft Office の日本語フォントを登録し、利用可能なファミリー名を返す。
    static func registerLocalFontFamilies() -> [String] {
        registerBundledFonts()
        return localMicrosoftJapaneseFontsRegistered
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

    /// 置換文字列の全文字を ToUnicode で PDF 文字コードへ戻し、
    /// Type0/Identity-H なら code=GID、単純 TrueType なら埋込 cmap で
    /// code→GID を解決する。1 文字でも確定できなければ nil。
    private static func exactGlyphs(
        for text: String,
        using info: PDFFontInfo,
        font: CTFont
    ) -> [(glyph: CGGlyph, emWidth: CGFloat)]? {
        guard !text.isEmpty else { return [] }
        var result: [(CGGlyph, CGFloat)] = []
        for character in text {
            guard let code = info.unicodeToCode[String(character)],
                  code > 0 else { return nil }
            let glyph: CGGlyph?
            if info.isIdentityCIDToGID {
                glyph = code <= Int(CGGlyph.max) ? CGGlyph(code) : nil
            } else if info.bytesPerCode == 1 {
                glyph = simpleTrueTypeGlyph(
                    for: String(character),
                    pdfCode: code,
                    info: info,
                    font: font
                )
            } else {
                glyph = nil
            }
            guard let glyph, isValidGlyphID(Int(glyph), in: font) else { return nil }
            result.append((glyph, info.width(for: code)))
        }
        return result
    }

    private static func simpleTrueTypeGlyph(
        for character: String,
        pdfCode: Int,
        info: PDFFontInfo,
        font: CTFont
    ) -> CGGlyph? {
        if let glyphName = info.simpleEncodingGlyphNames[pdfCode] {
            let graphicsFont = CTFontCopyGraphicsFont(font, nil)
            let namedGlyph = graphicsFont.getGlyphWithGlyphName(name: glyphName as CFString)
            if isValidGlyphID(Int(namedGlyph), in: font) {
                return namedGlyph
            }
        }

        let directGlyph = PDFTrueTypeCMap.glyphID(forCharacterCode: pdfCode, in: font)
        let unicodeGlyph = unicodeGlyph(for: character, in: font)
        if let directGlyph, directGlyph == unicodeGlyph {
            return directGlyph
        }

        let pdfWidth = info.width(for: pdfCode)
        let directMatchesWidth = directGlyph.map {
            glyph($0, matchesPDFWidth: pdfWidth, in: font)
        } ?? false
        let unicodeMatchesWidth = unicodeGlyph.map {
            glyph($0, matchesPDFWidth: pdfWidth, in: font)
        } ?? false

        switch (directMatchesWidth, unicodeMatchesWidth) {
        case (true, false): return directGlyph
        case (false, true): return unicodeGlyph
        default:
            // Encoding と cmap の文字空間が衝突し、どちらが正しいか
            // 一意に証明できない。誤字を「厳密」扱いせず代替経路へ戻す。
            return nil
        }
    }

    private static func unicodeGlyph(for character: String, in font: CTFont) -> CGGlyph? {
        let utf16 = Array(character.utf16)
        guard utf16.count == 1 else { return nil }
        var codeUnit = utf16[0]
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &codeUnit, &glyph, 1),
              isValidGlyphID(Int(glyph), in: font) else { return nil }
        return glyph
    }

    private static func glyph(_ glyph: CGGlyph, matchesPDFWidth pdfWidth: CGFloat, in font: CTFont) -> Bool {
        let size = CTFontGetSize(font)
        guard size.isFinite, size > 0, pdfWidth.isFinite, pdfWidth > 0 else { return false }
        var candidate = glyph
        var advance = CGSize.zero
        guard CTFontGetAdvancesForGlyphs(font, .horizontal, &candidate, &advance, 1) > 0,
              advance.width.isFinite else { return false }
        let emWidth = advance.width / size
        let tolerance = max(0.02, pdfWidth * 0.03)
        return abs(emWidth - pdfWidth) <= tolerance
    }

    static func isValidGlyphID(_ code: Int, in font: CTFont) -> Bool {
        code > 0 && code < CTFontGetGlyphCount(font)
    }

    /// Embedded cmap tables can disagree with Unicode layout. Trust a subset only when
    /// ToUnicode plus Identity CID→GID or the simple TrueType cmap resolves every glyph.
    static func embeddedFontResolution(
        font: CTFont,
        info: PDFFontInfo,
        replacementText: String
    ) -> Resolution? {
        guard let glyphs = exactGlyphs(for: replacementText, using: info, font: font) else { return nil }
        return Resolution(font: font, isExact: true, exactGlyphs: glyphs, reason: nil)
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
        registerBundledFonts()
        let requestedName = normalizedFontName(name)
        let direct = CTFontCreateWithName(name as CFString, size, nil)
        if [CTFontCopyFamilyName(direct) as String, CTFontCopyPostScriptName(direct) as String]
            .contains(where: { normalizedFontName($0) == requestedName }) {
            return direct
        }
        let postScriptNames = CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        let familyNames = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        let candidates = postScriptNames.filter { normalizedFontName($0) == requestedName }
            + familyNames.filter { normalizedFontName($0) == requestedName }
        for candidate in candidates {
            let font = CTFontCreateWithName(candidate as CFString, size, nil)
            let actualNames = [
                CTFontCopyFamilyName(font) as String,
                CTFontCopyPostScriptName(font) as String
            ]
            if actualNames.contains(where: { normalizedFontName($0) == requestedName }) {
                return font
            }
        }
        return nil
    }

    static func availableFont(named name: String, size: CGFloat) -> CTFont? {
        installedFont(named: name, size: size)
    }

    static func resolveSearchableFont(
        named name: String,
        size: CGFloat,
        replacementText: String,
        supportingText: String? = nil
    ) -> Resolution? {
        guard let font = availableFont(named: name, size: size) else { return nil }
        let missing = missingCharacters(in: supportingText ?? replacementText, font: font)
        guard missing.isEmpty else { return nil }
        return Resolution(font: font, isExact: true, exactGlyphs: nil, reason: nil)
    }

    static func bundledFontURL(
        mainBundle: Bundle = .main,
        packageBundle: () -> Bundle = { .module }
    ) -> URL? {
        mainBundle.url(
            forResource: "NotoSansJP-Regular",
            withExtension: "otf",
            subdirectory: "Fonts"
        ) ?? packageBundle().url(
            forResource: "NotoSansJP-Regular",
            withExtension: "otf",
            subdirectory: "Fonts"
        )
    }

    private static func normalizedFontName(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static let bundledFontsRegistered: Void = {
        // 配布アプリでは通常の app Resources を使う。Bundle.module は SwiftPM 実行時の
        // fallback として遅延評価し、生成コードが埋め込む開発機の build path に依存しない。
        guard let fontURL = bundledFontURL() else { return }
        _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }()

    /// Office のインストール先は `/Applications` に置かれたアプリの symlink も解決する。
    /// フォント本体をリポジトリや PDF editor.app に複製せず、ローカルの Office から直接読む。
    private static let localMicrosoftJapaneseFontsRegistered: [String] = {
        let wordApplications = [
            URL(fileURLWithPath: "/Applications/Microsoft Word.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Microsoft Word.app")
        ]
        let fontRelativePaths = [
            "Contents/Resources/DFonts/msgothic.ttc",
            "Contents/Resources/DFonts/msmincho.ttc"
        ]

        var families = Set<String>()
        for relativePath in fontRelativePaths {
            let candidates = wordApplications.map { $0.appendingPathComponent(relativePath) }
            guard let fontURL = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) else { continue }
            if let registered = try? registerFontFile(at: fontURL) {
                families.formUnion(registered)
            }
        }
        return families.sorted()
    }()

    private static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3040...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value) || (0xFF66...0xFF9F).contains(value)
        }
    }

    static func missingCharacters(in text: String, font: CTFont) -> [String] {
        var missing: [String] = []
        for character in text {
            let allScalarsHaveGlyphs = character.unicodeScalars.allSatisfy { scalar in
                var units = Array(String(scalar).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: units.count)
                _ = CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
                return glyphs.contains(where: { $0 != 0 })
            }
            if !allScalarsHaveGlyphs, !missing.contains(String(character)) {
                missing.append(String(character))
            }
        }
        return missing
    }

    private static func coversAllCharacters(of text: String, font: CTFont) -> Bool {
        missingCharacters(in: text, font: font).isEmpty
    }
}
