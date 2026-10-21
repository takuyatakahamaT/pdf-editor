import SwiftUI

struct PDFOCRSheet: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var pageSpecification = ""
    @State private var language = OCRLanguage.both

    private enum OCRLanguage: String, CaseIterable {
        case both = "日本語と英語"
        case japanese = "日本語"
        case english = "英語"

        var identifiers: [String] {
            switch self {
            case .both: ["ja-JP", "en-US"]
            case .japanese: ["ja-JP"]
            case .english: ["en-US"]
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("画像PDFをOCR")
                        .font(.title2.weight(.semibold))
                    Text("認識はこのMac内のVisionで実行します。元のPDFは変更しません。")
                        .font(.callout)
                        .foregroundStyle(NihoPalette.muted)
                }
                Spacer()
                Button("閉じる") { dismiss() }
                    .disabled(model.ocrIsRunning)
            }

            TextField("ページ範囲（例: 1-3, 5）", text: $pageSpecification)
                .textFieldStyle(.roundedBorder)
            Picker("認識言語", selection: $language) {
                ForEach(OCRLanguage.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if model.hasOCRLayer {
                Text("このPDFにはOCR層があります。再実行すると元の画像PDFから作り直し、文字層が重なるのを防ぎます。")
                    .font(.footnote)
                    .foregroundStyle(NihoPalette.muted)
            } else {
                Text("文字を含むページはそのまま残し、画像だけのページに透明なテキスト層を追加します。")
                    .font(.footnote)
                    .foregroundStyle(NihoPalette.muted)
            }
            if model.canUndo || model.hasPendingEditorInput {
                Text("編集中の変更を別名保存して開き直すとOCRを開始できます。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(model.hasOCRLayer ? "OCRをやり直して別名保存" : "OCRを開始して別名保存") {
                    model.runOCR(pageSpecification: pageSpecification, languages: language.identifiers)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartOCR)
                if model.hasOCRLayer {
                    Button("OCR層を削除して別名保存") { model.removeOCRLayer() }
                        .disabled(model.ocrIsRunning || model.canUndo)
                }
            }

            if model.ocrIsRunning {
                ProgressView(model.ocrProgress)
            } else if !model.ocrProgress.isEmpty {
                Text(model.ocrProgress)
                    .font(.footnote)
                    .foregroundStyle(NihoPalette.muted)
            }

            if !model.ocrProcessedPages.isEmpty {
                Text("OCR完了: \(model.ocrProcessedPages.map { String($0 + 1) }.joined(separator: ", ")) ページ")
                    .font(.callout.weight(.medium))
            }
            if !model.ocrLowConfidenceLines.isEmpty {
                Text("確認が必要な候補（信頼度75%未満）")
                    .font(.callout.weight(.semibold))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.ocrLowConfidenceLines) { line in
                            HStack(alignment: .top) {
                                Text("\(line.pageIndex + 1)ページ · \(Int(line.confidence * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(NihoPalette.muted)
                                    .frame(width: 90, alignment: .leading)
                                Text(line.text)
                                    .textSelection(.enabled)
                                Spacer()
                                Button("ページを確認") {
                                    model.search(line.text)
                                    if let hit = model.searchResults.first(where: { $0.pageIndex == line.pageIndex }) {
                                        model.focusSearchResult(hit)
                                    }
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 620, height: 460)
        .onAppear {
            if pageSpecification.isEmpty, let count = model.document?.pageCount {
                pageSpecification = "1-\(count)"
            }
        }
    }
}
