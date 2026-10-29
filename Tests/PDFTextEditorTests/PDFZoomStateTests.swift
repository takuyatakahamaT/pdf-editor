import AppKit
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite("PDF zoom state")
struct PDFZoomStateTests {
    @Test("custom percentages are limited to a readable scale range")
    @MainActor
    func clampsCustomScale() {
        let state = PDFZoomState()

        state.setPercent(10)
        #expect(state.command == .setScale(0.25))

        state.setPercent(850)
        #expect(state.command == .setScale(4))
    }

    @Test("zoom commands are delivered as distinct revisions")
    @MainActor
    func incrementsCommandRevision() {
        let state = PDFZoomState()

        state.zoomIn()
        #expect(state.command == .zoomIn)
        #expect(state.commandRevision == 1)

        state.fitWidth()
        #expect(state.command == .fitWidth)
        #expect(state.commandRevision == 2)
    }

    @Test("page navigation is delivered as commands and page reports are clamped")
    @MainActor
    func deliversPageNavigationCommands() {
        let state = PDFZoomState()

        state.nextPage()
        #expect(state.command == .nextPage)
        #expect(state.commandRevision == 1)

        state.previousPage()
        #expect(state.command == .previousPage)
        #expect(state.commandRevision == 2)

        state.reportPage(index: 4, count: 3)
        #expect(state.currentPageIndex == 2)
        #expect(state.pageCount == 3)

        state.reportPage(index: 0, count: 0)
        #expect(state.currentPageIndex == 0)
        #expect(state.pageCount == 0)
    }

    @Test("magnifier can be dismissed without changing zoom")
    @MainActor
    func togglesMagnifierIndependently() {
        let state = PDFZoomState()
        state.reportScale(1.75)

        state.toggleMagnifier()
        #expect(state.magnifierIsActive)
        #expect(state.scale == 1.75)

        state.setMagnifierActive(false)
        #expect(!state.magnifierIsActive)
        #expect(state.scale == 1.75)
    }

    @Test("pinch and modified scroll gestures are captured only inside the PDF canvas")
    @MainActor
    func scopesZoomGesturesToThePDF() {
        #expect(ClickablePDFView.shouldZoomOnScroll(modifierFlags: .command))
        #expect(ClickablePDFView.shouldZoomOnScroll(modifierFlags: .control))
        #expect(!ClickablePDFView.shouldZoomOnScroll(modifierFlags: []))
        #expect(!ClickablePDFView.shouldZoomOnScroll(modifierFlags: .option))

        #expect(ClickablePDFView.zoomGestureKind(
            eventType: .magnify,
            modifierFlags: [],
            pointerInsidePDF: true
        ) == .magnify)
        #expect(ClickablePDFView.zoomGestureKind(
            eventType: .scrollWheel,
            modifierFlags: .control,
            pointerInsidePDF: true
        ) == .modifiedScroll)
        #expect(ClickablePDFView.zoomGestureKind(
            eventType: .scrollWheel,
            modifierFlags: .command,
            pointerInsidePDF: true
        ) == .modifiedScroll)
        #expect(ClickablePDFView.zoomGestureKind(
            eventType: .scrollWheel,
            modifierFlags: [],
            pointerInsidePDF: true
        ) == nil)
        #expect(ClickablePDFView.zoomGestureKind(
            eventType: .magnify,
            modifierFlags: [],
            pointerInsidePDF: false
        ) == nil)
    }

    @Test("PDFKit native magnification is disabled so it cannot fight custom zoom")
    @MainActor
    func disablesNativePDFScrollViewMagnification() {
        let view = ClickablePDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.document = PDFDocument()

        view.disableNativeMagnification()

        let scrollView = view.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView
        #expect(scrollView?.allowsMagnification == false)
    }

    @Test("scroll direction changes the zoom multiplier")
    @MainActor
    func scrollDeltaControlsZoomDirection() {
        #expect(ClickablePDFView.zoomMultiplier(forScrollDelta: 90) < 1)
        #expect(ClickablePDFView.zoomMultiplier(forScrollDelta: -90) > 1)
    }

    @Test("高倍率でもインライン入力欄がフォントを切らない")
    @MainActor
    func inlineEditorFitsLargeFont() {
        let field = NSTextField()
        field.stringValue = "09"
        field.isBezeled = true
        field.font = NSFont(name: "Noto Sans JP", size: 100)
            ?? NSFont.systemFont(ofSize: 100)
        let requiredHeight = ClickablePDFView.inlineEditorRequiredHeight(for: field)
        let pageRect = CGRect(x: 120, y: 300, width: 80, height: 46)
        let containerBounds = CGRect(x: 0, y: 0, width: 900, height: 1_200)

        let frame = ClickablePDFView.inlineEditorFrame(
            pageRect: pageRect,
            measuredTextWidth: 130,
            requiredFieldHeight: requiredHeight,
            containerBounds: containerBounds
        )

        #expect(frame.height >= requiredHeight)
        #expect(abs(frame.midY - pageRect.midY) < 0.01)
        #expect(frame.width >= 154)
    }

    @Test("大きいインライン入力欄を表示領域の上下端に収める")
    @MainActor
    func clampsTallInlineEditorAtContainerEdges() {
        let containerBounds = CGRect(x: 0, y: 0, width: 600, height: 500)
        let bottomFrame = ClickablePDFView.inlineEditorFrame(
            pageRect: CGRect(x: 50, y: 0, width: 50, height: 20),
            measuredTextWidth: 80,
            requiredFieldHeight: 126,
            containerBounds: containerBounds
        )
        let topFrame = ClickablePDFView.inlineEditorFrame(
            pageRect: CGRect(x: 50, y: 490, width: 50, height: 20),
            measuredTextWidth: 80,
            requiredFieldHeight: 126,
            containerBounds: containerBounds
        )

        #expect(bottomFrame.minY >= containerBounds.minY + 4)
        #expect(topFrame.maxY <= containerBounds.maxY - 4)
        #expect(bottomFrame.height == 126)
        #expect(topFrame.height == 126)
    }
}
