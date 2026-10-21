import Foundation
import PDFKit

enum PDFPrintPreparationError: Error, Equatable, LocalizedError {
    case unreadableSource
    case lockedSource
    case printingNotAllowed
    case exportFailed
    case unreadablePreparedPDF

    var errorDescription: String? {
        switch self {
        case .unreadableSource:
            return "印刷元のPDFを読み込めません。"
        case .lockedSource:
            return "印刷元のPDFがロックされています。"
        case .printingNotAllowed:
            return "このPDFは印刷が許可されていません。"
        case .exportFailed:
            return "確定済みの編集を印刷用PDFへ反映できませんでした。"
        case .unreadablePreparedPDF:
            return "作成した印刷用PDFを読み込めませんでした。"
        }
    }
}

final class PreparedPrintDocument {
    let url: URL
    let document: PDFDocument
    private var didCleanUp = false

    init(url: URL, document: PDFDocument) {
        self.url = url
        self.document = document
    }

    func cleanup() {
        guard !didCleanUp else { return }
        didCleanUp = true
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        cleanup()
    }
}

enum PDFPrintPreparationEngine {
    static func prepare(
        sourceURL: URL,
        edits: [ReplacementEdit],
        markups: [PDFMarkupEdit] = [],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> PreparedPrintDocument {
        guard let sourceDocument = PDFDocument(url: sourceURL) else {
            throw PDFPrintPreparationError.unreadableSource
        }
        guard !sourceDocument.isLocked else {
            throw PDFPrintPreparationError.lockedSource
        }
        guard sourceDocument.allowsPrinting else {
            throw PDFPrintPreparationError.printingNotAllowed
        }

        let outputURL = temporaryDirectory
            .appendingPathComponent("pdf-editor-print-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        do {
            try PDFExportEngine.exportForPrinting(
                sourceURL: sourceURL,
                edits: edits,
                markups: markups,
                to: outputURL
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw PDFPrintPreparationError.exportFailed
        }
        guard let preparedDocument = PDFDocument(url: outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw PDFPrintPreparationError.unreadablePreparedPDF
        }
        return PreparedPrintDocument(url: outputURL, document: preparedDocument)
    }
}
