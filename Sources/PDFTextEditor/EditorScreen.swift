import SwiftUI

struct EditorScreen: View {
    @EnvironmentObject private var model: EditorModel
    @StateObject private var zoomState = PDFZoomState()
    @State private var zoomInput = "100"
    @FocusState private var zoomInputIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            NihoDivider()

            if let document = model.document {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            zoomToolbar
                            Spacer()
                        }
                        .frame(height: 44)
                        .background(NihoPalette.pdfStage)
                        NihoDivider()

                        PDFCanvas(
                            document: document,
                            revision: model.revision,
                            mode: model.mode,
                            selectedTarget: model.selectedTarget,
                            isInlineEditing: model.isInlineEditing,
                            zoomState: zoomState,
                            onSelection: { target in model.select(target) },
                            onInsertion: { pageIndex, point in model.beginInsertion(pageIndex: pageIndex, point: point) },
                            onMoveInsertion: { marker, pageIndex, bounds in
                                model.moveInsertion(marker: marker, pageIndex: pageIndex, bounds: bounds)
                            },
                            onMoveSelection: { delta in model.moveSelection(by: delta) },
                            onMoveExistingEdit: { id, delta in model.moveExistingEdit(id: id, by: delta) },
                            onBeginInlineEditing: { model.beginInlineEditing() },
                            onChangeInlineText: { value in model.updateEditorText(value) },
                            onCommitInlineEditing: { model.commitEditorText() },
                            onCancelInlineEditing: { model.cancelInlineEditing() }
                        )
                        .background(NihoPalette.pdfStage)
                    }

                    inspector
                        .frame(width: 370)
                }
            } else {
                landing
            }

            statusBar
        }
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
        .sheet(isPresented: $model.isShowingResizeSheet) {
            PDFPageResizeSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingCompressionSheet) {
            PDFCompressionSheet()
                .environmentObject(model)
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(NihoPalette.green)
                Text("T/")
                    .font(.custom("Avenir Next", size: 16).weight(.heavy))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("PDF EDITOR")
                    .font(.custom("Avenir Next", size: 13).weight(.bold))
                    .tracking(1.8)
                    .foregroundStyle(NihoPalette.heading)
                Text(model.sourceURL?.lastPathComponent ?? "PDFを選択してください")
                    .font(.custom("Hiragino Sans", size: 11))
                    .foregroundStyle(NihoPalette.muted)
                    .lineLimit(1)
            }

            Spacer()

            Text(model.pageCountText)
                .font(.custom("Avenir Next", size: 12).weight(.medium))
                .foregroundStyle(NihoPalette.muted)

            actionButton("PDFを開く", icon: "folder", emphasized: false) {
                model.openFromPanel()
            }

            actionButton("結合", icon: "doc.on.doc", emphasized: false) {
                model.showMergeSheet()
            }

            actionButton("ページサイズ", icon: "arrow.up.left.and.arrow.down.right", emphasized: false) {
                model.showResizeSheet()
            }
            .disabled(model.document == nil)

            actionButton("PDFを圧縮", icon: "arrow.down.doc", emphasized: false) {
                model.showCompressionSheet()
            }
            .disabled(model.document == nil)

            actionButton("印刷", icon: "printer", emphasized: false) {
                model.printFromPanel()
            }
            .disabled(!model.canPrint)

            actionButton("書き出す", icon: "square.and.arrow.up", emphasized: true) {
                model.exportFromPanel()
            }
            .disabled(model.document == nil)
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .background(NihoPalette.canvas)
    }

    private var zoomToolbar: some View {
        HStack(spacing: 8) {
            zoomButton("minus.magnifyingglass", help: "縮小") { zoomState.zoomOut() }
            TextField("倍率", text: $zoomInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .focused($zoomInputIsFocused)
                .onSubmit {
                    zoomState.setPercent(Double(zoomInput) ?? Double(zoomState.scale * 100))
                    zoomInputIsFocused = false
                }
            Text("%")
                .font(.custom("Avenir Next", size: 11).weight(.medium))
                .foregroundStyle(NihoPalette.muted)
            zoomButton("plus.magnifyingglass", help: "拡大") { zoomState.zoomIn() }

            Menu {
                Button("ページ全体に合わせる") { zoomState.fitPage() }
                Button("ページ幅に合わせる") { zoomState.fitWidth() }
                Button("実寸（100%）") { zoomState.actualSize() }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help("ページの表示倍率")

            NihoDivider()
                .frame(height: 20)

            Button {
                zoomState.toggleMagnifier()
            } label: {
                Image(systemName: zoomState.magnifierIsActive ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(zoomState.magnifierIsActive ? NihoPalette.green : NihoPalette.ink)
            .help(zoomState.magnifierIsActive ? "虫眼鏡を終了（Esc）" : "ポインター付近を拡大")
            .accessibilityLabel(zoomState.magnifierIsActive ? "虫眼鏡を終了" : "虫眼鏡")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(NihoPalette.line, lineWidth: 1)
        }
        .padding(.top, 10)
        .zIndex(1)
    }

    private func zoomButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TEXT PATCH")
                    .font(.custom("Avenir Next", size: 12).weight(.bold))
                    .tracking(1.7)
                    .foregroundStyle(NihoPalette.green)
                Picker("編集方法", selection: Binding(
                    get: { model.mode },
                    set: { newMode in model.setMode(newMode) }
                )) {
                    ForEach(EditorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.vertical, 8)

                Text(model.mode == .replacement ? "既存の文字を選択して編集" : "PDF上をクリックして配置")
                    .font(.custom("Hiragino Sans", size: 21).weight(.semibold))
                    .foregroundStyle(NihoPalette.heading)
                Text(model.mode == .replacement
                    ? "クリックで選択、ダブルクリックで直接編集。選択した文字はドラッグで移動できます。"
                    : "クリックした位置へ文字を追加。確定後は文字をドラッグして移動できます。")
                    .font(.custom("Hiragino Sans", size: 12))
                    .foregroundStyle(NihoPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            NihoDivider()

            VStack(alignment: .leading, spacing: 18) {
                if model.mode == .replacement {
                    fieldLabel("選択した文字")
                    Text(model.selectedTarget?.originalText ?? "まだ選択されていません")
                        .font(.custom("Hiragino Sans", size: 15).weight(.medium))
                        .foregroundStyle(model.hasSelection ? NihoPalette.ink : NihoPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(NihoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(NihoPalette.line, lineWidth: 1)
                        }
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: model.hasInsertionLocation ? "mappin.and.ellipse" : "cursorarrow.click")
                            .foregroundStyle(accentColor)
                        Text(model.hasInsertionLocation ? "入力位置を配置済み" : "PDF上の追加位置をクリック")
                            .font(.custom("Hiragino Sans", size: 12).weight(.medium))
                            .foregroundStyle(model.hasInsertionLocation ? NihoPalette.ink : NihoPalette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(NihoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                }

                if model.mode == .insertion {
                    fieldLabel("追加する文字")
                    ReplacementTextField(
                        text: Binding(
                            get: { model.replacementText },
                            set: { newText in model.updateEditorText(newText) }
                        ),
                        isEnabled: model.canEditText,
                        focusRequest: model.replacementFocusRequest,
                        onSubmit: { model.commitEditorText() }
                    )
                        .frame(minHeight: 20)
                        .padding(14)
                        .background(NihoPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(model.canEditText ? accentColor.opacity(0.7) : NihoPalette.line, lineWidth: 1)
                        }
                }

                if model.mode == .replacement {
                    ReplacementStylePanel(model: model)
                    VStack(alignment: .leading, spacing: 5) {
                        Button(action: model.importFontFromPanel) {
                            Label("フォントファイルを読み込む", systemImage: "textformat")
                                .font(.custom("Hiragino Sans", size: 12).weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(NihoPalette.green)
                        Text("一致するフォントは置換に使われます。読み込んだフォントはアプリ終了まで有効です。")
                            .font(.custom("Hiragino Sans", size: 10))
                            .foregroundStyle(NihoPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if !model.importedFontFamilies.isEmpty {
                            Text("読み込み済み: \(model.importedFontFamilies.joined(separator: "、"))")
                                .font(.custom("Hiragino Sans", size: 10))
                                .foregroundStyle(NihoPalette.green)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if model.mode == .insertion {
                    InsertionStylePanel(model: model)
                }

                if model.mode == .insertion {
                    Button(action: model.commitEditorText) {
                        HStack {
                            Text("この文字を追加")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.custom("Hiragino Sans", size: 14).weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canCommit)
                    .opacity(model.canCommit ? 1 : 0.42)
                }

                if model.mode == .replacement {
                    Button("選択文字を表示から削除", action: model.deleteSelection)
                        .buttonStyle(.plain)
                        .font(.custom("Hiragino Sans", size: 13).weight(.medium))
                        .foregroundStyle(model.hasSelection ? NihoPalette.ink : NihoPalette.muted.opacity(0.6))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(model.hasSelection ? NihoPalette.creamTint : NihoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(!model.hasSelection)
                }

                Button("直前の変更を取り消す", action: model.undoLastEdit)
                    .buttonStyle(.plain)
                    .font(.custom("Hiragino Sans", size: 12).weight(.medium))
                    .foregroundStyle(model.canUndo ? NihoPalette.muted : NihoPalette.muted.opacity(0.45))
                    .disabled(!model.canUndo)
            }
            .padding(24)

            Spacer()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(accentColor)
                Text(model.mode == .replacement
                    ? "白い背景の帳票向けMVPです。白塗りは元の文字を見えなくするだけで、書き出したPDFのテキスト抽出では元の文字列が残ります。元ファイルは上書きせず、編集済みPDFを別名保存します。"
                    : "文字は1行で追加され、書き出し時にベクター化されます。回転・縦書き・複数行は未対応です。")
                    .font(.custom("Hiragino Sans", size: 11))
                    .foregroundStyle(NihoPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .background(NihoPalette.surface)
            .overlay(alignment: .top) { NihoDivider() }
        }
        .background(NihoPalette.canvas)
        .overlay(alignment: .leading) {
            Rectangle().fill(NihoPalette.line).frame(width: 1)
        }
    }

    private var landing: some View {
        VStack(spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(NihoPalette.canvas)
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [8, 8]))
                    .foregroundStyle(NihoPalette.heading.opacity(0.28))

                VStack(spacing: 20) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(NihoPalette.green)
                    VStack(spacing: 8) {
                        Text("PDFを作業台へ")
                            .font(.custom("Hiragino Sans", size: 26).weight(.semibold))
                            .foregroundStyle(NihoPalette.heading)
                        Text("既存文字の置換も、好きな位置への文字追加もできます。")
                            .font(.custom("Hiragino Sans", size: 13))
                            .foregroundStyle(NihoPalette.muted)
                    }
                    actionButton("PDFを1つ選ぶ", icon: "folder", emphasized: true) {
                        model.openFromPanel()
                    }
                    actionButton("複数のPDFを結合", icon: "doc.on.doc", emphasized: false) {
                        model.showMergeSheet()
                    }
                }
            }
            .frame(width: 560, height: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NihoPalette.surface)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(NihoPalette.green)
                .frame(width: 6, height: 6)
            Text(model.statusMessage)
                .font(.custom("Hiragino Sans", size: 11))
                .foregroundStyle(NihoPalette.muted)
            Spacer()
            Text("⌘O 開く  ·  ⌘P 印刷  ·  ⌘S 書き出す  ·  ⌘Z 取り消す")
                .font(.custom("Avenir Next", size: 10))
                .foregroundStyle(NihoPalette.muted)
        }
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(NihoPalette.canvas)
        .overlay(alignment: .top) { NihoDivider() }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom("Hiragino Sans", size: 11).weight(.medium))
            .foregroundStyle(NihoPalette.muted)
    }

    private var accentColor: Color {
        NihoPalette.green
    }

    private func actionButton(
        _ title: String,
        icon: String,
        emphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.custom("Hiragino Sans", size: 12).weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .foregroundStyle(emphasized ? Color.white : NihoPalette.ink)
                .background(
                    emphasized ? NihoPalette.green : NihoPalette.creamTint,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct InsertionStylePanel: View {
    @ObservedObject var model: EditorModel

    private var fontChoice: Binding<InsertionFontChoice> {
        Binding(
            get: { model.insertionFontChoice },
            set: { newChoice in model.setInsertionFontChoice(newChoice) }
        )
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { model.insertionFontSize },
            set: { newSize in model.setInsertionFontSize(newSize) }
        )
    }

    private var fontColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: model.insertionFontColor) },
            set: { model.setInsertionFontColor(NSColor($0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                label("フォント")
                Spacer()
                Picker("フォント", selection: fontChoice) {
                    ForEach(InsertionFontChoice.allCases.filter { $0 != .custom || !model.importedFontFamilies.isEmpty }) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 210)
            }

            if model.insertionFontChoice == .custom {
                ImportedFontPicker(model: model)
            }

            if model.hasInsertionLocation {
                VStack(alignment: .leading, spacing: 3) {
                    Text("検出: \(model.detectedFontName ?? "なし")")
                    Text("使用: \(model.effectiveInsertionFontName)")
                    if let reason = model.insertionFontPreviewReason {
                        Text(reason).foregroundStyle(.orange)
                    }
                }
                .font(.custom("Avenir Next", size: 10))
                .foregroundStyle(NihoPalette.muted)
            }

            HStack(spacing: 12) {
                label("サイズ")
                Stepper(value: fontSize, in: 6.0...72.0, step: 1.0) {
                    Text("\(Int(model.insertionFontSize)) pt")
                        .font(.custom("Avenir Next", size: 12).weight(.medium))
                        .monospacedDigit()
                }
                Spacer()
                ColorPicker("色", selection: fontColor, supportsOpacity: true)
                    .font(.custom("Hiragino Sans", size: 11))
            }
        }
        .padding(12)
        .background(NihoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(NihoPalette.line, lineWidth: 1)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.custom("Hiragino Sans", size: 11).weight(.medium))
            .foregroundStyle(NihoPalette.muted)
    }
}

private struct ReplacementStylePanel: View {
    @ObservedObject var model: EditorModel

    private var fontChoice: Binding<InsertionFontChoice> {
        Binding(get: { model.replacementFontChoice }, set: { model.setReplacementFontChoice($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("選択文字のフォント")
                .font(.custom("Hiragino Sans", size: 11).weight(.medium))
                .foregroundStyle(NihoPalette.muted)
            if let target = model.selectedTarget {
                let detail = model.selectedFontDescription
                Text("PDF指定: \(detail?.pdfName ?? "取得不可")")
                Text("形式: \(detail?.subtype ?? "不明")\(detail?.descendantSubtype.map { "/" + $0 } ?? "") / \(detail?.encoding ?? "標準または辞書指定")\(detail?.isSubset == true ? " / サブセット" : "")")
                Text("\(Int(target.fontSize.rounded())) pt  ·  \(detail?.hasEmbeddedProgram == true ? "埋め込みあり" : "埋め込みなし")  ·  \(detail?.installedFamily.map { "ローカル: " + $0 } ?? "同名フォント未導入")")
                HStack(spacing: 5) {
                    Text("色: \(colorCode(target.fontColor))")
                    Circle().fill(Color(nsColor: target.fontColor)).frame(width: 12, height: 12)
                }
            } else {
                Text("文字を選ぶとPDF内の書体情報を表示します。")
            }

            HStack {
                Text("置換に使うフォント")
                Spacer()
                Picker("置換に使うフォント", selection: fontChoice) {
                    ForEach(InsertionFontChoice.allCases.filter { $0 != .custom || !model.importedFontFamilies.isEmpty }) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 190)
            }
            if model.replacementFontChoice == .custom {
                ImportedFontPicker(model: model)
            }
            if let preview = model.replacementFontPreview {
                Text("使用予定: \(preview.familyName)\(preview.isExact ? "（PDF埋め込み）" : "")")
                if let reason = preview.reason { Text(reason).foregroundStyle(.orange) }
            }
        }
        .font(.custom("Hiragino Sans", size: 10))
        .foregroundStyle(NihoPalette.ink)
        .padding(12)
        .background(NihoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(NihoPalette.line, lineWidth: 1)
        }
    }

    private func colorCode(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "不明" }
        return String(format: "#%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
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
