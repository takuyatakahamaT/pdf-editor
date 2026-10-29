import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct AppliedEdit {
    let pageIndex: Int
    var annotations: [PDFAnnotation]
    var replacement: ReplacementEdit?
    var restoredAnnotations: [PDFAnnotation] = []
    var markupChange: MarkupChange?

    init(
        pageIndex: Int,
        annotations: [PDFAnnotation],
        replacement: ReplacementEdit? = nil,
        restoredAnnotations: [PDFAnnotation] = [],
        markupChange: MarkupChange? = nil
    ) {
        self.pageIndex = pageIndex
        self.annotations = annotations
        self.replacement = replacement
        self.restoredAnnotations = restoredAnnotations
        self.markupChange = markupChange
    }
}

enum MarkupChange {
    case added(PDFMarkupEdit)
    case changed(before: PDFMarkupEdit, after: PDFMarkupEdit)
    case deleted(PDFMarkupEdit)
}

struct InsertionDraft {
    let pageIndex: Int
    let annotation: PDFAnnotation
    let detectedFontName: String?
    let automaticFontName: String
    let editingID: UUID?
    let restoredAnnotations: [PDFAnnotation]
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
    @Published private(set) var replacementFontSize: Double = 12
    @Published private(set) var customFontName: String?
    @Published private(set) var insertionFontSize: Double = 12
    @Published private(set) var insertionFontColor: NSColor = .black
    @Published private(set) var importedFontFamilies: [String] = []
    @Published private(set) var edits: [AppliedEdit] = []
    @Published private(set) var redactionRegions: [PDFRedactionRegion] = []
    @Published private(set) var activeMarkupEdits: [PDFMarkupEdit] = []
    @Published private(set) var selectedMarkupTool: PDFMarkupTool = .highlight
    @Published private(set) var selectedMarkupID: UUID?
    @Published var markupText = ""
    @Published var signatureText = UserDefaults.standard.string(forKey: "PDFEditor.SignatureText") ?? ""
    @Published private(set) var revision = 0
    @Published private(set) var statusMessage = "PDFを開いて、変更したい文字をクリックしてください。"
    /// 失敗・拒否の文言。画面の下に数秒だけ出す。
    @Published private(set) var noticeMessage: String?
    @Published private(set) var noticeRevision = 0
    @Published var isShowingMergeSheet = false
    @Published var isShowingPageOrganizerSheet = false
    @Published var isShowingResizeSheet = false
    @Published var isShowingCompressionSheet = false
    @Published var isShowingSearchSheet = false
    @Published var isShowingOCRSheet = false
    @Published private(set) var ocrIsRunning = false
    @Published private(set) var ocrProgress = ""
    @Published private(set) var ocrLowConfidenceLines: [PDFOCRLine] = []
    @Published private(set) var ocrProcessedPages: [Int] = []
    @Published private(set) var ocrLayerPresent = false
    @Published private(set) var searchQuery = ""
    @Published private(set) var searchResults: [PDFSearchHit] = []
    @Published private(set) var highlightedSearchSelections: [PDFSelection] = []
    @Published private(set) var focusedSearchSelection: PDFSelection?
    @Published private(set) var focusedSearchResultID: UUID?
    @Published private(set) var searchHighlightRevision = 0
    @Published private(set) var searchNavigationRevision = 0

    private var redoEdits: [AppliedEdit] = []
    private var editingReplacementID: UUID?

    init(initialURL: URL?) {
        importedFontFamilies = PDFEmbeddedFontLoader.registerLocalFontFamilies()
        if let initialURL { load(url: initialURL) }
    }

    var canUndo: Bool { !edits.isEmpty }
    var canRedo: Bool { !redoEdits.isEmpty }
    var activeReplacements: [ReplacementEdit] {
        let latestIndexByID = Dictionary(
            edits.enumerated().compactMap { index, applied in
                applied.replacement.map { ($0.id, index) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let latestEdits = edits.enumerated().compactMap { index, applied -> (Int, ReplacementEdit)? in
            guard let replacement = applied.replacement,
                  latestIndexByID[replacement.id] == index else { return nil }
            return (index, replacement)
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
    var canPrint: Bool { document != nil && sourceURL != nil && redactionRegions.isEmpty }
    var canExport: Bool { document != nil && redactionRegions.isEmpty }
    var hasOCRLayer: Bool { ocrLayerPresent }
    var canStartOCR: Bool { document != nil && !ocrIsRunning && !canUndo && !hasPendingEditorInput }
    var hasPendingEditorInput: Bool { isInlineEditing || insertionDraft != nil || !redactionRegions.isEmpty }
    var hasSelection: Bool { selectedTarget != nil }
    var hasInsertionLocation: Bool { insertionDraft != nil }
    var isReeditingInsertion: Bool { insertionDraft?.editingID != nil }
    var selectedMarkup: PDFMarkupEdit? {
        guard let selectedMarkupID else { return nil }
        return activeMarkupEdits.first(where: { $0.id == selectedMarkupID })
    }
    var canEditText: Bool {
        switch mode {
        case .replacement: hasSelection
        case .insertion: hasInsertionLocation
        case .redaction: false
        case .markup: hasSelection && selectedMarkupTool.isTextMarkup
        }
    }
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
        return PDFEmbeddedFontLoader.describe(
            fontDict: dictionary,
            postScriptNameOverride: target.fontPostScriptNameOverride
        )
    }
    var selectedFontChoiceName: String? {
        let choice = mode == .replacement ? replacementFontChoice : insertionFontChoice
        return choice == .custom ? customFontName : choice.fontName
    }
    var selectedReplacementFontSelection: ReplacementFontSelection {
        ReplacementFontSelection(choice: replacementFontChoice, customFontName: customFontName)
    }
    var selectedInsertionFontSelection: ReplacementFontSelection {
        ReplacementFontSelection(choice: insertionFontChoice, customFontName: customFontName)
    }
    var replacementFontPreview: PDFEmbeddedFontLoader.Resolution? {
        guard let target = selectedTarget, let page = document?.page(at: target.pageIndex) else { return nil }
        return PDFEditEngine.resolveFont(
            for: target, on: page, replacement: replacementText,
            preferredFontName: selectedFontChoiceName,
            size: CGFloat(replacementFontSize)
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

    /// 失敗・拒否を画面に短く知らせる。下のステータス行を撤去したぶん、帯で見せる。
    private func notice(_ message: String) {
        statusMessage = message
        noticeMessage = message
        noticeRevision += 1
    }

    func dismissNotice() {
        noticeMessage = nil
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
            notice("フォントを読み込めませんでした: \(error.localizedDescription)")
        }
    }

    func showMergeSheet() {
        guard !hasPendingEditorInput else {
            notice("墨消し範囲をプレビュー中は結合できません。範囲を外すか、墨消し済みPDFを作成してください。")
            return
        }
        isShowingMergeSheet = true
    }

    func showPageOrganizerSheet() {
        guard let document, sourceURL != nil else { return }
        guard !hasPendingEditorInput else {
            notice("入力中の文字を確定してからページを整理してください。")
            return
        }
        guard document.allowsCopying && document.allowsDocumentAssembly else {
            notice("このPDFはページのコピーまたは組み替えが許可されていません。")
            return
        }
        isShowingPageOrganizerSheet = true
    }

    func showResizeSheet() {
        guard document != nil else { return }
        guard !hasPendingEditorInput else {
            notice("墨消し範囲をプレビュー中はページサイズを変更できません。範囲を外すか、墨消し済みPDFを作成してください。")
            return
        }
        isShowingResizeSheet = true
    }

    func showCompressionSheet() {
        guard document != nil else { return }
        guard !hasPendingEditorInput else {
            notice("入力中の文字を確定してからPDFを圧縮してください。")
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
            notice("編集中の文字を確定またはキャンセルしてから検索結果を選んでください。")
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
            notice("PDFファイルを指定してください。")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            notice("指定されたPDFが見つかりません。")
            return
        }
        guard let loadedDocument = PDFDocument(url: url), loadedDocument.pageCount > 0 else {
            notice("PDFを読み込めませんでした。破損または未対応の形式です。")
            return
        }

        discardInsertionDraft()
        document = loadedDocument
        sourceURL = url
        ocrLayerPresent = PDFOCREngine.hasLayer(url: url)
        selectedTarget = nil
        isInlineEditing = false
        replacementFontChoice = .automatic
        replacementFontSize = 12
        editingReplacementID = nil
        replacementText = ""
        edits = []
        redactionRegions = []
        ocrLowConfidenceLines = []
        ocrProcessedPages = []
        ocrProgress = ""
        redoEdits = []
        activeMarkupEdits = PDFMarkupEngine.edits(in: loadedDocument)
        selectedMarkupID = nil
        markupText = ""
        searchResults = []
        highlightedSearchSelections = []
        focusedSearchSelection = nil
        focusedSearchResultID = nil
        searchHighlightRevision += 1
        searchNavigationRevision += 1
        revision += 1
        statusMessage = statusForMode(mode)
    }

    func runOCR(pageSpecification: String, languages: [String]) {
        guard canStartOCR, let sourceURL, let document else { return }
        let selected: [Int]
        do { selected = try PDFCropEngine.pageIndices(from: pageSpecification, pageCount: document.pageCount) }
        catch { notice(error.localizedDescription); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-ocr.pdf"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.message = "OCR済みPDFを別名で保存します。元のPDFは変更しません。"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        guard !PDFOCREngine.sameFile(sourceURL, outputURL) else {
            notice(PDFOCRError.sameFile.localizedDescription)
            return
        }
        ocrIsRunning = true
        ocrProgress = "画像だけのページを解析しています…"
        let owner = self
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PDFOCREngine.recognize(sourceURL: sourceURL, outputURL: outputURL,
                                               selectedPages: selected, languages: languages) { completed, total in
                        Task { @MainActor in
                            owner.ocrProgress = "\(completed) / \(total) ページ処理済み"
                        }
                    }
                }.value
                load(url: result.outputURL)
                ocrProcessedPages = result.processedPages
                ocrLowConfidenceLines = result.lowConfidenceLines
                ocrProgress = "処理が完了しました。"
                statusMessage = "OCR済みPDFを保存しました。検索・選択・コピーできます。"
            } catch {
                notice(error.localizedDescription)
                ocrProgress = error.localizedDescription
            }
            ocrIsRunning = false
        }
    }

    func removeOCRLayer() {
        guard hasOCRLayer, let sourceURL, !ocrIsRunning, !canUndo else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-without-ocr.pdf"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.message = "OCR層を除いたPDFを別名で保存します。"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        guard !PDFOCREngine.sameFile(sourceURL, outputURL) else {
            notice(PDFOCRError.sameFile.localizedDescription)
            return
        }
        ocrIsRunning = true
        ocrProgress = "OCR層を削除しています…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try PDFOCREngine.removeLayer(sourceURL: sourceURL, outputURL: outputURL)
                }.value
                load(url: outputURL)
                statusMessage = "OCR層を削除したPDFを保存しました。"
            } catch {
                notice(error.localizedDescription)
                ocrProgress = error.localizedDescription
            }
            ocrIsRunning = false
        }
    }

    func setMode(_ newMode: EditorMode) {
        guard mode != newMode else { return }
        discardInsertionDraft()
        mode = newMode
        selectedTarget = nil
        selectedMarkupID = nil
        isInlineEditing = false
        replacementFontChoice = .automatic
        replacementText = ""
        revision += 1
        statusMessage = statusForMode(newMode)
    }

    func setMarkupTool(_ tool: PDFMarkupTool) {
        selectedMarkupTool = tool
        selectedTarget = nil
        selectedMarkupID = nil
        revision += 1
        statusMessage = tool.isTextMarkup
            ? "注釈を付ける文字をクリックして選択してください。"
            : "PDF上をクリックまたはドラッグして「\(tool.title)」を配置してください。"
    }

    func selectMarkup(_ id: UUID?) {
        selectedTarget = nil
        isInlineEditing = false
        selectedMarkupID = id
        guard let id, let edit = activeMarkupEdits.first(where: { $0.id == id }) else { return }
        if edit.tool == .note { markupText = edit.text }
        if edit.tool == .signature { signatureText = edit.text }
        statusMessage = "\(edit.tool.title)を選択しました。移動・削除できます。"
    }

    func setMarkupText(_ text: String) {
        markupText = text
    }

    func setSignatureText(_ text: String) {
        signatureText = text
    }

    func saveSignatureLocally() {
        let value = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            notice("保存する署名を入力してください。")
            return
        }
        signatureText = value
        UserDefaults.standard.set(value, forKey: "PDFEditor.SignatureText")
        statusMessage = "署名をこのMacに保存しました。"
    }

    func applySelectedTextMarkup() {
        guard mode == .markup, selectedMarkupTool.isTextMarkup,
              let target = selectedTarget else {
            notice("先に注釈を付ける文字を選択してください。")
            return
        }
        addMarkup(pageIndex: target.pageIndex, bounds: target.bounds, points: [], text: "")
    }

    func addMarkup(pageIndex: Int, bounds: CGRect, points: [CGPoint] = [], text: String? = nil) {
        guard mode == .markup, let document, let page = document.page(at: pageIndex) else { return }
        let tool = selectedMarkupTool
        var annotationText = text ?? ""
        if tool == .note { annotationText = markupText.trimmingCharacters(in: .whitespacesAndNewlines) }
        if tool == .signature { annotationText = signatureText.trimmingCharacters(in: .whitespacesAndNewlines) }
        if tool.usesTextInput && annotationText.isEmpty {
            notice(tool == .note ? "メモの内容を入力してください。" : "署名する名前を入力してください。")
            return
        }
        guard bounds.width >= 1, bounds.height >= 1 else {
            notice("注釈の範囲が小さすぎます。")
            return
        }
        let edit = PDFMarkupEdit(
            pageIndex: pageIndex,
            tool: tool,
            bounds: bounds,
            points: points,
            text: annotationText
        )
        let annotation = PDFMarkupEngine.makeAnnotation(for: edit)
        page.addAnnotation(annotation)
        activeMarkupEdits.append(edit)
        selectedMarkupID = edit.id
        recordEdit(AppliedEdit(
            pageIndex: pageIndex,
            annotations: [annotation],
            markupChange: .added(edit)
        ))
        selectedTarget = nil
        revision += 1
        statusMessage = "\(tool.title)を追加しました。保存後もPDF内で編集できます。"
    }

    func moveMarkup(id: UUID, to bounds: CGRect) {
        guard mode == .markup, let document,
              let index = activeMarkupEdits.firstIndex(where: { $0.id == id }),
              let page = document.page(at: activeMarkupEdits[index].pageIndex) else { return }
        let previous = activeMarkupEdits[index]
        var updated = previous
        updated.bounds = bounds
        updated.points = previous.points.map { point in
            CGPoint(
                x: bounds.minX + (point.x - previous.bounds.minX) / max(previous.bounds.width, 1) * bounds.width,
                y: bounds.minY + (point.y - previous.bounds.minY) / max(previous.bounds.height, 1) * bounds.height
            )
        }
        let newAnnotation = PDFMarkupEngine.makeAnnotation(for: updated)
        let existingAnnotation = page.annotations.first(where: { $0.userName == PDFMarkupEngine.markerPrefix + id.uuidString })
        let oldAnnotation = existingAnnotation ?? PDFMarkupEngine.makeAnnotation(for: previous)
        oldAnnotation.bounds = previous.bounds
        if existingAnnotation != nil { page.removeAnnotation(oldAnnotation) }
        page.addAnnotation(newAnnotation)
        activeMarkupEdits[index] = updated
        recordEdit(AppliedEdit(
            pageIndex: updated.pageIndex,
            annotations: [newAnnotation],
            restoredAnnotations: [oldAnnotation],
            markupChange: .changed(before: previous, after: updated)
        ))
        revision += 1
        statusMessage = "\(updated.tool.title)を移動しました。"
    }

    func updateSelectedMarkupText(_ text: String) {
        guard let id = selectedMarkupID,
              let index = activeMarkupEdits.firstIndex(where: { $0.id == id }),
              activeMarkupEdits[index].tool == .note || activeMarkupEdits[index].tool == .signature,
              let document, let page = document.page(at: activeMarkupEdits[index].pageIndex) else { return }
        if activeMarkupEdits[index].tool == .signature,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notice("署名は空にできません。文字を入力してください。")
            return
        }
        let previous = activeMarkupEdits[index]
        var updated = previous
        updated.text = text
        let newAnnotation = PDFMarkupEngine.makeAnnotation(for: updated)
        let oldAnnotation = page.annotations.first(where: { $0.userName == PDFMarkupEngine.markerPrefix + id.uuidString })
            ?? PDFMarkupEngine.makeAnnotation(for: previous)
        if page.annotations.contains(where: { $0 === oldAnnotation }) { page.removeAnnotation(oldAnnotation) }
        page.addAnnotation(newAnnotation)
        activeMarkupEdits[index] = updated
        recordEdit(AppliedEdit(
            pageIndex: updated.pageIndex,
            annotations: [newAnnotation],
            restoredAnnotations: [oldAnnotation],
            markupChange: .changed(before: previous, after: updated)
        ))
        revision += 1
    }

    func commitSelectedMarkupText() {
        guard let selectedMarkup else { return }
        updateSelectedMarkupText(selectedMarkup.tool == .note ? markupText : signatureText)
    }

    func deleteSelectedMarkup() {
        guard let id = selectedMarkupID,
              let index = activeMarkupEdits.firstIndex(where: { $0.id == id }),
              let document, let page = document.page(at: activeMarkupEdits[index].pageIndex) else { return }
        let deleted = activeMarkupEdits.remove(at: index)
        let annotation = page.annotations.first(where: { $0.userName == PDFMarkupEngine.markerPrefix + id.uuidString })
        if let annotation { page.removeAnnotation(annotation) }
        recordEdit(AppliedEdit(
            pageIndex: deleted.pageIndex,
            annotations: [],
            restoredAnnotations: annotation.map { [$0] } ?? [PDFMarkupEngine.makeAnnotation(for: deleted)],
            markupChange: .deleted(deleted)
        ))
        selectedMarkupID = nil
        revision += 1
        statusMessage = "注釈を削除しました。Undoで戻せます。"
    }

    func select(_ target: TextTarget?) {
        guard mode == .replacement || mode == .redaction
                || (mode == .markup && selectedMarkupTool.isTextMarkup) else { return }
        selectedMarkupID = nil
        selectedTarget = target
        isInlineEditing = false
        editingReplacementID = nil
        if mode == .replacement {
            replacementFontChoice = .automatic
            replacementFontSize = Double(target?.fontSize ?? 12)
            replacementText = target?.originalText ?? ""
        }
        if let target {
            statusMessage = mode == .replacement
                ? "\(target.pageIndex + 1)ページ目の文字を選択しました。ダブルクリックで編集、ドラッグで移動できます。"
                : mode == .redaction
                ? "\(target.pageIndex + 1)ページ目の文字を選択しました。墨消し対象に追加できます。"
                : "\(target.pageIndex + 1)ページ目の文字を選択しました。注釈を適用できます。"
        } else {
            statusMessage = mode == .replacement
                ? "文字のない場所です。既存の文字をクリックしてください。"
                : mode == .redaction
                ? "文字のない場所です。墨消しする文字をクリックしてください。"
                : "文字のない場所です。注釈を付ける文字をクリックしてください。"
        }
    }

    func addSelectedRedactionRegion() {
        guard mode == .redaction, let target = selectedTarget else {
            notice("先に墨消しする文字をPDF上で選択してください。")
            return
        }
        addRedactionRegion(pageIndex: target.pageIndex, bounds: target.bounds, text: target.originalText)
        selectedTarget = nil
    }

    func addRedactionRegion(pageIndex: Int, bounds: CGRect, text: String = "") {
        guard mode == .redaction,
              let page = document?.page(at: pageIndex),
              bounds.width > 0, bounds.height > 0,
              !bounds.isNull, !bounds.isInfinite else {
            notice("PDFページ内の範囲を指定してください。")
            return
        }
        let clippedBounds = bounds.intersection(page.bounds(for: .cropBox))
        guard !clippedBounds.isNull, !clippedBounds.isEmpty else {
            notice("墨消し範囲がページ内にありません。")
            return
        }
        guard !redactionRegions.contains(where: {
            $0.pageIndex == pageIndex && $0.bounds == clippedBounds
        }) else {
            notice("この範囲はすでに墨消し対象へ追加されています。")
            return
        }
        redactionRegions.append(PDFRedactionRegion(pageIndex: pageIndex, bounds: clippedBounds, text: text))
        selectedTarget = nil
        revision += 1
        statusMessage = "墨消し対象を\(redactionRegions.count)か所プレビューしています。"
    }

    func removeRedactionRegion(id: UUID) {
        redactionRegions.removeAll { $0.id == id }
        revision += 1
        statusMessage = redactionRegions.isEmpty
            ? "墨消し対象をすべて外しました。"
            : "墨消し対象を\(redactionRegions.count)か所プレビューしています。"
    }

    func clearRedactionRegions() {
        redactionRegions = []
        selectedTarget = nil
        revision += 1
        statusMessage = "墨消し対象をすべて外しました。"
    }

    func applyRedactionsFromPanel() {
        guard let sourceURL, !redactionRegions.isEmpty else {
            notice("先に墨消し対象を追加してください。")
            return
        }

        let confirmation = NSAlert()
        confirmation.alertStyle = .critical
        confirmation.messageText = "墨消しを適用しますか？"
        confirmation.informativeText = "適用後は元に戻せません。元PDFは変更せず別ファイルを作ります。全ページを高解像度画像に変換するため、テキスト選択・検索、注釈、リンク、フォームは出力に残りません。元PDFのタイトル・作者などの文書メタデータも引き継ぎません。PDF生成ライブラリが新しい作成日時やProducer情報を付ける場合があります。画像内の文字も選択範囲に重なる部分は黒くなります。"
        confirmation.addButton(withTitle: "墨消し済みPDFを作成")
        confirmation.addButton(withTitle: "キャンセル")
        guard confirmation.runModal() == .alertFirstButtonReturn else {
            statusMessage = "墨消しをキャンセルしました。"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-redacted.pdf"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.message = "元PDFを保持し、画像化した墨消し済みPDFを別名保存します"
        guard panel.runModal() == .OK, let outputURL = panel.url else {
            statusMessage = "墨消し済みPDFの保存をキャンセルしました。"
            return
        }
        do {
            try PDFRedactionEngine.export(
                sourceURL: sourceURL,
                regions: redactionRegions,
                edits: activeReplacements,
                markups: activeMarkupEdits,
                forcePrepareSource: !edits.isEmpty,
                to: outputURL
            )
            statusMessage = "墨消し済みPDFを保存しました。ページ本文を画像化し、元PDFの文書メタデータは引き継いでいません: \(outputURL.lastPathComponent)"
            redactionRegions = []
            selectedTarget = nil
            revision += 1
        } catch {
            notice("安全な墨消しを完了できませんでした: \(error.localizedDescription)")
        }
    }

    func beginInlineEditing() {
        guard mode == .replacement, selectedTarget != nil else { return }
        isInlineEditing = true
        if editingReplacementID == nil {
            replacementText = selectedTarget?.originalText ?? ""
        }
        revision += 1
    }

    func cancelInlineEditing() {
        isInlineEditing = false
        if editingReplacementID != nil {
            selectedTarget = nil
            replacementText = ""
            editingReplacementID = nil
        } else {
            replacementText = selectedTarget?.originalText ?? ""
        }
        revision += 1
    }

    func beginReeditingReplacement(id: UUID) {
        guard mode == .replacement else { return }
        let active = activeReplacements.last(where: { edit in
            edit.id == id || edit.lineReplacements.contains(where: { $0.id == id })
        })
        let source = edits.last(where: { $0.replacement?.id == id })?.replacement
        guard let active, let source, source.kind == .replacement else { return }
        let currentRun = active.lineReplacements.first(where: { $0.id == id })
        let currentText = currentRun?.text ?? active.replacement
        guard !currentText.isEmpty else { return }
        selectedTarget = source.sourceTarget
        replacementText = currentText
        let fontSelection = currentRun?.outputFontSelection ?? active.outputFontSelection
        replacementFontChoice = fontSelection.choice
        if fontSelection.choice == .custom {
            customFontName = fontSelection.customFontName
        }
        replacementFontSize = Double(currentRun.map { CTFontGetSize($0.font) } ?? active.fontSize)
        editingReplacementID = id
        isInlineEditing = true
        revision += 1
        statusMessage = "置換済みの文字を再編集しています。現在の出力は\(formattedPointSize(CGFloat(replacementFontSize))) ptです。"
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
            automaticFontName: style.resolvedName,
            editingID: nil,
            restoredAnnotations: []
        )
        replacementFocusRequest += 1
        revision += 1
        statusMessage = "\(pageIndex + 1)ページ目に入力位置を置きました。文字を入力してください。"
    }

    func beginReeditingInsertion(id: UUID) {
        guard mode == .insertion,
              let document,
              let applied = edits.last(where: { $0.replacement?.id == id }),
              let edit = applied.replacement,
              edit.kind == .insertion,
              let page = document.page(at: edit.pageIndex) else { return }
        discardInsertionDraft()

        for annotation in applied.annotations { page.removeAnnotation(annotation) }
        let actualFontName = edit.fontName ?? "Hiragino Sans"
        let annotation = PDFEditEngine.makeInsertionAnnotation(
            bounds: edit.bounds,
            text: edit.replacement,
            fontName: actualFontName,
            fontSize: edit.fontSize,
            fontColor: edit.fontColor
        )
        page.addAnnotation(annotation)
        let selection = edit.outputFontSelection
        insertionFontChoice = selection.choice
        if selection.choice == .custom {
            customFontName = selection.customFontName
        }
        insertionFontSize = Double(edit.fontSize)
        insertionFontColor = edit.fontColor
        replacementText = edit.replacement
        insertionDraft = InsertionDraft(
            pageIndex: edit.pageIndex,
            annotation: annotation,
            detectedFontName: actualFontName,
            automaticFontName: actualFontName,
            editingID: id,
            restoredAnnotations: applied.annotations
        )
        replacementFocusRequest += 1
        revision += 1
        statusMessage = "追加済みテキストを再編集しています。現在の出力は\(formattedPointSize(edit.fontSize)) ptです。"
    }

    func cancelInsertionEditing() {
        guard insertionDraft != nil else { return }
        discardInsertionDraft()
        replacementText = ""
        revision += 1
        statusMessage = "テキスト追加の編集をキャンセルしました。"
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

    func setReplacementFontSize(_ size: Double) {
        replacementFontSize = min(max(size, 6), 72)
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
        switch mode {
        case .replacement: applyReplacement()
        case .insertion: applyInsertion()
        case .redaction: addSelectedRedactionRegion()
        case .markup: applySelectedTextMarkup()
        }
    }

    func applyReplacement() {
        guard let document, let target = selectedTarget,
              let page = document.page(at: target.pageIndex) else { return }
        let normalized = replacementText.trimmingCharacters(in: .newlines)
        guard !normalized.isEmpty else {
            notice("置換後の文字を入力してください。")
            return
        }
        let previewReason = replacementFontPreview?.reason
        let selectedFontName = selectedFontChoiceName
        let previousApplied = editingReplacementID.flatMap { id in
            edits.last(where: { $0.replacement?.id == id })
        }
        let previousEdit = previousApplied?.replacement
        let result = PDFEditEngine.prepareReplacement(
            normalized,
            on: page,
            target: target,
            preferredFontName: selectedFontChoiceName,
            outputFontSize: CGFloat(replacementFontSize),
            id: previousEdit?.id ?? UUID(),
            destinationOrigin: previousEdit?.destinationOrigin,
            outputFontSelection: selectedReplacementFontSelection
        )
        var replacement = result.edit
        var supersededApplied = previousApplied
        if replacement.destinationOrigin == nil,
           let layout = replacement.lineLayout,
           let previous = activeReplacements.last(where: { existing in
               existing.destinationOrigin == nil
                   && (existing.id != replacement.id
                       || existing.lineReplacements.contains(where: { $0.id != replacement.id }))
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
            supersededApplied = edits.last(where: { $0.replacement?.id == previous.id })
        }
        let fit = PDFTextRenderer.fitResult(for: replacement, in: page.bounds(for: .mediaBox))
        guard fit.fits else {
            notice(
                "置換文字が配置可能範囲（隣接文字またはページ境界）を\(formattedPointSize(fit.overflow)) pt超えます。"
                    + " 出力サイズ（現在 \(formattedPointSize(CGFloat(replacementFontSize))) pt）を小さくして再度確定してください。"
            )
            return
        }

        if replacement.destinationOrigin == nil, !replacement.composesLineEdits, let sourceURL {
            switch PDFInternalTextEditEngine.eligibility(sourceURL: sourceURL, edit: replacement) {
            case .supported:
                replacement.storage = .internalPDFium
            case .unsupported(let reason):
                replacement.storage = .overlay(reason: reason)
            }
        } else {
            replacement.storage = .overlay(reason: "移動または行再配置を含むためPDF内部置換の対象外です。")
        }

        let restoredAnnotations = supersededApplied?.annotations ?? []
        for annotation in restoredAnnotations { page.removeAnnotation(annotation) }
        let annotations: [PDFAnnotation]
        if replacement.destinationOrigin != nil {
            annotations = PDFEditEngine.addMovementAnnotations(for: replacement, to: page)
        } else {
            let annotation = ReplacementTextAnnotation(edit: replacement)
            page.addAnnotation(annotation)
            annotations = [annotation]
        }
        recordEdit(AppliedEdit(
            pageIndex: target.pageIndex,
            annotations: annotations,
            replacement: replacement,
            restoredAnnotations: restoredAnnotations
        ))
        selectedTarget = nil
        isInlineEditing = false
        editingReplacementID = nil
        replacementText = ""
        revision += 1
        let fontMessage = previewReason ?? (selectedFontName == nil && !result.fontIsExact
            ? "元フォントを再現できないため代替フォントで描画します。" : "")
        let storageMessage: String
        switch replacement.storage {
        case .internalPDFium:
            storageMessage = "保存時にPDF内部の単一text objectを置換し、再読込検証します。"
        case .overlay(let reason):
            storageMessage = "白い重ね描きで保存します（\(reason)）。元の文字データはPDF内に残ります。画像・罫線・背景との干渉は完全には判定できません。墨消しには使えません。"
        }
        statusMessage = "文字を置換しました（出力 \(formattedPointSize(replacement.fontSize)) pt）。\(storageMessage)\(fontMessage)確認後に編集済みPDFを書き出してください。"
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
        recordEdit(AppliedEdit(pageIndex: target.pageIndex, annotations: result.annotations, replacement: result.edit))
        selectedTarget = nil
        isInlineEditing = false
        editingReplacementID = nil
        replacementText = ""
        revision += 1
        statusMessage = "選択した文字を移動しました。"
    }

    func moveExistingEdit(id: UUID, by delta: CGPoint) {
        guard let document,
              let previous = edits.last(where: { $0.replacement?.id == id }),
              let page = document.page(at: previous.pageIndex),
              let edit = previous.replacement,
              edit.kind == .replacement,
              !edit.replacement.isEmpty,
              !previous.annotations.isEmpty else { return }
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
        recordEdit(AppliedEdit(pageIndex: edit.pageIndex, annotations: annotations,
                               replacement: movedEdit, restoredAnnotations: oldAnnotations))
        selectedTarget = nil
        isInlineEditing = false
        editingReplacementID = nil
        replacementText = ""
        revision += 1
        statusMessage = "文字の位置を移動しました。"
    }

    func deleteSelection() {
        guard mode == .replacement, let document, let target = selectedTarget,
              let page = document.page(at: target.pageIndex) else { return }
        let result = PDFEditEngine.applyDeletion(to: page, target: target)
        recordEdit(AppliedEdit(
            pageIndex: target.pageIndex,
            annotations: [result.annotation],
            replacement: result.edit
        ))
        selectedTarget = nil
        isInlineEditing = false
        editingReplacementID = nil
        replacementText = ""
        revision += 1
        statusMessage = "選択した文字を表示から削除しました。確認後に編集済みPDFを書き出してください。"
    }

    func applyInsertion() {
        guard let draft = insertionDraft,
              let page = document?.page(at: draft.pageIndex) else { return }
        let normalized = replacementText.trimmingCharacters(in: .newlines)
        guard !normalized.isEmpty else {
            notice("追加する文字を入力してください。")
            return
        }
        let actualFontName = effectiveInsertionFontName
        let fit = PDFEditEngine.insertionFitResult(
            text: normalized,
            fontName: actualFontName,
            fontSize: CGFloat(insertionFontSize),
            bounds: draft.annotation.bounds,
            pageBounds: page.bounds(for: .mediaBox)
        )
        guard fit.fits else {
            notice(
                "追加テキストが入力枠またはページ境界を\(formattedPointSize(fit.overflow)) pt超えます。"
                    + " 文字を短くするか、出力サイズ（現在 \(formattedPointSize(CGFloat(insertionFontSize))) pt）を小さくしてください。"
            )
            return
        }
        let id = draft.editingID ?? UUID()
        draft.annotation.contents = normalized
        draft.annotation.fontColor = insertionFontColor
        draft.annotation.userName = PDFEditEngine.annotationMarkerPrefix + id.uuidString
        let edit = ReplacementEdit(
            insertionOn: draft.pageIndex,
            bounds: draft.annotation.bounds,
            text: normalized,
            fontName: actualFontName,
            fontSize: CGFloat(insertionFontSize),
            fontColor: insertionFontColor,
            id: id,
            outputFontSelection: selectedInsertionFontSelection
        )
        recordEdit(AppliedEdit(
            pageIndex: draft.pageIndex,
            annotations: [draft.annotation],
            replacement: edit,
            restoredAnnotations: draft.restoredAnnotations
        ))
        insertionDraft = nil
        replacementText = ""
        revision += 1
        statusMessage = draft.editingID == nil
            ? "テキストを追加しました（出力 \(formattedPointSize(edit.fontSize)) pt）。追加した文字はドラッグで移動できます。"
            : "追加済みテキストを更新しました（出力 \(formattedPointSize(edit.fontSize)) pt）。"
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
              let index = edits.lastIndex(where: { $0.pageIndex == pageIndex && $0.replacement?.id == id }),
              let replacement = edits[index].replacement,
              replacement.kind == .insertion,
              replacement.bounds != bounds,
              let page = document?.page(at: pageIndex) else { return }
        let priorAnnotation = PDFEditEngine.makeInsertionAnnotation(
            bounds: replacement.bounds,
            text: replacement.replacement,
            fontName: replacement.fontName ?? "Hiragino Sans",
            fontSize: replacement.fontSize,
            fontColor: replacement.fontColor,
            marker: marker
        )
        let moved = replacement.moved(to: bounds)
        let movedAnnotation = PDFEditEngine.makeInsertionAnnotation(
            bounds: bounds,
            text: moved.replacement,
            fontName: moved.fontName ?? "Hiragino Sans",
            fontSize: moved.fontSize,
            fontColor: moved.fontColor,
            marker: marker
        )
        for annotation in edits[index].annotations { page.removeAnnotation(annotation) }
        page.addAnnotation(movedAnnotation)
        edits[index].annotations = [priorAnnotation]
        recordEdit(AppliedEdit(
            pageIndex: pageIndex,
            annotations: [movedAnnotation],
            replacement: moved,
            restoredAnnotations: [priorAnnotation]
        ))
        revision += 1
        statusMessage = "追加したテキストの位置を移動しました。"
    }

    func undoLastEdit() {
        if insertionDraft != nil {
            discardInsertionDraft()
            replacementText = ""
        }
        guard let document, let edit = edits.popLast(),
              let page = document.page(at: edit.pageIndex) else { return }
        for annotation in edit.annotations.reversed() { page.removeAnnotation(annotation) }
        for annotation in edit.restoredAnnotations { page.addAnnotation(annotation) }
        if let change = edit.markupChange { undoMarkupState(change) }
        redoEdits.append(edit)
        selectedMarkupID = nil
        selectedTarget = nil
        isInlineEditing = false
        editingReplacementID = nil
        replacementText = ""
        revision += 1
        statusMessage = "直前の変更を取り消しました。"
    }

    func redoLastEdit() {
        if insertionDraft != nil {
            discardInsertionDraft()
            replacementText = ""
        }
        guard let document, let edit = redoEdits.popLast(),
              let page = document.page(at: edit.pageIndex) else { return }
        for annotation in edit.restoredAnnotations.reversed() { page.removeAnnotation(annotation) }
        for annotation in edit.annotations { page.addAnnotation(annotation) }
        if let change = edit.markupChange { redoMarkupState(change) }
        edits.append(edit)
        selectedTarget = nil
        isInlineEditing = false
        editingReplacementID = nil
        replacementText = ""
        revision += 1
        statusMessage = "変更をやり直しました。"
    }

    func exportFromPanel() {
        guard document != nil, let sourceURL else { return }
        guard redactionRegions.isEmpty else {
            notice("墨消し範囲をプレビュー中は通常書き出しできません。範囲を外すか、墨消し済みPDFを作成してください。")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-edited.pdf"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.message = "元のPDFは上書きせず、編集済みPDFを別名で保存します"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        guard outputURL.standardizedFileURL != sourceURL.standardizedFileURL else {
            notice("元のPDFとは別のファイル名を指定してください。")
            return
        }
        do {
            try PDFExportEngine.export(
                sourceURL: sourceURL,
                edits: activeReplacements,
                markups: activeMarkupEdits,
                to: outputURL
            )
            statusMessage = "保存しました: \(outputURL.lastPathComponent)"
        } catch PDFExportError.overlappingEditPaths {
            notice("内部置換と重ね描きが同じ位置で重なるため保存できません。編集位置を離すか、一方の編集を取り消してください。")
        } catch {
            notice("PDFの保存に失敗しました。")
        }
    }

    @discardableResult
    func resizeFromPanel(size: PDFPageSize, label: String) -> Bool {
        guard let sourceURL, let document else { return false }
        guard size.isValid else {
            notice(PDFPageResizeError.invalidSize.localizedDescription)
            return false
        }
        guard document.allowsCopying && document.allowsDocumentAssembly else {
            notice("このPDFは内容のコピーまたはページの変更が許可されていません。")
            return false
        }
        guard !hasPendingEditorInput else {
            notice("入力中の文字を確定してからページサイズを変更してください。")
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
                try PDFExportEngine.export(
                    sourceURL: sourceURL,
                    edits: activeReplacements,
                    markups: activeMarkupEdits,
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
            notice(error.localizedDescription)
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
            notice(PDFCropError.invalidMargins.localizedDescription)
            return false
        }
        guard !hasPendingEditorInput else {
            notice("入力中の文字を確定してから切り抜いてください。")
            return false
        }
        do {
            _ = try PDFCropEngine.pageIndices(from: pageSpecification, pageCount: document.pageCount)
        } catch {
            notice(error.localizedDescription)
            return false
        }
        guard document.allowsCopying && document.allowsDocumentAssembly else {
            notice("このPDFは内容のコピーまたはページの変更が許可されていません。")
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
            notice(error.localizedDescription)
            return false
        }
    }

    func printFromPanel() {
        guard let sourceURL else { return }
        guard redactionRegions.isEmpty else {
            notice("墨消し範囲をプレビュー中は印刷できません。範囲を外すか、墨消し済みPDFを作成してください。")
            return
        }

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
                    notice("入力を確定できませんでした。内容を確認してから印刷してください。")
                } else {
                    statusMessage = "印刷をキャンセルしました。"
                }
                return
            }
        }

        do {
            let prepared = try PDFPrintPreparationEngine.prepare(
                sourceURL: sourceURL,
                edits: activeReplacements,
                markups: activeMarkupEdits
            )
            defer { prepared.cleanup() }
            guard let operation = prepared.document.printOperation(
                for: NSPrintInfo.shared,
                scalingMode: .pageScaleDownToFit,
                autoRotate: true
            ) else {
                notice("標準の印刷ダイアログを準備できませんでした。")
                return
            }
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            statusMessage = operation.run()
                ? "印刷ジョブを送信しました。"
                : "印刷をキャンセルしました。"
        } catch {
            notice("印刷の準備に失敗しました: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func resolvePendingPrintInput(_ decision: PendingPrintInputDecision) -> Bool {
        guard redactionRegions.isEmpty else {
            notice("墨消し範囲をプレビュー中は印刷できません。範囲を外すか、墨消し済みPDFを作成してください。")
            return false
        }
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

    private func recordEdit(_ edit: AppliedEdit) {
        edits.append(edit)
        redoEdits.removeAll()
    }

    private func formattedPointSize(_ size: CGFloat) -> String {
        Double(size).formatted(.number.precision(.fractionLength(0...1)))
    }

    private func undoMarkupState(_ change: MarkupChange) {
        switch change {
        case .added(let edit):
            activeMarkupEdits.removeAll { $0.id == edit.id }
        case .changed(let before, _):
            if let index = activeMarkupEdits.firstIndex(where: { $0.id == before.id }) {
                activeMarkupEdits[index] = before
            }
        case .deleted(let edit):
            if !activeMarkupEdits.contains(where: { $0.id == edit.id }) {
                activeMarkupEdits.append(edit)
            }
        }
    }

    private func redoMarkupState(_ change: MarkupChange) {
        switch change {
        case .added(let edit):
            if !activeMarkupEdits.contains(where: { $0.id == edit.id }) {
                activeMarkupEdits.append(edit)
            }
        case .changed(_, let after):
            if let index = activeMarkupEdits.firstIndex(where: { $0.id == after.id }) {
                activeMarkupEdits[index] = after
            }
        case .deleted(let edit):
            activeMarkupEdits.removeAll { $0.id == edit.id }
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
        if let page = document?.page(at: draft.pageIndex) {
            page.removeAnnotation(draft.annotation)
            for annotation in draft.restoredAnnotations where annotation.page == nil {
                page.addAnnotation(annotation)
            }
        }
        insertionDraft = nil
    }

    private func discardPendingEditorInput() {
        discardInsertionDraft()
        selectedTarget = nil
        isInlineEditing = false
        replacementText = ""
        revision += 1
    }

    private func statusForMode(_ mode: EditorMode) -> String {
        switch mode {
        case .replacement: "変更したい文字をクリックしてください。"
        case .insertion: "PDF上の追加したい位置をクリックしてください。"
        case .redaction: "墨消し対象の文字を選択して、範囲をプレビューしてください。"
        case .markup: "注釈・署名の種類を選び、PDF上に配置してください。"
        }
    }
}
