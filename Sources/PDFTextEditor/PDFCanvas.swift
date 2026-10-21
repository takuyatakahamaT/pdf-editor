import AppKit
import PDFKit
import SwiftUI

struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let revision: Int
    let mode: EditorMode
    let selectedTarget: TextTarget?
    let isInlineEditing: Bool
    @ObservedObject var zoomState: PDFZoomState
    let onSelection: (TextTarget?) -> Void
    let onInsertion: (Int, CGPoint) -> Void
    let onMoveInsertion: (String, Int, CGRect) -> Void
    let onMoveSelection: (CGPoint) -> Void
    let onMoveExistingEdit: (UUID, CGPoint) -> Void
    let onBeginInlineEditing: () -> Void
    let onChangeInlineText: (String) -> Void
    let onCommitInlineEditing: () -> Void
    let onCancelInlineEditing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            onInsertion: onInsertion,
            onMoveInsertion: onMoveInsertion,
            onMoveSelection: onMoveSelection,
            onMoveExistingEdit: onMoveExistingEdit,
            onBeginInlineEditing: onBeginInlineEditing,
            onChangeInlineText: onChangeInlineText,
            onCommitInlineEditing: onCommitInlineEditing,
            onCancelInlineEditing: onCancelInlineEditing,
            onScaleChange: { scale in zoomState.reportScale(scale) },
            onMagnifierChange: { active in zoomState.setMagnifierActive(active) }
        )
    }

    func makeNSView(context: Context) -> ClickablePDFView {
        let view = ClickablePDFView()
        configure(view, coordinator: context.coordinator)
        if mode == .insertion { view.clearSelection() }
        view.document = document
        view.minScaleFactor = PDFZoomState.minimumScale
        view.maxScaleFactor = PDFZoomState.maximumScale
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = NihoPalette.pdfStageNSColor
        view.autoScales = false
        view.scaleChangeHandler = context.coordinator.handleScaleChange
        view.magnifierChangeHandler = context.coordinator.handleMagnifierChange
        view.startObservingScaleChanges()
        view.applyZoomCommand(.fitPage)
        view.appliedZoomCommandRevision = zoomState.commandRevision
        view.scaleChangeHandler?(view.scaleFactor)
        return view
    }

    func updateNSView(_ view: ClickablePDFView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.onInsertion = onInsertion
        context.coordinator.onMoveInsertion = onMoveInsertion
        context.coordinator.onMoveSelection = onMoveSelection
        context.coordinator.onMoveExistingEdit = onMoveExistingEdit
        context.coordinator.onBeginInlineEditing = onBeginInlineEditing
        context.coordinator.onChangeInlineText = onChangeInlineText
        context.coordinator.onCommitInlineEditing = onCommitInlineEditing
        context.coordinator.onCancelInlineEditing = onCancelInlineEditing
        view.scaleChangeHandler = context.coordinator.handleScaleChange
        view.magnifierChangeHandler = context.coordinator.handleMagnifierChange
        configure(view, coordinator: context.coordinator)
        if view.document !== document {
            view.resetFitMode()
            view.setMagnifierActive(false)
            view.document = document
            view.autoScales = false
            view.applyZoomCommand(.fitPage)
            view.appliedZoomCommandRevision = zoomState.commandRevision
        }
        if view.magnifierIsActive != zoomState.magnifierIsActive {
            view.setMagnifierActive(zoomState.magnifierIsActive)
        }
        if view.appliedZoomCommandRevision != zoomState.commandRevision {
            view.applyZoomCommand(zoomState.command)
            view.appliedZoomCommandRevision = zoomState.commandRevision
        }
        view.selectedTextTarget = selectedTarget
        view.syncInlineEditor(isEditing: isInlineEditing)
        if selectedTarget == nil {
            view.clearReplacementHighlight()
        }
        _ = revision
        view.layoutDocumentView()
        zoomState.reportScale(view.scaleFactor)
        view.window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }

    private func configure(_ view: ClickablePDFView, coordinator: Coordinator) {
        view.editorMode = mode
        view.selectionHandler = coordinator.handleSelection
        view.insertionHandler = coordinator.handleInsertion
        view.moveInsertionHandler = coordinator.handleMoveInsertion
        view.moveSelectionHandler = coordinator.handleMoveSelection
        view.moveExistingEditHandler = coordinator.handleMoveExistingEdit
        view.beginInlineEditingHandler = coordinator.handleBeginInlineEditing
        view.changeInlineTextHandler = coordinator.handleChangeInlineText
        view.commitInlineEditingHandler = coordinator.handleCommitInlineEditing
        view.cancelInlineEditingHandler = coordinator.handleCancelInlineEditing
    }

    final class Coordinator {
        var onSelection: (TextTarget?) -> Void
        var onInsertion: (Int, CGPoint) -> Void
        var onMoveInsertion: (String, Int, CGRect) -> Void
        var onMoveSelection: (CGPoint) -> Void
        var onMoveExistingEdit: (UUID, CGPoint) -> Void
        var onBeginInlineEditing: () -> Void
        var onChangeInlineText: (String) -> Void
        var onCommitInlineEditing: () -> Void
        var onCancelInlineEditing: () -> Void
        private let onScaleChange: (CGFloat) -> Void
        private let onMagnifierChange: (Bool) -> Void

        init(
            onSelection: @escaping (TextTarget?) -> Void,
            onInsertion: @escaping (Int, CGPoint) -> Void,
            onMoveInsertion: @escaping (String, Int, CGRect) -> Void,
            onMoveSelection: @escaping (CGPoint) -> Void,
            onMoveExistingEdit: @escaping (UUID, CGPoint) -> Void,
            onBeginInlineEditing: @escaping () -> Void,
            onChangeInlineText: @escaping (String) -> Void,
            onCommitInlineEditing: @escaping () -> Void,
            onCancelInlineEditing: @escaping () -> Void,
            onScaleChange: @escaping (CGFloat) -> Void,
            onMagnifierChange: @escaping (Bool) -> Void
        ) {
            self.onSelection = onSelection
            self.onInsertion = onInsertion
            self.onMoveInsertion = onMoveInsertion
            self.onMoveSelection = onMoveSelection
            self.onMoveExistingEdit = onMoveExistingEdit
            self.onBeginInlineEditing = onBeginInlineEditing
            self.onChangeInlineText = onChangeInlineText
            self.onCommitInlineEditing = onCommitInlineEditing
            self.onCancelInlineEditing = onCancelInlineEditing
            self.onScaleChange = onScaleChange
            self.onMagnifierChange = onMagnifierChange
        }

        func handleSelection(_ target: TextTarget?) { onSelection(target) }
        func handleInsertion(_ pageIndex: Int, _ point: CGPoint) { onInsertion(pageIndex, point) }
        func handleScaleChange(_ scale: CGFloat) { onScaleChange(scale) }
        func handleMagnifierChange(_ active: Bool) { onMagnifierChange(active) }
        func handleMoveInsertion(_ marker: String, _ pageIndex: Int, _ bounds: CGRect) {
            onMoveInsertion(marker, pageIndex, bounds)
        }
        func handleMoveSelection(_ delta: CGPoint) { onMoveSelection(delta) }
        func handleMoveExistingEdit(_ id: UUID, _ delta: CGPoint) { onMoveExistingEdit(id, delta) }
        func handleBeginInlineEditing() { onBeginInlineEditing() }
        func handleChangeInlineText(_ text: String) { onChangeInlineText(text) }
        func handleCommitInlineEditing() { onCommitInlineEditing() }
        func handleCancelInlineEditing() { onCancelInlineEditing() }
    }
}

final class ClickablePDFView: PDFView, NSTextFieldDelegate {
    var editorMode: EditorMode = .replacement
    var selectionHandler: ((TextTarget?) -> Void)?
    var insertionHandler: ((Int, CGPoint) -> Void)?
    var moveInsertionHandler: ((String, Int, CGRect) -> Void)?
    var moveSelectionHandler: ((CGPoint) -> Void)?
    var moveExistingEditHandler: ((UUID, CGPoint) -> Void)?
    var beginInlineEditingHandler: (() -> Void)?
    var changeInlineTextHandler: ((String) -> Void)?
    var commitInlineEditingHandler: (() -> Void)?
    var cancelInlineEditingHandler: (() -> Void)?
    var selectedTextTarget: TextTarget?
    private var inlineField: NSTextField?
    private var movingSelectionTarget: TextTarget?
    private var movingExistingEdit: ReplacementEdit?
    private var movementStartPoint = CGPoint.zero
    private var movementDelta = CGPoint.zero
    var scaleChangeHandler: ((CGFloat) -> Void)?
    var magnifierChangeHandler: ((Bool) -> Void)?
    private(set) var magnifierIsActive = false
    var appliedZoomCommandRevision = 0

    private var scaleObserver: NSObjectProtocol?
    private var magnifierTrackingArea: NSTrackingArea?
    private var magnifierPoint: CGPoint?
    private var fitsWidthOnResize = false
    private var fitsPageOnResize = false
    private let magnifierDiameter: CGFloat = 164
    private let magnifierFactor: CGFloat = 2.5

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

    override var acceptsFirstResponder: Bool { true }

    deinit {
        MainActor.assumeIsolated {
            if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMagnifier()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let magnifierTrackingArea { removeTrackingArea(magnifierTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        magnifierTrackingArea = trackingArea
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard fitsWidthOnResize || fitsPageOnResize else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.fitsPageOnResize {
                self.updateFitPageScale()
            } else if self.fitsWidthOnResize {
                self.updateFitWidthScale()
            }
        }
    }

    func startObservingScaleChanges() {
        if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
        scaleObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scaleChangeHandler?(self.scaleFactor)
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard magnifierIsActive else { return }
        magnifierPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        magnifierPoint = nil
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setScale(scaleFactor * max(0.1, 1 + event.magnification), anchoredAt: point)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        guard delta != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        setScale(scaleFactor * pow(1.1, -delta / 90), anchoredAt: point)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, magnifierIsActive {
            setMagnifierActive(false)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=":
            setScale(scaleFactor * 1.2, anchoredAt: visibleRect.center)
        case "-":
            setScale(scaleFactor / 1.2, anchoredAt: visibleRect.center)
        case "0":
            applyZoomCommand(.actualSize)
        default:
            super.keyDown(with: event)
        }
    }

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
            if let edit = movingExistingEdit,
               let page = document?.page(at: edit.pageIndex) {
                let viewPoint = convert(event.locationInWindow, from: nil)
                let pagePoint = convert(viewPoint, to: page)
                movementDelta = CGPoint(x: pagePoint.x - movementStartPoint.x, y: pagePoint.y - movementStartPoint.y)
                showHighlight(bounds: edit.displayedTextBounds.offsetBy(dx: movementDelta.x, dy: movementDelta.y), on: page)
                return
            }
            if let target = movingSelectionTarget,
               let page = document?.page(at: target.pageIndex) {
                let viewPoint = convert(event.locationInWindow, from: nil)
                let pagePoint = convert(viewPoint, to: page)
                movementDelta = CGPoint(x: pagePoint.x - movementStartPoint.x, y: pagePoint.y - movementStartPoint.y)
                showHighlight(bounds: target.bounds.offsetBy(dx: movementDelta.x, dy: movementDelta.y), on: page)
                return
            }
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
            if let edit = movingExistingEdit {
                if hypot(movementDelta.x, movementDelta.y) > 0.5 {
                    moveExistingEditHandler?(edit.id, movementDelta)
                }
                movingExistingEdit = nil
                movementDelta = .zero
                return
            }
            if movingSelectionTarget != nil {
                if hypot(movementDelta.x, movementDelta.y) > 0.5 {
                    moveSelectionHandler?(movementDelta)
                }
                movingSelectionTarget = nil
                movementDelta = .zero
                return
            }
            if inlineField != nil { return }
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

    func syncInlineEditor(isEditing: Bool) {
        if !isEditing {
            inlineField?.removeFromSuperview()
            inlineField = nil
        } else if inlineField == nil, let selectedTextTarget {
            showInlineEditor(for: selectedTextTarget)
        }
    }

    private func showInlineEditor(for target: TextTarget) {
        guard inlineField == nil else { return }
        guard let page = document?.page(at: target.pageIndex), let container = documentView else { return }
        let pageRect = container.convert(convert(target.bounds, from: page), from: self)
        let field = NSTextField()
        field.delegate = self
        field.stringValue = target.originalText
        field.isBezeled = true
        field.isEditable = true
        field.drawsBackground = true
        field.backgroundColor = .white
        field.textColor = target.fontColor
        field.font = NSFont(name: "Noto Sans JP", size: max(13, pageRect.height * 0.82))
            ?? NSFont.systemFont(ofSize: max(13, pageRect.height * 0.82))
        field.focusRingType = .none
        field.cell?.lineBreakMode = .byClipping
        let measuredWidth = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width
        let width = min(max(pageRect.width + 18, measuredWidth + 24, 90), max(container.bounds.maxX - pageRect.minX - 8, 90))
        field.frame = CGRect(x: pageRect.minX - 5, y: pageRect.minY - 4,
                             width: width, height: max(pageRect.height + 10, 25))
        container.addSubview(field)
        inlineField = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        changeInlineTextHandler?(field.stringValue)
        let measuredWidth = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width + 28
        let available = max(field.superview?.bounds.maxX ?? bounds.maxX, field.frame.maxX)
        field.frame.size.width = min(max(field.frame.width, measuredWidth), max(available - field.frame.minX - 8, 90))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            changeInlineTextHandler?((control as? NSTextField)?.stringValue ?? "")
            commitInlineEditingHandler?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineEditingHandler?()
            return true
        }
        return false
    }

    func setMagnifierActive(_ active: Bool) {
        guard magnifierIsActive != active else { return }
        magnifierIsActive = active
        if active {
            window?.makeFirstResponder(self)
        } else {
            magnifierPoint = nil
        }
        magnifierChangeHandler?(active)
        needsDisplay = true
    }

    func applyZoomCommand(_ command: PDFZoomCommand) {
        switch command {
        case .zoomIn:
            setScale(scaleFactor * 1.2, anchoredAt: visibleRect.center)
        case .zoomOut:
            setScale(scaleFactor / 1.2, anchoredAt: visibleRect.center)
        case .fitPage:
            fitsWidthOnResize = false
            fitsPageOnResize = true
            updateFitPageScale()
        case .fitWidth:
            fitsWidthOnResize = true
            fitsPageOnResize = false
            updateFitWidthScale()
        case .actualSize:
            setScale(1, anchoredAt: visibleRect.center)
        case .setScale(let value):
            setScale(value, anchoredAt: visibleRect.center)
        }
    }

    func resetFitMode() {
        fitsWidthOnResize = false
        fitsPageOnResize = false
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
        if let existing = page.annotations.reversed().compactMap({ $0 as? ReplacementTextAnnotation })
            .first(where: { !$0.edit.replacement.isEmpty && $0.edit.displayedTextBounds.contains(pagePoint) }) {
            movingExistingEdit = existing.edit
            movementStartPoint = pagePoint
            movementDelta = .zero
            return
        }
        if let selectedTextTarget,
           selectedTextTarget.pageIndex == document.index(for: page),
           selectedTextTarget.bounds.contains(pagePoint) {
            if event.clickCount >= 2 {
                beginInlineEditingHandler?()
                showInlineEditor(for: selectedTextTarget)
                return
            }
            movingSelectionTarget = selectedTextTarget
            movementStartPoint = pagePoint
            movementDelta = .zero
            return
        }
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
        annotation.interiorColor = NihoPalette.selectionNSColor
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        page.addAnnotation(annotation)
        highlightAnnotation = annotation
        highlightPage = page
    }

    private func setScale(
        _ requestedScale: CGFloat,
        anchoredAt viewPoint: CGPoint,
        preservingFitMode: Bool = false
    ) {
        if !preservingFitMode { resetFitMode() }
        let targetScale = PDFZoomState.clampedScale(requestedScale)
        guard abs(targetScale - scaleFactor) > 0.001 else { return }

        let page = page(for: viewPoint, nearest: true)
        let anchorInPage = page.map { convert(viewPoint, to: $0) }
        // PDFKit hosts its document view in an internal scroll view; PDFView itself
        // is an NSView, so `enclosingScrollView` is nil for this hierarchy.
        let scrollView = subviews.first(where: { $0 is NSScrollView }) as? NSScrollView
        let clipView = scrollView?.contentView
        let documentView = scrollView?.documentView

        autoScales = false
        scaleFactor = targetScale
        layoutDocumentView()

        if let page, let anchorInPage, let clipView, let documentView {
            let scaledPointInView = convert(anchorInPage, from: page)
            let anchorInDocument = documentView.convert(scaledPointInView, from: self)
            let cursorInDocument = documentView.convert(viewPoint, from: self)
            let delta = CGPoint(
                x: anchorInDocument.x - cursorInDocument.x,
                y: anchorInDocument.y - cursorInDocument.y
            )
            clipView.scroll(to: CGPoint(
                x: clipView.bounds.origin.x + delta.x,
                y: clipView.bounds.origin.y + delta.y
            ))
            scrollView?.reflectScrolledClipView(clipView)
        }
        scaleChangeHandler?(scaleFactor)
        needsDisplay = true
    }

    private func updateFitWidthScale() {
        guard let page = currentPage ?? document?.page(at: 0) else { return }
        let pageWidth = displaySize(of: page).width
        guard pageWidth > 0 else { return }
        autoScales = false
        setScale(max(bounds.width - 32, 1) / pageWidth, anchoredAt: visibleRect.center, preservingFitMode: true)
    }

    private func updateFitPageScale() {
        guard let page = currentPage ?? document?.page(at: 0) else { return }
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return }
        let availableWidth = max(bounds.width - 32, 1)
        let availableHeight = max(bounds.height - 32, 1)
        let scale = min(availableWidth / size.width, availableHeight / size.height)
        autoScales = false
        setScale(scale, anchoredAt: visibleRect.center, preservingFitMode: true)
    }

    private func displaySize(of page: PDFPage) -> CGSize {
        let pageBounds = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return CGSize(width: pageBounds.height, height: pageBounds.width)
        }
        return pageBounds.size
    }

    private func drawMagnifier() {
        guard magnifierIsActive,
              let mousePoint = magnifierPoint,
              let page = page(for: mousePoint, nearest: false),
              let context = NSGraphicsContext.current?.cgContext else { return }

        let pagePoint = convert(mousePoint, to: page)
        let drawingPoint = pagePoint.applying(page.transform(for: .cropBox))
        let size = magnifierDiameter
        var origin = CGPoint(x: mousePoint.x + 20, y: mousePoint.y - size - 20)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size - 8)
        let lens = CGRect(origin: origin, size: CGSize(width: size, height: size))

        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.addEllipse(in: lens)
        context.fillPath()
        context.addEllipse(in: lens)
        context.clip()
        let pageScale = scaleFactor * magnifierFactor
        context.translateBy(x: lens.midX - drawingPoint.x * pageScale, y: lens.midY - drawingPoint.y * pageScale)
        context.scaleBy(x: pageScale, y: pageScale)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()

        context.saveGState()
        context.addEllipse(in: lens.insetBy(dx: 1.5, dy: 1.5))
        context.setStrokeColor(NSColor(NihoPalette.green).cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.restoreGState()

        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: lens.midX - 7, y: lens.midY))
        crosshair.line(to: CGPoint(x: lens.midX + 7, y: lens.midY))
        crosshair.move(to: CGPoint(x: lens.midX, y: lens.midY - 7))
        crosshair.line(to: CGPoint(x: lens.midX, y: lens.midY + 7))
        NSColor(NihoPalette.green).withAlphaComponent(0.75).setStroke()
        crosshair.lineWidth = 1
        crosshair.stroke()
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
