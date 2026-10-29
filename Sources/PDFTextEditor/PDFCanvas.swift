import AppKit
import CoreText
import PDFKit
import SwiftUI

struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let revision: Int
    let mode: EditorMode
    let markupTool: PDFMarkupTool
    let selectedTarget: TextTarget?
    let redactionRegions: [PDFRedactionRegion]
    let selectedMarkupID: UUID?
    let highlightedSearchSelections: [PDFSelection]
    let focusedSearchSelection: PDFSelection?
    let searchHighlightRevision: Int
    let searchNavigationRevision: Int
    let isInlineEditing: Bool
    @ObservedObject var zoomState: PDFZoomState
    let onSelection: (TextTarget?) -> Void
    let onInsertion: (Int, CGPoint) -> Void
    let onMoveInsertion: (String, Int, CGRect) -> Void
    let onBeginExistingInsertionEditing: (UUID) -> Void
    let onMoveSelection: (CGPoint) -> Void
    let onMoveExistingEdit: (UUID, CGPoint) -> Void
    let onBeginExistingReplacementEditing: (UUID) -> Void
    let onMarkupCreate: (Int, CGRect, [CGPoint]) -> Void
    let onRedactionRegion: (Int, CGRect) -> Void
    let onSelectMarkup: (UUID?) -> Void
    let onMoveMarkup: (UUID, CGRect) -> Void
    let onBeginInlineEditing: () -> Void
    let onChangeInlineText: (String) -> Void
    let onCommitInlineEditing: () -> Void
    let onCancelInlineEditing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            onInsertion: onInsertion,
            onMoveInsertion: onMoveInsertion,
            onBeginExistingInsertionEditing: onBeginExistingInsertionEditing,
            onMoveSelection: onMoveSelection,
            onMoveExistingEdit: onMoveExistingEdit,
            onBeginExistingReplacementEditing: onBeginExistingReplacementEditing,
            onMarkupCreate: onMarkupCreate,
            onRedactionRegion: onRedactionRegion,
            onSelectMarkup: onSelectMarkup,
            onMoveMarkup: onMoveMarkup,
            onBeginInlineEditing: onBeginInlineEditing,
            onChangeInlineText: onChangeInlineText,
            onCommitInlineEditing: onCommitInlineEditing,
            onCancelInlineEditing: onCancelInlineEditing,
            onScaleChange: { scale in zoomState.reportScale(scale) },
            onMagnifierChange: { active in zoomState.setMagnifierActive(active) },
            onPageChange: { index, count in zoomState.reportPage(index: index, count: count) }
        )
    }

    func makeNSView(context: Context) -> ClickablePDFView {
        let view = ClickablePDFView()
        configure(view, coordinator: context.coordinator)
        let replacementOverlayProvider = ReplacementPreviewOverlayProvider()
        view.replacementOverlayProvider = replacementOverlayProvider
        view.pageOverlayViewProvider = replacementOverlayProvider
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
        view.disableNativeMagnification()
        view.scaleChangeHandler = context.coordinator.handleScaleChange
        view.magnifierChangeHandler = context.coordinator.handleMagnifierChange
        view.startObservingScaleChanges()
        view.pageChangeHandler = context.coordinator.handlePageChange
        view.startObservingPageChanges()
        view.applyZoomCommand(.fitPage)
        view.appliedZoomCommandRevision = zoomState.commandRevision
        view.reportCurrentPageLater()
        view.syncRedactionPreviews(regions: redactionRegions, mode: mode)
        view.scaleChangeHandler?(view.scaleFactor)
        return view
    }

    func updateNSView(_ view: ClickablePDFView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.onInsertion = onInsertion
        context.coordinator.onMoveInsertion = onMoveInsertion
        context.coordinator.onBeginExistingInsertionEditing = onBeginExistingInsertionEditing
        context.coordinator.onMoveSelection = onMoveSelection
        context.coordinator.onMoveExistingEdit = onMoveExistingEdit
        context.coordinator.onBeginExistingReplacementEditing = onBeginExistingReplacementEditing
        context.coordinator.onMarkupCreate = onMarkupCreate
        context.coordinator.onRedactionRegion = onRedactionRegion
        context.coordinator.onSelectMarkup = onSelectMarkup
        context.coordinator.onMoveMarkup = onMoveMarkup
        context.coordinator.onBeginInlineEditing = onBeginInlineEditing
        context.coordinator.onChangeInlineText = onChangeInlineText
        context.coordinator.onCommitInlineEditing = onCommitInlineEditing
        context.coordinator.onCancelInlineEditing = onCancelInlineEditing
        view.scaleChangeHandler = context.coordinator.handleScaleChange
        view.magnifierChangeHandler = context.coordinator.handleMagnifierChange
        view.pageChangeHandler = context.coordinator.handlePageChange
        configure(view, coordinator: context.coordinator)
        view.markupTool = markupTool
        if view.document !== document {
            view.resetFitMode()
            view.setMagnifierActive(false)
            view.document = document
            view.autoScales = false
            view.disableNativeMagnification()
            view.applyZoomCommand(.fitPage)
            view.appliedZoomCommandRevision = zoomState.commandRevision
            view.reportCurrentPageLater()
        }
        if view.magnifierIsActive != zoomState.magnifierIsActive {
            view.setMagnifierActive(zoomState.magnifierIsActive)
        }
        if view.appliedZoomCommandRevision != zoomState.commandRevision {
            view.applyZoomCommand(zoomState.command)
            view.appliedZoomCommandRevision = zoomState.commandRevision
        }
        if view.searchHighlightRevision != searchHighlightRevision {
            view.highlightedSelections = highlightedSearchSelections.isEmpty ? nil : highlightedSearchSelections
            view.searchHighlightRevision = searchHighlightRevision
        }
        if view.searchNavigationRevision != searchNavigationRevision {
            if let focusedSearchSelection {
                view.go(to: focusedSearchSelection)
                view.setCurrentSelection(focusedSearchSelection, animate: true)
            }
            view.searchNavigationRevision = searchNavigationRevision
        }
        view.selectedTextTarget = selectedTarget
        view.syncRedactionPreviews(regions: redactionRegions, mode: mode)
        view.replacementOverlayProvider?.invalidate(revision: revision)
        view.selectedMarkupID = selectedMarkupID
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
        view.markupTool = markupTool
        view.selectionHandler = coordinator.handleSelection
        view.insertionHandler = coordinator.handleInsertion
        view.moveInsertionHandler = coordinator.handleMoveInsertion
        view.beginExistingInsertionEditingHandler = coordinator.handleBeginExistingInsertionEditing
        view.moveSelectionHandler = coordinator.handleMoveSelection
        view.moveExistingEditHandler = coordinator.handleMoveExistingEdit
        view.beginExistingReplacementEditingHandler = coordinator.handleBeginExistingReplacementEditing
        view.markupCreateHandler = coordinator.handleMarkupCreate
        view.redactionRegionHandler = coordinator.handleRedactionRegion
        view.selectMarkupHandler = coordinator.handleSelectMarkup
        view.moveMarkupHandler = coordinator.handleMoveMarkup
        view.beginInlineEditingHandler = coordinator.handleBeginInlineEditing
        view.changeInlineTextHandler = coordinator.handleChangeInlineText
        view.commitInlineEditingHandler = coordinator.handleCommitInlineEditing
        view.cancelInlineEditingHandler = coordinator.handleCancelInlineEditing
    }

    final class Coordinator {
        var onSelection: (TextTarget?) -> Void
        var onInsertion: (Int, CGPoint) -> Void
        var onMoveInsertion: (String, Int, CGRect) -> Void
        var onBeginExistingInsertionEditing: (UUID) -> Void
        var onMoveSelection: (CGPoint) -> Void
        var onMoveExistingEdit: (UUID, CGPoint) -> Void
        var onBeginExistingReplacementEditing: (UUID) -> Void
        var onMarkupCreate: (Int, CGRect, [CGPoint]) -> Void
        var onRedactionRegion: (Int, CGRect) -> Void
        var onSelectMarkup: (UUID?) -> Void
        var onMoveMarkup: (UUID, CGRect) -> Void
        var onBeginInlineEditing: () -> Void
        var onChangeInlineText: (String) -> Void
        var onCommitInlineEditing: () -> Void
        var onCancelInlineEditing: () -> Void
        private let onScaleChange: (CGFloat) -> Void
        private let onMagnifierChange: (Bool) -> Void
        private let onPageChange: (Int, Int) -> Void

        init(
            onSelection: @escaping (TextTarget?) -> Void,
            onInsertion: @escaping (Int, CGPoint) -> Void,
            onMoveInsertion: @escaping (String, Int, CGRect) -> Void,
            onBeginExistingInsertionEditing: @escaping (UUID) -> Void,
            onMoveSelection: @escaping (CGPoint) -> Void,
            onMoveExistingEdit: @escaping (UUID, CGPoint) -> Void,
            onBeginExistingReplacementEditing: @escaping (UUID) -> Void,
            onMarkupCreate: @escaping (Int, CGRect, [CGPoint]) -> Void,
            onRedactionRegion: @escaping (Int, CGRect) -> Void,
            onSelectMarkup: @escaping (UUID?) -> Void,
            onMoveMarkup: @escaping (UUID, CGRect) -> Void,
            onBeginInlineEditing: @escaping () -> Void,
            onChangeInlineText: @escaping (String) -> Void,
            onCommitInlineEditing: @escaping () -> Void,
            onCancelInlineEditing: @escaping () -> Void,
            onScaleChange: @escaping (CGFloat) -> Void,
            onMagnifierChange: @escaping (Bool) -> Void,
            onPageChange: @escaping (Int, Int) -> Void
        ) {
            self.onSelection = onSelection
            self.onInsertion = onInsertion
            self.onMoveInsertion = onMoveInsertion
            self.onBeginExistingInsertionEditing = onBeginExistingInsertionEditing
            self.onMoveSelection = onMoveSelection
            self.onMoveExistingEdit = onMoveExistingEdit
            self.onBeginExistingReplacementEditing = onBeginExistingReplacementEditing
            self.onMarkupCreate = onMarkupCreate
            self.onRedactionRegion = onRedactionRegion
            self.onSelectMarkup = onSelectMarkup
            self.onMoveMarkup = onMoveMarkup
            self.onBeginInlineEditing = onBeginInlineEditing
            self.onChangeInlineText = onChangeInlineText
            self.onCommitInlineEditing = onCommitInlineEditing
            self.onCancelInlineEditing = onCancelInlineEditing
            self.onScaleChange = onScaleChange
            self.onMagnifierChange = onMagnifierChange
            self.onPageChange = onPageChange
        }

        func handleSelection(_ target: TextTarget?) { onSelection(target) }
        func handleInsertion(_ pageIndex: Int, _ point: CGPoint) { onInsertion(pageIndex, point) }
        func handleScaleChange(_ scale: CGFloat) { onScaleChange(scale) }
        func handleMagnifierChange(_ active: Bool) { onMagnifierChange(active) }
        /// 表示中のページ（0 始まり）と総ページ数を上のバーのページ送りへ渡す。
        func handlePageChange(_ index: Int, _ count: Int) { onPageChange(index, count) }
        func handleMoveInsertion(_ marker: String, _ pageIndex: Int, _ bounds: CGRect) {
            onMoveInsertion(marker, pageIndex, bounds)
        }
        func handleBeginExistingInsertionEditing(_ id: UUID) {
            onBeginExistingInsertionEditing(id)
        }
        func handleMoveSelection(_ delta: CGPoint) { onMoveSelection(delta) }
        func handleMoveExistingEdit(_ id: UUID, _ delta: CGPoint) { onMoveExistingEdit(id, delta) }
        func handleBeginExistingReplacementEditing(_ id: UUID) { onBeginExistingReplacementEditing(id) }
        func handleMarkupCreate(_ pageIndex: Int, _ bounds: CGRect, _ points: [CGPoint]) {
            onMarkupCreate(pageIndex, bounds, points)
        }
        func handleRedactionRegion(_ pageIndex: Int, _ bounds: CGRect) {
            onRedactionRegion(pageIndex, bounds)
        }
        func handleSelectMarkup(_ id: UUID?) { onSelectMarkup(id) }
        func handleMoveMarkup(_ id: UUID, _ bounds: CGRect) { onMoveMarkup(id, bounds) }
        func handleBeginInlineEditing() { onBeginInlineEditing() }
        func handleChangeInlineText(_ text: String) { onChangeInlineText(text) }
        func handleCommitInlineEditing() { onCommitInlineEditing() }
        func handleCancelInlineEditing() { onCancelInlineEditing() }
    }
}

final class ClickablePDFView: PDFView, NSTextFieldDelegate {
    enum ZoomGestureKind: Equatable {
        case magnify
        case modifiedScroll
    }

    static func shouldZoomOnScroll(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.command) || modifierFlags.contains(.control)
    }

    static func zoomGestureKind(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        pointerInsidePDF: Bool
    ) -> ZoomGestureKind? {
        guard pointerInsidePDF else { return nil }
        switch eventType {
        case .magnify:
            return .magnify
        case .scrollWheel where shouldZoomOnScroll(modifierFlags: modifierFlags):
            return .modifiedScroll
        default:
            return nil
        }
    }

    static func zoomMultiplier(forScrollDelta delta: CGFloat) -> CGFloat {
        pow(1.1, -delta / 90)
    }

    static func inlineEditorRequiredHeight(for field: NSTextField) -> CGFloat {
        ceil(max(field.cell?.cellSize.height ?? 0, field.intrinsicContentSize.height)) + 2
    }

    static func inlineEditorFrame(
        pageRect: CGRect,
        measuredTextWidth: CGFloat,
        requiredFieldHeight: CGFloat,
        containerBounds: CGRect
    ) -> CGRect {
        let pageRect = pageRect.standardized
        let x = max(pageRect.minX - 5, containerBounds.minX + 4)
        let availableWidth = max(containerBounds.maxX - x - 8, 90)
        let width = min(
            max(pageRect.width + 18, measuredTextWidth + 24, 90),
            availableWidth
        )
        let height = max(pageRect.height + 10, requiredFieldHeight, 25)
        let centeredY = pageRect.midY - height / 2
        let minimumY = containerBounds.minY + 4
        let maximumY = containerBounds.maxY - height - 4
        let y = maximumY >= minimumY
            ? min(max(centeredY, minimumY), maximumY)
            : centeredY
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var replacementOverlayProvider: ReplacementPreviewOverlayProvider?
    var editorMode: EditorMode = .replacement
    var markupTool: PDFMarkupTool = .highlight
    var selectedMarkupID: UUID?
    var selectionHandler: ((TextTarget?) -> Void)?
    var insertionHandler: ((Int, CGPoint) -> Void)?
    var moveInsertionHandler: ((String, Int, CGRect) -> Void)?
    var beginExistingInsertionEditingHandler: ((UUID) -> Void)?
    var moveSelectionHandler: ((CGPoint) -> Void)?
    var moveExistingEditHandler: ((UUID, CGPoint) -> Void)?
    var beginExistingReplacementEditingHandler: ((UUID) -> Void)?
    var markupCreateHandler: ((Int, CGRect, [CGPoint]) -> Void)?
    var redactionRegionHandler: ((Int, CGRect) -> Void)?
    var selectMarkupHandler: ((UUID?) -> Void)?
    var moveMarkupHandler: ((UUID, CGRect) -> Void)?
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
    var pageChangeHandler: ((Int, Int) -> Void)?
    private(set) var magnifierIsActive = false
    var appliedZoomCommandRevision = 0

    private var scaleObserver: NSObjectProtocol?
    private var zoomGestureMonitor: Any?
    private var pageObserver: NSObjectProtocol?
    private var magnifierTrackingArea: NSTrackingArea?
    private var magnifierPoint: CGPoint?
    private var fitsWidthOnResize = false
    private var fitsPageOnResize = false
    var searchHighlightRevision = -1
    var searchNavigationRevision = -1
    private let magnifierDiameter: CGFloat = 164
    private let magnifierFactor: CGFloat = 2.5

    private var draggedAnnotation: PDFAnnotation?
    private weak var draggedPage: PDFPage?
    private var dragStartPoint = CGPoint.zero
    private var dragStartBounds = CGRect.zero
    private var redactionPreviewRegions: [PDFRedactionRegion] = []
    private var redactionPreviewMode: EditorMode?
    private var redactionPreviewAnnotations: [PDFAnnotation] = []
    private weak var redactionDrawingPage: PDFPage?
    private var redactionDrawingPageIndex: Int?
    private var redactionDrawingStart = CGPoint.zero
    private var redactionDrawingDidMove = false
    private var redactionDrawingAnnotation: PDFAnnotation?
    private var draggedMarkupID: UUID?
    private var resizingMarkup = false
    private var markupDidMove = false
    private var markupDrawingPage: PDFPage?
    private var markupDrawingPageIndex: Int?
    private var markupDrawingStart = CGPoint.zero
    private var markupDrawingPoints: [CGPoint] = []
    private var markupPreviewAnnotation: PDFAnnotation?

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
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            if let zoomGestureMonitor { NSEvent.removeMonitor(zoomGestureMonitor) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disableNativeMagnification()
        if let zoomGestureMonitor {
            NSEvent.removeMonitor(zoomGestureMonitor)
            self.zoomGestureMonitor = nil
        }
        guard window != nil else { return }

        // PDFKit routes wheel and magnification events through its internal PDFScrollView,
        // bypassing PDFView's responder methods. Keep one owner for zoom gestures so the
        // native scroll-view magnification cannot fight the app's PDF scale and snap back.
        zoomGestureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify]
        ) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard let gesture = Self.zoomGestureKind(
                eventType: event.type,
                modifierFlags: event.modifierFlags,
                pointerInsidePDF: self.bounds.contains(point)
            ) else { return event }
            switch gesture {
            case .magnify:
                self.zoom(forMagnify: event)
                return nil
            case .modifiedScroll:
                return self.zoom(forScrollWheel: event) ? nil : event
            }
        }
    }

    func disableNativeMagnification() {
        let scrollView = subviews.first(where: { $0 is NSScrollView }) as? NSScrollView
        scrollView?.allowsMagnification = false
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

    func startObservingPageChanges() {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reportCurrentPage()
            }
        }
    }

    /// SwiftUI の更新中に状態を変えないよう、表示中のページは次の周回で知らせる。
    func reportCurrentPageLater() {
        Task { @MainActor [weak self] in
            self?.reportCurrentPage()
        }
    }

    private func reportCurrentPage() {
        guard let document else {
            pageChangeHandler?(0, 0)
            return
        }
        var index = currentPage.map { document.index(for: $0) } ?? 0
        if index == NSNotFound || index < 0 { index = 0 }
        pageChangeHandler?(index, document.pageCount)
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

    private func zoom(forMagnify event: NSEvent) {
        guard event.magnification != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        setScale(scaleFactor * max(0.1, 1 + event.magnification), anchoredAt: point)
    }

    @discardableResult
    private func zoom(forScrollWheel event: NSEvent) -> Bool {
        guard Self.shouldZoomOnScroll(modifierFlags: event.modifierFlags) else { return false }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        guard delta != 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        setScale(scaleFactor * Self.zoomMultiplier(forScrollDelta: delta), anchoredAt: point)
        return true
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

    override func copy(_ sender: Any?) {
        if let text = selectedTextTarget?.originalText, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else {
            super.copy(sender)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if editorMode == .insertion || editorMode == .markup || editorMode == .redaction {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if editorMode == .redaction {
            handleRedactionMouseDown(event)
            return
        }
        if editorMode == .insertion {
            handleInsertionMouseDown(event)
            return
        }
        if editorMode == .markup {
            if handleMarkupMouseDown(event) { return }
            if markupTool.isTextMarkup {
                handleReplacementMouseDown(event, allowMovingExistingContent: false)
            }
            return
        }
        handleReplacementMouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if editorMode == .redaction {
            handleRedactionMouseDragged(event)
            return
        }
        if editorMode == .markup && markupTool.isTextMarkup && draggedMarkupID == nil {
            handleReplacementMouseDragged(event)
            return
        }
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
        if editorMode == .markup, let page = markupDrawingPage {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let pagePoint = PDFMarkupEngine.clampedPoint(
                convert(viewPoint, to: page),
                to: page.bounds(for: .mediaBox)
            )
            let points: [CGPoint]
            if markupTool == .ink {
                markupDrawingPoints.append(pagePoint)
                points = markupDrawingPoints
            } else {
                points = [markupDrawingStart, pagePoint]
            }
            updateMarkupPreview(on: page, points: points)
            return
        }
        guard let annotation = draggedAnnotation,
              let page = draggedPage else {
            super.mouseDragged(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let pagePoint = convert(viewPoint, to: page)
        if editorMode == .markup, let id = draggedMarkupID {
            var bounds = dragStartBounds
            let pageBounds = page.bounds(for: .mediaBox)
            if resizingMarkup {
                bounds.size.width = dragStartBounds.width + pagePoint.x - dragStartPoint.x
                bounds.size.height = dragStartBounds.height + pagePoint.y - dragStartPoint.y
                bounds = PDFMarkupEngine.clampedResizeBounds(
                    bounds,
                    anchoredAt: dragStartBounds.origin,
                    to: pageBounds,
                    minimumSize: CGSize(width: 8, height: 8)
                )
            } else {
                let delta = CGPoint(x: pagePoint.x - dragStartPoint.x, y: pagePoint.y - dragStartPoint.y)
                bounds.origin.x += delta.x
                bounds.origin.y += delta.y
                bounds = PDFMarkupEngine.clampedBounds(
                    bounds,
                    to: pageBounds,
                    minimumSize: CGSize(width: 8, height: 8)
                )
            }
            annotation.bounds = bounds
            markupDidMove = true
            needsDisplay = true
            _ = id
            return
        }
        let delta = CGPoint(x: pagePoint.x - dragStartPoint.x, y: pagePoint.y - dragStartPoint.y)
        var bounds = dragStartBounds.offsetBy(dx: delta.x, dy: delta.y)
        let pageBounds = page.bounds(for: .mediaBox)
        bounds.origin.x = min(max(bounds.minX, pageBounds.minX), max(pageBounds.maxX - bounds.width, pageBounds.minX))
        bounds.origin.y = min(max(bounds.minY, pageBounds.minY), max(pageBounds.maxY - bounds.height, pageBounds.minY))
        annotation.bounds = bounds
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if editorMode == .markup, let id = draggedMarkupID, let annotation = draggedAnnotation {
            if markupDidMove { moveMarkupHandler?(id, annotation.bounds) }
            draggedMarkupID = nil
            draggedAnnotation = nil
            draggedPage = nil
            resizingMarkup = false
            markupDidMove = false
            return
        }
        if editorMode == .redaction {
            if redactionDrawingDidMove,
               let pageIndex = redactionDrawingPageIndex,
               let bounds = redactionDrawingBounds(at: convert(event.locationInWindow, from: nil)) {
                clearRedactionDrawingPreview()
                selectionHandler?(nil)
                redactionRegionHandler?(pageIndex, bounds)
            } else {
                clearRedactionDrawingPreview()
                selectionHandler?(replacementDragTarget)
            }
            replacementDragTarget = nil
            replacementDragRun = nil
            replacementDragAnchorIndex = nil
            replacementDragPage = nil
            return
        }
        if editorMode == .markup, markupTool.isTextMarkup {
            if movingExistingEdit != nil || movingSelectionTarget != nil {
                movingExistingEdit = nil
                movingSelectionTarget = nil
                movementDelta = .zero
                return
            }
            if inlineField != nil { return }
            selectionHandler?(replacementDragTarget)
            replacementDragTarget = nil
            replacementDragRun = nil
            replacementDragAnchorIndex = nil
            replacementDragPage = nil
            return
        }
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
        if editorMode == .markup, let page = markupDrawingPage, let pageIndex = markupDrawingPageIndex {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let endPoint = PDFMarkupEngine.clampedPoint(
                convert(viewPoint, to: page),
                to: page.bounds(for: .mediaBox)
            )
            var points = markupTool == .ink ? markupDrawingPoints : [markupDrawingStart, endPoint]
            if markupTool == .ink, points.last != endPoint { points.append(endPoint) }
            if (markupTool == .arrow || markupTool == .ink),
               !PDFMarkupEngine.hasVisibleLineLength(points) {
                if let markupPreviewAnnotation { page.removeAnnotation(markupPreviewAnnotation) }
                markupPreviewAnnotation = nil
                markupDrawingPage = nil
                markupDrawingPageIndex = nil
                markupDrawingPoints = []
                needsDisplay = true
                return
            }
            let bounds = PDFMarkupEngine.clampedBounds(
                markupBounds(for: points, tool: markupTool),
                to: page.bounds(for: .mediaBox),
                minimumSize: CGSize(width: 8, height: 8)
            )
            if let markupPreviewAnnotation { page.removeAnnotation(markupPreviewAnnotation) }
            markupPreviewAnnotation = nil
            markupDrawingPage = nil
            markupDrawingPageIndex = nil
            markupDrawingPoints = []
            markupCreateHandler?(pageIndex, bounds, points)
            return
        }
        if let annotation = draggedAnnotation, let page = draggedPage {
            if annotation.bounds != dragStartBounds, let document {
                let marker = annotation.userName ?? PDFEditEngine.draftMarker
                moveInsertionHandler?(marker, document.index(for: page), annotation.bounds)
            }
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

    func syncRedactionPreviews(regions: [PDFRedactionRegion], mode: EditorMode) {
        guard redactionPreviewMode != mode || redactionPreviewRegions != regions else { return }
        for annotation in redactionPreviewAnnotations {
            annotation.page?.removeAnnotation(annotation)
        }
        redactionPreviewAnnotations = []
        redactionPreviewMode = mode
        redactionPreviewRegions = regions
        guard mode == .redaction else { return }

        for region in regions {
            guard let page = document?.page(at: region.pageIndex),
                  let bounds = PDFRedactionEngine.redactionBounds(for: region, in: page.bounds(for: .cropBox)) else { continue }
            let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            annotation.userName = "PDFEditorRedactionPreview:\(region.id.uuidString)"
            annotation.shouldPrint = false
            annotation.color = NSColor.systemRed.withAlphaComponent(0.9)
            annotation.interiorColor = NSColor.black.withAlphaComponent(0.55)
            let border = PDFBorder()
            border.lineWidth = 1.5
            annotation.border = border
            page.addAnnotation(annotation)
            redactionPreviewAnnotations.append(annotation)
        }
        needsDisplay = true
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
        showInlineEditor(
            pageIndex: target.pageIndex,
            bounds: target.bounds,
            text: target.originalText,
            color: target.fontColor,
            pointSize: target.fontSize
        )
    }

    private func showInlineEditor(for edit: ReplacementEdit) {
        showInlineEditor(
            pageIndex: edit.pageIndex,
            bounds: edit.displayedTextBounds,
            text: edit.replacement,
            color: edit.fontColor,
            pointSize: edit.fontSize
        )
    }

    private func showInlineEditor(for edit: ReplacementEdit, replacement: TextRunReplacement) {
        // 移動後の置換は元の行位置ではなく、表示中の注釈位置に入力欄を置く。
        if edit.destinationOrigin != nil {
            showInlineEditor(for: edit)
            return
        }
        guard let layout = edit.lineLayout,
              let plan = PDFTextRenderer.composedReflowPlan(
                  layout: layout,
                  replacements: edit.lineReplacements,
                  startingAt: edit.lineCompositionStart
              ),
              let placement = plan.replacements.first(where: { $0.replacement.id == replacement.id }) else {
            showInlineEditor(for: edit)
            return
        }
        showInlineEditor(
            pageIndex: edit.pageIndex,
            bounds: CGRect(
                x: layout.lineStartX + placement.offsetX,
                y: layout.coverBounds.minY,
                width: max(replacement.renderedWidth, 1),
                height: layout.coverBounds.height
            ),
            text: replacement.text,
            color: replacement.color,
            pointSize: CTFontGetSize(replacement.font)
        )
    }

    private func showInlineEditor(
        pageIndex: Int,
        bounds: CGRect,
        text: String,
        color: NSColor,
        pointSize: CGFloat
    ) {
        guard inlineField == nil else { return }
        guard let page = document?.page(at: pageIndex), let container = documentView else { return }
        let pageRect = container.convert(convert(bounds, from: page), from: self)
        let field = NSTextField()
        field.delegate = self
        field.stringValue = text
        field.isBezeled = true
        field.isEditable = true
        field.drawsBackground = true
        field.backgroundColor = .white
        field.textColor = color
        let displayedSize = max(13, pointSize * scaleFactor)
        field.font = NSFont(name: "Noto Sans JP", size: displayedSize)
            ?? NSFont.systemFont(ofSize: displayedSize)
        field.focusRingType = .none
        field.cell?.lineBreakMode = .byClipping
        let measuredWidth = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width
        let requiredHeight = Self.inlineEditorRequiredHeight(for: field)
        field.frame = Self.inlineEditorFrame(
            pageRect: pageRect,
            measuredTextWidth: measuredWidth,
            requiredFieldHeight: requiredHeight,
            containerBounds: container.bounds
        )
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
        case .previousPage:
            goToPreviousPage(nil)
        case .nextPage:
            goToNextPage(nil)
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
            if event.clickCount >= 2,
               let marker = annotation.userName,
               marker != PDFEditEngine.draftMarker,
               let id = UUID(uuidString: String(marker.dropFirst(PDFEditEngine.annotationMarkerPrefix.count))) {
                beginExistingInsertionEditingHandler?(id)
                return
            }
            draggedAnnotation = annotation
            draggedPage = page
            dragStartPoint = pagePoint
            dragStartBounds = annotation.bounds
            return
        }

        clearSelection()
        insertionHandler?(document.index(for: page), pagePoint)
    }

    @discardableResult
    private func handleMarkupMouseDown(_ event: NSEvent) -> Bool {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false), let document else { return true }
        let pagePoint = PDFMarkupEngine.clampedPoint(convert(viewPoint, to: page), to: page.bounds(for: .mediaBox))
        let pageIndex = document.index(for: page)
        let managedAnnotations = page.annotations.reversed().compactMap { annotation -> (PDFAnnotation, PDFMarkupEdit)? in
            guard let edit = PDFMarkupEngine.edit(from: annotation, pageIndex: pageIndex) else { return nil }
            return (annotation, edit)
        }
        if let (annotation, edit) = managedAnnotations.first(where: { $0.1.id == selectedMarkupID }),
           PDFMarkupEngine.hitTestResizeHandle(pagePoint, bounds: edit.bounds) {
            selectMarkupHandler?(edit.id)
            draggedMarkupID = edit.id
            draggedAnnotation = annotation
            draggedPage = page
            dragStartPoint = pagePoint
            dragStartBounds = annotation.bounds
            resizingMarkup = true
            markupDidMove = false
            return true
        }
        if let (annotation, edit) = managedAnnotations.first(where: { PDFMarkupEngine.hitTest(pagePoint, in: $0.1) }) {
            selectMarkupHandler?(edit.id)
            draggedMarkupID = edit.id
            draggedAnnotation = annotation
            draggedPage = page
            dragStartPoint = pagePoint
            dragStartBounds = annotation.bounds
            resizingMarkup = PDFMarkupEngine.hitTestResizeHandle(pagePoint, bounds: edit.bounds)
            markupDidMove = false
            return true
        }
        guard !markupTool.isTextMarkup else { return false }
        selectMarkupHandler?(nil)
        markupDrawingPage = page
        markupDrawingPageIndex = document.index(for: page)
        markupDrawingStart = pagePoint
        markupDrawingPoints = [pagePoint]
        if markupTool == .note {
            markupDrawingPoints = []
            let bounds = PDFMarkupEngine.clampedBounds(
                CGRect(origin: pagePoint, size: CGSize(width: 20, height: 20)),
                to: page.bounds(for: .mediaBox),
                minimumSize: CGSize(width: 8, height: 8)
            )
            markupDrawingPage = nil
            markupDrawingPageIndex = nil
            markupCreateHandler?(document.index(for: page), bounds, [])
        } else if markupTool == .signature {
            markupDrawingPoints = []
            let bounds = PDFMarkupEngine.clampedBounds(
                CGRect(origin: pagePoint, size: CGSize(width: 140, height: 40)),
                to: page.bounds(for: .mediaBox),
                minimumSize: CGSize(width: 80, height: 24)
            )
            markupDrawingPage = nil
            markupDrawingPageIndex = nil
            markupCreateHandler?(document.index(for: page), bounds, [])
        }
        return true
    }

    private func updateMarkupPreview(on page: PDFPage, points: [CGPoint]) {
        if let markupPreviewAnnotation { page.removeAnnotation(markupPreviewAnnotation) }
        let bounds = PDFMarkupEngine.clampedBounds(
            markupBounds(for: points, tool: markupTool),
            to: page.bounds(for: .mediaBox),
            minimumSize: CGSize(width: 8, height: 8)
        )
        let preview = PDFMarkupEngine.makeAnnotation(for: PDFMarkupEdit(
            pageIndex: 0, tool: markupTool, bounds: bounds, points: points,
            text: markupTool == .signature ? "署名" : ""
        ))
        preview.shouldPrint = false
        preview.color = markupTool.color.withAlphaComponent(0.65)
        page.addAnnotation(preview)
        markupPreviewAnnotation = preview
    }

    private func markupBounds(for points: [CGPoint], tool: PDFMarkupTool) -> CGRect {
        guard let first = points.first else { return .zero }
        guard let last = points.last else { return CGRect(origin: first, size: CGSize(width: 1, height: 1)) }
        var bounds = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                            width: abs(last.x - first.x), height: abs(last.y - first.y))
        if tool == .ink, points.count > 2 {
            for point in points.dropFirst() { bounds = bounds.union(CGRect(origin: point, size: CGSize(width: 0.1, height: 0.1))) }
        }
        let minWidth: CGFloat = tool == .signature ? 80 : 8
        let minHeight: CGFloat = tool == .signature ? 24 : 8
        if bounds.width < minWidth { bounds.size.width = minWidth }
        if bounds.height < minHeight { bounds.size.height = minHeight }
        return bounds
    }

    private func handleReplacementMouseDown(_ event: NSEvent, allowMovingExistingContent: Bool = true) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false), let document else {
            clearReplacementHighlight()
            replacementDragTarget = nil
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        if allowMovingExistingContent,
           let existing = page.annotations.reversed().compactMap({ $0 as? ReplacementTextAnnotation })
            .first(where: { !$0.edit.replacement.isEmpty && $0.edit.replacementID(at: pagePoint) != nil }) {
            if event.clickCount >= 2 {
                let replacementID = existing.edit.replacementID(at: pagePoint) ?? existing.edit.id
                beginExistingReplacementEditingHandler?(replacementID)
                if let run = existing.edit.lineReplacements.first(where: { $0.id == replacementID }) {
                    showInlineEditor(for: existing.edit, replacement: run)
                } else {
                    showInlineEditor(for: existing.edit)
                }
                return
            }
            // 合成行の各置換はダブルクリックで再編集できるが、移動は従来どおり
            // outer edit 自身の範囲だけで開始する。合成行全体を単一文字として
            // 移動すると他の置換を落としてしまうため。
            if existing.edit.displayedTextBounds.contains(pagePoint) {
                movingExistingEdit = existing.edit
                movementStartPoint = pagePoint
                movementDelta = .zero
                return
            }
        }
        if allowMovingExistingContent,
           let selectedTextTarget,
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

    private func handleRedactionMouseDown(_ event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false), let document else {
            clearRedactionDrawingPreview()
            replacementDragTarget = nil
            return
        }
        redactionDrawingPage = page
        redactionDrawingPageIndex = document.index(for: page)
        redactionDrawingStart = PDFMarkupEngine.clampedPoint(
            convert(viewPoint, to: page),
            to: page.bounds(for: .cropBox)
        )
        redactionDrawingDidMove = false
        handleReplacementMouseDown(event, allowMovingExistingContent: false)
    }

    private func handleRedactionMouseDragged(_ event: NSEvent) {
        guard let page = redactionDrawingPage else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let bounds = redactionDrawingBounds(at: viewPoint) else { return }
        redactionDrawingDidMove = true
        replacementDragTarget = nil
        replacementDragRun = nil
        replacementDragAnchorIndex = nil
        replacementDragPage = nil
        clearReplacementHighlight()

        if redactionDrawingAnnotation == nil {
            let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            annotation.userName = "PDFEditorRedactionDrawPreview"
            annotation.shouldPrint = false
            annotation.color = NSColor.systemRed.withAlphaComponent(0.9)
            annotation.interiorColor = NSColor.black.withAlphaComponent(0.55)
            let border = PDFBorder()
            border.lineWidth = 1.5
            annotation.border = border
            page.addAnnotation(annotation)
            redactionDrawingAnnotation = annotation
        } else {
            redactionDrawingAnnotation?.bounds = bounds
        }
        needsDisplay = true
    }

    private func redactionDrawingBounds(at viewPoint: CGPoint) -> CGRect? {
        guard let page = redactionDrawingPage else { return nil }
        let end = PDFMarkupEngine.clampedPoint(convert(viewPoint, to: page), to: page.bounds(for: .cropBox))
        let bounds = CGRect(
            x: min(redactionDrawingStart.x, end.x),
            y: min(redactionDrawingStart.y, end.y),
            width: abs(end.x - redactionDrawingStart.x),
            height: abs(end.y - redactionDrawingStart.y)
        )
        guard bounds.width >= 3, bounds.height >= 3 else { return nil }
        return bounds
    }

    private func clearRedactionDrawingPreview() {
        if let redactionDrawingAnnotation {
            redactionDrawingAnnotation.page?.removeAnnotation(redactionDrawingAnnotation)
        }
        redactionDrawingAnnotation = nil
        redactionDrawingPage = nil
        redactionDrawingPageIndex = nil
        redactionDrawingDidMove = false
        needsDisplay = true
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
        context.setStrokeColor(NSColor(NihoPalette.greenLine).cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.restoreGState()

        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: lens.midX - 7, y: lens.midY))
        crosshair.line(to: CGPoint(x: lens.midX + 7, y: lens.midY))
        crosshair.move(to: CGPoint(x: lens.midX, y: lens.midY - 7))
        crosshair.line(to: CGPoint(x: lens.midX, y: lens.midY + 7))
        NSColor(NihoPalette.greenLine).withAlphaComponent(0.75).setStroke()
        crosshair.lineWidth = 1
        crosshair.stroke()
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
