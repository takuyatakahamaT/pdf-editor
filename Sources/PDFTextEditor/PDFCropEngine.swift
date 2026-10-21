import AppKit
import Foundation
import PDFKit

struct PDFCropMargins: Equatable {
    let topMM: Double
    let rightMM: Double
    let bottomMM: Double
    let leftMM: Double

    var isValid: Bool {
        [topMM, rightMM, bottomMM, leftMM].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 2_000 }
    }

    static let zero = PDFCropMargins(topMM: 0, rightMM: 0, bottomMM: 0, leftMM: 0)

    func cropBox(from original: CGRect) throws -> CGRect {
        guard isValid else { throw PDFCropError.invalidMargins }
        let pointsPerMM = 72.0 / 25.4
        let width = original.width - (leftMM + rightMM) * pointsPerMM
        let height = original.height - (topMM + bottomMM) * pointsPerMM
        guard width >= 1, height >= 1 else { throw PDFCropError.cropOutsidePage }
        let result = CGRect(
            x: original.minX + leftMM * pointsPerMM,
            y: original.minY + bottomMM * pointsPerMM,
            width: width,
            height: height
        )
        guard result.minX >= original.minX - 0.01,
              result.minY >= original.minY - 0.01,
              result.maxX <= original.maxX + 0.01,
              result.maxY <= original.maxY + 0.01 else {
            throw PDFCropError.cropOutsidePage
        }
        return result
    }
}

enum PDFCropError: Error, Equatable, LocalizedError {
    case invalidMargins
    case invalidPageRange
    case pageOutOfRange
    case unreadableSource
    case lockedSource
    case copyingNotAllowed
    case assemblyNotAllowed
    case noPagesSelected
    case cropOutsidePage
    case outputMatchesInput
    case invalidOutput
    case cannotSave

    var errorDescription: String? {
        switch self {
        case .invalidMargins:
            return "上下左右の余白は0〜2,000 mmの数値で指定してください。"
        case .invalidPageRange:
            return "ページは「すべて」、または「1, 3-5」の形式で指定してください。"
        case .pageOutOfRange:
            return "ページ番号がPDFのページ数の範囲外です。"
        case .unreadableSource:
            return "元のPDFを読み込めません。"
        case .lockedSource:
            return "パスワードでロックされたPDFは切り抜けません。"
        case .copyingNotAllowed:
            return "内容のコピーが許可されていないPDFは切り抜けません。"
        case .assemblyNotAllowed:
            return "ページの変更が許可されていないPDFは切り抜けません。"
        case .noPagesSelected:
            return "切り抜くページを指定してください。"
        case .cropOutsidePage:
            return "指定した余白では切り抜き後のページが小さすぎるか、元の表示範囲を超えています。"
        case .outputMatchesInput:
            return "元のPDFとは別の保存先を指定してください。"
        case .invalidOutput:
            return "切り抜き後のPDFを検証できませんでした。元のPDFは変更していません。"
        case .cannotSave:
            return "切り抜き後のPDFを保存できませんでした。"
        }
    }
}

struct PDFCropPreview {
    let originalImage: NSImage
    let croppedImage: NSImage
    let originalBounds: CGRect
    let croppedBounds: CGRect
}

enum PDFCropEngine {
    static func pageIndices(from specification: String, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { throw PDFCropError.noPagesSelected }
        let trimmed = specification.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("all") == .orderedSame || trimmed == "すべて" {
            return Array(0..<pageCount)
        }

        let components = trimmed.components(separatedBy: ",")
        guard !components.isEmpty else { throw PDFCropError.invalidPageRange }
        var pages = Set<Int>()
        for component in components {
            let token = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw PDFCropError.invalidPageRange }
            let rangeParts = token.split(separator: "-", omittingEmptySubsequences: false)
            guard rangeParts.count <= 2,
                  let first = Int(rangeParts[0].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw PDFCropError.invalidPageRange
            }
            let last: Int
            if rangeParts.count == 2 {
                guard let parsedLast = Int(rangeParts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                      parsedLast >= first else { throw PDFCropError.invalidPageRange }
                last = parsedLast
            } else {
                last = first
            }
            guard first >= 1, last <= pageCount else { throw PDFCropError.pageOutOfRange }
            for pageNumber in first...last { pages.insert(pageNumber - 1) }
        }
        guard !pages.isEmpty else { throw PDFCropError.noPagesSelected }
        return pages.sorted()
    }

    static func preview(
        document: PDFDocument,
        pageIndex: Int,
        margins: PDFCropMargins,
        thumbnailSize: CGSize = CGSize(width: 360, height: 440)
    ) throws -> PDFCropPreview {
        guard let page = document.page(at: pageIndex) else { throw PDFCropError.pageOutOfRange }
        let originalBounds = page.bounds(for: .cropBox)
        let croppedBounds = try margins.cropBox(from: originalBounds)
        let originalImage = page.thumbnail(of: thumbnailSize, for: .cropBox)
        page.setBounds(croppedBounds, for: .cropBox)
        let croppedImage = page.thumbnail(of: thumbnailSize, for: .cropBox)
        page.setBounds(originalBounds, for: .cropBox)
        return PDFCropPreview(
            originalImage: originalImage,
            croppedImage: croppedImage,
            originalBounds: originalBounds,
            croppedBounds: croppedBounds
        )
    }

    static func crop(
        sourceURL: URL,
        to outputURL: URL,
        margins: PDFCropMargins,
        pageSpecification: String,
        protecting additionalSourceURLs: [URL] = []
    ) throws {
        guard margins.isValid else { throw PDFCropError.invalidMargins }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path),
              let source = PDFDocument(url: sourceURL) else { throw PDFCropError.unreadableSource }
        guard !source.isLocked else { throw PDFCropError.lockedSource }
        guard source.pageCount > 0 else { throw PDFCropError.unreadableSource }
        guard source.allowsCopying else { throw PDFCropError.copyingNotAllowed }
        guard source.allowsDocumentAssembly else { throw PDFCropError.assemblyNotAllowed }
        guard !([sourceURL] + additionalSourceURLs).contains(where: { sameFile($0, outputURL) }) else {
            throw PDFCropError.outputMatchesInput
        }
        let pageIndices = try pageIndices(from: pageSpecification, pageCount: source.pageCount)
        var expectedCropBoxes: [Int: CGRect] = [:]
        for index in pageIndices {
            guard let page = source.page(at: index) else { throw PDFCropError.pageOutOfRange }
            expectedCropBoxes[index] = try margins.cropBox(from: page.bounds(for: .cropBox))
        }

        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".pdf-editor-crop-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        for (index, cropBox) in expectedCropBoxes {
            source.page(at: index)?.setBounds(cropBox, for: .cropBox)
        }
        guard source.write(to: temporaryURL), let output = PDFDocument(url: temporaryURL),
              output.pageCount == source.pageCount,
              expectedCropBoxes.allSatisfy({ index, expected in
                  guard let page = output.page(at: index) else { return false }
                  let actualCrop = page.bounds(for: .cropBox)
                  let actualMedia = page.bounds(for: .mediaBox)
                  let sourceMedia = source.page(at: index)?.bounds(for: .mediaBox) ?? .zero
                  return rectsMatch(actualCrop, expected)
                      && rectsMatch(actualMedia, sourceMedia)
              }) else { throw PDFCropError.invalidOutput }

        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
        } catch {
            throw PDFCropError.cannotSave
        }
    }

    private static func rectsMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.1
            && abs(lhs.minY - rhs.minY) < 0.1
            && abs(lhs.width - rhs.width) < 0.1
            && abs(lhs.height - rhs.height) < 0.1
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if left == right { return true }
        guard let leftIdentity = identity(left), let rightIdentity = identity(right) else { return false }
        return leftIdentity == rightIdentity
    }

    private static func identity(_ url: URL) -> [FileAttributeKey: NSNumber]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return [.systemNumber: device, .systemFileNumber: inode]
    }
}
