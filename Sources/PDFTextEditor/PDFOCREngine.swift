import AppKit
import PDFKit
import Vision

struct PDFOCRLine: Sendable, Identifiable {
    let id = UUID()
    let pageIndex: Int
    let text: String
    let confidence: Float
    let bounds: CGRect
    /// Text patches preserve the resolved font and point size so a later edit can use
    /// the same appearance. Real OCR results leave these unset.
    let fontPostScriptName: String?
    let fontSize: CGFloat?

    init(
        pageIndex: Int,
        text: String,
        confidence: Float,
        bounds: CGRect,
        fontPostScriptName: String? = nil,
        fontSize: CGFloat? = nil
    ) {
        self.pageIndex = pageIndex
        self.text = text
        self.confidence = confidence
        self.bounds = bounds
        self.fontPostScriptName = fontPostScriptName
        self.fontSize = fontSize
    }
}

struct PDFOCRResult: Sendable {
    let outputURL: URL
    let processedPages: [Int]
    let lowConfidenceLines: [PDFOCRLine]
}

enum PDFOCRError: LocalizedError {
    case unreadableSource, lockedSource, copyingNotAllowed, sameFile, noImagePages
    case cannotRender, cannotSave, recognitionFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSource: "PDFを読み込めませんでした。"
        case .lockedSource: "パスワードで保護されたPDFはOCRできません。"
        case .copyingNotAllowed: "内容のコピーまたはページの変更が許可されていません。"
        case .sameFile: "元のPDFとは別のファイル名を指定してください。"
        case .noImagePages: "指定した範囲に画像だけのページはありません。"
        case .cannotRender: "ページ画像を読み込めませんでした。"
        case .cannotSave: "OCR済みPDFを保存できませんでした。"
        case .recognitionFailed: "端末内のOCRを実行できませんでした。時間をおいて再試行してください。元のPDFは変更されていません。"
        }
    }
}

enum PDFOCREngine {
    static func hasLayer(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return PDFOCRLayerWriter.hasLayer(in: data)
    }

    static func candidatePages(in document: PDFDocument, selected: [Int]) -> [Int] {
        selected.filter { index in
            guard let page = document.page(at: index) else { return false }
            return (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func recognize(
        sourceURL: URL,
        outputURL: URL,
        selectedPages: [Int],
        languages: [String],
        progress: @Sendable (Int, Int) -> Void = { _, _ in },
        recognizePage: ((PDFPage, Int, [String]) throws -> [PDFOCRLine])? = nil
    ) throws -> PDFOCRResult {
        guard !sameFile(sourceURL, outputURL) else { throw PDFOCRError.sameFile }
        guard let input = PDFDocument(url: sourceURL) else { throw PDFOCRError.unreadableSource }
        guard !input.isLocked else { throw PDFOCRError.lockedSource }
        guard input.pageCount > 0 else { throw PDFOCRError.unreadableSource }
        guard input.allowsCopying && input.allowsDocumentAssembly else { throw PDFOCRError.copyingNotAllowed }
        let inputData: Data
        do { inputData = try Data(contentsOf: sourceURL) }
        catch { throw PDFOCRError.unreadableSource }
        let previousPages = PDFOCRLayerWriter.hasLayer(in: inputData)
            ? try PDFOCRLayerWriter.layeredPageIndexes(in: inputData) : []
        let baseData = previousPages.isEmpty ? inputData : try PDFOCRLayerWriter.removingLayer(from: inputData)
        guard let base = PDFDocument(data: baseData), base.pageCount == input.pageCount else {
            throw PDFOCRError.unreadableSource
        }
        guard !base.isLocked else { throw PDFOCRError.lockedSource }
        guard base.allowsCopying && base.allowsDocumentAssembly else { throw PDFOCRError.copyingNotAllowed }
        let targets = candidatePages(in: base, selected: Array(Set(selectedPages).union(previousPages)).sorted())
        guard !targets.isEmpty else { throw PDFOCRError.noImagePages }

        var lowConfidence: [PDFOCRLine] = []
        var processed: [Int] = []
        var linesByPage: [Int: [PDFOCRLine]] = [:]
        for index in 0..<base.pageCount {
            guard let page = base.page(at: index) else { throw PDFOCRError.unreadableSource }
            if targets.contains(index) {
                let lines: [PDFOCRLine]
                if let recognizePage {
                    lines = try recognizePage(page, index, languages)
                } else {
                    lines = try recognize(page: page, pageIndex: index, languages: languages)
                }
                if !lines.isEmpty {
                    linesByPage[index] = lines
                    processed.append(index)
                    lowConfidence += lines.filter { $0.confidence < 0.75 }
                }
                progress(targets.filter { $0 <= index }.count, targets.count)
            }
        }
        guard !processed.isEmpty else { throw PDFOCRError.noImagePages }
        // PDFKitで空のPDFへページを挿し直すと、しおり・添付・フォーム・文書情報など
        // ページ外のカタログ構造が失われる。元PDFのバイト列へOCRオブジェクトだけを
        // 増分追記し、既存のカタログとページオブジェクトをそのまま維持する。
        let layeredData = try PDFOCRLayerWriter.add(linesByPage: linesByPage, to: baseData)
        do { try layeredData.write(to: outputURL, options: .atomic) }
        catch { throw PDFOCRError.cannotSave }
        return PDFOCRResult(outputURL: outputURL, processedPages: processed, lowConfidenceLines: lowConfidence)
    }

    static func removeLayer(sourceURL: URL, outputURL: URL) throws {
        guard !sameFile(sourceURL, outputURL) else { throw PDFOCRError.sameFile }
        guard let input = PDFDocument(url: sourceURL) else { throw PDFOCRError.unreadableSource }
        guard !input.isLocked else { throw PDFOCRError.lockedSource }
        guard input.allowsCopying && input.allowsDocumentAssembly else { throw PDFOCRError.copyingNotAllowed }
        let data: Data
        do { data = try Data(contentsOf: sourceURL) }
        catch { throw PDFOCRError.unreadableSource }
        let stripped = try PDFOCRLayerWriter.removingLayer(from: data)
        guard let strippedDocument = PDFDocument(data: stripped) else { throw PDFOCRError.cannotSave }
        let clean = PDFDocument()
        for index in 0..<strippedDocument.pageCount {
            guard let page = strippedDocument.page(at: index)?.copy() as? PDFPage else {
                throw PDFOCRError.cannotSave
            }
            clean.insert(page, at: index)
        }
        guard clean.write(to: outputURL) else { throw PDFOCRError.cannotSave }
    }

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL.resolvingSymlinksInPath() ==
            rhs.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let left = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let right = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let leftDevice = left[.systemNumber] as? NSNumber,
              let rightDevice = right[.systemNumber] as? NSNumber,
              let leftInode = left[.systemFileNumber] as? NSNumber,
              let rightInode = right[.systemFileNumber] as? NSNumber else { return false }
        return leftDevice == rightDevice && leftInode == rightInode
    }

    private static func recognize(page: PDFPage, pageIndex: Int, languages: [String]) throws -> [PDFOCRLine] {
        let box = page.bounds(for: .mediaBox)
        // Render up to roughly 288 dpi for small print, with a bounded 4,000 px edge
        // so unusually large pages do not allocate unbounded bitmap memory.
        let scale = min(4.0, 4000 / max(box.width, box.height))
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PDFOCRError.cannotRender
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        let rotation = page.rotation
        page.rotation = 0
        page.draw(with: .mediaBox, to: context)
        page.rotation = rotation
        guard let image = context.makeImage() else { throw PDFOCRError.cannotRender }
        let request = VNRecognizeTextRequest()
        request.revision = languages.contains("ja-JP")
            ? VNRecognizeTextRequestRevision3 : VNRecognizeTextRequestRevision1
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            throw PDFOCRError.recognitionFailed
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return PDFOCRLine(pageIndex: pageIndex, text: candidate.string,
                              confidence: candidate.confidence, bounds: observation.boundingBox)
        }
    }
}
