import AppKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

/// Sparkle owns download verification, atomic installation and relaunch. The app
/// owns the document-save gate: installing an update must never discard edits.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let publicKeyPlaceholder = "REPLACE_WITH_PDF_EDITOR_SPARKLE_PUBLIC_KEY"
    private static let reopenKey = "PDFEditor.reopenAfterUpdate"
    @Published private(set) var isConfigured = false
    @Published private(set) var isRestartPending = false
    private let model: EditorModel
    private var controller: SPUStandardUpdaterController?
    private var installHandler: (() -> Void)?

    init(model: EditorModel) {
        self.model = model
        super.init()
    }

    static func takeReopenURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: reopenKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: reopenKey)
        return URL(fileURLWithPath: path)
    }

    func start() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              key != Self.publicKeyPlaceholder,
              let decoded = Data(base64Encoded: key), decoded.count == 32,
              decoded.contains(where: { $0 != 0 }) else { return }
        isConfigured = true
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "自動更新はまだ設定されていません"
            alert.informativeText = "署名付き更新の公開鍵が設定されると、このメニューから更新できます。"
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        self.installHandler = installHandler
        isRestartPending = true
        Task { @MainActor [weak self] in self?.restartToUpdate() }
        return true
    }

    /// Called only after the user chooses Install and Relaunch in Sparkle's UI,
    /// or explicitly retries the pending restart from the app menu.
    func restartToUpdate() {
        guard let installHandler else { return }
        guard !model.hasPendingEditorInput else {
            let alert = NSAlert()
            alert.messageText = "入力中の文字を確定してください"
            alert.informativeText = "文字の編集を確定してから、アプリメニューの「更新して再起動」を選んでください。"
            alert.runModal()
            return
        }
        var reopenURL = model.sourceURL
        if model.canUndo, let sourceURL = model.sourceURL {
            let alert = NSAlert()
            alert.messageText = "編集済みPDFを保存して更新します"
            alert.informativeText = "保存後にアプリを再起動し、保存したPDFを開きます。キャンセルすると編集を続けられます。"
            alert.addButton(withTitle: "保存して更新")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-edited.pdf"
            panel.directoryURL = sourceURL.deletingLastPathComponent()
            guard panel.runModal() == .OK, let outputURL = panel.url,
                  outputURL.standardizedFileURL != sourceURL.standardizedFileURL else { return }
            do {
                try PDFExportEngine.export(sourceURL: sourceURL, edits: model.activeReplacements, to: outputURL)
                reopenURL = outputURL
            } catch {
                let failure = NSAlert(error: error)
                failure.messageText = "PDFを保存できなかったため、更新を延期しました"
                failure.runModal()
                return
            }
        }
        if let reopenURL {
            UserDefaults.standard.set(reopenURL.path, forKey: Self.reopenKey)
        }
        self.installHandler = nil
        isRestartPending = false
        installHandler()
    }
}
