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
}
