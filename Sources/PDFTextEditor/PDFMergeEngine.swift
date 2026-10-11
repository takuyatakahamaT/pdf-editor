import Foundation
import PDFKit

struct PDFMergeInput: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let pageCount: Int

    init(id: UUID = UUID(), url: URL, pageCount: Int) {
        self.id = id
        self.url = url
        self.pageCount = pageCount
    }
}

struct PDFMergeResult: Equatable {
    let outputURL: URL
    let pageCount: Int
}

enum PDFMergeError: Error, Equatable, LocalizedError {
    case insufficientInputs
    case unreadableFile(URL)
    case lockedFile(URL)
    case noPages(URL)
    case copyingNotAllowed(URL)
    case assemblyNotAllowed(URL)
    case outputMatchesInput(URL)
    case cannotCopyPage(URL, Int)
    case cannotAssemble(URL, Int)
    case cannotEncode
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .insufficientInputs:
            return "結合するPDFを2ファイル以上指定してください。"
        case .unreadableFile(let url):
            return "「\(url.lastPathComponent)」を読み込めません。ファイルのアクセス権またはPDFの内容を確認してください。"
        case .lockedFile(let url):
            return "「\(url.lastPathComponent)」はパスワードでロックされています。ロックを解除したPDFを選んでください。"
        case .noPages(let url):
            return "「\(url.lastPathComponent)」には結合できるページがありません。"
        case .copyingNotAllowed(let url):
            return "「\(url.lastPathComponent)」は内容のコピーが許可されていないため結合できません。"
        case .assemblyNotAllowed(let url):
            return "「\(url.lastPathComponent)」はページの組み替えが許可されていないため結合できません。"
        case .outputMatchesInput(let url):
            return "保存先が入力PDF「\(url.lastPathComponent)」と同じファイルです。別の保存先を指定してください。"
        case .cannotCopyPage(let url, let pageIndex):
            return "「\(url.lastPathComponent)」の\(pageIndex + 1)ページ目をコピーできませんでした。"
        case .cannotAssemble(let url, let pageIndex):
            return "「\(url.lastPathComponent)」の\(pageIndex + 1)ページ目を結合結果へ追加できませんでした。"
        case .cannotEncode:
            return "結合したPDFデータを作成できませんでした。"
        case .cannotWrite(let url):
            return "結合したPDFを「\(url.lastPathComponent)」へ保存できませんでした。"
        }
    }
}

enum PDFMergeEngine {
    private struct ValidatedInput {
        let item: PDFMergeInput
        let document: PDFDocument
    }

    static func inspect(url: URL) throws -> PDFMergeInput {
        try validate(url: url).item
    }

    static func merge(inputURLs: [URL], to outputURL: URL) throws -> PDFMergeResult {
        guard inputURLs.count >= 2 else {
            throw PDFMergeError.insufficientInputs
        }
        let validatedInputs = try inputURLs.map(validate)

        for input in validatedInputs where refersToSameFile(input.item.url, outputURL) {
            throw PDFMergeError.outputMatchesInput(input.item.url)
        }

        let mergedDocument = PDFDocument()
        var insertionIndex = 0
        for input in validatedInputs {
            for pageIndex in 0..<input.document.pageCount {
                guard let sourcePage = input.document.page(at: pageIndex),
                      let copiedPage = sourcePage.copy() as? PDFPage else {
                    throw PDFMergeError.cannotCopyPage(input.item.url, pageIndex)
                }
                mergedDocument.insert(copiedPage, at: insertionIndex)
                guard mergedDocument.pageCount == insertionIndex + 1,
                      mergedDocument.page(at: insertionIndex) != nil else {
                    throw PDFMergeError.cannotAssemble(input.item.url, pageIndex)
                }
                insertionIndex += 1
            }
        }

        guard let data = mergedDocument.dataRepresentation() else {
            throw PDFMergeError.cannotEncode
        }

        // Save only after every input has been validated and every page has been copied.
        // Data.write(.atomic) keeps a failed write from leaving a partial destination file.
        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw PDFMergeError.cannotWrite(outputURL)
        }
        return PDFMergeResult(outputURL: outputURL, pageCount: insertionIndex)
    }

    private static func validate(url: URL) throws -> ValidatedInput {
        let normalizedURL = url.standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: normalizedURL.path),
              let document = PDFDocument(url: normalizedURL) else {
            throw PDFMergeError.unreadableFile(url)
        }
        guard !document.isLocked else {
            throw PDFMergeError.lockedFile(url)
        }
        guard document.pageCount > 0 else {
            throw PDFMergeError.noPages(url)
        }
        guard document.allowsCopying else {
            throw PDFMergeError.copyingNotAllowed(url)
        }
        guard document.allowsDocumentAssembly else {
            throw PDFMergeError.assemblyNotAllowed(url)
        }
        return ValidatedInput(
            item: PDFMergeInput(url: normalizedURL, pageCount: document.pageCount),
            document: document
        )
    }

    private static func refersToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let normalizedLeft = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedRight = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if normalizedLeft == normalizedRight { return true }

        guard let leftIdentity = fileIdentity(at: normalizedLeft),
              let rightIdentity = fileIdentity(at: normalizedRight) else {
            return false
        }
        return leftIdentity == rightIdentity
    }

    private static func fileIdentity(at url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }
}
