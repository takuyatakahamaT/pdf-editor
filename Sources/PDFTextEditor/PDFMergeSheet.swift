import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PDFMergeModel: ObservableObject {
    @Published private(set) var items: [PDFMergeInput] = []
    @Published private(set) var message: String?
    @Published private(set) var completedResult: PDFMergeResult?
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    var totalPageCount: Int {
        items.reduce(0) { $0 + $1.pageCount }
    }

    var canMerge: Bool {
        items.count >= 2
    }

    func addFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "結合するPDFを1つ以上選んでください"
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
    }

    func add(urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            do {
                items.append(try PDFMergeEngine.inspect(url: url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        completedResult = nil
        message = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        thumbnails[id] = nil
        completedResult = nil
        message = nil
    }

    func moveUp(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index > 0 else { return }
        items.swapAt(index, index - 1)
        completedResult = nil
        message = nil
    }

    func moveDown(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index + 1 < items.count else { return }
        items.swapAt(index, index + 1)
        completedResult = nil
        message = nil
    }

    /// A drop occupies the target's position; the other documents keep their relative order.
    @discardableResult
    func move(id: UUID, to targetID: UUID) -> Bool {
        guard let source = items.firstIndex(where: { $0.id == id }),
              let destination = items.firstIndex(where: { $0.id == targetID }),
              source != destination else { return false }
        let item = items.remove(at: source)
        items.insert(item, at: destination)
        completedResult = nil
        message = nil
        return true
    }

    func loadThumbnail(for item: PDFMergeInput) async {
        guard thumbnails[item.id] == nil else { return }
        let url = item.url
        // Each task owns its PDFDocument. Only encoded image data crosses back to the UI.
        let data = await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: url), !document.isLocked,
                  let page = document.page(at: 0) else { return Data?.none }
            return page.thumbnail(of: CGSize(width: 360, height: 400), for: .cropBox).tiffRepresentation
        }.value
        guard !Task.isCancelled, items.contains(where: { $0.id == item.id }),
              let data, let image = NSImage(data: data) else { return }
        thumbnails[item.id] = image
    }

    func saveFromPanel() {
        guard canMerge else {
            message = "結合するPDFを2ファイル以上追加してください。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "結合したPDF.pdf"
        panel.message = "入力PDFとは別のファイルへ保存します"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        merge(to: outputURL)
    }

    func merge(to outputURL: URL) {
        guard canMerge else {
            message = "結合するPDFを2ファイル以上追加してください。"
            return
        }
        do {
            let result = try PDFMergeEngine.merge(inputURLs: items.map(\.url), to: outputURL)
            completedResult = result
            message = "\(result.pageCount)ページを結合しました。保存先: \(result.outputURL.path)"
        } catch {
            completedResult = nil
            message = error.localizedDescription
        }
    }
}

@MainActor
struct PDFMergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mergeModel = PDFMergeModel()
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var draggedID: UUID?
    @State private var dragStartFrame: CGRect?
    @State private var dragTranslation = CGSize.zero
    @State private var dragLocation = CGPoint.zero
    @State private var dropTargetID: UUID?
    private static let dragSpace = "mergeThumbnails"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PDFを結合")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(NihoPalette.heading)
                    Text("サムネイルをドラッグして順番を変更。左から右、上から下の順に結合します。")
                        .foregroundStyle(NihoPalette.muted)
                }
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if mergeModel.items.isEmpty {
                ContentUnavailableView(
                    "PDFを追加してください",
                    systemImage: "doc.on.doc",
                    description: Text("入力PDFは変更されません。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { viewport in
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            // Keep the source card alive while scrolling during a drag.
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(0..<((mergeModel.items.count + 3) / 4), id: \.self) { row in
                                    HStack(alignment: .top, spacing: 14) {
                                        ForEach(0..<4, id: \.self) { column in
                                            let index = row * 4 + column
                                            if index < mergeModel.items.count {
                                                let item = mergeModel.items[index]
                                                ZStack {
                                                    PDFMergeThumbnailCard(
                                                        model: mergeModel, item: item, index: index,
                                                        isDropTarget: dropTargetID == item.id,
                                                        dragChanged: { updateDrag(id: item.id, value: $0) },
                                                        dragEnded: { finishDrag(id: item.id, value: $0) }
                                                    )
                                                    .offset(dragOffset(for: item.id))
                                                    .shadow(color: NihoPalette.heading.opacity(draggedID == item.id ? 0.25 : 0), radius: 12)
                                                }
                                                .frame(minWidth: 0, maxWidth: .infinity)
                                                .background {
                                                    GeometryReader { geometry in
                                                        Color.clear.preference(key: PDFMergeCardFrames.self, value: [
                                                            item.id: geometry.frame(in: .named(Self.dragSpace))
                                                        ])
                                                    }
                                                }
                                                .zIndex(draggedID == item.id ? 1 : 0)
                                                .id(item.id)
                                            } else {
                                                Color.clear.frame(minWidth: 0, maxWidth: .infinity).frame(height: 0)
                                            }
                                        }
                                    }
                                    .zIndex(mergeModel.items.dropFirst(row * 4).prefix(4).contains { $0.id == draggedID } ? 1 : 0)
                                }
                            }
                            .padding(4)
                        }
                        .coordinateSpace(name: Self.dragSpace)
                        .onPreferenceChange(PDFMergeCardFrames.self) { frames in
                            cardFrames = frames
                            updateDropTarget()
                        }
                        .task(id: draggedID) {
                            guard draggedID != nil else { return }
                            while !Task.isCancelled {
                                do { try await Task.sleep(for: .milliseconds(250)) }
                                catch { return }
                                guard draggedID != nil else { return }
                                let visible = mergeModel.items.indices.filter { index in
                                    guard let frame = cardFrames[mergeModel.items[index].id] else { return false }
                                    return frame.maxY > 0 && frame.minY < viewport.size.height
                                }
                                var next: Int?
                                if dragLocation.y < 45, let first = visible.first, first > 0 {
                                    next = first - 1
                                } else if dragLocation.y > viewport.size.height - 45,
                                          let last = visible.last, last + 1 < mergeModel.items.count {
                                    next = last + 1
                                }
                                if let next {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        scrollProxy.scrollTo(mergeModel.items[next].id,
                                            anchor: dragLocation.y < 45 ? .top : .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if let message = mergeModel.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(mergeModel.completedResult == nil ? NihoPalette.danger : NihoPalette.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("PDFを追加…") { mergeModel.addFromPanel() }
                Spacer()
                Text("\(mergeModel.items.count)ファイル・合計 \(mergeModel.totalPageCount)ページ")
                    .foregroundStyle(NihoPalette.muted)
                    .monospacedDigit()
                Button("結合して保存…") { mergeModel.saveFromPanel() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!mergeModel.canMerge)
            }
        }
        .padding(24)
        .frame(width: 900, height: 660)
        .background(NihoPalette.canvas)
        .foregroundStyle(NihoPalette.ink)
        .tint(NihoPalette.green)
        .preferredColorScheme(.light)
    }

    private func updateDrag(id: UUID, value: DragGesture.Value) {
        if draggedID == nil { dragStartFrame = cardFrames[id] }
        draggedID = id
        dragTranslation = value.translation
        dragLocation = value.location
        updateDropTarget()
    }

    private func dragOffset(for id: UUID) -> CGSize {
        guard draggedID == id, let start = dragStartFrame, let current = cardFrames[id] else { return .zero }
        return CGSize(width: dragTranslation.width + start.minX - current.minX,
                      height: dragTranslation.height + start.minY - current.minY)
    }

    private func updateDropTarget() {
        guard let draggedID else { dropTargetID = nil; return }
        dropTargetID = cardFrames.first { $0.key != draggedID && $0.value.contains(dragLocation) }?.key
    }

    private func finishDrag(id: UUID, value: DragGesture.Value) {
        dragLocation = value.location
        updateDropTarget()
        if let target = dropTargetID {
            withAnimation(.easeInOut(duration: 0.18)) { _ = mergeModel.move(id: id, to: target) }
        }
        draggedID = nil
        dragStartFrame = nil
        dragTranslation = .zero
        dropTargetID = nil
    }
}

private struct PDFMergeCardFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
private struct PDFMergeThumbnailCard: View {
    @ObservedObject var model: PDFMergeModel
    let item: PDFMergeInput
    let index: Int
    let isDropTarget: Bool
    let dragChanged: (DragGesture.Value) -> Void
    let dragEnded: (DragGesture.Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(index + 1)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(NihoPalette.green)
                    .background(NihoPalette.sageTint, in: Capsule())
                Spacer()
                Button(role: .destructive) { model.remove(id: item.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("\(item.url.lastPathComponent)を一覧から削除")
                .accessibilityLabel("\(item.url.lastPathComponent)を一覧から削除")
            }
            thumbnail
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .padding(8)
                .background(NihoPalette.pdfStage, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("mergeThumbnails"))
                        .onChanged(dragChanged)
                        .onEnded(dragEnded)
                )
                .help("ドラッグして結合順を変更")
            Text(item.url.lastPathComponent)
                .font(.callout.weight(.medium))
                .lineLimit(1).truncationMode(.middle)
                .help(item.url.path)
            HStack {
                Text("\(item.pageCount)ページ")
                    .font(.caption).foregroundStyle(NihoPalette.muted)
                Spacer()
                Button { model.moveUp(id: item.id) } label: { Image(systemName: "arrow.left") }
                    .disabled(index == 0).help("前へ移動").accessibilityLabel("前へ移動")
                Button { model.moveDown(id: item.id) } label: { Image(systemName: "arrow.right") }
                    .disabled(index == model.items.count - 1).help("後ろへ移動").accessibilityLabel("後ろへ移動")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(isDropTarget ? NihoPalette.sageTint : NihoPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTarget ? NihoPalette.green : NihoPalette.line, lineWidth: isDropTarget ? 3 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .task(id: item.id) { await model.loadThumbnail(for: item) }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = model.thumbnails[item.id] {
            Image(nsImage: image).resizable().scaledToFit()
                .accessibilityLabel("\(item.url.lastPathComponent)の先頭ページ")
        } else {
            Image(systemName: "doc.richtext")
                .font(.system(size: 42)).foregroundStyle(NihoPalette.muted)
                .accessibilityLabel("プレビューを読み込み中")
        }
    }
}
