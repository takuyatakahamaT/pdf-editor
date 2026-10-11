import Foundation
import PDFKit

struct PDFPageSize: Equatable {
    let widthMM: Double
    let heightMM: Double

    static let jisB5 = PDFPageSize(widthMM: 182, heightMM: 257)

    var widthPoints: Double { widthMM * 72 / 25.4 }
    var heightPoints: Double { heightMM * 72 / 25.4 }

    var isValid: Bool {
        widthMM.isFinite && heightMM.isFinite
            && (10...2_000).contains(widthMM)
            && (10...2_000).contains(heightMM)
    }
}

enum PDFPageResizeError: Error, Equatable, LocalizedError {
    case invalidSize
    case unreadableSource
    case lockedSource
    case copyingNotAllowed
    case assemblyNotAllowed
    case outputMatchesInput
    case helperMissing
    case conversionFailed(String)
    case invalidOutput
    case cannotSave

    var errorDescription: String? {
        switch self {
        case .invalidSize:
            return "幅と高さを10〜2,000 mmで指定してください。"
        case .unreadableSource:
            return "元のPDFを読み込めません。"
        case .lockedSource:
            return "パスワードでロックされたPDFは変換できません。"
        case .copyingNotAllowed:
            return "内容のコピーが許可されていないPDFは変換できません。"
        case .assemblyNotAllowed:
            return "ページの変更が許可されていないPDFは変換できません。"
        case .outputMatchesInput:
            return "元のPDFとは別の保存先を指定してください。"
        case .helperMissing:
            return "ページサイズ変換ツールがアプリに含まれていません。アプリを再ビルドしてください。"
        case .conversionFailed(let details):
            return details.isEmpty ? "PDFのページサイズを変更できませんでした。" : "PDFのページサイズを変更できませんでした: \(details)"
        case .invalidOutput:
            return "変換後のPDFを検証できませんでした。元のPDFは変更していません。"
        case .cannotSave:
            return "変換後のPDFを保存できませんでした。"
        }
    }
}

enum PDFPageResizeEngine {
    static func resize(
        sourceURL: URL,
        to outputURL: URL,
        size: PDFPageSize,
        protecting additionalSourceURLs: [URL] = [],
        helperURL: URL? = nil
    ) throws {
        guard size.isValid else { throw PDFPageResizeError.invalidSize }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path),
              let source = PDFDocument(url: sourceURL) else {
            throw PDFPageResizeError.unreadableSource
        }
        guard !source.isLocked else { throw PDFPageResizeError.lockedSource }
        guard source.pageCount > 0 else { throw PDFPageResizeError.unreadableSource }
        guard source.allowsCopying else { throw PDFPageResizeError.copyingNotAllowed }
        guard source.allowsDocumentAssembly else { throw PDFPageResizeError.assemblyNotAllowed }
        guard !([sourceURL] + additionalSourceURLs).contains(where: { sameFile($0, outputURL) }) else {
            throw PDFPageResizeError.outputMatchesInput
        }

        let executable = helperURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/pdfcpu")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PDFPageResizeError.helperMissing
        }

        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".pdf-editor-resize-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let description = "dim:\(size.widthPoints) \(size.heightPoints), enforce:on, rotate:off"
        let process = Process()
        process.executableURL = executable
        process.arguments = ["resize", description, sourceURL.path, temporaryURL.path]
        let log = Pipe()
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
        } catch {
            throw PDFPageResizeError.conversionFailed("")
        }
        let logData = log.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: logData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw PDFPageResizeError.conversionFailed(String(message.suffix(400)))
        }

        guard let output = PDFDocument(url: temporaryURL),
              output.pageCount == source.pageCount,
              (0..<output.pageCount).allSatisfy({ index in
                  guard let bounds = output.page(at: index)?.bounds(for: .mediaBox) else { return false }
                  return abs(bounds.width - size.widthPoints) < 0.1
                      && abs(bounds.height - size.heightPoints) < 0.1
              }) else {
            throw PDFPageResizeError.invalidOutput
        }

        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
        } catch {
            throw PDFPageResizeError.cannotSave
        }
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if left == right { return true }
        guard let leftIdentity = identity(left), let rightIdentity = identity(right) else {
            return false
        }
        return leftIdentity == rightIdentity
    }

    private static func identity(_ url: URL) -> [FileAttributeKey: NSNumber]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return [.systemNumber: device, .systemFileNumber: inode]
    }
}
