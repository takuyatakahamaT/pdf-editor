import PDFKit
import SwiftUI

private enum PageSizeChoice: String, CaseIterable, Identifiable {
    case a4 = "A4"
    case a5 = "A5"
    case b4 = "B4（JIS）"
    case b5 = "B5（JIS）"
    case b6 = "B6（JIS）"
    case custom = "カスタム"

    var id: Self { self }

    var size: PDFPageSize? {
        switch self {
        case .a4: PDFPageSize(widthMM: 210, heightMM: 297)
        case .a5: PDFPageSize(widthMM: 148, heightMM: 210)
        case .b4: PDFPageSize(widthMM: 257, heightMM: 364)
        case .b5: .jisB5
        case .b6: PDFPageSize(widthMM: 128, heightMM: 182)
        case .custom: nil
        }
    }

    var fileSuffix: String {
        switch self {
        case .a4: "A4"
        case .a5: "A5"
        case .b4: "B4"
        case .b5: "B5"
        case .b6: "B6"
        case .custom: "resized"
        }
    }
}

struct PDFPageResizeSheet: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var choice: PageSizeChoice = .b5
    @State private var customWidth = "182"
    @State private var customHeight = "257"
    @State private var message = ""

    private var selectedSize: PDFPageSize {
        choice.size ?? PDFPageSize(
            widthMM: Double(customWidth.replacingOccurrences(of: ",", with: ".")) ?? 0,
            heightMM: Double(customHeight.replacingOccurrences(of: ",", with: ".")) ?? 0
        )
    }

    private var currentSizeText: String {
        guard let bounds = model.document?.page(at: 0)?.bounds(for: .mediaBox) else {
            return "現在のサイズを取得できません"
        }
        return String(format: "現在の1ページ目: %.1f × %.1f mm", bounds.width * 25.4 / 72, bounds.height * 25.4 / 72)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ページサイズを変更")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(NihoPalette.heading)
                Text(currentSizeText)
                    .foregroundStyle(NihoPalette.muted)
                Text("全\(model.document?.pageCount ?? 0)ページを指定した仕上がりサイズに変更します。")
                    .foregroundStyle(NihoPalette.muted)
            }

            Picker("仕上がりサイズ", selection: $choice) {
                ForEach(PageSizeChoice.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }

            HStack(spacing: 12) {
                dimensionField("幅", value: $customWidth)
                dimensionField("高さ", value: $customHeight)
            }
            .disabled(choice != .custom)

            if choice != .custom {
                Text("\(Int(selectedSize.widthMM)) × \(Int(selectedSize.heightMM)) mm")
                    .font(.headline)
            }

            Text("元ページの縦横比は保ちます。比率が違う場合は余白が入ります。写真の解像度は上がりません。")
                .font(.callout)
                .foregroundStyle(NihoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(NihoPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("別名で保存…") {
                    message = ""
                    if model.resizeFromPanel(size: selectedSize, label: choice.fileSuffix) {
                        dismiss()
                    } else {
                        message = model.statusMessage
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!selectedSize.isValid)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(NihoPalette.canvas)
        .foregroundStyle(NihoPalette.ink)
        .tint(NihoPalette.green)
        .preferredColorScheme(.light)
    }

    private func dimensionField(_ title: String, value: Binding<String>) -> some View {
        HStack {
            Text(title)
            TextField(title, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            Text("mm")
                .foregroundStyle(NihoPalette.muted)
        }
    }
}
