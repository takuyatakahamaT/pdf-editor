import Testing
@testable import PDFTextEditor

@Suite("App update notice")
struct AppUpdateNoticeTests {
    @Test("a newer version appears and dismissing only hides that version")
    func showsNewVersionAndResetsForLaterVersion() {
        var state = AppUpdateNoticeState()
        #expect(!state.isVisible)

        state.stage(version: "0.6.11")
        #expect(state.isVisible)
        #expect(state.availableVersion == "0.6.11")

        state.dismiss()
        #expect(!state.isVisible)

        state.stage(version: "0.6.11")
        #expect(!state.isVisible)

        state.stage(version: "0.6.12")
        #expect(state.isVisible)
        #expect(state.availableVersion == "0.6.12")
    }

    @Test("empty versions cannot create an update notice")
    func ignoresEmptyVersion() {
        var state = AppUpdateNoticeState()
        state.stage(version: "  \n")
        #expect(!state.isVisible)
    }
}
