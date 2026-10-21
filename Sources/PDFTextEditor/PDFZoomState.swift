import SwiftUI

enum PDFZoomCommand: Equatable {
    case zoomIn
    case zoomOut
    case fitPage
    case fitWidth
    case actualSize
    case setScale(CGFloat)
    case previousPage
    case nextPage
}

@MainActor
final class PDFZoomState: ObservableObject {
    static let minimumScale: CGFloat = 0.25
    static let maximumScale: CGFloat = 4.0

    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var magnifierIsActive = false
    @Published private(set) var command: PDFZoomCommand = .fitPage
    @Published private(set) var commandRevision = 0
    /// 表示中のページ（0 始まり）と総ページ数。PDFCanvas が知らせる。
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var pageCount = 0

    func zoomIn() { issue(.zoomIn) }
    func zoomOut() { issue(.zoomOut) }
    func fitPage() { issue(.fitPage) }
    func fitWidth() { issue(.fitWidth) }
    func actualSize() { issue(.actualSize) }
    func previousPage() { issue(.previousPage) }
    func nextPage() { issue(.nextPage) }

    func setPercent(_ value: Double) {
        guard value.isFinite else { return }
        issue(.setScale(Self.clampedScale(CGFloat(value / 100))))
    }

    func setMagnifierActive(_ active: Bool) {
        magnifierIsActive = active
    }

    func toggleMagnifier() {
        setMagnifierActive(!magnifierIsActive)
    }

    func reportScale(_ value: CGFloat) {
        guard value.isFinite, value > 0, abs(scale - value) > 0.001 else { return }
        scale = value
    }

    func reportPage(index: Int, count: Int) {
        let safeCount = max(count, 0)
        let safeIndex = safeCount == 0 ? 0 : min(max(index, 0), safeCount - 1)
        if pageCount != safeCount { pageCount = safeCount }
        if currentPageIndex != safeIndex { currentPageIndex = safeIndex }
    }

    static func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumScale), maximumScale)
    }

    private func issue(_ next: PDFZoomCommand) {
        if case .setScale(let value) = next {
            command = .setScale(Self.clampedScale(value))
        } else {
            command = next
        }
        commandRevision += 1
    }
}
