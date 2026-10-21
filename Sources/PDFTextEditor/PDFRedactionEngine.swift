import AppKit
import CoreGraphics
import Foundation
import PDFKit

struct PDFRedactionRegion: Equatable, Identifiable {
    let id: UUID
    let pageIndex: Int
    var bounds: CGRect
    let text: String

    init(id: UUID = UUID(), pageIndex: Int, bounds: CGRect, text: String) {
        self.id = id
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.text = text
    }
}

enum PDFRedactionError: Error, LocalizedError {
    case unreadableSource
    case lockedSource
    case copyingNotAllowed
    case assemblyNotAllowed
    case noRegions
    case invalidRegion
    case sameFile
    case cannotRender
    case cannotSave
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSource: "墨消し元のPDFを読み込めません。"
        case .lockedSource: "パスワードでロックされたPDFは墨消しできません。"
        case .copyingNotAllowed: "内容のコピーが許可されていないPDFは墨消しできません。"
        case .assemblyNotAllowed: "ページの変更が許可されていないPDFは墨消しできません。"
        case .noRegions: "墨消し範囲を1つ以上追加してください。"
        case .invalidRegion: "墨消し範囲がページ内にありません。"
        case .sameFile: "元PDFと同じファイルには保存できません。"
        case .cannotRender: "PDFページを墨消し用画像へ変換できません。"
        case .cannotSave: "墨消し済みPDFを保存できません。"
        case .verificationFailed: "生成PDFにテキストまたは注釈が残っているため保存を中止しました。"
        }
    }
}

enum PDFRedactionEngine {
    static let safetyMargin: CGFloat = 2
    private static let preferredRasterScale: CGFloat = 4
    private static let maximumRasterEdge: CGFloat = 4_000
    private static let maximumPixelCount: CGFloat = 20_000_000

    static func redactionBounds(for region: PDFRedactionRegion, in pageBounds: CGRect) -> CGRect? {
        let expanded = region.bounds.insetBy(dx: -safetyMargin, dy: -safetyMargin)
        let clipped = expanded.intersection(pageBounds)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    static func export(sourceURL: URL, regions: [PDFRedactionRegion], to outputURL: URL) throws {
        guard !regions.isEmpty else { throw PDFRedactionError.noRegions }
        guard !PDFOCREngine.sameFile(sourceURL, outputURL) else { throw PDFRedactionError.sameFile }
        guard let source = PDFDocument(url: sourceURL) else { throw PDFRedactionError.unreadableSource }
        guard !source.isLocked else { throw PDFRedactionError.lockedSource }
        guard source.pageCount > 0 else { throw PDFRedactionError.unreadableSource }
        guard source.allowsCopying else { throw PDFRedactionError.copyingNotAllowed }
        guard source.allowsDocumentAssembly else { throw PDFRedactionError.assemblyNotAllowed }

        let regionsByPage = Dictionary(grouping: regions, by: \.pageIndex)
        for (pageIndex, pageRegions) in regionsByPage {
            guard let page = source.page(at: pageIndex) else { throw PDFRedactionError.invalidRegion }
            for region in pageRegions where redactionBounds(for: region, in: page.bounds(for: .cropBox)) == nil {
                throw PDFRedactionError.invalidRegion
            }
        }

        let redacted = PDFDocument()
        for pageIndex in 0..<source.pageCount {
            guard let page = source.page(at: pageIndex),
                  let bitmap = render(page: page, regions: regionsByPage[pageIndex] ?? []) else {
                throw PDFRedactionError.cannotRender
            }
            let pageSize = page.bounds(for: .mediaBox).size
            let image = NSImage(cgImage: bitmap, size: pageSize)
            guard let redactedPage = PDFPage(image: image) else { throw PDFRedactionError.cannotRender }
            redactedPage.setBounds(CGRect(origin: .zero, size: pageSize), for: .mediaBox)
            let mediaBox = page.bounds(for: .mediaBox)
            for displayBox: PDFDisplayBox in [.cropBox, .bleedBox, .trimBox, .artBox] {
                let sourceBox = page.bounds(for: displayBox).intersection(mediaBox)
                if !sourceBox.isNull && !sourceBox.isEmpty {
                    redactedPage.setBounds(
                        sourceBox.offsetBy(dx: -mediaBox.minX, dy: -mediaBox.minY),
                        for: displayBox
                    )
                }
            }
            redactedPage.rotation = page.rotation
            redacted.insert(redactedPage, at: pageIndex)
        }

        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-redacted-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        guard redacted.write(to: stagedURL),
              let verified = PDFDocument(url: stagedURL),
              verified.pageCount == source.pageCount else {
            throw PDFRedactionError.cannotSave
        }
        for index in 0..<verified.pageCount {
            guard let page = verified.page(at: index), page.annotations.isEmpty,
                  page.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                throw PDFRedactionError.verificationFailed
            }
        }
        guard let data = try? Data(contentsOf: stagedURL) else { throw PDFRedactionError.cannotSave }
        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw PDFRedactionError.cannotSave
        }
    }

    static func render(page: PDFPage, regions: [PDFRedactionRegion]) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let cropBox = page.bounds(for: .cropBox).intersection(box)
        guard box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0,
              !cropBox.isNull, !cropBox.isEmpty,
              page.pageRef != nil else { return nil }
        let pixelScale = min(
            preferredRasterScale,
            maximumRasterEdge / max(box.width, box.height),
            sqrt(maximumPixelCount / (box.width * box.height))
        )
        guard pixelScale.isFinite, pixelScale > 0 else { return nil }
        let width = max(1, Int((box.width * pixelScale).rounded()))
        let height = max(1, Int((box.height * pixelScale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.scaleBy(x: pixelScale, y: pixelScale)
        context.translateBy(x: -box.minX, y: -box.minY)

        let originalRotation = page.rotation
        page.rotation = 0
        page.draw(with: .mediaBox, to: context)
        page.rotation = originalRotation

        context.setShouldAntialias(false)
        context.setBlendMode(.normal)
        context.setFillColor(NSColor.white.cgColor)
        let cropExterior = [
            CGRect(x: box.minX, y: box.minY, width: box.width, height: cropBox.minY - box.minY),
            CGRect(x: box.minX, y: cropBox.maxY, width: box.width, height: box.maxY - cropBox.maxY),
            CGRect(x: box.minX, y: cropBox.minY, width: cropBox.minX - box.minX, height: cropBox.height),
            CGRect(x: cropBox.maxX, y: cropBox.minY, width: box.maxX - cropBox.maxX, height: cropBox.height)
        ]
        for rect in cropExterior where !rect.isNull && !rect.isEmpty { context.fill(rect) }
        context.setFillColor(NSColor.black.cgColor)
        for region in regions {
            guard let bounds = redactionBounds(for: region, in: box) else { continue }
            context.fill(bounds)
        }
        context.restoreGState()
        return context.makeImage()
    }
}
