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
}
