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

private enum PageOperation: String, CaseIterable, Identifiable {
    case resize = "サイズ変更"
    case crop = "切り抜き"

    var id: Self { self }
}

struct PDFPageResizeSheet: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var operation: PageOperation = .resize
    @State private var choice: PageSizeChoice = .b5
    @State private var customWidth = "182"
    @State private var customHeight = "257"
    @State private var pageRange = "すべて"
    @State private var topMargin = "0"
    @State private var rightMargin = "0"
    @State private var bottomMargin = "0"
    @State private var leftMargin = "0"
    @State private var previewPageNumber = 1
    @State private var cropPreview: PDFCropPreview?
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

    private var parsedMargins: PDFCropMargins? {
        guard let top = millimeters(topMargin), let right = millimeters(rightMargin),
              let bottom = millimeters(bottomMargin), let left = millimeters(leftMargin) else { return nil }
        let margins = PDFCropMargins(topMM: top, rightMM: right, bottomMM: bottom, leftMM: left)
        return margins.isValid ? margins : nil
    }

    private var selectedPageIndices: [Int]? {
        guard let pageCount = model.document?.pageCount else { return nil }
        return try? PDFCropEngine.pageIndices(from: pageRange, pageCount: pageCount)
    }

    private var previewPageNumbers: [Int] {
        selectedPageIndices?.map { $0 + 1 } ?? []
    }

    private var cropInputKey: String {
        [pageRange, topMargin, rightMargin, bottomMargin, leftMargin].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ページ編集")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(NihoPalette.heading)
                Text(currentSizeText)
                    .foregroundStyle(NihoPalette.muted)
            }

            Picker("ページ操作", selection: $operation) {
                ForEach(PageOperation.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if operation == .resize {
                resizeControls
            } else {
                cropControls
            }

            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(NihoPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                if operation == .resize {
                    Button("別名で保存…") {
                        message = ""
                        if model.resizeFromPanel(size: selectedSize, label: choice.fileSuffix) {
                            dismiss()
                        } else {
                            message = model.statusMessage
                        }
                    }
                    .disabled(!selectedSize.isValid)
                } else {
                    Button("切り抜いて別名保存…") {
                        message = ""
                        guard let margins = parsedMargins, selectedPageIndices != nil else { return }
                        if model.cropFromPanel(margins: margins, pageSpecification: pageRange) {
                            dismiss()
                        } else {
                            message = model.statusMessage
                        }
                    }
                    .disabled(parsedMargins == nil || selectedPageIndices == nil || cropPreview == nil)
                }
            }
        }
        .padding(24)
        .frame(width: operation == .crop ? 620 : 520)
        .frame(maxHeight: 760)
        .background(NihoPalette.canvas)
        .foregroundStyle(NihoPalette.ink)
        .tint(NihoPalette.green)
        .preferredColorScheme(.light)
        .onChange(of: cropInputKey) { _, _ in
            cropPreview = nil
            previewPageNumber = previewPageNumbers.first ?? 1
        }
        .onChange(of: previewPageNumber) { _, _ in cropPreview = nil }
        .onChange(of: operation) { _, _ in
            cropPreview = nil
            message = ""
        }
    }

    private var resizeControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("全\(model.document?.pageCount ?? 0)ページを指定した仕上がりサイズに変更します。")
                .foregroundStyle(NihoPalette.muted)

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
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("切り抜くページ")
                .font(.headline)
            HStack(spacing: 10) {
                TextField("すべて / 1-3, 5", text: $pageRange)
                    .textFieldStyle(.roundedBorder)
                Button("全ページ") { pageRange = "すべて" }
            }
            Text("ページ番号は1始まりです。例: 1, 3-5。空欄または「すべて」で全ページを対象にします。")
                .font(.caption)
                .foregroundStyle(NihoPalette.muted)

            Text("各辺から切り取る量")
                .font(.headline)
            HStack(spacing: 12) {
                marginField("上", value: $topMargin)
                marginField("下", value: $bottomMargin)
            }
            HStack(spacing: 12) {
                marginField("左", value: $leftMargin)
                marginField("右", value: $rightMargin)
                Button("リセット") {
                    topMargin = "0"
                    rightMargin = "0"
                    bottomMargin = "0"
                    leftMargin = "0"
                }
                .help("切り抜き量を元に戻す")
            }

            HStack {
                if !previewPageNumbers.isEmpty {
                    Button {
                        movePreviewPage(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(previewPageNumbers.firstIndex(of: previewPageNumber).map { $0 == 0 } ?? true)
                    Text("プレビュー: \(previewPageNumber)ページ")
                        .frame(minWidth: 130)
                    Button {
                        movePreviewPage(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(previewPageNumbers.firstIndex(of: previewPageNumber).map { $0 == previewPageNumbers.count - 1 } ?? true)
                } else {
                    Text("ページ範囲を確認してください")
                        .foregroundStyle(NihoPalette.muted)
                }
                Spacer()
                Button("プレビューを更新") { makeCropPreview() }
                    .disabled(parsedMargins == nil || selectedPageIndices == nil)
            }

            if let cropPreview {
                HStack(alignment: .top, spacing: 12) {
                    previewCard(title: "変更前", image: cropPreview.originalImage, bounds: cropPreview.originalBounds)
                    previewCard(title: "切り抜き後", image: cropPreview.croppedImage, bounds: cropPreview.croppedBounds)
                }
                .frame(maxWidth: .infinity)
            }

            Text("切り抜きはCropBox（表示範囲）の変更です。隠れた文字や画像データはPDF内部に残るため、機密情報の削除には使えません。保存前にリセットまたはキャンセルすれば元に戻せます。")
                .font(.caption)
                .foregroundStyle(NihoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func makeCropPreview() {
        message = ""
        guard let margins = parsedMargins,
              let pageNumber = previewPageNumbers.first(where: { $0 == previewPageNumber }) ?? previewPageNumbers.first,
              let preview = model.cropPreview(pageIndex: pageNumber - 1, margins: margins) else {
            message = "プレビューを作成できませんでした。ページ範囲と余白を確認してください。"
            cropPreview = nil
            return
        }
        previewPageNumber = pageNumber
        cropPreview = preview
    }

    private func movePreviewPage(by offset: Int) {
        guard let currentIndex = previewPageNumbers.firstIndex(of: previewPageNumber) else {
            previewPageNumber = previewPageNumbers.first ?? 1
            return
        }
        let targetIndex = currentIndex + offset
        guard previewPageNumbers.indices.contains(targetIndex) else { return }
        previewPageNumber = previewPageNumbers[targetIndex]
    }

    private func previewCard(title: String, image: NSImage, bounds: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(NihoPalette.line, lineWidth: 1))
            Text(String(format: "%.1f × %.1f mm", bounds.width * 25.4 / 72, bounds.height * 25.4 / 72))
                .font(.caption.monospacedDigit())
                .foregroundStyle(NihoPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func marginField(_ title: String, value: Binding<String>) -> some View {
        HStack {
            Text(title)
                .frame(width: 26, alignment: .leading)
            TextField("0", text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            Text("mm")
                .foregroundStyle(NihoPalette.muted)
        }
    }

    private func millimeters(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}
