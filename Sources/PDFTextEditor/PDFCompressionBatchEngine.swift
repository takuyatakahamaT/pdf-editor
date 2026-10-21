import Foundation

enum PDFCompressionBatchStatus: Sendable, Equatable {
    case succeeded
    case largerThanOriginal
    case failed
    case cancelled
}

struct PDFCompressionBatchResult: Identifiable, Sendable {
    let id: UUID
    let sourceURL: URL
    let sourceBytes: Int64?
    let outputBytes: Int64?
    let outputURL: URL?
    let status: PDFCompressionBatchStatus
    let message: String?

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        sourceBytes: Int64?,
        outputBytes: Int64?,
        outputURL: URL?,
        status: PDFCompressionBatchStatus,
        message: String?
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceBytes = sourceBytes
        self.outputBytes = outputBytes
        self.outputURL = outputURL
        self.status = status
        self.message = message
    }
}

enum PDFCompressionBatchEngine {
    static func run(
        sourceURLs: [URL],
        outputDirectory: URL,
        filenameSuffix: String,
        quality: Int,
        helperURL: URL? = nil,
        cancellationRequested: @Sendable () -> Bool = { false },
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) -> [PDFCompressionBatchResult] {
        var results: [PDFCompressionBatchResult] = []
        var reservedOutputPaths = Set<String>()
        let hasOutputAccess = outputDirectory.startAccessingSecurityScopedResource()
        defer {
            if hasOutputAccess { outputDirectory.stopAccessingSecurityScopedResource() }
        }

        for (index, sourceURL) in sourceURLs.enumerated() {
            onProgress?(index)
            if cancellationRequested() {
                results.append(contentsOf: cancelledResults(for: sourceURLs[index...]))
                break
            }

            let hasSourceAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasSourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            let sourceBytes = try? PDFCompressionEngine.fileSize(sourceURL)
            var outputBytes: Int64?

            do {
                let estimate = try PDFCompressionEngine.estimate(
                    sourceURL: sourceURL,
                    originalURL: sourceURL,
                    quality: quality,
                    helperURL: helperURL,
                    cancellationRequested: cancellationRequested
                )
                defer { try? FileManager.default.removeItem(at: estimate.temporaryURL) }
                outputBytes = estimate.outputBytes

                if cancellationRequested() {
                    results.append(cancelledResult(
                        for: sourceURL,
                        sourceBytes: estimate.sourceBytes,
                        outputBytes: estimate.outputBytes
                    ))
                    results.append(contentsOf: cancelledResults(for: sourceURLs.dropFirst(index + 1)))
                    break
                }

                guard estimate.outputBytes <= estimate.sourceBytes else {
                    results.append(PDFCompressionBatchResult(
                        sourceURL: sourceURL,
                        sourceBytes: estimate.sourceBytes,
                        outputBytes: estimate.outputBytes,
                        outputURL: nil,
                        status: .largerThanOriginal,
                        message: "圧縮後の方が大きいため保存しませんでした。"
                    ))
                    continue
                }

                let outputURL = uniqueOutputURL(
                    for: sourceURL,
                    in: outputDirectory,
                    suffix: filenameSuffix,
                    sourceURLs: sourceURLs,
                    reservedPaths: &reservedOutputPaths
                )
                try PDFCompressionEngine.saveNew(estimate, to: outputURL, protecting: sourceURL)
                results.append(PDFCompressionBatchResult(
                    sourceURL: sourceURL,
                    sourceBytes: estimate.sourceBytes,
                    outputBytes: estimate.outputBytes,
                    outputURL: outputURL,
                    status: .succeeded,
                    message: "保存しました: \(outputURL.lastPathComponent)"
                ))
            } catch let error as PDFCompressionError where error == .cancelled {
                results.append(cancelledResult(for: sourceURL, sourceBytes: sourceBytes, outputBytes: nil))
                results.append(contentsOf: cancelledResults(for: sourceURLs.dropFirst(index + 1)))
                break
            } catch {
                results.append(PDFCompressionBatchResult(
                    sourceURL: sourceURL,
                    sourceBytes: sourceBytes,
                    outputBytes: outputBytes,
                    outputURL: nil,
                    status: .failed,
                    message: error.localizedDescription
                ))
            }
        }
        return results
    }

    private static func uniqueOutputURL(
        for sourceURL: URL,
        in directory: URL,
        suffix: String,
        sourceURLs: [URL],
        reservedPaths: inout Set<String>
    ) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let safeSuffix = suffix
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        var number = 1
        while true {
            let numberedSuffix = number == 1 ? "" : "-\(number)"
            let name = "\(stem)\(safeSuffix)\(numberedSuffix).pdf"
            let candidate = directory.appendingPathComponent(name).standardizedFileURL
            let isInput = sourceURLs.contains { sameFile($0, candidate) }
            if !isInput,
               !reservedPaths.contains(candidate.path),
               !FileManager.default.fileExists(atPath: candidate.path) {
                reservedPaths.insert(candidate.path)
                return candidate
            }
            number += 1
        }
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

    private static func cancelledResults<S: Collection>(for sourceURLs: S) -> [PDFCompressionBatchResult]
    where S.Element == URL {
        sourceURLs.map { cancelledResult(for: $0, sourceBytes: try? PDFCompressionEngine.fileSize($0), outputBytes: nil) }
    }

    private static func cancelledResult(
        for sourceURL: URL,
        sourceBytes: Int64?,
        outputBytes: Int64?
    ) -> PDFCompressionBatchResult {
        PDFCompressionBatchResult(
            sourceURL: sourceURL,
            sourceBytes: sourceBytes,
            outputBytes: outputBytes,
            outputURL: nil,
            status: .cancelled,
            message: "キャンセルしました。"
        )
    }
}
