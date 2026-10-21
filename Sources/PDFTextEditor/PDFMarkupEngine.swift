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

    static func clampedPoint(_ point: CGPoint, to pageBounds: CGRect) -> CGPoint {
        let pageBounds = pageBounds.standardized
        return CGPoint(
            x: min(max(point.x, pageBounds.minX), pageBounds.maxX),
            y: min(max(point.y, pageBounds.minY), pageBounds.maxY)
        )
    }

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

    static func clampedResizeBounds(
        _ bounds: CGRect,
        anchoredAt origin: CGPoint,
        to pageBounds: CGRect,
        minimumSize: CGSize = .zero
    ) -> CGRect {
        let pageBounds = pageBounds.standardized
        let anchor = CGPoint(
            x: min(max(origin.x, pageBounds.minX), pageBounds.maxX),
            y: min(max(origin.y, pageBounds.minY), pageBounds.maxY)
        )
        let availableWidth = max(0, pageBounds.maxX - anchor.x)
        let availableHeight = max(0, pageBounds.maxY - anchor.y)
        let width = min(max(bounds.width, min(max(0, minimumSize.width), availableWidth)), availableWidth)
        let height = min(max(bounds.height, min(max(0, minimumSize.height), availableHeight)), availableHeight)
        return CGRect(origin: anchor, size: CGSize(width: width, height: height))
    }

    static func hitTest(_ point: CGPoint, in edit: PDFMarkupEdit, tolerance: CGFloat = 6) -> Bool {
        let bounds = edit.bounds.standardized
        switch edit.tool {
        case .rectangle:
            let outer = bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard outer.contains(point) else { return false }
            let borderDistance = min(
                min(abs(point.x - bounds.minX), abs(point.x - bounds.maxX)),
                min(abs(point.y - bounds.minY), abs(point.y - bounds.maxY))
            )
            return borderDistance <= tolerance
        case .ellipse:
            guard bounds.width > 0, bounds.height > 0 else { return false }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radiusX = bounds.width / 2
            let radiusY = bounds.height / 2
            let normalizedDistance = hypot((point.x - center.x) / radiusX, (point.y - center.y) / radiusY)
            return abs(normalizedDistance - 1) * min(radiusX, radiusY) <= tolerance
        case .arrow:
            guard let start = edit.points.first, let end = edit.points.last else { return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            return distance(from: point, toSegmentFrom: start, to: end) <= tolerance
        case .ink:
            guard let first = edit.points.first else { return false }
            if edit.points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= tolerance }
            return zip(edit.points, edit.points.dropFirst()).contains {
                distance(from: point, toSegmentFrom: $0.0, to: $0.1) <= tolerance
            }
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
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
