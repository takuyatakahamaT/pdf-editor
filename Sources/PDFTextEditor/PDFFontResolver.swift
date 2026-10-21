import AppKit
import PDFKit

enum EditorMode: String, CaseIterable, Identifiable {
    case replacement
    case insertion
    case markup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replacement: return "既存文字を置換"
        case .insertion: return "テキストを追加"
        case .markup: return "注釈・署名"
        }
    }
}

enum InsertionFontChoice: String, CaseIterable, Identifiable {
    case automatic
    case msGothic
    case msPGothic
    case msUIGothic
    case hiraginoSans
    case hiraginoMincho
    case notoSansJP
    case helveticaNeue
    case arial
    case timesNewRoman
    case courierNew
    case menlo
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "元の書体・自動"
        case .msGothic: return "MS Gothic"
        case .msPGothic: return "MS PGothic"
        case .msUIGothic: return "MS UI Gothic"
        case .hiraginoSans: return "ヒラギノ角ゴ"
        case .hiraginoMincho: return "ヒラギノ明朝"
        case .notoSansJP: return "Noto Sans JP"
        case .helveticaNeue: return "Helvetica Neue"
        case .arial: return "Arial"
        case .timesNewRoman: return "Times New Roman"
        case .courierNew: return "Courier New"
        case .menlo: return "Menlo"
        case .custom: return "読み込み済みのフォント"
        }
    }

    var fontName: String? {
        switch self {
        case .automatic: return nil
        case .msGothic: return "MS Gothic"
        case .msPGothic: return "MS PGothic"
        case .msUIGothic: return "MS UI Gothic"
        case .hiraginoSans: return "Hiragino Sans"
        case .hiraginoMincho: return "Hiragino Mincho ProN"
        case .notoSansJP: return "Noto Sans JP"
        case .helveticaNeue: return "Helvetica Neue"
        case .arial: return "Arial"
        case .timesNewRoman: return "Times New Roman"
        case .courierNew: return "Courier New"
        case .menlo: return "Menlo"
        case .custom: return nil
        }
    }
}

struct PDFFontResolution {
    let detectedName: String?
    let resolvedName: String
    let size: CGFloat
    let color: NSColor
}

enum PDFFontResolver {
    private static let fallbackFontName = "Hiragino Sans"

    static func resolve(on page: PDFPage, at point: CGPoint) -> PDFFontResolution {
        if let nearby = nearbyStyle(on: page, at: point) {
            return resolution(from: nearby)
        }
        if let dominant = dominantStyle(on: page) {
            return resolution(from: dominant)
        }
        return PDFFontResolution(
            detectedName: nil,
            resolvedName: availableFont(named: fallbackFontName),
            size: 12,
            color: .black
        )
    }

    private static func nearbyStyle(on page: PDFPage, at point: CGPoint) -> (NSFont, NSColor)? {
        for radius in [12.0, 24.0, 48.0, 96.0] {
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            if let selection = page.selection(for: rect), let style = firstStyle(in: selection.attributedString) {
                return style
            }
        }
        return nil
    }

    private static func dominantStyle(on page: PDFPage) -> (NSFont, NSColor)? {
        guard let attributed = page.attributedString, attributed.length > 0 else { return nil }
        var weights: [String: (font: NSFont, color: NSColor, count: Int)] = [:]
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attributes, range, _ in
            guard let font = attributes[.font] as? NSFont else { return }
            let color = attributes[.foregroundColor] as? NSColor ?? .black
            let current = weights[font.fontName]
            weights[font.fontName] = (font, color, (current?.count ?? 0) + range.length)
        }
        return weights.values.max(by: { $0.count < $1.count }).map { ($0.font, $0.color) }
    }

    private static func firstStyle(in attributed: NSAttributedString?) -> (NSFont, NSColor)? {
        guard let attributed, attributed.length > 0 else { return nil }
        var result: (NSFont, NSColor)?
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attributes, _, stop in
            guard let font = attributes[.font] as? NSFont else { return }
            result = (font, attributes[.foregroundColor] as? NSColor ?? .black)
            stop.pointee = true
        }
        return result
    }

    private static func resolution(from style: (NSFont, NSColor)) -> PDFFontResolution {
        let detected = style.0.fontName
        return PDFFontResolution(
            detectedName: detected,
            resolvedName: availableFont(named: detected),
            size: min(max(style.0.pointSize, 6), 72),
            color: style.1
        )
    }

    private static func availableFont(named name: String) -> String {
        if NSFont(name: name, size: 12) != nil { return name }
        if NSFont(name: fallbackFontName, size: 12) != nil { return fallbackFontName }
        return NSFont.systemFont(ofSize: 12).fontName
    }
}
