import AppKit
import Darwin
import Foundation
import PDFKit

enum PDFInternalTextEligibility: Equatable {
    case supported
    case unsupported(String)
}

enum PDFInternalTextEditError: LocalizedError {
    case unavailable(String)
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "PDFiumを利用できません: \(reason)"
        case .unsupported(let reason): "PDF内部置換に対応していません: \(reason)"
        case .failed(let reason): "PDF内部置換に失敗しました: \(reason)"
        }
    }
}

/// PDFium の C API を動的に読み込み、SwiftPM 単体ビルドでは PDFium を必須にしない。
/// 対応範囲外を推測で補わず、照合できない状態は必ず unsupported とする。
enum PDFInternalTextEditEngine {
    private static let lock = NSLock()

    static func eligibility(sourceURL: URL, edit: ReplacementEdit) -> PDFInternalTextEligibility {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard let sourceDocument = PDFDocument(url: sourceURL),
                  let sourcePage = sourceDocument.page(at: edit.pageIndex), sourcePage.rotation == 0 else {
                throw PDFInternalTextEditError.unsupported("回転ページは対象外です。")
            }
            let api = try PDFiumAPI.load()
            api.initialize()
            defer { api.destroyLibrary() }
            let document = try api.openDocument(sourceURL)
            defer { api.closeDocument(document) }
            try validateDocument(document, api: api)
            _ = try match(edit: edit, document: document, api: api)
            return .supported
        } catch let error as PDFInternalTextEditError {
            return .unsupported(error.errorDescription ?? "安全性を確認できませんでした。")
        } catch {
            return .unsupported("PDFiumの照合中に不明なエラーが発生しました。")
        }
    }

    /// 元PDFを変更せず、全編集を照合してから一時出力を作る。途中失敗時は出力へ書かない。
    static func apply(sourceURL: URL, edits: [ReplacementEdit], to outputURL: URL) throws {
        guard !edits.isEmpty else { throw PDFInternalTextEditError.failed("内部置換がありません。") }
        guard sourceURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw PDFInternalTextEditError.failed("元PDFは上書きできません。")
        }
        lock.lock()
        defer { lock.unlock() }
        let api = try PDFiumAPI.load()
        api.initialize()
        defer { api.destroyLibrary() }
        let document = try api.openDocument(sourceURL)
        defer { api.closeDocument(document) }
        try validateDocument(document, api: api)

        try validateEditSet(edits)
        guard let sourcePDF = PDFDocument(url: sourceURL), edits.allSatisfy({ edit in
            sourcePDF.page(at: edit.pageIndex)?.rotation == 0
        }) else {
            throw PDFInternalTextEditError.unsupported("回転ページは対象外です。")
        }
        for edit in edits {
            try requireUniqueSourceText(edit.sourceText, in: document, api: api)
        }
        let grouped = Dictionary(grouping: edits, by: \.pageIndex)
        var loadedPages: [Int: PDFiumHandle] = [:]
        defer { loadedPages.values.forEach(api.closePage) }

        for (pageIndex, pageEdits) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let page = api.loadPage(document, Int32(pageIndex)) else {
                throw PDFInternalTextEditError.failed("\(pageIndex + 1)ページ目を開けませんでした。")
            }
            loadedPages[pageIndex] = page
            guard let textPage = api.loadTextPage(page) else {
                throw PDFInternalTextEditError.failed("\(pageIndex + 1)ページ目の文字情報を読めませんでした。")
            }
            let matches: [Match]
            do {
                matches = try pageEdits.map { try match(edit: $0, page: page, textPage: textPage, api: api) }
            } catch {
                api.closeTextPage(textPage)
                throw error
            }
            let objectIDs = Set(matches.map { UInt(bitPattern: $0.object) })
            guard objectIDs.count == matches.count else {
                api.closeTextPage(textPage)
                throw PDFInternalTextEditError.unsupported("同じtext objectへの複数編集は保存できません。")
            }
            for (edit, matched) in zip(pageEdits, matches) {
                let utf16 = Array(edit.replacement.utf16) + [0]
                let didSet = utf16.withUnsafeBufferPointer { buffer in
                    api.setText(matched.object, buffer.baseAddress)
                }
                guard didSet != 0 else {
                    api.closeTextPage(textPage)
                    throw PDFInternalTextEditError.failed("置換文字を元フォントへ設定できませんでした。")
                }
            }
            api.closeTextPage(textPage)
            guard api.generateContent(page) != 0 else {
                throw PDFInternalTextEditError.failed("\(pageIndex + 1)ページ目のcontent生成に失敗しました。")
            }
        }

        let writer = PDFiumDataWriter()
        guard writer.save(document: document, api: api) else {
            throw PDFInternalTextEditError.failed("PDFiumがPDFを書き出せませんでした。")
        }
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-pdfium-stage-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        do { try writer.data.write(to: stagedURL, options: .atomic) }
        catch { throw PDFInternalTextEditError.failed("一時PDFを書き出せませんでした。") }

        try verify(sourceURL: sourceURL, outputURL: stagedURL, edits: edits, api: api, requireObjectGeometry: true)
        do { try writer.data.write(to: outputURL, options: .atomic) }
        catch { throw PDFInternalTextEditError.failed("検証済みPDFを一時出力へ配置できませんでした。") }
    }

    /// overlay/markupを別段で適用した後も、抽出文字とページ構造を再確認する。
    static func verifyFinalOutput(sourceURL: URL, outputURL: URL, edits: [ReplacementEdit]) throws {
        lock.lock()
        defer { lock.unlock() }
        let api = try PDFiumAPI.load()
        api.initialize()
        defer { api.destroyLibrary() }
        try verify(sourceURL: sourceURL, outputURL: outputURL, edits: edits, api: api, requireObjectGeometry: false)
    }

    private static func validateEditSet(_ edits: [ReplacementEdit]) throws {
        for edit in edits where !edit.storage.isInternal {
            throw PDFInternalTextEditError.failed("overlay編集が内部置換処理へ渡されました。")
        }
        for (index, edit) in edits.enumerated() {
            for other in edits.dropFirst(index + 1) {
                if edit.sourceText.contains(other.replacement)
                    || other.sourceText.contains(edit.replacement)
                    || edit.replacement.contains(other.sourceText)
                    || other.replacement.contains(edit.sourceText) {
                    throw PDFInternalTextEditError.unsupported("置換文字列が別の内部編集と衝突します。")
                }
            }
        }
    }

    private static func validateDocument(_ document: PDFiumHandle, api: PDFiumAPI) throws {
        guard api.securityHandlerRevision(document) == -1 else {
            throw PDFInternalTextEditError.unsupported("暗号化または権限制限のあるPDFは対象外です。")
        }
        guard api.signatureCount(document) == 0 else {
            throw PDFInternalTextEditError.unsupported("電子署名付きPDFは対象外です。")
        }
    }

    private struct Match {
        let object: PDFiumHandle
    }

    private static func match(
        edit: ReplacementEdit,
        document: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> Match {
        try requireUniqueSourceText(edit.sourceText, in: document, api: api)
        return try matchByLoadingPage(edit: edit, document: document, api: api)
    }

    private static func requireUniqueSourceText(
        _ sourceText: String,
        in document: PDFiumHandle,
        api: PDFiumAPI
    ) throws {
        var occurrences = 0
        let pageCount = api.pageCount(document)
        guard pageCount > 0 else {
            throw PDFInternalTextEditError.unsupported("文書のページ数を検証できません。")
        }
        for pageIndex in 0..<pageCount {
            guard let page = api.loadPage(document, pageIndex) else {
                throw PDFInternalTextEditError.unsupported("全ページの文字を検証できません。")
            }
            guard let textPage = api.loadTextPage(page) else {
                api.closePage(page)
                throw PDFInternalTextEditError.unsupported("全ページの文字を検証できません。")
            }
            occurrences += api.extractedText(textPage).components(separatedBy: sourceText).count - 1
            api.closeTextPage(textPage)
            api.closePage(page)
        }
        guard occurrences == 1 else {
            throw PDFInternalTextEditError.unsupported("元文字列が文書内に複数あるか、抽出結果と一致しません。")
        }
    }

    private static func matchByLoadingPage(
        edit: ReplacementEdit,
        document: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> Match {
        guard let page = api.loadPage(document, Int32(edit.pageIndex)) else {
            throw PDFInternalTextEditError.unsupported("対象ページをPDFiumで開けません。")
        }
        defer { api.closePage(page) }
        guard let textPage = api.loadTextPage(page) else {
            throw PDFInternalTextEditError.unsupported("対象ページの文字情報を取得できません。")
        }
        defer { api.closeTextPage(textPage) }
        return try match(edit: edit, page: page, textPage: textPage, api: api)
    }

    private static func match(
        edit: ReplacementEdit,
        page: PDFiumHandle,
        textPage: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> Match {
        guard edit.kind == .replacement, edit.destinationOrigin == nil,
              !edit.composesLineEdits, edit.lineReplacements.count <= 1 else {
            throw PDFInternalTextEditError.unsupported("移動・行再配置・複数範囲の編集は対象外です。")
        }
        guard !edit.sourceSelectionIsAmbiguous else {
            throw PDFInternalTextEditError.unsupported("選択位置に別の可視文字が重なっており対象objectが曖昧です。")
        }
        guard edit.sourceIsPlainTextObject else {
            throw PDFInternalTextEditError.unsupported("単一Tjまたは単一文字列TJ以外（複数show・調整付きTJ・Form・marked content）は対象外です。")
        }
        guard edit.hasExplicitSourceMapping else {
            throw PDFInternalTextEditError.unsupported("選択文字の明示ToUnicodeがありません。")
        }
        let sourceScalars = Array(edit.sourceText.unicodeScalars)
        let replacementScalars = Array(edit.replacement.unicodeScalars)
        guard !sourceScalars.isEmpty, sourceScalars.count == replacementScalars.count,
              sourceScalars.count == edit.sourceGlyphBounds.count else {
            throw PDFInternalTextEditError.unsupported("文字数または文字単位bboxを一意に照合できません。")
        }
        guard sourceScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              replacementScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw PDFInternalTextEditError.unsupported("初期対応は空白を含まないASCII文字だけです。")
        }
        guard edit.sourceText != edit.replacement, !edit.replacement.contains(edit.sourceText) else {
            throw PDFInternalTextEditError.unsupported("元文字の不在を保存後に検証できない置換です。")
        }
        guard edit.outputFontSelection == .automatic,
              abs(edit.fontSize - edit.sourceFontSize) <= 0.01 else {
            throw PDFInternalTextEditError.unsupported("書体または文字サイズを変更した編集です。")
        }
        guard api.pageHasTransparency(page) == 0 else {
            throw PDFInternalTextEditError.unsupported("透明効果を含むページは対象外です。")
        }
        let extractedPageText = api.extractedText(textPage)
        guard extractedPageText.components(separatedBy: edit.sourceText).count - 1 == 1 else {
            throw PDFInternalTextEditError.unsupported("元文字列がページ内に複数あり、対象objectが曖昧です。")
        }

        let charCount = api.textCountChars(textPage)
        guard charCount > 0 else { throw PDFInternalTextEditError.unsupported("文字を抽出できません。") }
        var indicesByObject: [UInt: [Int32]] = [:]
        for index in 0..<charCount {
            guard let object = api.textObjectForCharacter(textPage, index) else { continue }
            indicesByObject[UInt(bitPattern: object), default: []].append(index)
        }

        var matchingTextObjects: [PDFiumHandle] = []
        let objectCount = api.pageObjectCount(page)
        guard objectCount >= 0 else { throw PDFInternalTextEditError.unsupported("page objectを列挙できません。") }
        for objectIndex in 0..<objectCount {
            guard let object = api.pageObject(page, objectIndex) else {
                throw PDFInternalTextEditError.unsupported("page objectを取得できません。")
            }
            if api.pageObjectType(object) != 1 {
                var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
                guard api.pageObjectBounds(object, &left, &bottom, &right, &top) != 0 else {
                    throw PDFInternalTextEditError.unsupported("非文字要素の位置を判定できません。")
                }
                let nonTextBounds = CGRect(
                    x: CGFloat(left), y: CGFloat(bottom),
                    width: CGFloat(right - left), height: CGFloat(top - bottom)
                ).standardized.insetBy(dx: -0.5, dy: -0.5)
                if nonTextBounds.intersects(edit.coverBounds) {
                    throw PDFInternalTextEditError.unsupported("選択文字に画像・罫線・背景などの非文字要素が重なっています。")
                }
                continue
            }
            guard api.objectText(object, textPage: textPage) == edit.sourceText else { continue }
            var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
            guard api.pageObjectBounds(object, &left, &bottom, &right, &top) != 0 else { continue }
            let objectBounds = CGRect(
                x: CGFloat(left), y: CGFloat(bottom),
                width: CGFloat(right - left), height: CGFloat(top - bottom)
            )
            let locationWindow = edit.bounds.insetBy(
                dx: -edit.sourceFontSize * 0.5,
                dy: -edit.sourceFontSize * 0.5
            )
            guard objectBounds.intersects(locationWindow),
                  abs(objectBounds.midX - edit.bounds.midX) <= edit.sourceFontSize,
                  abs(objectBounds.midY - edit.bounds.midY) <= edit.sourceFontSize else { continue }
            matchingTextObjects.append(object)
        }
        guard matchingTextObjects.count == 1 else {
            let reason = matchingTextObjects.isEmpty
                ? "選択範囲と完全一致する単一text objectを証明できません。"
                : "同じ文字・位置のtext objectが複数あり曖昧です。"
            throw PDFInternalTextEditError.unsupported(reason)
        }

        var candidates: [PDFiumHandle] = []
        for object in matchingTextObjects {
            guard let charIndices = indicesByObject[UInt(bitPattern: object)],
                  charIndices.count == sourceScalars.count else { continue }
            if try objectMatches(
                object: object,
                charIndices: charIndices,
                sourceScalars: sourceScalars,
                replacementScalars: replacementScalars,
                edit: edit,
                textPage: textPage,
                api: api
            ) {
                candidates.append(object)
            }
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw PDFInternalTextEditError.unsupported(
                "単一text objectと文字単位のUnicode・bbox・styleを一致確認できません。"
            )
        }
        return Match(object: candidate)
    }

    private static func objectMatches(
        object: PDFiumHandle,
        charIndices: [Int32],
        sourceScalars: [Unicode.Scalar],
        replacementScalars: [Unicode.Scalar],
        edit: ReplacementEdit,
        textPage: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> Bool {
        let diagnostics = ProcessInfo.processInfo.environment["PDFIUM_DIAGNOSTICS"] == "1"
        func reject(_ message: String) -> Bool {
            if diagnostics { fputs("PDFium照合: \(message)\n", stderr) }
            return false
        }
        guard api.pageObjectHasTransparency(object) == 0,
              api.pageObjectMarkCount(object) == 0,
              api.textRenderMode(object) == 0 else { return reject("透明・marked content・render mode") }
        var matrix = PDFiumMatrix()
        let hasMatrix = withUnsafeMutablePointer(to: &matrix) {
            api.pageObjectMatrix(object, UnsafeMutableRawPointer($0))
        }
        guard hasMatrix != 0,
              abs(matrix.a - 1) <= 0.0001, abs(matrix.d - 1) <= 0.0001,
              abs(matrix.b) <= 0.0001, abs(matrix.c) <= 0.0001 else {
            return reject("matrix=\(matrix)")
        }
        var objectFontSize: Float = 0
        guard api.textObjectFontSize(object, &objectFontSize) != 0,
              abs(CGFloat(objectFontSize) - edit.sourceFontSize) <= 0.05,
              let font = api.textObjectFont(object), api.fontIsEmbedded(font) == 0 else {
            return reject("font sizeまたはembedded: object=\(objectFontSize), source=\(edit.sourceFontSize)")
        }
        let baseFontName = api.baseFontName(font)
        let standardFonts: Set<String> = [
            "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
            "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
            "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"
        ]
        guard standardFonts.contains(baseFontName) else { return reject("base font=\(baseFontName)") }

        let sourceColor = edit.fontColor.usingColorSpace(.deviceRGB)
        for (offset, charIndex) in charIndices.enumerated() {
            guard api.textIsGenerated(textPage, charIndex) == 0,
                  api.textHasUnicodeMapError(textPage, charIndex) == 0,
                  api.textUnicode(textPage, charIndex) == sourceScalars[offset].value,
                  abs(api.textFontSize(textPage, charIndex) - Double(edit.sourceFontSize)) <= 0.05,
                  abs(api.textCharAngle(textPage, charIndex)) <= 0.0001 else {
                return reject("char metadata index=\(charIndex), unicode=\(api.textUnicode(textPage, charIndex)), fontSize=\(api.textFontSize(textPage, charIndex)), angle=\(api.textCharAngle(textPage, charIndex))")
            }

            var box = PDFiumRect()
            let hasBox = withUnsafeMutablePointer(to: &box) {
                api.textLooseCharBox(textPage, charIndex, UnsafeMutableRawPointer($0))
            }
            guard hasBox != 0 else { return reject("loose bboxなし") }
            let pdfiumBox = CGRect(
                x: CGFloat(box.left), y: CGFloat(box.bottom),
                width: CGFloat(box.right - box.left), height: CGFloat(box.top - box.bottom)
            )
            guard boxesMatch(edit.sourceGlyphBounds[offset], pdfiumBox, fontSize: edit.sourceFontSize) else {
                return reject("bbox index=\(edit.sourceGlyphBounds[offset]), pdfium=\(pdfiumBox)")
            }
            var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 0
            guard api.textFillColor(textPage, charIndex, &red, &green, &blue, &alpha) != 0,
                  let sourceColor,
                  abs(sourceColor.redComponent - CGFloat(red) / 255) <= 0.01,
                  abs(sourceColor.greenComponent - CGFloat(green) / 255) <= 0.01,
                  abs(sourceColor.blueComponent - CGFloat(blue) / 255) <= 0.01,
                  abs(sourceColor.alphaComponent - CGFloat(alpha) / 255) <= 0.01 else {
                return reject("fill color source=\(String(describing: sourceColor)), pdfium=\(red),\(green),\(blue),\(alpha)")
            }

            var sourceWidth: Float = 0
            var replacementWidth: Float = 0
            guard api.fontGlyphWidth(font, sourceScalars[offset].value, objectFontSize, &sourceWidth) != 0,
                  api.fontGlyphWidth(font, replacementScalars[offset].value, objectFontSize, &replacementWidth) != 0,
                  api.fontGlyphPath(font, sourceScalars[offset].value, objectFontSize) != nil,
                  api.fontGlyphPath(font, replacementScalars[offset].value, objectFontSize) != nil,
                  sourceWidth > 0, replacementWidth > 0,
                  abs(sourceWidth - replacementWidth) <= 0.01 else {
                return reject("glyph source=\(sourceScalars[offset]) width=\(sourceWidth), replacement=\(replacementScalars[offset]) width=\(replacementWidth), paths=\(String(describing: api.fontGlyphPath(font, sourceScalars[offset].value, objectFontSize)))/\(String(describing: api.fontGlyphPath(font, replacementScalars[offset].value, objectFontSize)))")
            }
        }
        return true
    }

    private static func boxesMatch(_ indexed: CGRect, _ pdfium: CGRect, fontSize: CGFloat) -> Bool {
        guard indexed.width > 0, indexed.height > 0, pdfium.width > 0, pdfium.height > 0 else { return false }
        // scannerはPDF宣言metric、PDFium loose boxは代替Base14 metricを使うため、
        // 高さだけは1割強ずれる。位置・送り幅はより厳しく照合する。
        let horizontalTolerance = max(0.75, fontSize * 0.08)
        let verticalTolerance = max(0.75, fontSize * 0.12)
        return abs(indexed.minX - pdfium.minX) <= horizontalTolerance
            && abs(indexed.maxX - pdfium.maxX) <= horizontalTolerance
            && abs(indexed.minY - pdfium.minY) <= verticalTolerance
            && abs(indexed.maxY - pdfium.maxY) <= verticalTolerance
    }

    private static func verify(
        sourceURL: URL,
        outputURL: URL,
        edits: [ReplacementEdit],
        api: PDFiumAPI,
        requireObjectGeometry: Bool
    ) throws {
        guard let sourcePDF = PDFDocument(url: sourceURL), let outputPDF = PDFDocument(url: outputURL),
              sourcePDF.pageCount == outputPDF.pageCount else {
            throw PDFInternalTextEditError.failed("保存後のページ数が一致しません。")
        }
        let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        for pageIndex in 0..<sourcePDF.pageCount {
            guard let sourcePage = sourcePDF.page(at: pageIndex), let outputPage = outputPDF.page(at: pageIndex),
                  sourcePage.rotation == outputPage.rotation,
                  boxes.allSatisfy({ sourcePage.bounds(for: $0).approximatelyEquals(outputPage.bounds(for: $0)) }) else {
                throw PDFInternalTextEditError.failed("保存後のページgeometryが一致しません。")
            }
        }

        let outputDocument = try api.openDocument(outputURL)
        defer { api.closeDocument(outputDocument) }
        guard api.pageCount(outputDocument) == Int32(sourcePDF.pageCount) else {
            throw PDFInternalTextEditError.failed("PDFium再読込後のページ数が一致しません。")
        }
        var pageTexts: [String] = []
        for pageIndex in 0..<sourcePDF.pageCount {
            guard let page = api.loadPage(outputDocument, Int32(pageIndex)) else {
                throw PDFInternalTextEditError.failed("保存後の文字を再抽出できません。")
            }
            guard let textPage = api.loadTextPage(page) else {
                api.closePage(page)
                throw PDFInternalTextEditError.failed("保存後の文字を再抽出できません。")
            }
            pageTexts.append(api.extractedText(textPage))
            if requireObjectGeometry {
                do {
                    for edit in edits where edit.pageIndex == pageIndex {
                        try verifyEditedGeometry(edit, page: page, textPage: textPage, api: api)
                    }
                } catch {
                    api.closeTextPage(textPage)
                    api.closePage(page)
                    throw error
                }
            }
            api.closeTextPage(textPage)
            api.closePage(page)
        }
        let allText = pageTexts.joined(separator: "\n")
        for edit in edits {
            guard pageTexts.indices.contains(edit.pageIndex),
                  pageTexts[edit.pageIndex].contains(edit.replacement),
                  !allText.contains(edit.sourceText) else {
                throw PDFInternalTextEditError.failed("保存後に置換文字を確認できないか、元文字が抽出結果に残っています。")
            }
        }
    }

    private static func verifyEditedGeometry(
        _ edit: ReplacementEdit,
        page: PDFiumHandle,
        textPage: PDFiumHandle,
        api: PDFiumAPI
    ) throws {
        let replacementScalars = Array(edit.replacement.unicodeScalars)
        let charCount = api.textCountChars(textPage)
        let objectCount = api.pageObjectCount(page)
        guard charCount > 0, objectCount >= 0,
              replacementScalars.count == edit.sourceGlyphBounds.count else {
            throw PDFInternalTextEditError.failed("保存後の文字単位geometryを照合できません。")
        }
        var indicesByObject: [UInt: [Int32]] = [:]
        for index in 0..<charCount {
            guard let object = api.textObjectForCharacter(textPage, index) else { continue }
            indicesByObject[UInt(bitPattern: object), default: []].append(index)
        }
        var matched: [[Int32]] = []
        for objectIndex in 0..<objectCount {
            guard let object = api.pageObject(page, objectIndex), api.pageObjectType(object) == 1,
                  api.objectText(object, textPage: textPage) == edit.replacement,
                  let indices = indicesByObject[UInt(bitPattern: object)],
                  indices.count == replacementScalars.count else { continue }
            var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
            guard api.pageObjectBounds(object, &left, &bottom, &right, &top) != 0 else { continue }
            let bounds = CGRect(
                x: CGFloat(left), y: CGFloat(bottom),
                width: CGFloat(right - left), height: CGFloat(top - bottom)
            ).standardized
            guard bounds.intersects(edit.bounds.insetBy(dx: -edit.sourceFontSize, dy: -edit.sourceFontSize)) else {
                continue
            }
            matched.append(indices)
        }
        guard matched.count == 1, let indices = matched.first else {
            throw PDFInternalTextEditError.failed("保存後の文字objectを一意に特定できません。")
        }
        for (offset, index) in indices.enumerated() {
            var box = PDFiumRect()
            let hasBox = withUnsafeMutablePointer(to: &box) {
                api.textLooseCharBox(textPage, index, UnsafeMutableRawPointer($0))
            }
            let savedBox = CGRect(
                x: CGFloat(box.left), y: CGFloat(box.bottom),
                width: CGFloat(box.right - box.left), height: CGFloat(box.top - box.bottom)
            )
            guard hasBox != 0,
                  api.textUnicode(textPage, index) == replacementScalars[offset].value,
                  abs(api.textFontSize(textPage, index) - Double(edit.sourceFontSize)) <= 0.05,
                  boxesMatch(edit.sourceGlyphBounds[offset], savedBox, fontSize: edit.sourceFontSize) else {
                throw PDFInternalTextEditError.failed("保存後の文字サイズ・位置を維持できませんでした。")
            }
        }
    }
}

private typealias PDFiumHandle = OpaquePointer

private struct PDFiumMatrix {
    var a: Float = 0
    var b: Float = 0
    var c: Float = 0
    var d: Float = 0
    var e: Float = 0
    var f: Float = 0
}

private struct PDFiumRect {
    var left: Float = 0
    var top: Float = 0
    var right: Float = 0
    var bottom: Float = 0
}

private struct PDFiumFileWrite {
    var version: Int32 = 1
    var writeBlock: (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt) -> Int32)?
    var context: UnsafeMutableRawPointer?
}

private final class PDFiumDataWriter {
    var data = Data()

    func save(document: PDFiumHandle, api: PDFiumAPI) -> Bool {
        var fileWrite = PDFiumFileWrite(
            writeBlock: { rawSelf, bytes, size in
                guard let rawSelf, let bytes else { return 0 }
                let extended = rawSelf.assumingMemoryBound(to: PDFiumFileWrite.self)
                guard let context = extended.pointee.context else { return 0 }
                let writer = Unmanaged<PDFiumDataWriter>.fromOpaque(context).takeUnretainedValue()
                writer.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(size))
                return 1
            },
            context: Unmanaged.passUnretained(self).toOpaque()
        )
        return withUnsafeMutablePointer(to: &fileWrite) { pointer in
            api.saveAsCopy(document, UnsafeMutableRawPointer(pointer), 2) != 0
        }
    }
}

private final class PDFiumAPI {
    let handle: UnsafeMutableRawPointer

    let initialize: @convention(c) () -> Void
    let destroyLibrary: @convention(c) () -> Void
    let loadDocument: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> PDFiumHandle?
    let closeDocument: @convention(c) (PDFiumHandle?) -> Void
    let pageCount: @convention(c) (PDFiumHandle?) -> Int32
    let securityHandlerRevision: @convention(c) (PDFiumHandle?) -> Int32
    let signatureCount: @convention(c) (PDFiumHandle?) -> Int32
    let loadPage: @convention(c) (PDFiumHandle?, Int32) -> PDFiumHandle?
    let closePage: @convention(c) (PDFiumHandle?) -> Void
    let loadTextPage: @convention(c) (PDFiumHandle?) -> PDFiumHandle?
    let closeTextPage: @convention(c) (PDFiumHandle?) -> Void
    let textCountChars: @convention(c) (PDFiumHandle?) -> Int32
    let textUnicode: @convention(c) (PDFiumHandle?, Int32) -> UInt32
    let textObjectForCharacter: @convention(c) (PDFiumHandle?, Int32) -> PDFiumHandle?
    let textIsGenerated: @convention(c) (PDFiumHandle?, Int32) -> Int32
    let textHasUnicodeMapError: @convention(c) (PDFiumHandle?, Int32) -> Int32
    let textFontSize: @convention(c) (PDFiumHandle?, Int32) -> Double
    let textFillColor: @convention(c) (PDFiumHandle?, Int32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    let textCharAngle: @convention(c) (PDFiumHandle?, Int32) -> Float
    let textLooseCharBox: @convention(c) (PDFiumHandle?, Int32, UnsafeMutableRawPointer?) -> Int32
    let pageObjectCount: @convention(c) (PDFiumHandle?) -> Int32
    let pageObject: @convention(c) (PDFiumHandle?, Int32) -> PDFiumHandle?
    let pageObjectType: @convention(c) (PDFiumHandle?) -> Int32
    let pageObjectBounds: @convention(c) (PDFiumHandle?, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?) -> Int32
    let pageHasTransparency: @convention(c) (PDFiumHandle?) -> Int32
    let pageObjectHasTransparency: @convention(c) (PDFiumHandle?) -> Int32
    let pageObjectMatrix: @convention(c) (PDFiumHandle?, UnsafeMutableRawPointer?) -> Int32
    let pageObjectMarkCount: @convention(c) (PDFiumHandle?) -> Int32
    let textObjectFontSize: @convention(c) (PDFiumHandle?, UnsafeMutablePointer<Float>?) -> Int32
    let textRenderMode: @convention(c) (PDFiumHandle?) -> Int32
    let textObjectText: @convention(c) (PDFiumHandle?, PDFiumHandle?, UnsafeMutablePointer<UInt16>?, UInt) -> UInt
    let textObjectFont: @convention(c) (PDFiumHandle?) -> PDFiumHandle?
    let fontBaseName: @convention(c) (PDFiumHandle?, UnsafeMutablePointer<CChar>?, UInt) -> UInt
    let fontIsEmbedded: @convention(c) (PDFiumHandle?) -> Int32
    let fontGlyphWidth: @convention(c) (PDFiumHandle?, UInt32, Float, UnsafeMutablePointer<Float>?) -> Int32
    let fontGlyphPath: @convention(c) (PDFiumHandle?, UInt32, Float) -> PDFiumHandle?
    let setText: @convention(c) (PDFiumHandle?, UnsafePointer<UInt16>?) -> Int32
    let generateContent: @convention(c) (PDFiumHandle?) -> Int32
    let saveAsCopy: @convention(c) (PDFiumHandle?, UnsafeMutableRawPointer?, UInt32) -> Int32

    private init(handle: UnsafeMutableRawPointer) throws {
        self.handle = handle
        initialize = try Self.symbol(handle, "FPDF_InitLibrary")
        destroyLibrary = try Self.symbol(handle, "FPDF_DestroyLibrary")
        loadDocument = try Self.symbol(handle, "FPDF_LoadDocument")
        closeDocument = try Self.symbol(handle, "FPDF_CloseDocument")
        pageCount = try Self.symbol(handle, "FPDF_GetPageCount")
        securityHandlerRevision = try Self.symbol(handle, "FPDF_GetSecurityHandlerRevision")
        signatureCount = try Self.symbol(handle, "FPDF_GetSignatureCount")
        loadPage = try Self.symbol(handle, "FPDF_LoadPage")
        closePage = try Self.symbol(handle, "FPDF_ClosePage")
        loadTextPage = try Self.symbol(handle, "FPDFText_LoadPage")
        closeTextPage = try Self.symbol(handle, "FPDFText_ClosePage")
        textCountChars = try Self.symbol(handle, "FPDFText_CountChars")
        textUnicode = try Self.symbol(handle, "FPDFText_GetUnicode")
        textObjectForCharacter = try Self.symbol(handle, "FPDFText_GetTextObject")
        textIsGenerated = try Self.symbol(handle, "FPDFText_IsGenerated")
        textHasUnicodeMapError = try Self.symbol(handle, "FPDFText_HasUnicodeMapError")
        textFontSize = try Self.symbol(handle, "FPDFText_GetFontSize")
        textFillColor = try Self.symbol(handle, "FPDFText_GetFillColor")
        textCharAngle = try Self.symbol(handle, "FPDFText_GetCharAngle")
        textLooseCharBox = try Self.symbol(handle, "FPDFText_GetLooseCharBox")
        pageObjectCount = try Self.symbol(handle, "FPDFPage_CountObjects")
        pageObject = try Self.symbol(handle, "FPDFPage_GetObject")
        pageObjectType = try Self.symbol(handle, "FPDFPageObj_GetType")
        pageObjectBounds = try Self.symbol(handle, "FPDFPageObj_GetBounds")
        pageHasTransparency = try Self.symbol(handle, "FPDFPage_HasTransparency")
        pageObjectHasTransparency = try Self.symbol(handle, "FPDFPageObj_HasTransparency")
        pageObjectMatrix = try Self.symbol(handle, "FPDFPageObj_GetMatrix")
        pageObjectMarkCount = try Self.symbol(handle, "FPDFPageObj_CountMarks")
        textObjectFontSize = try Self.symbol(handle, "FPDFTextObj_GetFontSize")
        textRenderMode = try Self.symbol(handle, "FPDFTextObj_GetTextRenderMode")
        textObjectText = try Self.symbol(handle, "FPDFTextObj_GetText")
        textObjectFont = try Self.symbol(handle, "FPDFTextObj_GetFont")
        fontBaseName = try Self.symbol(handle, "FPDFFont_GetBaseFontName")
        fontIsEmbedded = try Self.symbol(handle, "FPDFFont_GetIsEmbedded")
        fontGlyphWidth = try Self.symbol(handle, "FPDFFont_GetGlyphWidth")
        fontGlyphPath = try Self.symbol(handle, "FPDFFont_GetGlyphPath")
        setText = try Self.symbol(handle, "FPDFText_SetText")
        generateContent = try Self.symbol(handle, "FPDFPage_GenerateContent")
        saveAsCopy = try Self.symbol(handle, "FPDF_SaveAsCopy")
    }

    deinit { dlclose(handle) }

    static func load() throws -> PDFiumAPI {
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        for key in ["PDFIUM_LIBRARY_PATH", "PDFIUM_PATH"] {
            if let value = environment[key], !value.isEmpty {
                let url = URL(fileURLWithPath: value)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    candidates.append(url.appendingPathComponent("lib/libpdfium.dylib"))
                    candidates.append(url.appendingPathComponent("libpdfium.dylib"))
                } else {
                    candidates.append(url)
                }
            }
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libpdfium.dylib"))
        guard let libraryURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw PDFInternalTextEditError.unavailable("署名済みlibpdfium.dylibが見つかりません。")
        }
        do { return try PDFiumAPI(handle: handle) }
        catch { dlclose(handle); throw error }
    }

    func openDocument(_ url: URL) throws -> PDFiumHandle {
        let document = url.path.withCString { loadDocument($0, nil) }
        guard let document else { throw PDFInternalTextEditError.failed("PDFをPDFiumで開けませんでした。") }
        return document
    }

    func objectText(_ object: PDFiumHandle, textPage: PDFiumHandle) -> String? {
        let byteCount = textObjectText(object, textPage, nil, 0)
        guard byteCount >= 2, byteCount % 2 == 0 else { return nil }
        var units = [UInt16](repeating: 0, count: Int(byteCount / 2))
        let result = units.withUnsafeMutableBufferPointer {
            textObjectText(object, textPage, $0.baseAddress, byteCount)
        }
        guard result == byteCount else { return nil }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    func baseFontName(_ font: PDFiumHandle) -> String {
        let size = fontBaseName(font, nil, 0)
        guard size > 1 else { return "" }
        var bytes = [CChar](repeating: 0, count: Int(size))
        let actual = bytes.withUnsafeMutableBufferPointer { fontBaseName(font, $0.baseAddress, size) }
        guard actual == size else { return "" }
        if bytes.last == 0 { bytes.removeLast() }
        return String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func extractedText(_ textPage: PDFiumHandle) -> String {
        let count = textCountChars(textPage)
        guard count > 0 else { return "" }
        var scalars = String.UnicodeScalarView()
        for index in 0..<count {
            if let scalar = Unicode.Scalar(textUnicode(textPage, index)) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw PDFInternalTextEditError.unavailable("固定SDKに必要なAPI \(name) がありません。")
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 0.01) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
