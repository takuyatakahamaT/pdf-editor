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

    static func clampedBounds(
        _ bounds: CGRect,
        to pageBounds: CGRect,
        minimumSize: CGSize = .zero
    ) -> CGRect {
        let pageBounds = pageBounds.standardized
        let pageWidth = max(0, pageBounds.width)
        let pageHeight = max(0, pageBounds.height)
        let width = min(max(bounds.width, min(max(0, minimumSize.width), pageWidth)), pageWidth)
        let height = min(max(bounds.height, min(max(0, minimumSize.height), pageHeight)), pageHeight)
        let originX = min(max(bounds.minX, pageBounds.minX), max(pageBounds.maxX - width, pageBounds.minX))
        let originY = min(max(bounds.minY, pageBounds.minY), max(pageBounds.maxY - height, pageBounds.minY))
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    static func edits(in document: PDFDocument) -> [PDFMarkupEdit] {
        (0..<document.pageCount).flatMap { pageIndex in
            document.page(at: pageIndex)?.annotations.compactMap {
                edit(from: $0, pageIndex: pageIndex)
            } ?? []
        }
    }

    static func replaceManagedAnnotations(on page: PDFPage, with edits: [PDFMarkupEdit]) {
        for annotation in page.annotations where annotation.userName?.hasPrefix(markerPrefix) == true {
            page.removeAnnotation(annotation)
        }
        for edit in edits {
            page.addAnnotation(makeAnnotation(for: edit))
        }
    }

    static func duplicateAnnotation(_ annotation: PDFAnnotation) -> PDFAnnotation? {
        guard let type = annotation.type else { return nil }
        let popup = annotation.popup
        var properties = annotation.annotationKeyValues
        properties.removeValue(forKey: PDFAnnotationKey.page)
        properties.removeValue(forKey: PDFAnnotationKey.popup)
        let duplicate = PDFAnnotation(
            bounds: annotation.bounds,
            forType: PDFAnnotationSubtype(rawValue: type),
            withProperties: properties
        )
        if let popup, let popupCopy = duplicateAnnotation(popup) {
            duplicate.popup = popupCopy
        }
        return duplicate
    }

    static func edit(from annotation: PDFAnnotation, pageIndex: Int) -> PDFMarkupEdit? {
        guard let marker = annotation.userName, marker.hasPrefix(markerPrefix),
              let id = UUID(uuidString: String(marker.dropFirst(markerPrefix.count))),
              let annotationType = annotation.type else { return nil }

        let tool: PDFMarkupTool
        switch annotationType {
        case PDFAnnotationSubtype.highlight.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")):
            tool = .highlight
        case PDFAnnotationSubtype.underline.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")):
            tool = .underline
        case PDFAnnotationSubtype.strikeOut.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")):
            tool = .strikeOut
        case PDFAnnotationSubtype.text.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")):
            tool = .note
        case PDFAnnotationSubtype.square.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")):
            tool = .rectangle
        case PDFAnnotationSubtype.circle.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")):
            tool = .ellipse
        case PDFAnnotationSubtype.line.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")):
            tool = .arrow
        case PDFAnnotationSubtype.ink.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")):
            tool = .ink
        case PDFAnnotationSubtype.freeText.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")):
            tool = .signature
        default:
            return nil
        }

        let bounds = annotation.bounds
        let points: [CGPoint]
        switch tool {
        case .arrow:
            points = [
                CGPoint(x: bounds.minX + annotation.startPoint.x, y: bounds.minY + annotation.startPoint.y),
                CGPoint(x: bounds.minX + annotation.endPoint.x, y: bounds.minY + annotation.endPoint.y)
            ]
        case .ink:
            points = (annotation.paths ?? []).flatMap { path in
                var pathPoints: [CGPoint] = []
                for index in 0..<path.elementCount {
                    var coordinates = [CGPoint](repeating: .zero, count: 3)
                    let element = path.element(at: index, associatedPoints: &coordinates)
                    if element == .moveTo || element == .lineTo {
                        pathPoints.append(CGPoint(
                            x: bounds.minX + coordinates[0].x,
                            y: bounds.minY + coordinates[0].y
                        ))
                    } else if element == .cubicCurveTo {
                        pathPoints.append(CGPoint(
                            x: bounds.minX + coordinates[2].x,
                            y: bounds.minY + coordinates[2].y
                        ))
                    }
                }
                return pathPoints
            }
        default:
            points = []
        }

        let color = ((tool == .signature ? annotation.fontColor : annotation.color) ?? tool.color)
            .withAlphaComponent(1)
        return PDFMarkupEdit(
            id: id,
            pageIndex: pageIndex,
            tool: tool,
            bounds: bounds,
            points: points,
            text: annotation.contents ?? "",
            color: color
        )
    }

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
