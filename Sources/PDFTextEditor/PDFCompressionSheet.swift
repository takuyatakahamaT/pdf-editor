import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFCompressionSheet: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var quality = 98
    @State private var estimate: PDFCompressionEstimate?
    @State private var isWorking = false
    @State private var message = ""
    @State private var attemptID: UUID?
    @State private var estimatedRevision: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PDFを圧縮")
                .font(.title2.weight(.semibold))
                .foregroundStyle(NihoPalette.heading)
            Text("写真の画質と容量のバランスを選べます。文字・ページサイズ・画像の画素数は変えません。")
                .foregroundStyle(NihoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            Picker("圧縮の程度", selection: $quality) {
                ForEach(90...98, id: \.self) { value in
                    Text(qualityLabel(value)).tag(value)
                }
                Text("画像を再圧縮しない（可逆）").tag(0)
            }
            .onChange(of: quality) { _, _ in clearEstimate() }

            Text("弱圧縮ほど写真の画質を優先します。初期値は印刷向けの弱圧縮です。画質の%は目標ファイルサイズの%ではありません。可逆では画像データを変更しません。")
                .font(.callout)
                .foregroundStyle(NihoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if isWorking {
                ProgressView("PDFを圧縮してサイズを計測中…")
            }
            if let estimate {
                VStack(alignment: .leading, spacing: 5) {
                    Text("元ファイル: \(sizeText(estimate.sourceBytes))")
                    Text("圧縮後: \(sizeText(estimate.outputBytes))")
                    Text(changeText(estimate))
                    Text("実測値: \(estimate.outputBytes.formatted())バイト")
                        .font(.caption)
                        .foregroundStyle(NihoPalette.muted)
                }
                .font(.headline)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(NihoPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("サイズを試算") { calculate() }
                    .disabled(isWorking)
                Button("別名で保存…") { save() }
                    .disabled(isWorking || estimate == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(NihoPalette.canvas)
        .foregroundStyle(NihoPalette.ink)
        .tint(NihoPalette.green)
        .preferredColorScheme(.light)
        .onChange(of: model.revision) { _, _ in clearEstimate() }
        .onDisappear { clearEstimate() }
    }

    private func sizeText(_ bytes: Int64) -> String {
        String(format: "%.2f MB", Double(bytes) / 1_000_000)
    }

    private func qualityLabel(_ value: Int) -> String {
        switch value {
        case 90: "90% · 強圧縮（容量優先）"
        case 95: "95% · 標準"
        case 98: "98% · 弱圧縮（画質優先）"
        default: "\(value)%"
        }
    }

    private func changeText(_ estimate: PDFCompressionEstimate) -> String {
        let percent = estimate.reductionPercent
        if percent > 0 { return String(format: "サイズ変化: %.1f%% 削減", percent) }
        if percent < 0 { return String(format: "サイズ変化: %.1f%% 増加", -percent) }
        return "サイズ変化: なし"
    }

    private func clearEstimate() {
        attemptID = nil
        isWorking = false
        if let estimate { try? FileManager.default.removeItem(at: estimate.temporaryURL) }
        estimate = nil
        estimatedRevision = nil
    }

    private func calculate() {
        guard let sourceURL = model.sourceURL else { return }
        guard !model.hasPendingEditorInput else {
            message = "入力中の文字を確定してから試算してください。"
            model.reportCompressionStatus(message)
            return
        }
        clearEstimate()
        message = ""
        isWorking = true
        let attempt = UUID()
        attemptID = attempt
        let revision = model.revision
        let selectedQuality = quality
        let preparedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-compress-prepared-\(UUID().uuidString).pdf")
        do {
            try PDFExportEngine.exportForPrinting(
                sourceURL: sourceURL,
                edits: model.edits.map(\.replacement),
                to: preparedURL
            )
        } catch {
            isWorking = false
            message = "編集済みPDFの準備に失敗しました: \(error.localizedDescription)"
            model.reportCompressionStatus(message)
            try? FileManager.default.removeItem(at: preparedURL)
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: preparedURL) }
                return Result {
                    try PDFCompressionEngine.estimate(
                        sourceURL: preparedURL,
                        originalURL: sourceURL,
                        quality: selectedQuality
                    )
                }
            }.value
            guard attemptID == attempt, model.revision == revision else {
                if case .success(let stale) = result {
                    try? FileManager.default.removeItem(at: stale.temporaryURL)
                }
                return
            }
            isWorking = false
            switch result {
            case .success(let value):
                estimate = value
                estimatedRevision = revision
                model.reportCompressionStatus("圧縮後のサイズを試算しました。")
            case .failure(let error):
                message = error.localizedDescription
                model.reportCompressionStatus(message)
            }
        }
    }

    private func save() {
        guard let estimate, let sourceURL = model.sourceURL,
              estimatedRevision == model.revision, !model.hasPendingEditorInput else {
            message = "編集内容が変わりました。もう一度サイズを試算してください。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-compressed.pdf"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.message = "元のPDFは上書きせず、試算済みPDFを別名で保存します"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        do {
            try PDFCompressionEngine.save(estimate, to: outputURL, protecting: sourceURL)
            model.reportCompressionStatus("圧縮済みPDFを保存しました: \(outputURL.lastPathComponent)")
            dismiss()
        } catch {
            message = error.localizedDescription
            model.reportCompressionStatus(message)
        }
    }
}
