import Foundation
import PDFKit

enum PDFCompressionError: Error, Equatable, LocalizedError {
    case invalidQuality
    case unreadableSource
    case lockedSource
    case copyingNotAllowed
    case outputMatchesInput
    case helperMissing
    case conversionFailed(String)
    case invalidOutput
    case cannotSave

    var errorDescription: String? {
        switch self {
        case .invalidQuality: "JPEG画質は90〜98%、または画像を再圧縮しない設定を選んでください。"
        case .unreadableSource: "元のPDFを読み込めません。"
        case .lockedSource: "パスワードでロックされたPDFは圧縮できません。"
        case .copyingNotAllowed: "内容のコピーが許可されていないPDFは圧縮できません。"
        case .outputMatchesInput: "元のPDFとは別の保存先を指定してください。"
        case .helperMissing: "PDF圧縮ツールがアプリに含まれていません。アプリを再ビルドしてください。"
        case .conversionFailed(let details):
            details.isEmpty ? "PDFを圧縮できませんでした。" : "PDFを圧縮できませんでした: \(details)"
        case .invalidOutput: "圧縮後のPDFを検証できませんでした。元のPDFは変更していません。"
        case .cannotSave: "圧縮後のPDFを保存できませんでした。"
        }
    }
}

struct PDFCompressionEstimate: Sendable {
    let temporaryURL: URL
    let sourceBytes: Int64
    let outputBytes: Int64

    var reductionPercent: Double {
        guard sourceBytes > 0 else { return 0 }
        return (1 - Double(outputBytes) / Double(sourceBytes)) * 100
    }
}

enum PDFCompressionEngine {
    static func estimate(
        sourceURL: URL,
        originalURL: URL,
        quality: Int,
        helperURL: URL? = nil
    ) throws -> PDFCompressionEstimate {
        guard quality == 0 || (90...98).contains(quality) else { throw PDFCompressionError.invalidQuality }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path),
              let source = PDFDocument(url: sourceURL), source.pageCount > 0 else {
            throw PDFCompressionError.unreadableSource
        }
        guard !source.isLocked else { throw PDFCompressionError.lockedSource }
        guard source.allowsCopying else { throw PDFCompressionError.copyingNotAllowed }
        let executable = helperURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/pdf-compress")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PDFCompressionError.helperMissing
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-compressed-\(UUID().uuidString).pdf")
        let process = Process()
        process.executableURL = executable
        process.arguments = [sourceURL.path, outputURL.path, String(quality)]
        let log = Pipe()
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
            let logData = log.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PDFCompressionError.conversionFailed(
                    String(String(data: logData, encoding: .utf8)?.suffix(400) ?? "")
                )
            }
            guard let output = PDFDocument(url: outputURL),
                  output.pageCount == source.pageCount,
                  pagesMatch(source, output) else {
                throw PDFCompressionError.invalidOutput
            }
            let sourceBytes = try fileSize(originalURL)
            let outputBytes = try fileSize(outputURL)
            guard outputBytes > 0 else { throw PDFCompressionError.invalidOutput }
            return PDFCompressionEstimate(
                temporaryURL: outputURL,
                sourceBytes: sourceBytes,
                outputBytes: outputBytes
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            if let compressionError = error as? PDFCompressionError { throw compressionError }
            throw PDFCompressionError.conversionFailed("")
        }
    }

    static func save(_ estimate: PDFCompressionEstimate, to outputURL: URL, protecting sourceURL: URL) throws {
        guard !sameFile(sourceURL, outputURL),
              !sameFile(estimate.temporaryURL, outputURL) else {
            throw PDFCompressionError.outputMatchesInput
        }
        guard (try? fileSize(estimate.temporaryURL)) == estimate.outputBytes else {
            throw PDFCompressionError.invalidOutput
        }
        let stagedURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".pdf-editor-compressed-save-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        do {
            try FileManager.default.copyItem(at: estimate.temporaryURL, to: stagedURL)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: stagedURL)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: outputURL)
            }
        } catch {
            throw PDFCompressionError.cannotSave
        }
    }

    private static func pagesMatch(_ source: PDFDocument, _ output: PDFDocument) -> Bool {
        let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        return (0..<source.pageCount).allSatisfy { index in
            guard let before = source.page(at: index), let after = output.page(at: index),
                  before.rotation == after.rotation,
                  before.annotations.count == after.annotations.count else { return false }
            return boxes.allSatisfy { box in
                let a = before.bounds(for: box), b = after.bounds(for: box)
                return abs(a.minX - b.minX) < 0.1 && abs(a.minY - b.minY) < 0.1
                    && abs(a.width - b.width) < 0.1 && abs(a.height - b.height) < 0.1
            }
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            throw PDFCompressionError.unreadableSource
        }
        return size.int64Value
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
