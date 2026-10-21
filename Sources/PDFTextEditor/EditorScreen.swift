import PDFKit
import SwiftUI

/// 編集画面。上のバー・PDF・右の文脈パネルの 3 つだけで組む。
///
/// 説明文や案内は置かない。右のパネルには、いま選んでいるものに関係する操作だけを出す。
struct EditorScreen: View {
    @EnvironmentObject private var model: EditorModel
    @EnvironmentObject private var updater: AppUpdateController
    @StateObject private var zoomState = PDFZoomState()
    @State private var zoomInput = "100"
    @FocusState private var zoomInputIsFocused: Bool
    @State private var toolsMenuIsHovered = false

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if updater.updateNotice.isVisible && !updater.isRestartPending {
                updateNotice
                NihoDivider()
            }

            if let document = model.document {
                HStack(spacing: 0) {
                    canvas(document)
                    ContextPanel()
                        .frame(width: 300)
                }
            } else {
                startScreen
            }
        }
        .overlay(alignment: .bottom) {
            noticeToast
        }
        .animation(.easeInOut(duration: 0.2), value: model.noticeMessage)
        .task(id: model.noticeRevision) {
            guard model.noticeMessage != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            model.dismissNotice()
        }
        // タイトルバーを隠した窓で、上のバーを信号機と同じ帯に置く。
        .ignoresSafeArea(.container, edges: .top)
        .background(NihoPalette.canvas)
        .foregroundStyle(NihoPalette.ink)
        .tint(NihoPalette.green)
        .preferredColorScheme(.light)
        .onChange(of: zoomState.scale) { _, newScale in
            guard !zoomInputIsFocused else { return }
            zoomInput = String(Int((newScale * 100).rounded()))
        }
        .sheet(isPresented: $model.isShowingMergeSheet) {
            PDFMergeSheet()
        }
        .sheet(isPresented: $model.isShowingPageOrganizerSheet) {
            if let document = model.document, let sourceURL = model.sourceURL {
                PDFPageOrganizerSheet(document: document, sourceURL: sourceURL)
            }
        }
        .sheet(isPresented: $model.isShowingResizeSheet) {
            PDFPageResizeSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingCompressionSheet) {
            PDFCompressionSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingSearchSheet, onDismiss: model.closeSearchSheet) {
            PDFSearchSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingOCRSheet) {
            PDFOCRSheet()
                .environmentObject(model)
        }
    }

    private var updateNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(NihoPalette.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("新しい版 \(updater.updateNotice.availableVersion ?? "") があります")
                    .font(.custom("Hiragino Sans", size: 13).weight(.semibold))
                    .foregroundStyle(NihoPalette.heading)
                Text("更新の確認後、PDF editorを再起動して反映します。")
                    .font(.custom("Hiragino Sans", size: 11))
                    .foregroundStyle(NihoPalette.muted)
            }

            Spacer(minLength: 8)

            Button("更新して再起動") {
                updater.checkForUpdates()
            }
            .buttonStyle(.borderedProminent)
            .tint(NihoPalette.green)

            Button {
                updater.dismissUpdateNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NihoPalette.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NihoPalette.surface)
    }

    // MARK: 上のバー

    private var topBar: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(NihoPalette.ink)
                Text("T/")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            Text(model.document == nil ? "PDF editor" : (model.sourceURL?.lastPathComponent ?? "PDF editor"))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(NihoPalette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 2)

            if let document = model.document {
                pager(pageCount: document.pageCount)
            }

            Spacer(minLength: 8)

            if model.document != nil {
                HStack(spacing: 2) {
                    Button(action: model.showSearchSheet) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("PDF内を検索（⌘F）")
                    .accessibilityLabel("PDF内を検索")

                    Button(action: model.undoLastEdit) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(!model.canUndo)
                    .help("直前の変更を取り消す（⌘Z）")
                    .accessibilityLabel("取り消す")

                    Button(action: model.redoLastEdit) {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(!model.canRedo)
                    .help("やり直す（⇧⌘Z）")
                    .accessibilityLabel("やり直す")
                }

                Rectangle()
                    .fill(NihoPalette.line)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 6)
            }

            toolsMenu
                .padding(.trailing, 6)

            if model.document != nil {
                Button(action: model.exportFromPanel) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                        Text("書き出す")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .primary, isLarge: true))
                .disabled(!model.canExport)
                .help("編集済みPDFを書き出す（⌘S）")
            }
        }
        // 先頭は窓の信号機のぶん空ける。
        .padding(.leading, 78)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(NihoPalette.canvas)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NihoPalette.line)
                .frame(height: 1)
        }
    }

    private func pager(pageCount: Int) -> some View {
        let total = zoomState.pageCount > 0 ? zoomState.pageCount : pageCount
        let current = min(zoomState.currentPageIndex, max(total - 1, 0))
        return HStack(spacing: 0) {
            Button(action: zoomState.previousPage) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 24, cornerRadius: 6))
            .disabled(current <= 0)
            .help("前のページ")
            .accessibilityLabel("前のページ")

            Text("\(total == 0 ? 0 : current + 1) / \(total)")
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(NihoPalette.ink2)
                .fixedSize()

            Button(action: zoomState.nextPage) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 24, cornerRadius: 6))
            .disabled(current >= total - 1)
            .help("次のページ")
            .accessibilityLabel("次のページ")
        }
        .padding(.leading, 4)
    }

    private var toolsMenu: some View {
        Menu {
            Button(action: model.openFromPanel) {
                Label("PDF を開く…", systemImage: "folder")
            }
            Button(action: model.showMergeSheet) {
                Label("結合…", systemImage: "doc.on.doc")
            }
            Button(action: model.showPageOrganizerSheet) {
                Label("ページ整理…", systemImage: "square.grid.2x2")
            }
            .disabled(model.document == nil)
            Button(action: model.showResizeSheet) {
                Label("ページサイズ…", systemImage: "aspectratio")
            }
            .disabled(model.document == nil)
            Button(action: model.showCompressionSheet) {
                Label("圧縮…", systemImage: "arrow.down.doc")
            }
            .disabled(model.document == nil)
            Button {
                model.isShowingOCRSheet = true
            } label: {
                Label("OCR…", systemImage: "text.viewfinder")
            }
            .disabled(model.document == nil)

            Divider()

            Button(action: model.printFromPanel) {
                Label("印刷…", systemImage: "printer")
            }
            .disabled(!model.canPrint)
            Button(action: model.importFontFromPanel) {
                Label("フォントを読み込む…", systemImage: "textformat")
            }
        } label: {
            Text("ツール")
                .font(.system(size: 12.5, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(toolsMenuIsHovered ? NihoPalette.ink : NihoPalette.ink2)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(toolsMenuIsHovered ? NihoPalette.bg3 : Color.clear, in: Capsule())
        .contentShape(Capsule())
        .onHover { toolsMenuIsHovered = $0 }
        .accessibilityLabel("ツール")
    }

    // MARK: キャンバス

    private func canvas(_ document: PDFDocument) -> some View {
        PDFCanvas(
            document: document,
            revision: model.revision,
            mode: model.mode,
            markupTool: model.selectedMarkupTool,
            selectedTarget: model.selectedTarget,
            redactionRegions: model.redactionRegions,
            selectedMarkupID: model.selectedMarkupID,
            highlightedSearchSelections: model.highlightedSearchSelections,
            focusedSearchSelection: model.focusedSearchSelection,
            searchHighlightRevision: model.searchHighlightRevision,
            searchNavigationRevision: model.searchNavigationRevision,
            isInlineEditing: model.isInlineEditing,
            zoomState: zoomState,
            onSelection: { target in model.select(target) },
            onInsertion: { pageIndex, point in model.beginInsertion(pageIndex: pageIndex, point: point) },
            onMoveInsertion: { marker, pageIndex, bounds in
                model.moveInsertion(marker: marker, pageIndex: pageIndex, bounds: bounds)
            },
            onMoveSelection: { delta in model.moveSelection(by: delta) },
            onMoveExistingEdit: { id, delta in model.moveExistingEdit(id: id, by: delta) },
            onMarkupCreate: { pageIndex, bounds, points in
                model.addMarkup(pageIndex: pageIndex, bounds: bounds, points: points)
            },
            onRedactionRegion: { pageIndex, bounds in
                model.addRedactionRegion(pageIndex: pageIndex, bounds: bounds)
            },
            onSelectMarkup: { id in model.selectMarkup(id) },
            onMoveMarkup: { id, bounds in model.moveMarkup(id: id, to: bounds) },
            onBeginInlineEditing: { model.beginInlineEditing() },
            onChangeInlineText: { value in model.updateEditorText(value) },
            onCommitInlineEditing: { model.commitEditorText() },
            onCancelInlineEditing: { model.cancelInlineEditing() }
        )
        .background(NihoPalette.pdfStage)
        .overlay(alignment: .bottomTrailing) {
            zoomControl
                .padding(.trailing, 16)
                .padding(.bottom, 14)
        }
    }

    /// キャンバスの右下に浮く表示倍率の操作。
    private var zoomControl: some View {
        HStack(spacing: 1) {
            Button {
                zoomState.zoomOut()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 26, cornerRadius: 13))
            .help("縮小")
            .accessibilityLabel("縮小")

            HStack(spacing: 0) {
                TextField("倍率", text: $zoomInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 27)
                    .focused($zoomInputIsFocused)
                    .onSubmit {
                        zoomState.setPercent(Double(zoomInput) ?? Double(zoomState.scale * 100))
                        zoomInputIsFocused = false
                    }
                    .accessibilityLabel("表示倍率（%）")
                Text("%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NihoPalette.ink)
                    .accessibilityHidden(true)
            }
            .frame(width: 42)
            .help("表示倍率（%）")

            Button {
                zoomState.zoomIn()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 26, cornerRadius: 13))
            .help("拡大")
            .accessibilityLabel("拡大")

            Rectangle()
                .fill(NihoPalette.line)
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)

            Menu {
                Button("ページ全体に合わせる") { zoomState.fitPage() }
                Button("ページ幅に合わせる") { zoomState.fitWidth() }
                Button("実寸（100%）") { zoomState.actualSize() }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 26)
            .foregroundStyle(NihoPalette.ink2)
            .help("ページの表示倍率")
            .accessibilityLabel("ページの表示倍率")

            Button {
                zoomState.toggleMagnifier()
            } label: {
                Image(systemName: zoomState.magnifierIsActive ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(IconButtonStyle(
                size: 26,
                cornerRadius: 13,
                tint: zoomState.magnifierIsActive ? NihoPalette.greenLine : nil
            ))
            .help(zoomState.magnifierIsActive ? "虫眼鏡を終了（Esc）" : "ポインター付近を拡大")
            .accessibilityLabel(zoomState.magnifierIsActive ? "虫眼鏡を終了" : "虫眼鏡")
        }
        .padding(3)
        .background(NihoPalette.canvas, in: Capsule())
        .overlay {
            Capsule().strokeBorder(NihoPalette.line, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    // MARK: 失敗の帯

    /// 失敗・拒否を短く知らせる帯。数秒で消え、クリックでも消える。
    @ViewBuilder
    private var noticeToast: some View {
        if let message = model.noticeMessage {
            Button(action: model.dismissNotice) {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(NihoPalette.danger)
                        .frame(width: 6, height: 6)
                    Text(message)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(NihoPalette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 560)
                .background(NihoPalette.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(NihoPalette.line, lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 4)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
            .transition(.opacity)
            .accessibilityLabel(message)
        }
    }

    // MARK: 開始画面

    private var startScreen: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(NihoPalette.muted)
                .padding(.bottom, 6)
                .accessibilityHidden(true)

            Button(action: model.openFromPanel) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .semibold))
                    Text("PDF を開く")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .primary, isLarge: true))

            Button("複数の PDF を結合", action: model.showMergeSheet)
                .buttonStyle(PillButtonStyle(kind: .ghost, isLarge: true))
        }
        .frame(width: 520, height: 300)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(NihoPalette.line2, style: StrokeStyle(lineWidth: 1.5, dash: [8, 8]))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NihoPalette.canvas)
    }
}

// MARK: - 右の文脈パネル

/// 編集方法の切替と、いま選んでいるものに関係する操作だけを置くパネル。
private struct ContextPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("編集方法", selection: Binding(
                    get: { model.mode },
                    set: { newMode in model.setMode(newMode) }
                )) {
                    ForEach(EditorMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                switch model.mode {
                case .replacement:
                    replacementSection
                case .insertion:
                    insertionSection
                case .redaction:
                    redactionSection
                case .markup:
                    markupSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .background(NihoPalette.canvas)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(NihoPalette.line)
                .frame(width: 1)
        }
    }

    // MARK: 置換

    @ViewBuilder
    private var replacementSection: some View {
        if model.hasSelection, let target = model.selectedTarget {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(target.originalText)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(NihoPalette.ink)
                        .lineLimit(4)
                        .inputBox()
                        .accessibilityLabel("選んだ文字 \(target.originalText)")
                    Text(replacementMeta(for: target))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(NihoPalette.muted)
                        .lineLimit(2)
                }

                fontPicker(selection: Binding(
                    get: { model.replacementFontChoice },
                    set: { model.setReplacementFontChoice($0) }
                ))
                if model.replacementFontChoice == .custom {
                    ImportedFontPicker(model: model)
                }
                if let reason = model.replacementFontPreview?.reason {
                    warning(reason)
                }

                HStack(spacing: 8) {
                    Button("置き換える", action: model.beginInlineEditing)
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(model.isInlineEditing)
                    Button(action: model.deleteSelection) {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("表示から削除")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .ghost))
                }
            }
        }
    }

    private func replacementMeta(for target: TextTarget) -> String {
        let detail = model.selectedFontDescription
        var parts = [
            "\(target.pageIndex + 1) ページ",
            "\(Int(target.fontSize.rounded())) pt",
            detail?.installedFamily ?? detail?.pdfName ?? "書体不明",
        ]
        if detail?.hasEmbeddedProgram == false {
            parts.append("埋め込みなし")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 追加

    @ViewBuilder
    private var insertionSection: some View {
        if model.hasInsertionLocation {
            VStack(alignment: .leading, spacing: 12) {
                ReplacementTextField(
                    text: Binding(
                        get: { model.replacementText },
                        set: { newText in model.updateEditorText(newText) }
                    ),
                    isEnabled: model.canEditText,
                    focusRequest: model.replacementFocusRequest,
                    onSubmit: { model.commitEditorText() }
                )
                .frame(minHeight: 22)
                .inputBox(highlighted: model.canEditText)

                fontPicker(selection: Binding(
                    get: { model.insertionFontChoice },
                    set: { model.setInsertionFontChoice($0) }
                ))
                if model.insertionFontChoice == .custom {
                    ImportedFontPicker(model: model)
                }
                if let reason = model.insertionFontPreviewReason {
                    warning(reason)
                }

                HStack(spacing: 8) {
                    Stepper(
                        value: Binding(
                            get: { model.insertionFontSize },
                            set: { model.setInsertionFontSize($0) }
                        ),
                        in: 6.0...72.0,
                        step: 1.0
                    ) {
                        Text("\(Int(model.insertionFontSize)) pt")
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                    }
                    .accessibilityLabel("文字の大きさ")

                    ColorPicker(
                        "文字の色",
                        selection: Binding(
                            get: { Color(nsColor: model.insertionFontColor) },
                            set: { model.setInsertionFontColor(NSColor($0)) }
                        ),
                        supportsOpacity: true
                    )
                    .labelsHidden()
                }

                Button("追加する", action: model.commitEditorText)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(!model.canCommit)
            }
        }
    }

    // MARK: 墨消し

    @ViewBuilder
    private var redactionSection: some View {
        if model.hasSelection || !model.redactionRegions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if model.hasSelection {
                    Button("選んだ文字を対象に追加", action: model.addSelectedRedactionRegion)
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }

                if !model.redactionRegions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(model.redactionRegions.enumerated()), id: \.element.id) { offset, region in
                            if offset > 0 {
                                Rectangle()
                                    .fill(NihoPalette.line)
                                    .frame(height: 1)
                            }
                            HStack(spacing: 8) {
                                Text("\(region.pageIndex + 1) ページ · \(region.text.isEmpty ? "ドラッグ範囲" : region.text)")
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundStyle(NihoPalette.ink)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    model.removeRedactionRegion(id: region.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(IconButtonStyle(size: 26, cornerRadius: 8))
                                .help("この範囲を外す")
                                .accessibilityLabel("この墨消し範囲を外す")
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 6)
                            .padding(.vertical, 7)
                        }
                    }
                    .background(NihoPalette.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(NihoPalette.line, lineWidth: 1)
                    }

                    HStack(spacing: 8) {
                        Button("墨消しして保存", action: model.applyRedactionsFromPanel)
                            .buttonStyle(PillButtonStyle(kind: .primary))
                        Button("すべて外す", action: model.clearRedactionRegions)
                            .buttonStyle(PillButtonStyle(kind: .ghost))
                    }
                }
            }
        }
    }

    // MARK: 注釈・署名

    private var markupSection: some View {
        let tool = model.selectedMarkupTool
        let selected = model.selectedMarkup
        // 選んだメモ・署名の文字を直しているときは、同じ文字の入力欄を二重に出さない。
        let editingTool: PDFMarkupTool? = selected.flatMap {
            $0.tool == .note || $0.tool == .signature ? $0.tool : nil
        }

        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                spacing: 6
            ) {
                ForEach(PDFMarkupTool.allCases) { candidate in
                    MarkupToolButton(tool: candidate, isSelected: candidate == tool) {
                        model.setMarkupTool(candidate)
                    }
                }
            }

            if tool.isTextMarkup, model.hasSelection {
                Button("選んだ文字に\(tool.title)", action: model.applySelectedTextMarkup)
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }

            if tool == .note, editingTool != .note {
                TextField("メモ", text: Binding(
                    get: { model.markupText },
                    set: { model.setMarkupText($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .inputBox(minHeight: 36)
            }

            if tool == .signature {
                if editingTool != .signature {
                    TextField("署名", text: Binding(
                        get: { model.signatureText },
                        set: { model.setSignatureText($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .inputBox(minHeight: 36)
                }
                Button("このMacに保存", action: model.saveSignatureLocally)
                    .buttonStyle(PillButtonStyle(kind: .ghost))
            }

            if model.selectedMarkupID != nil {
                if let selected, let editingTool {
                    TextField(editingTool == .note ? "メモ" : "署名", text: Binding(
                        get: { selected.tool == .note ? model.markupText : model.signatureText },
                        set: { value in
                            if selected.tool == .note {
                                model.setMarkupText(value)
                            } else {
                                model.setSignatureText(value)
                            }
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .inputBox(minHeight: 36)
                }
                HStack(spacing: 8) {
                    if editingTool != nil {
                        Button("更新", action: model.commitSelectedMarkupText)
                            .buttonStyle(PillButtonStyle(kind: .primary))
                    }
                    Button(action: model.deleteSelectedMarkup) {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("選んだ注釈を削除")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .ghost))
                }
            }
        }
    }

    // MARK: 共通

    private func fontPicker(selection: Binding<InsertionFontChoice>) -> some View {
        Picker("書体", selection: selection) {
            ForEach(InsertionFontChoice.allCases.filter { $0 != .custom || !model.importedFontFamilies.isEmpty }) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    /// 書体を差し替えられないときの警告。
    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(NihoPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 注釈ツールの格子の 1 マス。
private struct MarkupToolButton: View {
    let tool: PDFMarkupTool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .regular))
                    .frame(height: 18)
                Text(tool.title)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? NihoPalette.ink : NihoPalette.ink2)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                isSelected ? NihoPalette.bg3 : (isHovered ? NihoPalette.surface : NihoPalette.canvas),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(NihoPalette.line, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbol: String {
        switch tool {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .note: "note.text"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .arrow: "arrow.up.right"
        case .ink: "scribble"
        case .signature: "signature"
        }
    }
}

private struct ImportedFontPicker: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Picker("読み込み済み", selection: Binding(
            get: { model.customFontName ?? model.importedFontFamilies.first ?? "" },
            set: { model.setCustomFontName($0) }
        )) {
            ForEach(model.importedFontFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .pickerStyle(.menu)
    }
}

// MARK: - ボタンと入力欄の見た目

/// 丸ピルのボタン。primary は若草の塗り、secondary は白地に枠、ghost は塗りなし。
private struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case ghost
    }

    var kind: Kind
    /// 上のバー・開始画面の高さ 34 の大きさ。false はパネルの高さ 30。
    var isLarge = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, isLarge: isLarge)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    let isLarge: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: isLarge ? 13 : 12.5, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, isLarge ? 15 : 12)
            .frame(height: isLarge ? 34 : 30)
            .background {
                Capsule().fill(fill)
                if kind == .primary, isActive {
                    Capsule().fill(Color.black.opacity(0.05))
                }
            }
            .overlay {
                if kind == .secondary {
                    Capsule().strokeBorder(NihoPalette.line2, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .onHover { isHovered = $0 }
    }

    private var isActive: Bool { isHovered && isEnabled }

    private var foreground: Color {
        switch kind {
        case .primary, .secondary: NihoPalette.ink
        case .ghost: isActive ? NihoPalette.ink : NihoPalette.ink2
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: NihoPalette.primaryFill
        case .secondary: isActive ? NihoPalette.surface : NihoPalette.canvas
        case .ghost: isActive ? NihoPalette.bg3 : Color.clear
        }
    }
}

/// アイコンだけのボタン。hover で淡い面を敷く。
private struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 8
    /// 有効な状態などで色を固定するときだけ指定する。
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, cornerRadius: cornerRadius, tint: tint)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let cornerRadius: CGFloat
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(tint ?? (isActive ? NihoPalette.ink : NihoPalette.ink2))
            .frame(width: size, height: size)
            .background(
                isActive ? NihoPalette.surface : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .onHover { isHovered = $0 }
    }

    private var isActive: Bool { isHovered && isEnabled }
}

private extension View {
    /// 入力欄風の箱（白地・枠・角 10）。
    func inputBox(highlighted: Bool = false, minHeight: CGFloat = 44) -> some View {
        self
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(NihoPalette.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(highlighted ? NihoPalette.greenLine : NihoPalette.line2, lineWidth: 1)
            }
    }
}
