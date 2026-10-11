import AppKit
import PDFKit
import SwiftUI

struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let revision: Int
    let mode: EditorMode
    let hasSelection: Bool
    let onSelection: (TextTarget?) -> Void
    let onInsertion: (Int, CGPoint) -> Void
    let onMoveInsertion: (String, Int, CGRect) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            onInsertion: onInsertion,
            onMoveInsertion: onMoveInsertion
        )
    }

    func makeNSView(context: Context) -> ClickablePDFView {
        let view = ClickablePDFView()
        configure(view, coordinator: context.coordinator)
        if mode == .insertion { view.clearSelection() }
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        return view
    }

    func updateNSView(_ view: ClickablePDFView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.onInsertion = onInsertion
        context.coordinator.onMoveInsertion = onMoveInsertion
        configure(view, coordinator: context.coordinator)
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
        if !hasSelection {
            view.clearReplacementHighlight()
        }
        _ = revision
        view.layoutDocumentView()
        view.window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }

    private func configure(_ view: ClickablePDFView, coordinator: Coordinator) {
        view.editorMode = mode
        view.selectionHandler = coordinator.handleSelection
        view.insertionHandler = coordinator.handleInsertion
        view.moveInsertionHandler = coordinator.handleMoveInsertion
    }

    final class Coordinator {
        var onSelection: (TextTarget?) -> Void
        var onInsertion: (Int, CGPoint) -> Void
        var onMoveInsertion: (String, Int, CGRect) -> Void

        init(
            onSelection: @escaping (TextTarget?) -> Void,
            onInsertion: @escaping (Int, CGPoint) -> Void,
            onMoveInsertion: @escaping (String, Int, CGRect) -> Void
        ) {
            self.onSelection = onSelection
            self.onInsertion = onInsertion
            self.onMoveInsertion = onMoveInsertion
        }

        func handleSelection(_ target: TextTarget?) { onSelection(target) }
        func handleInsertion(_ pageIndex: Int, _ point: CGPoint) { onInsertion(pageIndex, point) }
        func handleMoveInsertion(_ marker: String, _ pageIndex: Int, _ bounds: CGRect) {
            onMoveInsertion(marker, pageIndex, bounds)
        }
    }
}

final class ClickablePDFView: PDFView {
    var editorMode: EditorMode = .replacement
    var selectionHandler: ((TextTarget?) -> Void)?
    var insertionHandler: ((Int, CGPoint) -> Void)?
    var moveInsertionHandler: ((String, Int, CGRect) -> Void)?

    private var draggedAnnotation: PDFAnnotation?
    private weak var draggedPage: PDFPage?
    private var dragStartPoint = CGPoint.zero
    private var dragStartBounds = CGRect.zero

    // 置換モードのグリフ単位ドラッグ選択に使う状態。
    // PDFKit のテキスト選択 (`PDFSelection`) はこの PDF の表領域で破綻するため使わない。
    private var replacementDragRun: ScannedRun?
    private var replacementDragAnchorIndex: Int?
    private weak var replacementDragPage: PDFPage?
    private var replacementDragTarget: TextTarget?

    private var highlightAnnotation: PDFAnnotation?
    private weak var highlightPage: PDFPage?

    override func resetCursorRects() {
        super.resetCursorRects()
        if editorMode == .insertion { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        if editorMode == .insertion {
            handleInsertionMouseDown(event)
            return
        }
        handleReplacementMouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if editorMode == .replacement {
            handleReplacementMouseDragged(event)
            return
        }
        guard let annotation = draggedAnnotation,
              let page = draggedPage,
              let document else {
            super.mouseDragged(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let pagePoint = convert(viewPoint, to: page)
        let delta = CGPoint(x: pagePoint.x - dragStartPoint.x, y: pagePoint.y - dragStartPoint.y)
        var bounds = dragStartBounds.offsetBy(dx: delta.x, dy: delta.y)
        let pageBounds = page.bounds(for: .mediaBox)
        bounds.origin.x = min(max(bounds.minX, pageBounds.minX), max(pageBounds.maxX - bounds.width, pageBounds.minX))
        bounds.origin.y = min(max(bounds.minY, pageBounds.minY), max(pageBounds.maxY - bounds.height, pageBounds.minY))
        annotation.bounds = bounds
        let marker = annotation.userName ?? PDFEditEngine.draftMarker
        moveInsertionHandler?(marker, document.index(for: page), bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if editorMode == .replacement {
            // 入力欄へのフォーカス移動はドラッグが終わってから行う。
            // mouseDown 中に select() を呼ぶと、範囲選択中に first responder が移ってしまう。
            selectionHandler?(replacementDragTarget)
            replacementDragTarget = nil
            replacementDragRun = nil
            replacementDragAnchorIndex = nil
            replacementDragPage = nil
            return
        }
        if draggedAnnotation != nil {
            draggedAnnotation = nil
            draggedPage = nil
            return
        }
        super.mouseUp(with: event)
    }

    func clearReplacementHighlight() {
        if let highlightAnnotation, let highlightPage {
            highlightPage.removeAnnotation(highlightAnnotation)
        }
        highlightAnnotation = nil
        highlightPage = nil
    }

    private func handleInsertionMouseDown(_ event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false), let document else { return }
        let pagePoint = convert(viewPoint, to: page)

        if let annotation = page.annotations.reversed().first(where: {
            ($0.userName?.hasPrefix(PDFEditEngine.annotationMarkerPrefix) == true) && $0.bounds.contains(pagePoint)
        }) {
            draggedAnnotation = annotation
            draggedPage = page
            dragStartPoint = pagePoint
            dragStartBounds = annotation.bounds
            return
        }

        clearSelection()
        insertionHandler?(document.index(for: page), pagePoint)
    }

    private func handleReplacementMouseDown(_ event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false), let document else {
            clearReplacementHighlight()
            replacementDragTarget = nil
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        let index = PDFGlyphIndex.makeIndex(for: page)

        guard let hit = index.clusterWithAnchor(at: pagePoint, pageIndex: document.index(for: page)) else {
            clearReplacementHighlight()
            replacementDragTarget = nil
            return
        }

        replacementDragRun = hit.run
        replacementDragAnchorIndex = hit.anchorGlyphIndex
        replacementDragPage = page
        replacementDragTarget = hit.target

        showHighlight(bounds: hit.target.bounds, on: page)
    }

    private func handleReplacementMouseDragged(_ event: NSEvent) {
        guard let run = replacementDragRun,
              let anchor = replacementDragAnchorIndex,
              let page = replacementDragPage,
              let document else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let pagePoint = convert(viewPoint, to: page)
        let index = PDFGlyphIndex.makeIndex(for: page)
        let currentIndex = index.nearestGlyphIndex(in: run, x: pagePoint.x)
        let lower = min(anchor, currentIndex)
        let upper = max(anchor, currentIndex)
        guard let target = index.target(in: run, range: lower..<(upper + 1), pageIndex: document.index(for: page)) else { return }

        replacementDragTarget = target
        showHighlight(bounds: target.bounds, on: page)
    }

    private func showHighlight(bounds: CGRect, on page: PDFPage) {
        clearReplacementHighlight()
        let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        annotation.color = .clear
        annotation.interiorColor = NSColor.systemYellow.withAlphaComponent(0.35)
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        page.addAnnotation(annotation)
        highlightAnnotation = annotation
        highlightPage = page
    }
}
