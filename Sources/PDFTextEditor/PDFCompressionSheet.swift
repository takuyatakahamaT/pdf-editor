import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFCompressionSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case single
        case batch

        var id: Self { self }
        var title: String { self == .single ? "このPDF" : "複数PDF" }
    }

    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.single
    @State private var quality = 98
    @State private var estimate: PDFCompressionEstimate?
    @State private var isWorking = false
    @State private var message = ""
    @State private var attemptID: UUID?
    @State private var estimatedRevision: Int?
    @State private var batchFiles: [URL] = []
    @State private var outputDirectory: URL?
    @State private var filenameSuffix = "-compressed"
    @State private var batchResults: [PDFCompressionBatchResult] = []
    @State private var batchSummary = ""
    @State private var isBatchRunning = false
    @State private var batchTask: Task<Void, Never>?
    @State private var batchAttemptID: UUID?
    @State private var currentBatchIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PDFを圧縮")
                .font(.title2.weight(.semibold))
                .foregroundStyle(NihoPalette.heading)
            Text("写真の画質と容量のバランスを選べます。文字・ページサイズ・画像の画素数は変えません。")
                .foregroundStyle(NihoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            Picker("処理", selection: $mode) {
                ForEach(Mode.allCases) { value in Text(value.title).tag(value) }
            }
            .pickerStyle(.segmented)
            .disabled(isWorking || isBatchRunning)

            if mode == .single {
                singleControls
            } else {
                batchControls
            }
        }
        .padding(28)
        .frame(width: mode == .single ? 540 : 720, height: mode == .batch ? 680 : nil)
        .background(NihoPalette.canvas)
        .foregroundStyle(NihoPalette.ink)
        .tint(NihoPalette.green)
        .preferredColorScheme(.light)
        .onChange(of: quality) { _, _ in
            clearEstimate()
            batchResults = []
            batchSummary = ""
        }
        .onChange(of: model.revision) { _, _ in clearEstimate() }
        .onAppear {
            if outputDirectory == nil { outputDirectory = model.sourceURL?.deletingLastPathComponent() }
        }
        .onDisappear {
            clearEstimate()
            stopBatch()
        }
    }

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("圧縮の程度", selection: $quality) {
                ForEach(90...98, id: \.self) { value in
                    Text(qualityLabel(value)).tag(value)
                }
                Text("画像を再圧縮しない（可逆）").tag(0)
            }

            Text("弱圧縮ほど写真の画質を優先します。初期値は印刷向けの弱圧縮です。画質の%は目標ファイルサイズの%ではありません。可逆では画像データを変更しません。")
                .font(.callout)
                .foregroundStyle(NihoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(isWorking || isBatchRunning)
    }

    private var singleControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            qualityControls
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
    }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            qualityControls

            HStack(spacing: 10) {
                Button("PDFを追加…") { addBatchFiles() }
                    .disabled(isBatchRunning)
                Button("一覧をクリア") {
                    batchFiles = []
                    batchResults = []
                    batchSummary = ""
                }
                .disabled(isBatchRunning || batchFiles.isEmpty)
                Text("\(batchFiles.count)件")
                    .font(.callout)
                    .foregroundStyle(NihoPalette.muted)
                Spacer()
            }

            HStack(spacing: 10) {
                Button("出力先フォルダ…") { chooseOutputDirectory() }
                    .disabled(isBatchRunning)
                Text(outputDirectory?.path ?? "出力先を選択してください")
                    .font(.callout)
                    .foregroundStyle(outputDirectory == nil ? NihoPalette.muted : NihoPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Text("出力名の末尾")
                    .foregroundStyle(NihoPalette.muted)
                TextField("-compressed", text: $filenameSuffix)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBatchRunning)
                Text("元の名前 + 末尾 + .pdf")
                    .font(.caption)
                    .foregroundStyle(NihoPalette.muted)
            }

            Text("追加した順に同じ画質設定で圧縮します。元ファイルは変更せず、圧縮後の方が大きい場合は保存しません。")
                .font(.callout)
                .foregroundStyle(NihoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if isBatchRunning {
                ProgressView("\(currentBatchIndex + 1) / \(batchFiles.count) 件を順番に圧縮しています…")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(batchFiles.indices, id: \.self) { index in
                        batchRow(at: index)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .background(NihoPalette.surface, in: RoundedRectangle(cornerRadius: 10))

            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(NihoPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !batchSummary.isEmpty {
                Text(batchSummary)
                    .font(.callout)
                    .foregroundStyle(NihoPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("閉じる") { dismiss() }
                    .disabled(isBatchRunning)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isBatchRunning {
                    Button("圧縮を停止") { batchTask?.cancel() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("一括圧縮") { startBatch() }
                        .disabled(batchFiles.isEmpty || outputDirectory == nil)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private func batchRow(at index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(batchFiles[index].lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if batchResults.indices.contains(index) {
                    batchResultDetails(batchResults[index])
                } else if isBatchRunning && currentBatchIndex == index {
                    Text("圧縮中…")
                        .font(.caption)
                        .foregroundStyle(NihoPalette.green)
                } else {
                    Text("待機中")
                        .font(.caption)
                        .foregroundStyle(NihoPalette.muted)
                }
            }
            Spacer(minLength: 0)
            if batchResults.indices.contains(index), let outputURL = batchResults[index].outputURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Finderで保存先を表示")
                .accessibilityLabel("Finderで保存先を表示")
                .disabled(batchResults[index].status != .succeeded)
            }
            if !isBatchRunning {
                Button {
                    guard index > 0 else { return }
                    batchFiles.swapAt(index, index - 1)
                    batchResults = []
                    batchSummary = ""
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("順番を上へ")
                Button {
                    guard index + 1 < batchFiles.count else { return }
                    batchFiles.swapAt(index, index + 1)
                    batchResults = []
                    batchSummary = ""
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(index + 1 == batchFiles.count)
                .help("順番を下へ")
                Button {
                    batchFiles.remove(at: index)
                    batchResults = []
                    batchSummary = ""
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("一覧から削除")
            }
        }
        .padding(10)
        .background(NihoPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func batchResultDetails(_ result: PDFCompressionBatchResult) -> some View {
        let sourceText = result.sourceBytes.map(sizeText) ?? "不明"
        let outputText = result.outputBytes.map(sizeText) ?? "—"
        VStack(alignment: .leading, spacing: 3) {
            Text("元 \(sourceText) → 後 \(outputText)")
            switch result.status {
            case .succeeded:
                Text("\(batchChangeText(result)) · \(result.message ?? "保存しました")")
                    .foregroundStyle(NihoPalette.green)
            case .largerThanOriginal:
                Text(result.message ?? "圧縮後の方が大きいため保存しませんでした。")
                    .foregroundStyle(NihoPalette.muted)
            case .failed:
                Text("失敗: \(result.message ?? "圧縮できませんでした。")")
                    .foregroundStyle(NihoPalette.danger)
            case .cancelled:
                Text(result.message ?? "キャンセルしました。")
                    .foregroundStyle(NihoPalette.muted)
            }
        }
        .font(.caption)
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

    private func batchChangeText(_ result: PDFCompressionBatchResult) -> String {
        guard let sourceBytes = result.sourceBytes, let outputBytes = result.outputBytes else {
            return "サイズを計測できませんでした"
        }
        let difference = sourceBytes - outputBytes
        if difference > 0 {
            let percent = sourceBytes > 0 ? Double(difference) / Double(sourceBytes) * 100 : 0
            return String(format: "%@削減（%.1f%%）", sizeText(difference), percent)
        }
        if difference < 0 {
            let percent = sourceBytes > 0 ? Double(-difference) / Double(sourceBytes) * 100 : 0
            return String(format: "%@増加（%.1f%%）", sizeText(-difference), percent)
        }
        return "サイズ変化なし"
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
        let compressionSourceURL: URL
        let preparedURL: URL?
        if model.edits.isEmpty {
            compressionSourceURL = sourceURL
            preparedURL = nil
        } else {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdf-editor-compress-prepared-\(UUID().uuidString).pdf")
            do {
                try PDFExportEngine.export(
                    sourceURL: sourceURL,
                    edits: model.activeReplacements,
                    markups: model.activeMarkupEdits,
                    to: outputURL
                )
            } catch {
                isWorking = false
                message = "編集済みPDFの準備に失敗しました: \(error.localizedDescription)"
                model.reportCompressionStatus(message)
                try? FileManager.default.removeItem(at: outputURL)
                return
            }
            compressionSourceURL = outputURL
            preparedURL = outputURL
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                defer {
                    if let preparedURL { try? FileManager.default.removeItem(at: preparedURL) }
                }
                return Result {
                    try PDFCompressionEngine.estimate(
                        sourceURL: compressionSourceURL,
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

    private func addBatchFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "一括圧縮するPDFを選んでください"
        guard panel.runModal() == .OK else { return }
        batchFiles.append(contentsOf: panel.urls)
        batchResults = []
        batchSummary = ""
        message = ""
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        panel.message = "圧縮後のPDFを保存するフォルダを選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url
        batchResults = []
        batchSummary = ""
    }

    private func startBatch() {
        guard !batchFiles.isEmpty, let outputDirectory else { return }
        message = ""
        batchSummary = ""
        batchResults = []
        currentBatchIndex = 0
        isBatchRunning = true
        let attempt = UUID()
        batchAttemptID = attempt
        let files = batchFiles
        let suffix = filenameSuffix
        let selectedQuality = quality
        let worker = Task.detached(priority: .userInitiated) {
            PDFCompressionBatchEngine.run(
                sourceURLs: files,
                outputDirectory: outputDirectory,
                filenameSuffix: suffix,
                quality: selectedQuality,
                cancellationRequested: { Task.isCancelled },
                onProgress: { index in
                    Task { @MainActor in
                        guard batchAttemptID == attempt else { return }
                        currentBatchIndex = index
                    }
                }
            )
        }
        batchTask = Task {
            let results = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel() }
            )
            guard self.batchAttemptID == attempt else { return }
            self.batchResults = results
            self.isBatchRunning = false
            self.batchTask = nil
            self.batchAttemptID = nil
            let saved = results.filter { $0.status == .succeeded }.count
            let failed = results.filter { $0.status == .failed }.count
            let larger = results.filter { $0.status == .largerThanOriginal }.count
            let cancelled = results.filter { $0.status == .cancelled }.count
            self.batchSummary = "完了: 保存 \(saved) 件、増量のため未保存 \(larger) 件、失敗 \(failed) 件、キャンセル \(cancelled) 件"
            self.model.reportCompressionStatus(self.batchSummary)
        }
    }

    private func stopBatch() {
        batchTask?.cancel()
        batchTask = nil
        batchAttemptID = nil
        isBatchRunning = false
    }
}
