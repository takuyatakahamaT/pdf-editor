import SwiftUI

struct EditorScreen: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Color.white.opacity(0.08))

            if let document = model.document {
                HStack(spacing: 0) {
                    PDFCanvas(
                        document: document,
                        revision: model.revision,
                        mode: model.mode,
                        hasSelection: model.hasSelection,
                        onSelection: { target in model.select(target) },
                        onInsertion: { pageIndex, point in model.beginInsertion(pageIndex: pageIndex, point: point) },
                        onMoveInsertion: { marker, pageIndex, bounds in
                            model.moveInsertion(marker: marker, pageIndex: pageIndex, bounds: bounds)
                        }
                    )
                    .background(Color(red: 0.10, green: 0.10, blue: 0.09))

                    inspector
                        .frame(width: 370)
                }
            } else {
                landing
            }

            statusBar
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.075))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isShowingMergeSheet) {
            PDFMergeSheet()
        }
        .sheet(isPresented: $model.isShowingResizeSheet) {
            PDFPageResizeSheet()
                .environmentObject(model)
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.95, green: 0.77, blue: 0.20))
                Text("T/")
                    .font(.custom("Avenir Next", size: 16).weight(.heavy))
                    .foregroundStyle(Color.black)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("PDF EDITOR")
                    .font(.custom("Avenir Next", size: 13).weight(.bold))
                    .tracking(1.8)
                Text(model.sourceURL?.lastPathComponent ?? "PDFを選択してください")
                    .font(.custom("Hiragino Sans", size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(model.pageCountText)
                .font(.custom("Avenir Next", size: 12).weight(.medium))
                .foregroundStyle(.secondary)

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
        .background(Color(red: 0.115, green: 0.11, blue: 0.10))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TEXT PATCH")
                    .font(.custom("Avenir Next", size: 12).weight(.bold))
                    .tracking(1.7)
                    .foregroundStyle(Color(red: 0.95, green: 0.77, blue: 0.20))
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

                Text(model.mode == .replacement ? "既存の文字をクリック・ドラッグ" : "PDF上をクリックして配置")
                    .font(.custom("Hiragino Sans", size: 21).weight(.semibold))
                Text(model.mode == .replacement
                    ? "括弧を含む範囲は先頭から末尾までドラッグして選べます。"
                    : "クリックした位置へ文字を追加。確定後は文字をドラッグして移動できます。")
                    .font(.custom("Hiragino Sans", size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 18) {
                if model.mode == .replacement {
                    fieldLabel("選択した文字")
                    Text(model.selectedTarget?.originalText ?? "まだ選択されていません")
                        .font(.custom("Hiragino Sans", size: 15).weight(.medium))
                        .foregroundStyle(model.hasSelection ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        }
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: model.hasInsertionLocation ? "mappin.and.ellipse" : "cursorarrow.click")
                            .foregroundStyle(accentColor)
                        Text(model.hasInsertionLocation ? "入力位置を配置済み" : "PDF上の追加位置をクリック")
                            .font(.custom("Hiragino Sans", size: 12).weight(.medium))
                            .foregroundStyle(model.hasInsertionLocation ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }

                fieldLabel(model.mode == .replacement ? "置換後の文字" : "追加する文字")
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
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(model.canEditText ? accentColor.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
                    }

                if model.mode == .insertion {
                    InsertionStylePanel(model: model)
                }

                Button(action: model.commitEditorText) {
                    HStack {
                        Text(model.mode == .replacement ? "この位置で置換" : "この文字を追加")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.custom("Hiragino Sans", size: 14).weight(.semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!model.canCommit)
                .opacity(model.canCommit ? 1 : 0.42)

                if model.mode == .replacement {
                    Button("選択文字を表示から削除", action: model.deleteSelection)
                        .buttonStyle(.plain)
                        .font(.custom("Hiragino Sans", size: 13).weight(.medium))
                        .foregroundStyle(model.hasSelection ? Color.white : Color.white.opacity(0.35))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(model.hasSelection ? 0.11 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                        .disabled(!model.hasSelection)
                }

                Button("直前の変更を取り消す", action: model.undoLastEdit)
                    .buttonStyle(.plain)
                    .font(.custom("Hiragino Sans", size: 12).weight(.medium))
                    .foregroundStyle(model.canUndo ? Color.white.opacity(0.72) : Color.white.opacity(0.25))
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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .background(Color.black.opacity(0.18))
        }
        .background(Color(red: 0.135, green: 0.13, blue: 0.12))
    }

    private var landing: some View {
        VStack(spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.035))
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [8, 8]))
                    .foregroundStyle(Color.white.opacity(0.16))

                VStack(spacing: 20) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color(red: 0.95, green: 0.77, blue: 0.20))
                    VStack(spacing: 8) {
                        Text("PDFを作業台へ")
                            .font(.custom("Hiragino Sans", size: 26).weight(.semibold))
                        Text("既存文字の置換も、好きな位置への文字追加もできます。")
                            .font(.custom("Hiragino Sans", size: 13))
                            .foregroundStyle(.secondary)
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
        .background {
            LinearGradient(
                colors: [Color.black.opacity(0.12), Color(red: 0.16, green: 0.145, blue: 0.10).opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(red: 0.95, green: 0.77, blue: 0.20))
                .frame(width: 6, height: 6)
            Text(model.statusMessage)
                .font(.custom("Hiragino Sans", size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text("⌘O 開く  ·  ⌘P 印刷  ·  ⌘S 書き出す  ·  ⌘Z 取り消す")
                .font(.custom("Avenir Next", size: 10))
                .foregroundStyle(Color.white.opacity(0.28))
        }
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(Color(red: 0.085, green: 0.082, blue: 0.075))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom("Hiragino Sans", size: 11).weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var accentColor: Color {
        Color(red: 0.95, green: 0.77, blue: 0.20)
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
                .foregroundStyle(emphasized ? Color.black : Color.white.opacity(0.82))
                .background(
                    emphasized ? Color(red: 0.95, green: 0.77, blue: 0.20) : Color.white.opacity(0.07),
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
                    ForEach(InsertionFontChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 210)
            }

            if model.hasInsertionLocation {
                VStack(alignment: .leading, spacing: 3) {
                    Text("検出: \(model.detectedFontName ?? "なし")")
                    Text("使用: \(model.effectiveInsertionFontName)")
                }
                .font(.custom("Avenir Next", size: 10))
                .foregroundStyle(.secondary)
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
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.custom("Hiragino Sans", size: 11).weight(.medium))
            .foregroundStyle(.secondary)
    }
}
