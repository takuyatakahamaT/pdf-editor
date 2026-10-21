import AppKit
import PDFKit

enum PDFMarkupTool: String, CaseIterable, Identifiable {
    case highlight
    case underline
    case strikeOut
    case note
    case rectangle
    case ellipse
    case arrow
    case ink
    case signature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highlight: "ハイライト"
        case .underline: "下線"
        case .strikeOut: "取り消し線"
        case .note: "メモ"
        case .rectangle: "四角形"
        case .ellipse: "楕円"
        case .arrow: "矢印"
        case .ink: "手書き"
        case .signature: "署名"
        }
    }

    var isTextMarkup: Bool {
        switch self {
        case .highlight, .underline, .strikeOut: true
        default: false
        }
    }

    var usesTextInput: Bool { self == .note || self == .signature }

    var color: NSColor {
        switch self {
        case .highlight: .systemYellow
        case .underline, .strikeOut, .note, .rectangle, .ellipse, .arrow, .ink, .signature: .systemRed
        }
    }
}

struct PDFMarkupEdit {
    let id: UUID
    let pageIndex: Int
    let tool: PDFMarkupTool
    var bounds: CGRect
    var points: [CGPoint]
    var text: String
    var color: NSColor

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        tool: PDFMarkupTool,
        bounds: CGRect,
        points: [CGPoint] = [],
        text: String = "",
        color: NSColor? = nil
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.tool = tool
        self.bounds = bounds
        self.points = points
        self.text = text
        self.color = color ?? tool.color
    }
}

enum PDFMarkupEngine {
    static let markerPrefix = "PDFEditorMarkup:"

    static func makeAnnotation(for edit: PDFMarkupEdit) -> PDFAnnotation {
        let type: PDFAnnotationSubtype
        switch edit.tool {
        case .highlight: type = .highlight
        case .underline: type = .underline
        case .strikeOut: type = .strikeOut
        case .note: type = .text
        case .rectangle: type = .square
        case .ellipse: type = .circle
        case .arrow: type = .line
        case .ink: type = .ink
        case .signature: type = .freeText
        }

        let annotation = PDFAnnotation(bounds: edit.bounds, forType: type, withProperties: nil)
        annotation.userName = markerPrefix + edit.id.uuidString
        annotation.shouldPrint = true
        annotation.color = edit.tool == .highlight ? edit.color.withAlphaComponent(0.38) : edit.color
        annotation.contents = edit.text.isEmpty ? nil : edit.text
        let border = PDFBorder()
        border.lineWidth = edit.tool == .highlight ? 0 : 1.5
        annotation.border = border

        switch edit.tool {
        case .highlight, .underline, .strikeOut:
            annotation.quadrilateralPoints = [
                NSValue(point: CGPoint(x: 0, y: edit.bounds.height)),
                NSValue(point: CGPoint(x: edit.bounds.width, y: edit.bounds.height)),
                NSValue(point: .zero),
                NSValue(point: CGPoint(x: edit.bounds.width, y: 0))
            ]
        case .note:
            annotation.iconType = .note
        case .rectangle, .ellipse:
            annotation.interiorColor = .clear
        case .arrow:
            annotation.startPoint = edit.points.first.map {
                CGPoint(x: $0.x - edit.bounds.minX, y: $0.y - edit.bounds.minY)
            } ?? .zero
            annotation.endPoint = edit.points.last.map {
                CGPoint(x: $0.x - edit.bounds.minX, y: $0.y - edit.bounds.minY)
            } ?? CGPoint(x: edit.bounds.width, y: edit.bounds.height)
            annotation.startLineStyle = .none
            annotation.endLineStyle = .closedArrow
            annotation.interiorColor = edit.color
        case .ink:
            let path = NSBezierPath()
            let relativePoints = edit.points.map { CGPoint(x: $0.x - edit.bounds.minX, y: $0.y - edit.bounds.minY) }
            if let first = relativePoints.first {
                path.move(to: first)
                for point in relativePoints.dropFirst() { path.line(to: point) }
                if relativePoints.count == 1 { path.line(to: CGPoint(x: first.x + 0.1, y: first.y + 0.1)) }
            }
            path.lineWidth = 2
            annotation.add(path)
        case .signature:
            annotation.color = .clear
            annotation.fontColor = edit.color
            annotation.alignment = .center
            annotation.font = NSFont(name: "Snell Roundhand", size: max(12, min(edit.bounds.height * 0.8, 48)))
                ?? NSFont.systemFont(ofSize: max(12, min(edit.bounds.height * 0.8, 48)))
        }
        return annotation
    }
}
