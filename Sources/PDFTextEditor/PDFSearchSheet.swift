import SwiftUI

struct PDFSearchSheet: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFieldIsFocused: Bool
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDF内を検索")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(NihoPalette.heading)
                    Text("文書全体からテキストを探します。")
                        .font(.callout)
                        .foregroundStyle(NihoPalette.muted)
                }
                Spacer()
                Button("閉じる") {
                    model.closeSearchSheet()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                TextField("検索する語句", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFieldIsFocused)
                    .onSubmit(search)
                Button(action: search) {
                    Label("検索", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 10) {
                Text(model.searchResults.isEmpty
                    ? "結果なし"
                    : "\(model.searchResults.count)件の結果")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(NihoPalette.muted)
                Spacer()
                Button {
                    model.moveSearchResult(by: -1)
                } label: {
                    Label("前へ", systemImage: "chevron.up")
                }
                .disabled(model.searchResults.isEmpty)
                Button {
                    model.moveSearchResult(by: 1)
                } label: {
                    Label("次へ", systemImage: "chevron.down")
                }
                .disabled(model.searchResults.isEmpty)
            }

            NihoDivider()

            if model.searchResults.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.searchResults) { result in
                            resultRow(result)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Text("結果を選ぶと該当ページへ移動します。編集できる文字は置換対象として選択されます。")
                .font(.footnote)
                .foregroundStyle(NihoPalette.muted)
        }
        .padding(24)
        .frame(width: 680, height: 500)
        .background(NihoPalette.canvas)
        .foregroundStyle(NihoPalette.ink)
        .tint(NihoPalette.green)
        .preferredColorScheme(.light)
        .onAppear {
            query = model.searchQuery
            searchFieldIsFocused = true
            if !query.isEmpty, model.searchResults.isEmpty {
                search()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? "text.magnifyingglass"
                  : "doc.text.viewfinder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(NihoPalette.green)
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "検索する語句を入力してください"
                 : "一致する文字がありません")
                .font(.headline)
                .foregroundStyle(NihoPalette.heading)
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("画像だけのスキャンPDFは、OCRでテキスト層を追加すると検索できます。")
                    .font(.callout)
                    .foregroundStyle(NihoPalette.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    private func resultRow(_ result: PDFSearchHit) -> some View {
        Button {
            model.focusSearchResult(result)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(result.pageIndex + 1)")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(NihoPalette.green)
                    .frame(width: 38, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.context)
                        .font(.callout)
                        .foregroundStyle(NihoPalette.ink)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if result.editTarget == nil {
                        Text("検索結果へ移動できます。編集する文字はPDF上で選択してください。")
                            .font(.caption)
                            .foregroundStyle(NihoPalette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if model.focusedSearchResultID == result.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NihoPalette.green)
                }
            }
            .padding(12)
            .background(
                model.focusedSearchResultID == result.id ? NihoPalette.green.opacity(0.09) : NihoPalette.surface,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(model.focusedSearchResultID == result.id ? NihoPalette.green.opacity(0.4) : NihoPalette.line,
                            lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(result.pageIndex + 1)ページ目、\(result.matchText)")
    }

    private func search() {
        model.search(query)
    }
}
