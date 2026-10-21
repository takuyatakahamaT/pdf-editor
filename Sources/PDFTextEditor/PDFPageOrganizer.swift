import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct OrganizedPage: Identifiable {
    let id: UUID
    let sourcePage: PDFPage
    let sourceURL: URL
    let sourceIndex: Int
    var rotation: Int

    init(id: UUID = UUID(), sourcePage: PDFPage, sourceURL: URL, sourceIndex: Int) {
        self.id = id
        self.sourcePage = sourcePage
        self.sourceURL = sourceURL
        self.sourceIndex = sourceIndex
        rotation = sourcePage.rotation
    }
}

enum PDFPageOrganizerError: Error, LocalizedError {
    case unreadable(URL)
    case locked(URL)
    case forbidden(URL)
    case emptySelection
    case emptyDocument
    case sourceDestination(URL)
    case cannotCopy(Int)
    case cannotEncode
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "「\(url.lastPathComponent)」を読み込めません。"
        case .locked(let url): "「\(url.lastPathComponent)」はロックされています。"
        case .forbidden(let url): "「\(url.lastPathComponent)」はページのコピーまたは組み替えが許可されていません。"
        case .emptySelection: "抽出するページを選択してください。"
        case .emptyDocument: "保存するページがありません。"
        case .sourceDestination(let url): "保存先が入力PDF「\(url.lastPathComponent)」と同じファイルです。別名で保存してください。"
        case .cannotCopy(let index): "\(index + 1)ページ目をコピーできませんでした。"
        case .cannotEncode: "PDFデータを作成できませんでした。"
        case .cannotWrite(let url): "「\(url.lastPathComponent)」へ保存できませんでした。"
        }
    }
}

enum PDFPageOrganizerEngine {
    static func load(url: URL) throws -> (PDFDocument, [OrganizedPage]) {
        guard FileManager.default.isReadableFile(atPath: url.path), let document = PDFDocument(url: url) else {
            throw PDFPageOrganizerError.unreadable(url)
        }
        guard !document.isLocked else { throw PDFPageOrganizerError.locked(url) }
        guard document.allowsCopying && document.allowsDocumentAssembly else {
            throw PDFPageOrganizerError.forbidden(url)
        }
        return (document, pages(from: document, url: url))
    }

    static func pages(from document: PDFDocument, url: URL) -> [OrganizedPage] {
        (0..<document.pageCount).compactMap { index in
            document.page(at: index).map { OrganizedPage(sourcePage: $0, sourceURL: url, sourceIndex: index) }
        }
    }

    static func assemble(_ pages: [OrganizedPage]) throws -> PDFDocument {
        guard !pages.isEmpty else { throw PDFPageOrganizerError.emptyDocument }
        let result = PDFDocument()
        for (index, item) in pages.enumerated() {
            guard let copy = item.sourcePage.copy() as? PDFPage else {
                throw PDFPageOrganizerError.cannotCopy(index)
            }
            copy.rotation = item.rotation
            result.insert(copy, at: index)
            guard result.pageCount == index + 1 else { throw PDFPageOrganizerError.cannotCopy(index) }
        }
        return result
    }

    static func save(_ pages: [OrganizedPage], to outputURL: URL, protecting inputURLs: [URL]) throws {
        if let source = inputURLs.first(where: { sameFile($0, outputURL) }) {
            throw PDFPageOrganizerError.sourceDestination(source)
        }
        guard let data = try assemble(pages).dataRepresentation() else {
            throw PDFPageOrganizerError.cannotEncode
        }
        do { try data.write(to: outputURL, options: .atomic) }
        catch { throw PDFPageOrganizerError.cannotWrite(outputURL) }
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if left == right { return true }
        guard let a = try? FileManager.default.attributesOfItem(atPath: left.path),
              let b = try? FileManager.default.attributesOfItem(atPath: right.path),
              let aDevice = a[.systemNumber] as? NSNumber,
              let bDevice = b[.systemNumber] as? NSNumber,
              let aInode = a[.systemFileNumber] as? NSNumber,
              let bInode = b[.systemFileNumber] as? NSNumber else { return false }
        return aDevice == bDevice && aInode == bInode
    }
}

@MainActor
final class PDFPageOrganizerModel: ObservableObject {
    @Published private(set) var pages: [OrganizedPage]
    @Published private(set) var selectedIDs: Set<UUID> = []
    @Published private(set) var message: String?
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    private var retainedDocuments: [PDFDocument] = []
    private var inputURLs: [URL]
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var selectionAnchor: UUID?

    private struct Snapshot {
        let pages: [OrganizedPage]
        let selectedIDs: Set<UUID>
    }

    init(document: PDFDocument, sourceURL: URL) {
        pages = PDFPageOrganizerEngine.pages(from: document, url: sourceURL)
        inputURLs = [sourceURL]
        retainedDocuments = [document]
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selectedPages: [OrganizedPage] { pages.filter { selectedIDs.contains($0.id) } }
    var primaryPage: OrganizedPage? { selectedPages.first ?? pages.first }

    func select(id: UUID, extending: Bool = false, range: Bool = false) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        if range, let anchor = selectionAnchor,
           let anchorIndex = pages.firstIndex(where: { $0.id == anchor }) {
            selectedIDs.formUnion(pages[min(index, anchorIndex)...max(index, anchorIndex)].map(\.id))
        } else if extending {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            selectionAnchor = id
        } else {
            selectedIDs = [id]
            selectionAnchor = id
        }
    }

    func selectAll() { selectedIDs = Set(pages.map(\.id)) }

    @discardableResult
    func move(_ ids: Set<UUID>, to targetID: UUID, after: Bool = false) -> Bool {
        guard pages.contains(where: { $0.id == targetID }), !ids.contains(targetID) else { return false }
        let moving = pages.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return false }
        let remaining = pages.filter { !ids.contains($0.id) }
        guard let targetIndex = remaining.firstIndex(where: { $0.id == targetID }) else { return false }
        let insertionIndex = targetIndex + (after ? 1 : 0)
        recordChange()
        pages = Array(remaining[..<insertionIndex]) + moving + Array(remaining[insertionIndex...])
        selectedIDs = Set(moving.map(\.id))
        return true
    }

    func rotateSelected(by degrees: Int) {
        guard !selectedIDs.isEmpty else { return }
        recordChange()
        for index in pages.indices where selectedIDs.contains(pages[index].id) {
            pages[index].rotation = (pages[index].rotation + degrees + 360) % 360
            thumbnails[pages[index].id] = nil
        }
    }

    func duplicateSelected() {
        guard !selectedIDs.isEmpty else { return }
        recordChange()
        var duplicated: Set<UUID> = []
        for index in pages.indices.reversed() where selectedIDs.contains(pages[index].id) {
            var copy = pages[index]
            copy = OrganizedPage(sourcePage: copy.sourcePage, sourceURL: copy.sourceURL, sourceIndex: copy.sourceIndex)
            copy.rotation = pages[index].rotation
            pages.insert(copy, at: index + 1)
            duplicated.insert(copy.id)
        }
        selectedIDs = duplicated
    }

    func deleteSelected() {
        guard !selectedIDs.isEmpty, selectedIDs.count < pages.count else {
            message = "すべてのページは削除できません。"
            return
        }
        recordChange()
        let removedIDs = selectedIDs
        pages.removeAll { removedIDs.contains($0.id) }
        for id in removedIDs { thumbnails[id] = nil }
        selectedIDs = []
    }

    func insert(from url: URL) throws {
        let (document, inserted) = try PDFPageOrganizerEngine.load(url: url)
        guard !inserted.isEmpty else { throw PDFPageOrganizerError.emptyDocument }
        recordChange()
        let insertionIndex = selectedPages.last.flatMap { selected in pages.firstIndex(where: { $0.id == selected.id }) }.map { $0 + 1 } ?? pages.count
        pages.insert(contentsOf: inserted, at: insertionIndex)
        selectedIDs = Set(inserted.map(\.id))
        retainedDocuments.append(document)
        inputURLs.append(url)
        message = "\(inserted.count)ページを挿入しました。"
    }

    func undo() {
        guard let prior = undoStack.popLast() else { return }
        redoStack.append(Snapshot(pages: pages, selectedIDs: selectedIDs))
        restore(prior)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(pages: pages, selectedIDs: selectedIDs))
        restore(next)
    }

    func loadThumbnail(for item: OrganizedPage) {
        guard thumbnails[item.id] == nil, let copy = item.sourcePage.copy() as? PDFPage else { return }
        copy.rotation = item.rotation
        thumbnails[item.id] = copy.thumbnail(of: CGSize(width: 250, height: 300), for: .cropBox)
    }

    func save(to url: URL, selectedOnly: Bool = false) throws {
        let outputPages = selectedOnly ? selectedPages : pages
        guard !outputPages.isEmpty else { throw PDFPageOrganizerError.emptySelection }
        try PDFPageOrganizerEngine.save(outputPages, to: url, protecting: inputURLs)
        message = "\(outputPages.count)ページを保存しました: \(url.lastPathComponent)"
    }

    func report(_ error: Error) { message = error.localizedDescription }

    private func recordChange() {
        undoStack.append(Snapshot(pages: pages, selectedIDs: selectedIDs))
        redoStack.removeAll()
        message = nil
    }

    private func restore(_ snapshot: Snapshot) {
        let currentRotations = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.rotation) })
        for page in snapshot.pages where currentRotations[page.id] != page.rotation {
            thumbnails[page.id] = nil
        }
        pages = snapshot.pages
        selectedIDs = snapshot.selectedIDs
        message = nil
    }
}

@MainActor
struct PDFPageOrganizerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var organizer: PDFPageOrganizerModel

    init(document: PDFDocument, sourceURL: URL) {
        _organizer = StateObject(wrappedValue: PDFPageOrganizerModel(document: document, sourceURL: sourceURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ページを整理").font(.title2.weight(.semibold))
                    Text("クリックで選択、⌘クリックで複数選択、Shiftクリックで範囲選択。カードの上半分/下半分へドロップして前後に並べ替えます。")
                        .font(.callout).foregroundStyle(NihoPalette.muted)
                }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(Array(organizer.pages.enumerated()), id: \.element.id) { index, page in
                            pageCard(page, index: index)
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text("変更結果のプレビュー").font(.headline)
                    if let page = organizer.primaryPage {
                        if let image = organizer.thumbnails[page.id] {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 360)
                                .background(NihoPalette.pdfStage)
                        } else {
                            ContentUnavailableView("プレビューを準備中", systemImage: "doc")
                                .frame(height: 360)
                        }
                        Text("\((organizer.pages.firstIndex { $0.id == page.id } ?? 0) + 1) / \(organizer.pages.count) ページ")
                            .foregroundStyle(NihoPalette.muted)
                        Text("元: \(page.sourceURL.lastPathComponent)・\(page.sourceIndex + 1)ページ")
                            .font(.caption).foregroundStyle(NihoPalette.muted)
                        Text("回転: \(page.rotation)°  サイズ: \(Int(page.sourcePage.bounds(for: .mediaBox).width)) × \(Int(page.sourcePage.bounds(for: .mediaBox).height)) pt")
                            .font(.caption).foregroundStyle(NihoPalette.muted)
                    }
                    Spacer()
                    Text("元のPDFは変更されません。保存時に別名のPDFを作成します。")
                        .font(.caption).foregroundStyle(NihoPalette.muted)
                }
                .padding(14)
                .frame(width: 310)
                .frame(maxHeight: .infinity)
                .background(NihoPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            }

            if let message = organizer.message {
                Text(message).font(.callout).textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button("すべて選択") { organizer.selectAll() }
                Button("別PDFから挿入…") { insertFromPanel() }
                Button("複製") { organizer.duplicateSelected() }.disabled(organizer.selectedIDs.isEmpty)
                Button("左回転") { organizer.rotateSelected(by: -90) }.disabled(organizer.selectedIDs.isEmpty)
                Button("右回転") { organizer.rotateSelected(by: 90) }.disabled(organizer.selectedIDs.isEmpty)
                Button("削除", role: .destructive) { organizer.deleteSelected() }.disabled(organizer.selectedIDs.isEmpty)
                Button("取り消す") { organizer.undo() }.disabled(!organizer.canUndo)
                Button("やり直す") { organizer.redo() }.disabled(!organizer.canRedo)
                Spacer()
                Button("選択ページを抽出…") { saveFromPanel(selectedOnly: true) }
                    .disabled(organizer.selectedIDs.isEmpty)
                Button("別名で保存…") { saveFromPanel(selectedOnly: false) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 1170, height: 720)
        .background(NihoPalette.canvas)
        .foregroundStyle(NihoPalette.ink)
        .tint(NihoPalette.green)
        .preferredColorScheme(.light)
    }

    private func pageCard(_ page: OrganizedPage, index: Int) -> some View {
        let selected = organizer.selectedIDs.contains(page.id)
        let targetID = page.id
        return VStack(spacing: 6) {
            Text("\(index + 1)").font(.caption.weight(.bold).monospacedDigit())
            Group {
                if let image = organizer.thumbnails[page.id] {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc.richtext").font(.largeTitle)
                }
            }
            .frame(height: 145)
            .frame(maxWidth: .infinity)
            .background(NihoPalette.pdfStage)
            Text("\(page.rotation)° · \(page.sourceURL.lastPathComponent)")
                .font(.caption2).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(selected ? NihoPalette.sageTint : NihoPalette.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? NihoPalette.green : NihoPalette.line, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            let modifiers = NSEvent.modifierFlags
            organizer.select(id: page.id, extending: modifiers.contains(.command), range: modifiers.contains(.shift))
        }
        .draggable(page.id.uuidString)
        .dropDestination(for: String.self) { draggedValues, location in
            guard let draggedID = draggedValues.first.flatMap(UUID.init(uuidString:)) else { return false }
            let ids = organizer.selectedIDs.contains(draggedID) ? organizer.selectedIDs : [draggedID]
            _ = organizer.move(ids, to: targetID, after: location.y >= 98)
            return true
        }
        .task(id: page.rotation) { organizer.loadThumbnail(for: page) }
        .accessibilityLabel("\(index + 1)ページ目、\(page.sourceURL.lastPathComponent)、回転\(page.rotation)度")
    }

    private func insertFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "挿入するPDFを選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try organizer.insert(from: url) }
        catch { organizer.report(error) }
    }

    private func saveFromPanel(selectedOnly: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = selectedOnly ? "抽出したページ.pdf" : "整理したPDF.pdf"
        panel.message = "入力PDFとは別のファイル名で保存します"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try organizer.save(to: url, selectedOnly: selectedOnly) }
        catch { organizer.report(error) }
    }
}
