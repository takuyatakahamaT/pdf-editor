import CoreText
import Foundation

enum AppResourceVerificationError: Error, LocalizedError {
    case missingFonts(URL)
    case missingFont
    case invalidFont

    var errorDescription: String? {
        switch self {
        case .missingFonts(let url): "アプリのフォント資源が見つかりません: \(url.path)"
        case .missingFont: "アプリ内のNoto Sans JPが見つかりません。"
        case .invalidFont: "アプリ内のNoto Sans JPを読み込めません。"
        }
    }
}

func verifyAppResources(at appURL: URL) throws {
    let resourceBundleURL = appURL.appendingPathComponent("PDFTextEditor_PDFTextEditor.bundle", isDirectory: true)
    let legacyBundleURL = appURL.appendingPathComponent(
        "Contents/Resources/PDFTextEditor_PDFTextEditor.bundle",
        isDirectory: true
    )
    guard !FileManager.default.fileExists(atPath: resourceBundleURL.path),
          !FileManager.default.fileExists(atPath: legacyBundleURL.path),
          let appBundle = Bundle(path: appURL.path) else {
        throw AppResourceVerificationError.missingFonts(
            appURL.appendingPathComponent("Contents/Resources/Fonts", isDirectory: true)
        )
    }
    guard let fontURL = appBundle.url(
        forResource: "NotoSansJP-Regular",
        withExtension: "otf",
        subdirectory: "Fonts"
    ) else {
        throw AppResourceVerificationError.missingFont
    }
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL),
          CFArrayGetCount(descriptors) > 0 else {
        throw AppResourceVerificationError.invalidFont
    }
    let expectedFontURL = appURL.appendingPathComponent(
        "Contents/Resources/Fonts/NotoSansJP-Regular.otf"
    )
    guard fontURL.standardizedFileURL == expectedFontURL.standardizedFileURL else {
        throw AppResourceVerificationError.missingFont
    }
    _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    let font = CTFontCreateWithName("Noto Sans JP" as CFString, 12, nil)
    guard CTFontCopyFamilyName(font) as String == "Noto Sans JP" else {
        throw AppResourceVerificationError.invalidFont
    }
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: verify-app-resources.swift '/path/PDF editor.app'")
}
do {
    try verifyAppResources(at: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    print("アプリのContents/Resources/FontsからNoto Sans JPを解決できました。")
} catch {
    fputs("アプリ内フォントの検証に失敗しました: \(error.localizedDescription)\n", stderr)
    exit(1)
}
