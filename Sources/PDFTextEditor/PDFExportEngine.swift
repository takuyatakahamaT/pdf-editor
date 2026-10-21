import AppKit
import CoreGraphics
import CoreText
import PDFKit

enum PDFTextEditKind {
    case replacement
    case insertion
}

/// 置換されたグリフ範囲。複数の編集が同じ PDF 行にあるとき、元の行に対して
/// まとめて再配置するため、各置換のフォント情報も保持する。
struct TextRunReplacement {
    let range: Range<Int>
    let text: String
    let font: CTFont
    let color: NSColor
    let exactGlyphs: [(glyph: CGGlyph, emWidth: CGFloat)]?

    var renderedWidth: CGFloat {
        if let exactGlyphs, !exactGlyphs.isEmpty {
            return exactGlyphs.reduce(CGFloat.zero) { $0 + $1.emWidth } * CTFontGetSize(font)
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
    }
}

/// 1 件の編集（置換 or 追加）。書き出し (`PDFExportEngine`) は元 PDF を再度開き直して
/// 描画するため、置換に必要なフォント解決結果 (`resolvedFont`/`fontIsExact`) は
/// 選択・置換確定時 (`PDFEditEngine.applyReplacement`) に一度だけ行い、ここへ焼き込む。
/// プレビューオーバーレイと書き出しは同じ `ReplacementEdit` を使うため、
/// フォント解決がぶれることはない。
struct ReplacementEdit {
    let id: UUID
    let kind: PDFTextEditKind
    let pageIndex: Int
    let bounds: CGRect
    let replacement: String
    let fontName: String?
    let fontSize: CGFloat
    let fontColor: NSColor

    /// 以下は kind == .replacement のときのみ意味を持つ。
    let baseline: CGFloat
    let coverBounds: CGRect
    let maxWidth: CGFloat
    let resolvedFont: CTFont?
    let fontIsExact: Bool
    let lineLayout: TextRunLayout?
    /// 置換対象行の元フォント。入力に選んだフォントとは分け、再配置される未編集文字に使う。
    var lineFont: CTFont?
    /// 同一行上の元グリフ範囲に対する累積置換。
    var lineReplacements: [TextRunReplacement]
    var lineCompositionStart: Int?
    var composesLineEdits: Bool
    /// 既存文字を移動した場合の新しい描画原点（x、ベースライン y）。
    var destinationOrigin: CGPoint?
    /// 元 PDF の CID を GID として直接指定できる場合の (GID, 送り幅[em]) 列。
    /// 埋め込みサブセットフォントが `cmap` を持たず `CTFontGetGlyphsForCharacters`
    /// が使えないときでも、元の GID を直接指定して真に同じグリフで描画するために使う。
    let exactGlyphs: [(glyph: CGGlyph, emWidth: CGFloat)]?

    init(
        target: TextTarget,
        replacement: String,
        resolvedFont: CTFont,
        fontIsExact: Bool,
        exactGlyphs: [(glyph: CGGlyph, emWidth: CGFloat)]? = nil,
        lineFont: CTFont? = nil
    ) {
        id = UUID()
        kind = .replacement
        pageIndex = target.pageIndex
        bounds = target.bounds
        self.replacement = replacement
        fontName = target.fontKey
        fontSize = target.fontSize
        fontColor = target.fontColor
        baseline = target.baseline
        coverBounds = target.coverBounds
        maxWidth = target.maxWidth
        self.resolvedFont = resolvedFont
        self.fontIsExact = fontIsExact
        lineLayout = target.lineLayout
        self.lineFont = lineFont ?? resolvedFont
        destinationOrigin = nil
        self.exactGlyphs = exactGlyphs
        if let lineLayout = target.lineLayout {
            lineCompositionStart = lineLayout.selectedRange.lowerBound
            composesLineEdits = false
            lineReplacements = [TextRunReplacement(
                range: lineLayout.selectedRange,
                text: replacement,
                font: resolvedFont,
                color: target.fontColor,
                exactGlyphs: exactGlyphs
            )]
        } else {
            lineCompositionStart = nil
            composesLineEdits = false
            lineReplacements = []
        }
    }

    init(deleting target: TextTarget) {
        id = UUID()
        kind = .replacement
        pageIndex = target.pageIndex
        bounds = target.bounds
        replacement = ""
        fontName = target.fontKey
        fontSize = target.fontSize
        fontColor = target.fontColor
        baseline = target.baseline
        coverBounds = target.coverBounds
        maxWidth = target.maxWidth
        resolvedFont = nil
        fontIsExact = true
        lineLayout = nil
        lineFont = nil
        lineReplacements = []
        lineCompositionStart = nil
        composesLineEdits = false
        destinationOrigin = nil
        exactGlyphs = nil
    }

    init(
        insertionOn pageIndex: Int,
        bounds: CGRect,
        text: String,
        fontName: String?,
        fontSize: CGFloat,
        fontColor: NSColor,
        id: UUID = UUID()
    ) {
        self.id = id
        kind = .insertion
        self.pageIndex = pageIndex
        self.bounds = bounds
        replacement = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontColor = fontColor
        baseline = bounds.midY
        coverBounds = bounds
        maxWidth = bounds.width
        resolvedFont = nil
        fontIsExact = true
        lineLayout = nil
        lineFont = nil
        lineReplacements = []
        lineCompositionStart = nil
        composesLineEdits = false
        destinationOrigin = nil
        exactGlyphs = nil
    }

    func moved(to newBounds: CGRect) -> ReplacementEdit {
        ReplacementEdit(
            insertionOn: pageIndex,
            bounds: newBounds,
            text: replacement,
            fontName: fontName,
            fontSize: fontSize,
            fontColor: fontColor,
            id: id
        )
    }

    func movingSelection(to point: CGPoint) -> ReplacementEdit {
        var copy = self
        copy.destinationOrigin = point
        return copy
    }

    var displayedTextBounds: CGRect {
        let font = resolvedFont ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let renderedWidth: CGFloat
        if let exactGlyphs, !exactGlyphs.isEmpty {
            renderedWidth = exactGlyphs.reduce(CGFloat.zero) { $0 + $1.emWidth } * CTFontGetSize(font)
        } else {
            let attributed = NSAttributedString(
                string: replacement,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            renderedWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        return CGRect(
            x: destinationOrigin?.x ?? bounds.minX,
            y: destinationOrigin.map { $0.y + bounds.minY - baseline } ?? bounds.minY,
            width: max(bounds.width, renderedWidth),
            height: bounds.height
        )
    }

    var annotationBounds: CGRect {
        if destinationOrigin != nil {
            return coverBounds.union(displayedTextBounds)
        }
        guard let lineLayout else { return coverBounds }
        return CGRect(
            x: lineLayout.coverBounds.minX,
            y: lineLayout.coverBounds.minY,
            width: lineLayout.maxWidth,
            height: lineLayout.coverBounds.height
        )
    }
}

enum PDFExportError: Error {
    case unreadableSource
    case cannotCreateContext
}

private struct PDFInternalLinkRemap: Encodable {
    let pageIndex: Int
    let linkIndex: Int
    let bounds: [CGFloat]
    let destinationPageIndex: Int
}

enum PDFExportEngine {
    static func export(
        sourceURL: URL,
        edits: [ReplacementEdit],
        markups: [PDFMarkupEdit] = [],
        to outputURL: URL,
        linkRemapHelperURL: URL? = nil
    ) throws {
        guard let document = PDFDocument(url: sourceURL),
              let firstPage = document.page(at: 0) else {
            throw PDFExportError.unreadableSource
        }

        var internalLinkRemaps: [PDFInternalLinkRemap] = []
        for sourcePageIndex in 0..<document.pageCount {
            guard let sourcePage = document.page(at: sourcePageIndex) else { continue }
            var linkIndex = 0
            for annotation in sourcePage.annotations
                where annotation.type == PDFAnnotationSubtype.link.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                let sourceLinkIndex = linkIndex
                linkIndex += 1
                guard let destination = annotation.destination
                        ?? (annotation.action as? PDFActionGoTo)?.destination,
                      let destinationPage = destination.page else { continue }
                let destinationPageIndex = document.index(for: destinationPage)
                if (0..<document.pageCount).contains(destinationPageIndex) {
                    let bounds = annotation.bounds
                    internalLinkRemaps.append(PDFInternalLinkRemap(
                        pageIndex: sourcePageIndex + 1,
                        linkIndex: sourceLinkIndex,
                        bounds: [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY],
                        destinationPageIndex: destinationPageIndex + 1
                    ))
                }
            }
        }

        var initialBox = firstPage.bounds(for: .mediaBox)
        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &initialBox, nil) else {
            throw PDFExportError.cannotCreateContext
        }

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            let pageInfo = [
                kCGPDFContextMediaBox as String: pageBounds,
                kCGPDFContextCropBox as String: page.bounds(for: .cropBox),
                kCGPDFContextBleedBox as String: page.bounds(for: .bleedBox),
                kCGPDFContextTrimBox as String: page.bounds(for: .trimBox),
                kCGPDFContextArtBox as String: page.bounds(for: .artBox)
            ] as CFDictionary

            let originalRotation = page.rotation
            page.rotation = 0
            defer { page.rotation = originalRotation }
            context.beginPDFPage(pageInfo)
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            for edit in edits where edit.pageIndex == pageIndex {
                switch edit.kind {
                case .replacement:
                    PDFTextRenderer.draw(edit, in: context)
                case .insertion:
                    drawInsertion(edit, in: context)
                }
            }

            context.endPDFPage()
        }

        context.closePDF()
        guard let annotatedDocument = PDFDocument(url: outputURL) else {
            throw PDFExportError.unreadableSource
        }
        let markupsByPage = Dictionary(grouping: markups, by: \.pageIndex)
        for pageIndex in 0..<document.pageCount {
            guard let sourcePage = document.page(at: pageIndex),
                  let outputPage = annotatedDocument.page(at: pageIndex) else {
                throw PDFExportError.unreadableSource
            }
            restorePageGeometry(from: sourcePage, to: outputPage)
            for sourceAnnotation in sourcePage.annotations
                where sourceAnnotation.userName?.hasPrefix(PDFMarkupEngine.markerPrefix) != true {
                guard let copiedAnnotation = PDFMarkupEngine.duplicateAnnotation(sourceAnnotation) else {
                    throw PDFExportError.cannotCreateContext
                }
                outputPage.addAnnotation(copiedAnnotation)
            }
            PDFMarkupEngine.replaceManagedAnnotations(on: outputPage, with: markupsByPage[pageIndex] ?? [])
        }
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-markup-export-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        guard annotatedDocument.write(to: stagedURL) else {
            throw PDFExportError.cannotCreateContext
        }
        let data = try remappedLinkData(
            sourceURL,
            stagedURL,
            mappings: internalLinkRemaps,
            helperURL: linkRemapHelperURL,
            expectedPageCount: document.pageCount
        )
        do { try data.write(to: outputURL, options: .atomic) }
        catch { throw PDFExportError.cannotCreateContext }
    }

    private static func restorePageGeometry(from sourcePage: PDFPage, to outputPage: PDFPage) {
        let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        for box in boxes {
            outputPage.setBounds(sourcePage.bounds(for: box), for: box)
        }
        outputPage.rotation = sourcePage.rotation
    }

    private static func remappedLinkData(
        _ sourceURL: URL,
        _ stagedURL: URL,
        mappings: [PDFInternalLinkRemap],
        helperURL: URL?,
        expectedPageCount: Int
    ) throws -> Data {
        guard !mappings.isEmpty else {
            guard let data = try? Data(contentsOf: stagedURL) else { throw PDFExportError.cannotCreateContext }
            return data
        }
        let helper = helperURL
            ?? ProcessInfo.processInfo.environment["PDF_EDITOR_LINK_REMAP_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pdf-link-remap")
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              let mappingData = try? JSONEncoder().encode(mappings) else {
            throw PDFExportError.cannotCreateContext
        }
        let mappingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-link-mappings-\(UUID().uuidString).json")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-link-remapped-\(UUID().uuidString).pdf")
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-link-remap-log-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: mappingURL)
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: logURL)
        }
        do { try mappingData.write(to: mappingURL, options: .atomic) }
        catch { throw PDFExportError.cannotCreateContext }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logURL.path) else {
            throw PDFExportError.cannotCreateContext
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = [sourceURL.path, stagedURL.path, outputURL.path, mappingURL.path]
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
            process.waitUntilExit()
            try? logHandle.close()
        } catch {
            try? logHandle.close()
            throw PDFExportError.cannotCreateContext
        }
        guard process.terminationStatus == 0,
              let output = PDFDocument(url: outputURL),
              output.pageCount == expectedPageCount else {
            throw PDFExportError.cannotCreateContext
        }
        for mapping in mappings {
            guard let page = output.page(at: mapping.pageIndex - 1) else {
                throw PDFExportError.cannotCreateContext
            }
            let links = page.annotations.filter {
                $0.type == PDFAnnotationSubtype.link.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            guard links.indices.contains(mapping.linkIndex),
                  let destination = links[mapping.linkIndex].destination,
                  let destinationPage = destination.page,
                  output.index(for: destinationPage) == mapping.destinationPageIndex - 1 else {
                throw PDFExportError.cannotCreateContext
            }
        }
        guard let data = try? Data(contentsOf: outputURL) else {
            throw PDFExportError.cannotCreateContext
        }
        return data
    }

    /// 印刷用の一時PDFを作る。無編集なら元PDFをそのまま複製する。編集がある場合は
    /// 未編集ページをPDFKitでそのままコピーし、編集ページだけ回転を一時的に0へ戻して
    /// 既存のベクター描画を適用した後、元の回転と各page boxを復元する。
    static func exportForPrinting(
        sourceURL: URL,
        edits: [ReplacementEdit],
        markups: [PDFMarkupEdit] = [],
        to outputURL: URL
    ) throws {
        guard let sourceDocument = PDFDocument(url: sourceURL), sourceDocument.pageCount > 0 else {
            throw PDFExportError.unreadableSource
        }
        let sourceHasManagedMarkups = PDFMarkupEngine.hasManagedAnnotations(in: sourceDocument)
        if edits.isEmpty && markups.isEmpty && !sourceHasManagedMarkups {
            do {
                let sourceData = try Data(contentsOf: sourceURL)
                try sourceData.write(to: outputURL, options: .atomic)
                return
            } catch {
                throw PDFExportError.unreadableSource
            }
        }

        let printDocument = PDFDocument()
        let editsByPage = Dictionary(grouping: edits, by: \.pageIndex)
        let markupsByPage = Dictionary(grouping: markups, by: \.pageIndex)
        for pageIndex in 0..<sourceDocument.pageCount {
            guard let sourcePage = sourceDocument.page(at: pageIndex),
                  let copiedPage = sourcePage.copy() as? PDFPage else {
                throw PDFExportError.unreadableSource
            }
            PDFMarkupEngine.replaceManagedAnnotations(on: copiedPage, with: markupsByPage[pageIndex] ?? [])
            let pageEdits = editsByPage[pageIndex] ?? []
            if !pageEdits.isEmpty || !(markupsByPage[pageIndex] ?? []).isEmpty {
                let renderedPage = try renderPrintPage(copiedPage, edits: pageEdits)
                printDocument.insert(renderedPage, at: pageIndex)
            } else {
                printDocument.insert(copiedPage, at: pageIndex)
            }
        }

        guard let data = printDocument.dataRepresentation() else {
            throw PDFExportError.cannotCreateContext
        }
        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw PDFExportError.cannotCreateContext
        }
    }

    private static func renderPrintPage(_ page: PDFPage, edits: [ReplacementEdit]) throws -> PDFPage {
        let originalRotation = page.rotation
        let boxes: [(PDFDisplayBox, CGRect)] = [
            (.mediaBox, page.bounds(for: .mediaBox)),
            (.cropBox, page.bounds(for: .cropBox)),
            (.bleedBox, page.bounds(for: .bleedBox)),
            (.trimBox, page.bounds(for: .trimBox)),
            (.artBox, page.bounds(for: .artBox))
        ]
        let mediaBox = boxes[0].1
        page.rotation = 0
        defer { page.rotation = originalRotation }

        let outputData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputData as CFMutableData) else {
            throw PDFExportError.cannotCreateContext
        }
        var outputMediaBox = mediaBox
        guard let context = CGContext(consumer: consumer, mediaBox: &outputMediaBox, nil) else {
            throw PDFExportError.cannotCreateContext
        }
        let pageInfo = [kCGPDFContextMediaBox as String: mediaBox] as CFDictionary
        context.beginPDFPage(pageInfo)
        context.saveGState()
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        for edit in edits {
            switch edit.kind {
            case .replacement:
                PDFTextRenderer.draw(edit, in: context)
            case .insertion:
                drawInsertion(edit, in: context)
            }
        }
        for annotation in page.annotations where annotation.shouldPrint {
            annotation.draw(with: .mediaBox, in: context)
        }
        context.endPDFPage()
        context.closePDF()

        guard let renderedDocument = PDFDocument(data: outputData as Data),
              let renderedPage = renderedDocument.page(at: 0)?.copy() as? PDFPage else {
            throw PDFExportError.cannotCreateContext
        }
        for (box, bounds) in boxes {
            renderedPage.setBounds(bounds, for: box)
        }
        renderedPage.rotation = originalRotation
        return renderedPage
    }

    /// テキスト追加モードの描画（従来どおり）。置換 (`.replacement`) は
    /// `PDFTextRenderer.draw` に一本化され、ここでは扱わない。
    private static func drawInsertion(_ edit: ReplacementEdit, in context: CGContext) {
        context.saveGState()
        let textBounds = edit.bounds

        let font = PDFEditEngine.fittedFont(
            named: edit.fontName,
            preferredSize: edit.fontSize,
            text: edit.replacement,
            bounds: textBounds
        )
        let coreTextFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        let attributed = NSAttributedString(
            string: edit.replacement,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): coreTextFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): edit.fontColor.cgColor
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        let baselineY = edit.bounds.midY - ((ascent - descent) / 2)
        context.setFillColor(edit.fontColor.cgColor)
        context.translateBy(x: edit.bounds.minX, y: baselineY)
        PDFTextRenderer.drawGlyphOutlines(for: line, in: context)
        context.restoreGState()
    }
}
