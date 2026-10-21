import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct AppliedEdit {
    let pageIndex: Int
    let annotations: [PDFAnnotation]
    var replacement: ReplacementEdit
    var restoredAnnotations: [PDFAnnotation] = []
}

struct InsertionDraft {
    let pageIndex: Int
    let annotation: PDFAnnotation
    let detectedFontName: String?
    let automaticFontName: String
}

enum PendingPrintInputDecision {
    case commit
    case discard
    case cancel
}

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var mode: EditorMode = .replacement
    @Published var selectedTarget: TextTarget?
    @Published private(set) var isInlineEditing = false
    @Published private(set) var insertionDraft: InsertionDraft?
    @Published var replacementText = ""
    @Published private(set) var replacementFocusRequest = 0
    @Published private(set) var insertionFontChoice: InsertionFontChoice = .automatic
    @Published private(set) var replacementFontChoice: InsertionFontChoice = .automatic
    @Published private(set) var customFontName: String?
    @Published private(set) var insertionFontSize: Double = 12
    @Published private(set) var insertionFontColor: NSColor = .black
    @Published private(set) var importedFontFamilies: [String] = []
    @Published private(set) var edits: [AppliedEdit] = []
    @Published private(set) var revision = 0
    @Published private(set) var statusMessage = "PDFを開いて、変更したい文字をクリックしてください。"
    @Published var isShowingMergeSheet = false
    @Published var isShowingPageOrganizerSheet = false
    @Published var isShowingResizeSheet = false
    @Published var isShowingCompressionSheet = false
    @Published var isShowingSearchSheet = false
    @Published private(set) var searchQuery = ""
    @Published private(set) var searchResults: [PDFSearchHit] = []
    @Published private(set) var highlightedSearchSelections: [PDFSelection] = []
    @Published private(set) var focusedSearchSelection: PDFSelection?
    @Published private(set) var focusedSearchResultID: UUID?
    @Published private(set) var searchHighlightRevision = 0
    @Published private(set) var searchNavigationRevision = 0

    init(initialURL: URL?) {
        importedFontFamilies = PDFEmbeddedFontLoader.registerLocalFontFamilies()
        if let initialURL { load(url: initialURL) }
    }

    var canUndo: Bool { !edits.isEmpty }
    var activeReplacements: [ReplacementEdit] {
        let latestIndexByID = Dictionary(edits.enumerated().map { ($0.element.replacement.id, $0.offset) },
                                         uniquingKeysWith: { _, latest in latest })
        let latestEdits = edits.enumerated().compactMap { index, applied -> (Int, ReplacementEdit)? in
            latestIndexByID[applied.replacement.id] == index ? (index, applied.replacement) : nil
        }
        var visible: [(Int, ReplacementEdit)] = []
        for item in latestEdits {
            if item.1.destinationOrigin == nil, let layout = item.1.lineLayout,
               !item.1.lineReplacements.isEmpty {
                visible.removeAll { previous in
                    guard previous.1.destinationOrigin == nil,
                          let previousLayout = previous.1.lineLayout else { return false }
                    return layout.hasSameSourceLine(as: previousLayout)
                }
            }
            visible.append(item)
        }
        return visible.map(\.1)
    }
    var canPrint: Bool { document != nil && sourceURL != nil }
    var hasPendingEditorInput: Bool { isInlineEditing || insertionDraft != nil }
    var hasSelection: Bool { selectedTarget != nil }
    var hasInsertionLocation: Bool { insertionDraft != nil }
    var canEditText: Bool { mode == .replacement ? hasSelection : hasInsertionLocation }
    var canCommit: Bool {
        canEditText && !replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var pageCountText: String {
        guard let document else { return "PDF未選択" }
        return "\(document.pageCount)ページ"
    }
    var detectedFontName: String? { insertionDraft?.detectedFontName }
    var selectedFontDescription: PDFEmbeddedFontLoader.FontDescription? {
        guard let target = selectedTarget, let page = document?.page(at: target.pageIndex),
              let key = target.fontKey,
              let dictionary = PDFGlyphIndex.fontDictionary(for: key, page: page) else { return nil }
        return PDFEmbeddedFontLoader.describe(fontDict: dictionary)
    }
    var selectedFontChoiceName: String? {
        let choice = mode == .replacement ? replacementFontChoice : insertionFontChoice
        return choice == .custom ? customFontName : choice.fontName
    }
    var replacementFontPreview: PDFEmbeddedFontLoader.Resolution? {
        guard let target = selectedTarget, let page = document?.page(at: target.pageIndex) else { return nil }
        return PDFEditEngine.resolveFont(
            for: target, on: page, replacement: replacementText,
            preferredFontName: selectedFontChoiceName
        )
    }
    var insertionFontPreviewReason: String? {
        guard insertionDraft != nil, let requested = selectedFontChoiceName else { return nil }
        guard let font = PDFEmbeddedFontLoader.availableFont(named: requested, size: CGFloat(insertionFontSize)) else {
            return "指定フォント「\(requested)」がこのMacで利用できないため自動フォントを使います。"
        }
        let missing = PDFEmbeddedFontLoader.missingCharacters(in: replacementText, font: font)
        return missing.isEmpty ? nil : "指定フォントに \(missing.joined(separator: "")) のグリフがないため自動フォントを使います。"
    }
    var effectiveInsertionFontName: String {
        let automatic = insertionDraft?.automaticFontName ?? "Hiragino Sans"
        guard let requested = selectedFontChoiceName,
              let font = PDFEmbeddedFontLoader.availableFont(named: requested, size: CGFloat(insertionFontSize)),
              PDFEmbeddedFontLoader.missingCharacters(in: replacementText, font: font).isEmpty else {
            return automatic
        }
        return requested
    }

    func openFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "編集するPDFを1つ選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func importFontFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.font]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "利用できるフォントファイルを選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let families = try PDFEmbeddedFontLoader.registerFontFile(at: url)
            importedFontFamilies = Array(Set(importedFontFamilies + families)).sorted()
            if customFontName == nil { customFontName = importedFontFamilies.first }
            revision += 1
            statusMessage = families.isEmpty
                ? "フォントファイルを読み込みました。"
                : "フォントを読み込みました: \(families.joined(separator: "、"))。フォント欄から選べます。"
        } catch {
            statusMessage = "フォントを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    func showMergeSheet() {
        isShowingMergeSheet = true
    }

    func showPageOrganizerSheet() {
        guard let document, sourceURL != nil else { return }
        guard !hasPendingEditorInput else {
            statusMessage = "入力中の文字を確定してからページを整理してください。"
            return
        }
        guard document.allowsCopying && document.allowsDocumentAssembly else {
            statusMessage = "このPDFはページのコピーまたは組み替えが許可されていません。"
            return
        }
        isShowingPageOrganizerSheet = true
    }

    func showResizeSheet() {
        guard document != nil else { return }
        isShowingResizeSheet = true
    }

    func showCompressionSheet() {
        guard document != nil else { return }
        guard !hasPendingEditorInput else {
            statusMessage = "入力中の文字を確定してからPDFを圧縮してください。"
            return
        }
        isShowingCompressionSheet = true
    }

    func showSearchSheet() {
        guard document != nil else { return }
        isShowingSearchSheet = true
        if !searchResults.isEmpty {
            highlightedSearchSelections = searchResults.map(\.selection)
            searchHighlightRevision += 1
        }
    }

    func closeSearchSheet() {
        isShowingSearchSheet = false
        guard !highlightedSearchSelections.isEmpty else { return }
        highlightedSearchSelections = []
        searchHighlightRevision += 1
    }

    func search(_ query: String) {
        searchQuery = query
        focusedSearchResultID = nil
        focusedSearchSelection = nil
        guard let document else {
            searchResults = []
            highlightedSearchSelections = []
            searchHighlightRevision += 1
            return
        }

        searchResults = PDFSearchEngine.search(document: document, query: query)
        highlightedSearchSelections = searchResults.map(\.selection)
        searchHighlightRevision += 1
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, searchResults.isEmpty {
            statusMessage = "「\(query)」は見つかりません。画像だけのページはOCRが必要です。"
        } else if !searchResults.isEmpty {
            statusMessage = "\(searchResults.count)件見つかりました。結果を選ぶと該当ページへ移動します。"
        }
    }

    func focusSearchResult(_ result: PDFSearchHit) {
        guard searchResults.contains(where: { $0.id == result.id }) else { return }
        guard !isInlineEditing else {
            statusMessage = "編集中の文字を確定またはキャンセルしてから検索結果を選んでください。"
            return
        }

        focusedSearchSelection = result.selection
        focusedSearchResultID = result.id
        searchNavigationRevision += 1
        if mode == .replacement, let target = result.editTarget {
            select(target)
            statusMessage = "検索結果を編集対象にしました。置換する文字を入力してください。"
        } else if result.editTarget == nil {
            statusMessage = "\(result.pageIndex + 1)ページ目へ移動しました。文字情報を取得できないため、ページ上で対象を選択してください。"
        } else {
            statusMessage = "\(result.pageIndex + 1)ページ目の検索結果へ移動しました。"
        }
    }

    func moveSearchResult(by offset: Int) {
        guard !searchResults.isEmpty else { return }
        let currentIndex = searchResults.firstIndex { $0.id == focusedSearchResultID }
        let startIndex = currentIndex ?? (offset < 0 ? 0 : -1)
        let nextIndex = (startIndex + offset + searchResults.count) % searchResults.count
        focusSearchResult(searchResults[nextIndex])
    }

    func reportCompressionStatus(_ message: String) {
        statusMessage = message
    }

    func load(url: URL) {
        guard url.pathExtension.lowercased() == "pdf" else {
            statusMessage = "PDFファイルを指定してください。"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "指定されたPDFが見つかりません。"
            return
        }
        guard let loadedDocument = PDFDocument(url: url), loadedDocument.pageCount > 0 else {
            statusMessage = "PDFを読み込めませんでした。破損または未対応の形式です。"
            return
        }

        discardInsertionDraft()
        document = loadedDocument
        sourceURL = url
        selectedTarget = nil
        isInlineEditing = false
        replacementFontChoice = .automatic
        replacementText = ""
        edits = []
        searchResults = []
        highlightedSearchSelections = []
        focusedSearchSelection = nil
        focusedSearchResultID = nil
        searchHighlightRevision += 1
        searchNavigationRevision += 1
        revision += 1
        statusMessage = mode == .replacement
            ? "変更したい文字をクリックしてください。"
            : "PDF上の追加したい位置をクリックしてください。"
    }

    func setMode(_ newMode: EditorMode) {
        guard mode != newMode else { return }
        discardInsertionDraft()
        mode = newMode
        selectedTarget = nil
        isInlineEditing = false
        replacementFontChoice = .automatic
        replacementText = ""
        revision += 1
        statusMessage = newMode == .replacement
            ? "変更したい文字をクリックしてください。"
            : "PDF上の追加したい位置をクリックしてください。"
    }

    func select(_ target: TextTarget?) {
        guard mode == .replacement else { return }
        selectedTarget = target
        isInlineEditing = false
        replacementFontChoice = .automatic
        replacementText = target?.originalText ?? ""
        if let target {
            statusMessage = "\(target.pageIndex + 1)ページ目の文字を選択しました。ダブルクリックで編集、ドラッグで移動できます。"
        } else {
            statusMessage = "文字のない場所です。既存の文字をクリックしてください。"
        }
    }

    func beginInlineEditing() {
        guard mode == .replacement, selectedTarget != nil else { return }
        isInlineEditing = true
        replacementText = selectedTarget?.originalText ?? ""
        revision += 1
    }

    func cancelInlineEditing() {
        isInlineEditing = false
        replacementText = selectedTarget?.originalText ?? ""
        revision += 1
    }

    func beginInsertion(pageIndex: Int, point: CGPoint) {
        guard mode == .insertion, let document, let page = document.page(at: pageIndex) else { return }
        discardInsertionDraft()

        let style = PDFFontResolver.resolve(on: page, at: point)
        insertionFontChoice = .automatic
        insertionFontSize = Double(style.size.rounded())
        insertionFontColor = style.color
        replacementText = ""
        let bounds = PDFEditEngine.insertionBounds(
            at: point,
            text: "",
            fontName: style.resolvedName,
            fontSize: CGFloat(insertionFontSize),
            pageBounds: page.bounds(for: .mediaBox)
        )
        let annotation = PDFEditEngine.makeInsertionAnnotation(
            bounds: bounds,
            text: "",
            fontName: style.resolvedName,
            fontSize: CGFloat(insertionFontSize),
            fontColor: style.color
        )
        page.addAnnotation(annotation)
        insertionDraft = InsertionDraft(
            pageIndex: pageIndex,
            annotation: annotation,
            detectedFontName: style.detectedName,
            automaticFontName: style.resolvedName
        )
        replacementFocusRequest += 1
        revision += 1
        statusMessage = "\(pageIndex + 1)ページ目に入力位置を置きました。文字を入力してください。"
    }

    func updateEditorText(_ text: String) {
        replacementText = text
        refreshInsertionPreview()
    }

    func setInsertionFontChoice(_ choice: InsertionFontChoice) {
        insertionFontChoice = choice
        refreshInsertionPreview()
    }

    func setReplacementFontChoice(_ choice: InsertionFontChoice) {
        replacementFontChoice = choice
    }

    func setCustomFontName(_ name: String) {
        customFontName = name
        if mode == .replacement { replacementFontChoice = .custom }
        else { insertionFontChoice = .custom; refreshInsertionPreview() }
    }

    func setInsertionFontSize(_ size: Double) {
        insertionFontSize = min(max(size, 6), 72)
        refreshInsertionPreview()
    }

    func setInsertionFontColor(_ color: NSColor) {
        insertionFontColor = color
        refreshInsertionPreview()
    }

    func commitEditorText() {
        if mode == .replacement { applyReplacement() } else { applyInsertion() }
    }

    func applyReplacement() {
        guard let document, let target = selectedTarget,
              let page = document.page(at: target.pageIndex) else { return }
        let normalized = replacementText.trimmingCharacters(in: .newlines)
        guard !normalized.isEmpty else {
            statusMessage = "置換後の文字を入力してください。"
            return
        }
        let previewReason = replacementFontPreview?.reason
        let selectedFontName = selectedFontChoiceName
        let result = PDFEditEngine.applyReplacement(
            normalized, to: page, target: target, preferredFontName: selectedFontChoiceName
        )
        var replacement = result.edit
        var annotation = result.annotation
        if let layout = replacement.lineLayout,
           let previous = activeReplacements.last(where: { existing in
               existing.destinationOrigin == nil
                   && existing.lineLayout.map { layout.hasSameSourceLine(as: $0) } == true
           }) {
            let incoming = replacement.lineReplacements
            let incomingRanges = incoming.map(\.range)
            let preserved = previous.lineReplacements.filter { old in
                !incomingRanges.contains(where: { $0.overlaps(old.range) })
            }
            replacement.lineReplacements = preserved + incoming
            replacement.lineFont = previous.lineFont
            replacement.lineCompositionStart = min(previous.lineCompositionStart ?? layout.selectedRange.lowerBound,
                                                  layout.selectedRange.lowerBound)
            replacement.composesLineEdits = true
            page.removeAnnotation(result.annotation)
            annotation = ReplacementTextAnnotation(edit: replacement)
            page.addAnnotation(annotation)
        }
        edits.append(AppliedEdit(
            pageIndex: target.pageIndex,
            annotations: [annotation],
            replacement: replacement
        ))
        selectedTarget = nil
        isInlineEditing = false
        replacementText = ""
        revision += 1
        let fontMessage = previewReason ?? (selectedFontName == nil && !result.fontIsExact
            ? "元フォントを再現できないため代替フォントで描画します。" : "")
        statusMessage = "文字を置換しました。\(fontMessage)確認後に編集済みPDFを書き出してください。"
    }

    func moveSelection(by delta: CGPoint) {
        guard mode == .replacement, let document, let target = selectedTarget,
              let page = document.page(at: target.pageIndex) else { return }
        let pageBounds = page.bounds(for: .mediaBox)
        let x = min(max(target.bounds.minX + delta.x, pageBounds.minX), pageBounds.maxX - target.bounds.width)
        let y = min(max(target.baseline + delta.y, pageBounds.minY + target.baseline - target.bounds.minY),
                    pageBounds.maxY - (target.bounds.maxY - target.baseline))
        let result = PDFEditEngine.applyMovement(
            to: page,
            target: target,
            destination: CGPoint(x: x, y: y)
        )
        edits.append(AppliedEdit(pageIndex: target.pageIndex, annotations: result.annotations, replacement: result.edit))
        selectedTarget = nil
        isInlineEditing = false
        replacementText = ""
        revision += 1
        statusMessage = "選択した文字を移動しました。"
    }

    func moveExistingEdit(id: UUID, by delta: CGPoint) {
        guard let document,
              let previous = edits.last(where: { $0.replacement.id == id }),
              let page = document.page(at: previous.pageIndex),
              previous.replacement.kind == .replacement,
              !previous.replacement.replacement.isEmpty,
              !previous.annotations.isEmpty else { return }
        let edit = previous.replacement
        let oldAnnotations = previous.annotations
        let currentOrigin = edit.destinationOrigin ?? CGPoint(x: edit.bounds.minX, y: edit.baseline)
        let displayedBounds = edit.displayedTextBounds
        let pageBounds = page.bounds(for: .mediaBox)
        let x = min(max(currentOrigin.x + delta.x, pageBounds.minX),
                    max(pageBounds.maxX - displayedBounds.width, pageBounds.minX))
        let y = min(max(currentOrigin.y + delta.y, pageBounds.minY + edit.baseline - edit.bounds.minY),
                    max(pageBounds.maxY - (edit.bounds.maxY - edit.baseline), pageBounds.minY))
        let movedEdit = edit.movingSelection(to: CGPoint(x: x, y: y))
        for annotation in oldAnnotations { page.removeAnnotation(annotation) }
        let annotations = PDFEditEngine.addMovementAnnotations(for: movedEdit, to: page)
        edits.append(AppliedEdit(pageIndex: edit.pageIndex, annotations: annotations,
                                 replacement: movedEdit, restoredAnnotations: oldAnnotations))
        selectedTarget = nil
        isInlineEditing = false
        replacementText = ""
        revision += 1
        statusMessage = "文字の位置を移動しました。"
    }

    func deleteSelection() {
        guard mode == .replacement, let document, let target = selectedTarget,
              let page = document.page(at: target.pageIndex) else { return }
        let result = PDFEditEngine.applyDeletion(to: page, target: target)
        edits.append(AppliedEdit(
            pageIndex: target.pageIndex,
            annotations: [result.annotation],
            replacement: result.edit
        ))
        selectedTarget = nil
        isInlineEditing = false
        replacementText = ""
        revision += 1
        statusMessage = "選択した文字を表示から削除しました。確認後に編集済みPDFを書き出してください。"
    }

    func applyInsertion() {
        guard let draft = insertionDraft else { return }
        let normalized = replacementText.trimmingCharacters(in: .newlines)
        guard !normalized.isEmpty else {
            statusMessage = "追加する文字を入力してください。"
            return
        }
        let id = UUID()
        draft.annotation.contents = normalized
        draft.annotation.fontColor = insertionFontColor
        draft.annotation.userName = PDFEditEngine.annotationMarkerPrefix + id.uuidString
        let edit = ReplacementEdit(
            insertionOn: draft.pageIndex,
            bounds: draft.annotation.bounds,
            text: normalized,
            fontName: effectiveInsertionFontName,
            fontSize: CGFloat(insertionFontSize),
            fontColor: insertionFontColor,
            id: id
        )
        edits.append(AppliedEdit(pageIndex: draft.pageIndex, annotations: [draft.annotation], replacement: edit))
        insertionDraft = nil
        replacementText = ""
        revision += 1
        statusMessage = "テキストを追加しました。追加した文字はドラッグで移動できます。"
    }

    func moveInsertion(marker: String, pageIndex: Int, bounds: CGRect) {
        guard marker.hasPrefix(PDFEditEngine.annotationMarkerPrefix) else { return }
        if marker == PDFEditEngine.draftMarker {
            insertionDraft?.annotation.bounds = bounds
            revision += 1
            return
        }
        let rawID = String(marker.dropFirst(PDFEditEngine.annotationMarkerPrefix.count))
        guard let id = UUID(uuidString: rawID),
              let index = edits.lastIndex(where: { $0.pageIndex == pageIndex && $0.replacement.id == id }) else { return }
        edits[index].replacement = edits[index].replacement.moved(to: bounds)
        revision += 1
        statusMessage = "追加したテキストの位置を移動しました。"
    }

    func undoLastEdit() {
        guard let document, let edit = edits.popLast(),
              let page = document.page(at: edit.pageIndex) else { return }
        for annotation in edit.annotations.reversed() { page.removeAnnotation(annotation) }
        for annotation in edit.restoredAnnotations { page.addAnnotation(annotation) }
        selectedTarget = nil
        isInlineEditing = false
        replacementText = ""
        revision += 1
        statusMessage = "直前の変更を取り消しました。"
    }

    func exportFromPanel() {
        guard document != nil, let sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-edited.pdf"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.message = "元のPDFは上書きせず、編集済みPDFを別名で保存します"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        guard outputURL.standardizedFileURL != sourceURL.standardizedFileURL else {
            statusMessage = "元のPDFとは別のファイル名を指定してください。"
            return
        }
        do {
            try PDFExportEngine.export(sourceURL: sourceURL, edits: activeReplacements, to: outputURL)
            statusMessage = "保存しました: \(outputURL.lastPathComponent)"
        } catch {
            statusMessage = "PDFの保存に失敗しました。"
        }
    }

    @discardableResult
    func resizeFromPanel(size: PDFPageSize, label: String) -> Bool {
        guard let sourceURL, let document else { return false }
        guard size.isValid else {
            statusMessage = PDFPageResizeError.invalidSize.localizedDescription
            return false
        }
        guard document.allowsCopying && document.allowsDocumentAssembly else {
            statusMessage = "このPDFは内容のコピーまたはページの変更が許可されていません。"
            return false
        }
        guard !hasPendingEditorInput else {
            statusMessage = "入力中の文字を確定してからページサイズを変更してください。"
            return false
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-\(label).pdf"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.message = "元のPDFは上書きせず、ページサイズを変更したPDFを別名で保存します"
        guard panel.runModal() == .OK, let outputURL = panel.url else {
            statusMessage = "保存をキャンセルしました。"
            return false
        }

        let preparedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-resize-prepared-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: preparedURL) }
        do {
            let resizeSourceURL: URL
            if edits.isEmpty {
                resizeSourceURL = sourceURL
            } else {
                try PDFExportEngine.exportForPrinting(
                    sourceURL: sourceURL,
                    edits: activeReplacements,
                    to: preparedURL
                )
                resizeSourceURL = preparedURL
            }
            try PDFPageResizeEngine.resize(
                sourceURL: resizeSourceURL,
                to: outputURL,
                size: size,
                protecting: [sourceURL]
            )
            statusMessage = "ページサイズを変更して保存しました: \(outputURL.lastPathComponent)"
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func cropPreview(pageIndex: Int, margins: PDFCropMargins) -> PDFCropPreview? {
        guard let document, !hasPendingEditorInput,
              document.page(at: pageIndex) != nil else { return nil }
        let previewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-crop-preview-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: previewURL) }
        guard document.write(to: previewURL), let previewDocument = PDFDocument(url: previewURL) else { return nil }
        return try? PDFCropEngine.preview(document: previewDocument, pageIndex: pageIndex, margins: margins)
    }

    @discardableResult
    func cropFromPanel(margins: PDFCropMargins, pageSpecification: String) -> Bool {
        guard let sourceURL, let document else { return false }
        guard margins.isValid else {
            statusMessage = PDFCropError.invalidMargins.localizedDescription
            return false
        }
        guard !hasPendingEditorInput else {
            statusMessage = "入力中の文字を確定してから切り抜いてください。"
            return false
        }
        do {
            _ = try PDFCropEngine.pageIndices(from: pageSpecification, pageCount: document.pageCount)
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
        guard document.allowsCopying && document.allowsDocumentAssembly else {
            statusMessage = "このPDFは内容のコピーまたはページの変更が許可されていません。"
            return false
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-cropped.pdf"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.message = "表示範囲だけを変更したPDFを別名で保存します。隠れた内容はPDF内部に残ります。"
        guard panel.runModal() == .OK, let outputURL = panel.url else {
            statusMessage = "保存をキャンセルしました。"
            return false
        }

        let preparedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-crop-prepared-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: preparedURL) }
        do {
            guard document.write(to: preparedURL) else { throw PDFCropError.unreadableSource }
            try PDFCropEngine.crop(
                sourceURL: preparedURL,
                to: outputURL,
                margins: margins,
                pageSpecification: pageSpecification,
                protecting: [sourceURL]
            )
            statusMessage = "切り抜いて保存しました: \(outputURL.lastPathComponent)"
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func printFromPanel() {
        guard let sourceURL else { return }

        if hasPendingEditorInput {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "未確定の入力があります"
            alert.informativeText = "印刷用PDFへ反映するには入力を確定してください。入力を破棄して確定済みの編集だけを印刷することもできます。"
            alert.addButton(withTitle: "入力を確定して印刷")
            alert.addButton(withTitle: "入力を破棄して印刷")
            alert.addButton(withTitle: "印刷をキャンセル")

            let decision: PendingPrintInputDecision
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                decision = .commit
            case .alertSecondButtonReturn:
                decision = .discard
            default:
                decision = .cancel
            }
            guard resolvePendingPrintInput(decision) else {
                if decision == .commit {
                    statusMessage = "入力を確定できませんでした。内容を確認してから印刷してください。"
                } else {
                    statusMessage = "印刷をキャンセルしました。"
                }
                return
            }
        }

        do {
            let prepared = try PDFPrintPreparationEngine.prepare(
                sourceURL: sourceURL,
                edits: activeReplacements
            )
            defer { prepared.cleanup() }
            guard let operation = prepared.document.printOperation(
                for: NSPrintInfo.shared,
                scalingMode: .pageScaleDownToFit,
                autoRotate: true
            ) else {
                statusMessage = "標準の印刷ダイアログを準備できませんでした。"
                return
            }
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            statusMessage = operation.run()
                ? "印刷ジョブを送信しました。"
                : "印刷をキャンセルしました。"
        } catch {
            statusMessage = "印刷の準備に失敗しました: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func resolvePendingPrintInput(_ decision: PendingPrintInputDecision) -> Bool {
        guard hasPendingEditorInput else { return decision != .cancel }
        switch decision {
        case .commit:
            commitEditorText()
            return !hasPendingEditorInput
        case .discard:
            discardPendingEditorInput()
            return true
        case .cancel:
            return false
        }
    }

    private func refreshInsertionPreview() {
        guard mode == .insertion, let draft = insertionDraft,
              let page = document?.page(at: draft.pageIndex) else { return }
        PDFEditEngine.updateInsertionAnnotation(
            draft.annotation,
            page: page,
            text: replacementText,
            fontName: effectiveInsertionFontName,
            fontSize: CGFloat(insertionFontSize),
            fontColor: insertionFontColor
        )
        revision += 1
    }

    private func discardInsertionDraft() {
        guard let draft = insertionDraft else { return }
        document?.page(at: draft.pageIndex)?.removeAnnotation(draft.annotation)
        insertionDraft = nil
    }

    private func discardPendingEditorInput() {
        discardInsertionDraft()
        selectedTarget = nil
        isInlineEditing = false
        replacementText = ""
        revision += 1
    }
}
