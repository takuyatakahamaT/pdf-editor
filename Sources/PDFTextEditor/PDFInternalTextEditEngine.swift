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
        let trialURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-pdfium-eligibility-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: trialURL) }
        var trialEdit = edit
        trialEdit.storage = .internalPDFium
        do {
            try preflightEligibility(sourceURL: sourceURL, edit: edit)
            // 候補判定の時点でも保存・再読込検証まで完走させる。画面で内部置換と
            // 表示した後に初めて保存失敗する候補はoverlayへ留める。
            try apply(sourceURL: sourceURL, edits: [trialEdit], to: trialURL)
            return .supported
        } catch let error as PDFInternalTextEditError {
            return .unsupported(error.errorDescription ?? "安全性を確認できませんでした。")
        } catch {
            return .unsupported("PDFiumの照合中に不明なエラーが発生しました。")
        }
    }

    private static func preflightEligibility(sourceURL: URL, edit: ReplacementEdit) throws {
        lock.lock()
        defer { lock.unlock() }
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
        let fontEvidence = try sourceFontEvidence(sourceURL: sourceURL, edit: edit)
        _ = try match(edit: edit, fontEvidence: fontEvidence, document: document, api: api)
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
        let fontEvidenceByID = try Dictionary(uniqueKeysWithValues: edits.map { edit in
            (edit.id, try sourceFontEvidence(sourcePDF: sourcePDF, edit: edit))
        })
        for edit in edits {
            try requireUniqueSourceText(edit.sourceText, in: document, api: api)
        }
        let grouped = Dictionary(grouping: edits, by: \.pageIndex)
        var loadedPages: [Int: PDFiumHandle] = [:]
        defer { loadedPages.values.forEach(api.closePage) }

        for (pageIndex, pageEdits) in grouped.sorted(by: { $0.key < $1.key }) {
            var replacementFonts: [PDFiumHandle] = []
            defer { replacementFonts.forEach(api.closeFont) }
            guard let page = api.loadPage(document, Int32(pageIndex)) else {
                throw PDFInternalTextEditError.failed("\(pageIndex + 1)ページ目を開けませんでした。")
            }
            loadedPages[pageIndex] = page
            guard let textPage = api.loadTextPage(page) else {
                throw PDFInternalTextEditError.failed("\(pageIndex + 1)ページ目の文字情報を読めませんでした。")
            }
            let matches: [Match]
            do {
                matches = try pageEdits.map { edit in
                    guard let evidence = fontEvidenceByID[edit.id] else {
                        throw PDFInternalTextEditError.unsupported("元フォントの文字コードを再照合できません。")
                    }
                    return try match(
                        edit: edit,
                        fontEvidence: evidence,
                        page: page,
                        textPage: textPage,
                        api: api
                    )
                }
            } catch {
                api.closeTextPage(textPage)
                throw error
            }
            let objectIDs = Set(matches.map { UInt(bitPattern: $0.object) })
            guard objectIDs.count == matches.count else {
                api.closeTextPage(textPage)
                throw PDFInternalTextEditError.unsupported("同じtext objectへの複数編集は保存できません。")
            }
            api.closeTextPage(textPage)
            for (edit, matched) in zip(pageEdits, matches) {
                if let fontData = matched.fontEvidence.replacementFontData {
                    replacementFonts.append(try replaceTextObject(
                        edit: edit,
                        match: matched,
                        fontData: fontData,
                        document: document,
                        page: page,
                        api: api
                    ))
                    continue
                }
                let didSet: Int32
                if let charcodes = matched.fontEvidence.replacementCharcodes {
                    didSet = charcodes.withUnsafeBufferPointer { buffer in
                        api.setCharcodes(matched.object, buffer.baseAddress, buffer.count)
                    }
                } else {
                    let utf16 = Array(edit.replacement.utf16) + [0]
                    didSet = utf16.withUnsafeBufferPointer { buffer in
                        api.setText(matched.object, buffer.baseAddress)
                    }
                }
                guard didSet != 0 else {
                    throw PDFInternalTextEditError.failed("置換文字を元フォントへ設定できませんでした。")
                }
            }
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

    private static func replaceTextObject(
        edit: ReplacementEdit,
        match: Match,
        fontData: Data,
        document: PDFiumHandle,
        page: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> PDFiumHandle {
        guard fontData.count <= UInt32.max else {
            throw PDFInternalTextEditError.unsupported("埋込フォントがPDFiumの読込上限を超えています。")
        }
        guard let glyphs = match.fontEvidence.replacementTrueTypeGlyphs else {
            throw PDFInternalTextEditError.unsupported("置換文字のTrueType GIDを再取得できません。")
        }
        let characters = Array(edit.replacement)
        let cids = generatedCharacterCodes(for: characters)
        guard glyphs.count == characters.count, cids.count == characters.count,
              let maximumCID = cids.max(), maximumCID <= UInt16.max else {
            throw PDFInternalTextEditError.unsupported("置換用CIDとTrueType GIDを一意に対応付けられません。")
        }
        var glyphByCID: [UInt32: CGGlyph] = [:]
        var unicodeByCID: [UInt32: UInt16] = [:]
        for ((character, cid), glyph) in zip(zip(characters, cids), glyphs) {
            let utf16 = Array(String(character).utf16)
            guard utf16.count == 1,
                  glyphByCID[cid].map({ $0 == glyph }) ?? true,
                  unicodeByCID[cid].map({ $0 == utf16[0] }) ?? true else {
                throw PDFInternalTextEditError.unsupported("置換文字のCID・Unicode・GID対応が一意ではありません。")
            }
            glyphByCID[cid] = glyph
            unicodeByCID[cid] = utf16[0]
        }
        var cidToGID = Data(repeating: 0, count: (Int(maximumCID) + 1) * 2)
        for (cid, glyph) in glyphByCID {
            cidToGID[Int(cid) * 2] = UInt8(glyph >> 8)
            cidToGID[Int(cid) * 2 + 1] = UInt8(glyph & 0xFF)
        }
        let mappings = unicodeByCID.sorted(by: { $0.key < $1.key }).map { cid, unicode in
            String(format: "<%04X> <%04X>", cid, unicode)
        }.joined(separator: "\n")
        let toUnicode = """
            /CIDInit /ProcSet findresource begin
            12 dict begin begincmap
            /CMapName /PDFEditorReplacement def
            /CMapType 2 def
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            \(unicodeByCID.count) beginbfchar
            \(mappings)
            endbfchar
            endcmap CMapName currentdict /CMap defineresource pop end end
            """
        let loadedFont = fontData.withUnsafeBytes { fontBytes in
            cidToGID.withUnsafeBytes { mapBytes in
                toUnicode.withCString { cmap in
                    api.loadCIDFont(
                        document,
                        fontBytes.bindMemory(to: UInt8.self).baseAddress,
                        UInt32(fontData.count),
                        cmap,
                        mapBytes.bindMemory(to: UInt8.self).baseAddress,
                        UInt32(cidToGID.count)
                    )
                }
            }
        }
        guard let loadedFont else {
            throw PDFInternalTextEditError.unsupported("同じ埋込TrueTypeフォントをPDFiumへ再読込できません。")
        }
        var returnsFont = false
        defer { if !returnsFont { api.closeFont(loadedFont) } }
        guard let replacementObject = api.createTextObject(document, loadedFont, Float(edit.sourceFontSize)) else {
            throw PDFInternalTextEditError.failed("置換用text objectを作成できませんでした。")
        }
        var inserted = false
        defer { if !inserted { api.destroyPageObject(replacementObject) } }

        let utf16 = Array(edit.replacement.utf16) + [0]
        let didSetText = utf16.withUnsafeBufferPointer { buffer in
            api.setText(replacementObject, buffer.baseAddress)
        }
        var matrix = match.sourceMatrix
        let didSetMatrix = withUnsafePointer(to: &matrix) {
            api.setPageObjectMatrix(replacementObject, UnsafeRawPointer($0))
        }
        guard didSetText != 0, didSetMatrix != 0,
              api.setPageObjectFillColor(
                  replacementObject,
                  match.fillColor.red,
                  match.fillColor.green,
                  match.fillColor.blue,
                  match.fillColor.alpha
              ) != 0 else {
            throw PDFInternalTextEditError.failed("置換用text objectの文字・位置・色を設定できませんでした。")
        }
        guard api.removePageObject(page, match.object) != 0 else {
            throw PDFInternalTextEditError.failed("元のtext objectを対象ページから外せませんでした。")
        }
        defer { api.destroyPageObject(match.object) }
        // InsertObjectAtIndexへ渡した時点で所有権はPDFiumへ戻る。
        inserted = true
        guard api.insertPageObject(page, replacementObject, Int(match.objectIndex)) != 0 else {
            throw PDFInternalTextEditError.failed("置換用text objectを元のpage object位置へ挿入できませんでした。")
        }
        returnsFont = true
        return loadedFont
    }

    /// 画面プレビューも保存と同じ内部編集・再読込検証を通す。
    static func previewDocument(sourceURL: URL, edits: [ReplacementEdit]) throws -> PDFDocument {
        let previewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-internal-preview-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: previewURL) }
        try apply(sourceURL: sourceURL, edits: edits, to: previewURL)
        let data = try Data(contentsOf: previewURL)
        guard let document = PDFDocument(data: data) else {
            throw PDFInternalTextEditError.failed("検証済みプレビューPDFをPDFKitで再読込できませんでした。")
        }
        return document
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

    private struct SourceFontEvidence {
        let isEmbedded: Bool
        let replacementCharcodes: [UInt32]?
        let replacementFontData: Data?
        let replacementTrueTypeGlyphs: [CGGlyph]?
        let sourceGlyphs: [UInt32]
        let replacementGlyphs: [UInt32]
        let savedReplacementGlyphs: [UInt32]
        let sourceDeclaredWidths: [CGFloat]
        let replacementDeclaredWidths: [CGFloat]
    }

    private struct ReplacementFontCandidate {
        let fontData: Data
        let glyphs: [CGGlyph]
        let declaredWidths: [CGFloat]

        func isEquivalent(to other: ReplacementFontCandidate) -> Bool {
            fontData == other.fontData
                && glyphs == other.glyphs
                && zip(declaredWidths, other.declaredWidths).allSatisfy {
                    abs($0.0 - $0.1) <= 0.001
                }
                && declaredWidths.count == other.declaredWidths.count
        }
    }

    private struct Match {
        let object: PDFiumHandle
        let objectIndex: Int32
        let fontEvidence: SourceFontEvidence
        let sourceOrigin: CGPoint
        let sourceMatrix: PDFiumMatrix
        let fillColor: ObjectColor
        let sourceWidth: CGFloat
        let replacementWidth: CGFloat
    }

    private static func sourceFontEvidence(sourceURL: URL, edit: ReplacementEdit) throws -> SourceFontEvidence {
        guard let sourcePDF = PDFDocument(url: sourceURL) else {
            throw PDFInternalTextEditError.unsupported("元PDFのフォント資源を開けません。")
        }
        return try sourceFontEvidence(sourcePDF: sourcePDF, edit: edit)
    }

    private static func sourceFontEvidence(
        sourcePDF: PDFDocument,
        edit: ReplacementEdit
    ) throws -> SourceFontEvidence {
        guard let page = sourcePDF.page(at: edit.pageIndex),
              let fontKey = edit.sourceFontKey,
              let fontDictionary = PDFGlyphIndex.fontDictionary(for: fontKey, page: page) else {
            throw PDFInternalTextEditError.unsupported("元フォント資源を一意に取得できません。")
        }
        let info = PDFFontInfoLoader.load(from: fontDictionary)
        let description = PDFEmbeddedFontLoader.describe(fontDict: fontDictionary)

        if description.hasEmbeddedProgram {
            guard let embeddedFont = PDFEmbeddedFontLoader.loadEmbeddedFont(
                fontDict: fontDictionary,
                size: edit.sourceFontSize
            ) else {
                throw PDFInternalTextEditError.unsupported("埋込フォント本体を再読込できません。")
            }
            let sourceCharacters = Array(edit.sourceText)
            let replacementCharacters = Array(edit.replacement)
            let sourceCodes = sourceCharacters.compactMap { info.unicodeToCode[String($0)] }
            let replacementHasExplicitCodes = replacementCharacters.allSatisfy {
                info.unicodeToCode[String($0)] != nil
            }
            let replacementCodes = replacementCharacters.compactMap {
                info.unicodeToCode[String($0)]
            }
            guard sourceCodes.count == sourceCharacters.count else {
                if ProcessInfo.processInfo.environment["PDFIUM_DIAGNOSTICS"] == "1" {
                    fputs(
                        "PDFium font code照合: subtype=\(description.subtype ?? "nil"), "
                            + "encoding=\(description.encoding ?? "nil"), "
                            + "source=\(sourceCodes.count)/\(sourceCharacters.count), "
                            + "replacement=\(replacementCodes.count)/\(replacementCharacters.count)\n",
                        stderr
                    )
                }
                throw PDFInternalTextEditError.unsupported("埋込フォントの元文字を明示ToUnicodeから逆引きできません。")
            }
            guard let sourceResolution = PDFEmbeddedFontLoader.embeddedFontResolution(
                font: embeddedFont,
                info: info,
                replacementText: edit.sourceText
            ), let sourceExact = sourceResolution.exactGlyphs else {
                throw PDFInternalTextEditError.unsupported(
                    "埋込フォントの明示ToUnicodeから元文字のglyphを一意に解決できません。"
                )
            }
            guard sourceExact.count == sourceCodes.count else {
                throw PDFInternalTextEditError.unsupported(
                    "埋込フォントの元文字とglyphの対応数が一致しません。"
                )
            }

            let replacementExact: [(glyph: CGGlyph, emWidth: CGFloat)]
            let replacementFontData: Data?
            if replacementHasExplicitCodes {
                guard replacementCodes.count == replacementCharacters.count,
                      let resolution = PDFEmbeddedFontLoader.embeddedFontResolution(
                          font: embeddedFont,
                          info: info,
                          replacementText: edit.replacement
                      ), let exact = resolution.exactGlyphs,
                      exact.count == replacementCodes.count else {
                    throw PDFInternalTextEditError.unsupported(
                        "埋込フォントの明示ToUnicodeから置換文字のglyphを一意に解決できません。"
                    )
                }
                replacementExact = exact
                replacementFontData = nil
            } else {
                guard let candidate = replacementFontCandidate(
                    on: page,
                    excluding: fontKey,
                    sourceDescription: description,
                    replacementText: edit.replacement,
                    fontSize: edit.sourceFontSize
                ) else {
                    throw PDFInternalTextEditError.unsupported(
                        "同じ書体の埋込フォント資源に、置換文字の明示ToUnicodeとglyphがありません。"
                    )
                }
                replacementExact = zip(candidate.glyphs, candidate.declaredWidths).map {
                    ($0.0, $0.1 / edit.sourceFontSize)
                }
                replacementFontData = candidate.fontData
            }
            return SourceFontEvidence(
                isEmbedded: true,
                replacementCharcodes: replacementHasExplicitCodes ? replacementCodes.map(UInt32.init) : nil,
                replacementFontData: replacementFontData,
                replacementTrueTypeGlyphs: replacementHasExplicitCodes ? nil : replacementExact.map(\.glyph),
                // PDFiumのFont APIは当該PDF font内のglyph識別子（文字コード）を受ける。
                // CoreText側のexactGlyphsはcode→実GIDが一意である証明にだけ使う。
                sourceGlyphs: sourceCodes.map(UInt32.init),
                replacementGlyphs: replacementHasExplicitCodes ? replacementCodes.map(UInt32.init) : [],
                savedReplacementGlyphs: replacementHasExplicitCodes
                    ? replacementCodes.map(UInt32.init) : replacementExact.map { UInt32($0.glyph) },
                sourceDeclaredWidths: sourceExact.map { $0.emWidth * edit.sourceFontSize },
                replacementDeclaredWidths: replacementExact.map { $0.emWidth * edit.sourceFontSize }
            )
        }

        let standardFonts: Set<String> = [
            "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
            "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
            "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"
        ]
        guard let baseFontName = description.pdfName, standardFonts.contains(baseFontName) else {
            throw PDFInternalTextEditError.unsupported(
                "非埋込フォントはPDF標準14書体以外のglyphを証明できません。"
            )
        }
        let sourceScalars = Array(edit.sourceText.unicodeScalars)
        let replacementScalars = Array(edit.replacement.unicodeScalars)
        guard sourceScalars.count == edit.sourceText.count,
              replacementScalars.count == edit.replacement.count,
              sourceScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              replacementScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw PDFInternalTextEditError.unsupported(
                "非埋込のPDF標準14書体は空白を含まないASCII glyphだけを証明できます。"
            )
        }
        func widths(for scalars: [Unicode.Scalar]) -> [CGFloat] {
            scalars.map { scalar in
                let code = info.unicodeToCode[String(scalar)] ?? Int(scalar.value)
                return info.width(for: code) * edit.sourceFontSize
            }
        }
        return SourceFontEvidence(
            isEmbedded: false,
            replacementCharcodes: nil,
            replacementFontData: nil,
            replacementTrueTypeGlyphs: nil,
            sourceGlyphs: sourceScalars.map(\.value),
            replacementGlyphs: replacementScalars.map(\.value),
            savedReplacementGlyphs: replacementScalars.map(\.value),
            sourceDeclaredWidths: widths(for: sourceScalars),
            replacementDeclaredWidths: widths(for: replacementScalars)
        )
    }

    /// 選択中のsubsetに置換文字が無い場合、同じページに埋め込まれた同一書体の
    /// 別subsetからだけglyphを借りる。subsetのcmapをUnicodeとして推測すると、
    /// 例えば code 0x31 が「1」ではなく「ス」を指すPDFがあるため、候補側にも
    /// 明示ToUnicodeがある場合に限定する。
    private static func replacementFontCandidate(
        on page: PDFPage,
        excluding sourceFontKey: String,
        sourceDescription: PDFEmbeddedFontLoader.FontDescription,
        replacementText: String,
        fontSize: CGFloat
    ) -> ReplacementFontCandidate? {
        guard sourceDescription.subtype == "TrueType",
              let sourceName = sourceDescription.pdfName.map(normalizedBaseFontName) else { return nil }
        let dictionaries = PDFGlyphIndex.makeIndex(for: page).fontDictionaries
        let candidates: [ReplacementFontCandidate] = dictionaries
            .sorted(by: { $0.key < $1.key })
            .compactMap { entry -> ReplacementFontCandidate? in
                let (key, dictionary) = entry
                guard key != sourceFontKey else { return nil }
                let description = PDFEmbeddedFontLoader.describe(fontDict: dictionary)
                guard description.subtype == "TrueType",
                      description.hasEmbeddedProgram,
                      description.pdfName.map(normalizedBaseFontName) == sourceName else { return nil }
                let info = PDFFontInfoLoader.load(from: dictionary)
                let characters = Array(replacementText)
                guard characters.allSatisfy({ info.unicodeToCode[String($0)] != nil }),
                      let font = PDFEmbeddedFontLoader.loadEmbeddedFont(
                          fontDict: dictionary,
                          size: fontSize
                      ), let resolution = PDFEmbeddedFontLoader.embeddedFontResolution(
                          font: font,
                          info: info,
                          replacementText: replacementText
                      ), let exact = resolution.exactGlyphs,
                      exact.count == characters.count,
                      let fontData = PDFEmbeddedFontLoader.embeddedFontData(fontDict: dictionary) else {
                    return nil
                }
                return ReplacementFontCandidate(
                    fontData: fontData,
                    glyphs: exact.map(\.glyph),
                    declaredWidths: exact.map { $0.emWidth * fontSize }
                )
            }
        guard let first = candidates.first,
              candidates.dropFirst().allSatisfy({ $0.isEquivalent(to: first) }) else { return nil }
        return first
    }

    private static func normalizedBaseFontName(_ name: String) -> String {
        guard name.count > 7 else { return name.lowercased() }
        let plusIndex = name.index(name.startIndex, offsetBy: 6)
        let prefix = name[name.startIndex..<plusIndex]
        guard name[plusIndex] == "+",
              prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return name.lowercased()
        }
        return String(name[name.index(after: plusIndex)...]).lowercased()
    }

    private static func generatedCharacterCodes(for characters: [Character]) -> [UInt32] {
        var codes: [Character: UInt32] = [:]
        var next: UInt32 = 1
        return characters.map { character in
            if let existing = codes[character] { return existing }
            let code = next
            next += 1
            codes[character] = code
            return code
        }
    }

    private static func match(
        edit: ReplacementEdit,
        fontEvidence: SourceFontEvidence,
        document: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> Match {
        try requireUniqueSourceText(edit.sourceText, in: document, api: api)
        return try matchByLoadingPage(
            edit: edit,
            fontEvidence: fontEvidence,
            document: document,
            api: api
        )
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
        fontEvidence: SourceFontEvidence,
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
        return try match(
            edit: edit,
            fontEvidence: fontEvidence,
            page: page,
            textPage: textPage,
            api: api
        )
    }

    private static func match(
        edit: ReplacementEdit,
        fontEvidence: SourceFontEvidence,
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
            throw PDFInternalTextEditError.unsupported("単一Tjまたは単一文字列TJ以外（複数show・調整付きTJ・Form・marked content・clip）は対象外です。")
        }
        guard edit.hasExplicitSourceMapping else {
            throw PDFInternalTextEditError.unsupported("選択文字の明示ToUnicodeがありません。")
        }
        let sourceScalars = Array(edit.sourceText.unicodeScalars)
        guard !sourceScalars.isEmpty, !edit.replacement.isEmpty,
              sourceScalars.count == edit.sourceGlyphBounds.count else {
            throw PDFInternalTextEditError.unsupported("元文字の文字単位bboxを一意に照合できません。")
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

        var matchingTextObjects: [(object: PDFiumHandle, index: Int32)] = []
        let objectCount = api.pageObjectCount(page)
        guard objectCount >= 0 else { throw PDFInternalTextEditError.unsupported("page objectを列挙できません。") }
        for objectIndex in 0..<objectCount {
            guard let object = api.pageObject(page, objectIndex) else {
                throw PDFInternalTextEditError.unsupported("page objectを取得できません。")
            }
            guard api.pageObjectType(object) == 1 else { continue }
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
            matchingTextObjects.append((object, objectIndex))
        }
        guard matchingTextObjects.count == 1 else {
            let reason = matchingTextObjects.isEmpty
                ? "選択範囲と完全一致する単一text objectを証明できません。"
                : "同じ文字・位置のtext objectが複数あり曖昧です。"
            throw PDFInternalTextEditError.unsupported(reason)
        }

        var candidates: [Match] = []
        for matched in matchingTextObjects {
            let object = matched.object
            guard let charIndices = indicesByObject[UInt(bitPattern: object)],
                  charIndices.count == sourceScalars.count else { continue }
            if let match = try objectMatch(
                object: object,
                objectIndex: matched.index,
                charIndices: charIndices,
                sourceScalars: sourceScalars,
                fontEvidence: fontEvidence,
                edit: edit,
                textPage: textPage,
                api: api
            ) {
                candidates.append(match)
            }
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw PDFInternalTextEditError.unsupported(
                "単一text objectと文字単位のUnicode・bbox・styleを一致確認できません。"
            )
        }
        return candidate
    }

    private static func objectMatch(
        object: PDFiumHandle,
        objectIndex: Int32,
        charIndices: [Int32],
        sourceScalars: [Unicode.Scalar],
        fontEvidence: SourceFontEvidence,
        edit: ReplacementEdit,
        textPage: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> Match? {
        let diagnostics = ProcessInfo.processInfo.environment["PDFIUM_DIAGNOSTICS"] == "1"
        func reject(_ message: String) -> Match? {
            if diagnostics { fputs("PDFium照合: \(message)\n", stderr) }
            return nil
        }
        guard api.pageObjectHasTransparency(object) == 0,
              api.pageObjectMarkCount(object) == 0,
              api.textRenderMode(object) == 0,
              api.clipPathCount(object) == 0 else {
            return reject(
                "透明=\(api.pageObjectHasTransparency(object))、marked=\(api.pageObjectMarkCount(object))、"
                    + "clip=\(api.clipPathCount(object))、renderMode=\(api.textRenderMode(object))"
            )
        }
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
              let font = api.textObjectFont(object),
              (api.fontIsEmbedded(font) != 0) == fontEvidence.isEmbedded else {
            return reject("font sizeまたは埋込状態: object=\(objectFontSize), source=\(edit.sourceFontSize)")
        }

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

        }

        guard let sourceWidth = provenGlyphWidth(
            glyphs: fontEvidence.sourceGlyphs,
            declaredWidths: fontEvidence.sourceDeclaredWidths,
            font: font,
            fontSize: objectFontSize,
            api: api
        ) else {
            return reject("元glyphのpath・幅を証明できません")
        }
        let replacementWidth: CGFloat
        if fontEvidence.replacementFontData != nil {
            guard !fontEvidence.replacementDeclaredWidths.isEmpty,
                  fontEvidence.replacementDeclaredWidths.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                return reject("同一書体の置換glyph幅を証明できません")
            }
            replacementWidth = fontEvidence.replacementDeclaredWidths.reduce(0, +)
        } else if let width = provenGlyphWidth(
            glyphs: fontEvidence.replacementGlyphs,
            declaredWidths: fontEvidence.replacementDeclaredWidths,
            font: font,
            fontSize: objectFontSize,
            api: api
        ) {
            replacementWidth = width
        } else {
            return reject("glyph path・幅を証明できないか、置換後の幅が元objectを超えます")
        }
        guard replacementWidth <= sourceWidth + max(0.1, CGFloat(objectFontSize) * 0.02) else {
            return reject("置換後の幅が元objectを超えます")
        }
        guard let firstIndex = charIndices.first,
              let sourceOrigin = api.characterOrigin(textPage, index: firstIndex),
              abs(sourceOrigin.x - edit.bounds.minX) <= max(0.75, edit.sourceFontSize * 0.08),
              abs(sourceOrigin.y - edit.baseline) <= max(0.75, edit.sourceFontSize * 0.08),
              let fillColor = api.objectColor(object, getter: api.pageObjectFillColor) else {
            return reject("文字原点・baselineを照合できません")
        }
        return Match(
            object: object,
            objectIndex: objectIndex,
            fontEvidence: fontEvidence,
            sourceOrigin: sourceOrigin,
            sourceMatrix: matrix,
            fillColor: fillColor,
            sourceWidth: sourceWidth,
            replacementWidth: replacementWidth
        )
    }

    private static func provenGlyphWidth(
        glyphs: [UInt32],
        declaredWidths: [CGFloat],
        font: PDFiumHandle,
        fontSize: Float,
        api: PDFiumAPI
    ) -> CGFloat? {
        guard !glyphs.isEmpty, glyphs.count == declaredWidths.count else { return nil }
        var total: CGFloat = 0
        for (glyph, declaredWidth) in zip(glyphs, declaredWidths) {
            var width: Float = 0
            let path = api.fontGlyphPath(font, glyph, fontSize)
            let gotWidth = api.fontGlyphWidth(font, glyph, fontSize, &width)
            guard path != nil,
                  gotWidth != 0,
                  width.isFinite, width > 0,
                  abs(CGFloat(width) - declaredWidth) <= max(0.15, declaredWidth * 0.05) else {
                if ProcessInfo.processInfo.environment["PDFIUM_DIAGNOSTICS"] == "1" {
                    fputs(
                        "PDFium glyph照合: gid=\(glyph), path=\(path != nil), gotWidth=\(gotWidth), "
                            + "width=\(width), declared=\(declaredWidth)\n",
                        stderr
                    )
                }
                return nil
            }
            total += CGFloat(width)
        }
        return total
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
        let sourceDocument: PDFiumHandle?
        let sourceMatches: [UUID: Match]
        if requireObjectGeometry {
            let openedSource = try api.openDocument(sourceURL)
            sourceDocument = openedSource
            var matches: [UUID: Match] = [:]
            do {
                for edit in edits {
                    let evidence = try sourceFontEvidence(sourcePDF: sourcePDF, edit: edit)
                    matches[edit.id] = try match(
                        edit: edit,
                        fontEvidence: evidence,
                        document: openedSource,
                        api: api
                    )
                }
            } catch {
                api.closeDocument(openedSource)
                throw error
            }
            sourceMatches = matches
        } else {
            sourceDocument = nil
            sourceMatches = [:]
        }
        defer { if let sourceDocument { api.closeDocument(sourceDocument) } }

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
                    guard let sourceDocument,
                          let sourcePage = api.loadPage(sourceDocument, Int32(pageIndex)),
                          let sourceTextPage = api.loadTextPage(sourcePage) else {
                        throw PDFInternalTextEditError.failed("保存前のpage objectを再読込できません。")
                    }
                    defer {
                        api.closeTextPage(sourceTextPage)
                        api.closePage(sourcePage)
                    }
                    var sourceTargetIndices = Set<Int32>()
                    var outputTargetIndices = Set<Int32>()
                    for edit in edits where edit.pageIndex == pageIndex {
                        guard let sourceMatch = sourceMatches[edit.id] else {
                            throw PDFInternalTextEditError.failed("保存前の対象objectを再照合できません。")
                        }
                        sourceTargetIndices.insert(sourceMatch.objectIndex)
                        outputTargetIndices.insert(try verifyEditedGeometry(
                            edit,
                            sourceMatch: sourceMatch,
                            page: page,
                            textPage: textPage,
                            api: api
                        ))
                    }
                    try verifyUneditedObjects(
                        sourcePage: sourcePage,
                        sourceTextPage: sourceTextPage,
                        sourceTargetIndices: sourceTargetIndices,
                        outputPage: page,
                        outputTextPage: textPage,
                        outputTargetIndices: outputTargetIndices,
                        api: api
                    )
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
        sourceMatch: Match,
        page: PDFiumHandle,
        textPage: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> Int32 {
        let replacementScalars = Array(edit.replacement.unicodeScalars)
        let charCount = api.textCountChars(textPage)
        let objectCount = api.pageObjectCount(page)
        guard charCount > 0, objectCount > sourceMatch.objectIndex, !replacementScalars.isEmpty else {
            throw PDFInternalTextEditError.failed("保存後の文字単位geometryを照合できません。")
        }
        var indicesByObject: [UInt: [Int32]] = [:]
        for index in 0..<charCount {
            guard let object = api.textObjectForCharacter(textPage, index) else { continue }
            indicesByObject[UInt(bitPattern: object), default: []].append(index)
        }
        var candidates: [(index: Int32, object: PDFiumHandle, indices: [Int32])] = []
        for objectIndex in 0..<objectCount {
            guard let object = api.pageObject(page, objectIndex), api.pageObjectType(object) == 1,
                  api.objectText(object, textPage: textPage) == edit.replacement,
                  let indices = indicesByObject[UInt(bitPattern: object)],
                  indices.count == replacementScalars.count,
                  let firstIndex = indices.first,
                  let origin = api.characterOrigin(textPage, index: firstIndex) else { continue }
            if ProcessInfo.processInfo.environment["PDFIUM_DIAGNOSTICS"] == "1" {
                fputs(
                    "PDFium replacement候補: index=\(objectIndex), origin=\(origin), "
                        + "sourceOrigin=\(sourceMatch.sourceOrigin)\n",
                    stderr
                )
            }
            guard
                  abs(origin.x - sourceMatch.sourceOrigin.x) <= 0.1,
                  abs(origin.y - sourceMatch.sourceOrigin.y) <= 0.1 else { continue }
            candidates.append((objectIndex, object, indices))
        }
        guard candidates.count == 1, let saved = candidates.first else {
            throw PDFInternalTextEditError.failed("保存後の対象文字objectをorigin・baselineから一意に再特定できません。")
        }
        let object = saved.object
        let indices = saved.indices
        for (offset, index) in indices.enumerated() {
            guard api.textUnicode(textPage, index) == replacementScalars[offset].value,
                  abs(api.textFontSize(textPage, index) - Double(edit.sourceFontSize)) <= 0.05 else {
                throw PDFInternalTextEditError.failed("保存後の文字サイズ・位置を維持できませんでした。")
            }
        }
        guard let firstIndex = indices.first,
              let savedOrigin = api.characterOrigin(textPage, index: firstIndex),
              abs(savedOrigin.x - sourceMatch.sourceOrigin.x) <= 0.1,
              abs(savedOrigin.y - sourceMatch.sourceOrigin.y) <= 0.1,
              let font = api.textObjectFont(object) else {
            throw PDFInternalTextEditError.failed("保存後のbaseline・origin・置換幅を維持できませんでした。")
        }
        let savedWidth: CGFloat
        if sourceMatch.fontEvidence.replacementFontData != nil {
            guard let glyphs = sourceMatch.fontEvidence.replacementTrueTypeGlyphs,
                  !glyphs.isEmpty,
                  glyphs.allSatisfy({ api.fontGlyphPath(font, UInt32($0), Float(edit.sourceFontSize)) != nil }) else {
                throw PDFInternalTextEditError.failed("保存後の埋込フォントから置換glyphを再取得できませんでした。")
            }
            var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
            guard api.pageObjectBounds(object, &left, &bottom, &right, &top) != 0 else {
                throw PDFInternalTextEditError.failed("保存後の置換glyph外接矩形を取得できませんでした。")
            }
            let inkWidth = CGFloat(right - left)
            guard inkWidth.isFinite, inkWidth > 0,
                  inkWidth <= sourceMatch.replacementWidth
                    + max(0.25, sourceMatch.replacementWidth * 0.15) else {
                throw PDFInternalTextEditError.failed("保存後の置換glyph外接矩形が証明済み送り幅を超えました。")
            }
            savedWidth = sourceMatch.replacementWidth
        } else {
            guard let width = provenGlyphWidth(
                glyphs: sourceMatch.fontEvidence.savedReplacementGlyphs,
                declaredWidths: sourceMatch.fontEvidence.replacementDeclaredWidths,
                font: font,
                fontSize: Float(edit.sourceFontSize),
                api: api
            ) else {
                throw PDFInternalTextEditError.failed("保存後の置換幅を元フォントと再照合できませんでした。")
            }
            savedWidth = width
        }
        if abs(savedWidth - sourceMatch.replacementWidth) > max(0.1, sourceMatch.replacementWidth * 0.05) {
            throw PDFInternalTextEditError.failed("保存後の置換幅が元フォントの証明値と一致しません。")
        }
        guard savedWidth <= sourceMatch.sourceWidth + max(0.1, edit.sourceFontSize * 0.02) else {
            throw PDFInternalTextEditError.failed("保存後の置換幅が許容範囲を超えました。")
        }
        return saved.index
    }

    fileprivate struct ObjectColor: Equatable {
        let red: UInt32
        let green: UInt32
        let blue: UInt32
        let alpha: UInt32
    }

    private struct ObjectSnapshot {
        let type: Int32
        let bounds: CGRect
        let matrix: PDFiumMatrix
        let hasTransparency: Int32
        let markCount: Int32
        let clipPathCount: Int32
        let fillColor: ObjectColor?
        let strokeColor: ObjectColor?
        let text: String?

        func approximatelyEquals(_ other: ObjectSnapshot) -> Bool {
            type == other.type
                && bounds.approximatelyEquals(other.bounds, tolerance: 0.02)
                && matrix.approximatelyEquals(other.matrix)
                && hasTransparency == other.hasTransparency
                && markCount == other.markCount
                && clipPathCount == other.clipPathCount
                && fillColor == other.fillColor
                && strokeColor == other.strokeColor
                && text == other.text
        }
    }

    private static func verifyUneditedObjects(
        sourcePage: PDFiumHandle,
        sourceTextPage: PDFiumHandle,
        sourceTargetIndices: Set<Int32>,
        outputPage: PDFiumHandle,
        outputTextPage: PDFiumHandle,
        outputTargetIndices: Set<Int32>,
        api: PDFiumAPI
    ) throws {
        let source = try objectSnapshots(page: sourcePage, textPage: sourceTextPage, api: api)
            .enumerated().filter { !sourceTargetIndices.contains(Int32($0.offset)) }.map(\.element)
        let output = try objectSnapshots(page: outputPage, textPage: outputTextPage, api: api)
            .enumerated().filter { !outputTargetIndices.contains(Int32($0.offset)) }.map(\.element)
        guard source.count == output.count,
              zip(source, output).allSatisfy({ $0.0.approximatelyEquals($0.1) }) else {
            throw PDFInternalTextEditError.failed(
                "保存後に対象外のpage object・geometry・色・透明度・clip構造が変化しました。"
            )
        }
    }

    private static func objectSnapshots(
        page: PDFiumHandle,
        textPage: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> [ObjectSnapshot] {
        let count = api.pageObjectCount(page)
        guard count >= 0 else { throw PDFInternalTextEditError.failed("page objectを列挙できません。") }
        return try (0..<count).map { index in
            guard let object = api.pageObject(page, index) else {
                throw PDFInternalTextEditError.failed("page objectを取得できません。")
            }
            var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
            var matrix = PDFiumMatrix()
            guard api.pageObjectBounds(object, &left, &bottom, &right, &top) != 0,
                  withUnsafeMutablePointer(to: &matrix, {
                      api.pageObjectMatrix(object, UnsafeMutableRawPointer($0))
                  }) != 0 else {
                throw PDFInternalTextEditError.failed("page objectのgeometryを取得できません。")
            }
            return ObjectSnapshot(
                type: api.pageObjectType(object),
                bounds: CGRect(
                    x: CGFloat(left), y: CGFloat(bottom),
                    width: CGFloat(right - left), height: CGFloat(top - bottom)
                ).standardized,
                matrix: matrix,
                hasTransparency: api.pageObjectHasTransparency(object),
                markCount: api.pageObjectMarkCount(object),
                clipPathCount: api.clipPathCount(object),
                fillColor: api.objectColor(object, getter: api.pageObjectFillColor),
                strokeColor: api.objectColor(object, getter: api.pageObjectStrokeColor),
                text: api.pageObjectType(object) == 1 ? api.objectText(object, textPage: textPage) : nil
            )
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
    let textCharOrigin: @convention(c) (PDFiumHandle?, Int32, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?) -> Int32
    let pageObjectCount: @convention(c) (PDFiumHandle?) -> Int32
    let pageObject: @convention(c) (PDFiumHandle?, Int32) -> PDFiumHandle?
    let pageObjectType: @convention(c) (PDFiumHandle?) -> Int32
    let pageObjectBounds: @convention(c) (PDFiumHandle?, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?) -> Int32
    let pageHasTransparency: @convention(c) (PDFiumHandle?) -> Int32
    let pageObjectHasTransparency: @convention(c) (PDFiumHandle?) -> Int32
    let pageObjectMatrix: @convention(c) (PDFiumHandle?, UnsafeMutableRawPointer?) -> Int32
    let setPageObjectMatrix: @convention(c) (PDFiumHandle?, UnsafeRawPointer?) -> Int32
    let pageObjectMarkCount: @convention(c) (PDFiumHandle?) -> Int32
    let pageObjectClipPath: @convention(c) (PDFiumHandle?) -> PDFiumHandle?
    let clipPathCountPaths: @convention(c) (PDFiumHandle?) -> Int32
    let pageObjectFillColor: @convention(c) (PDFiumHandle?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    let setPageObjectFillColor: @convention(c) (PDFiumHandle?, UInt32, UInt32, UInt32, UInt32) -> Int32
    let pageObjectStrokeColor: @convention(c) (PDFiumHandle?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    let textObjectFontSize: @convention(c) (PDFiumHandle?, UnsafeMutablePointer<Float>?) -> Int32
    let textRenderMode: @convention(c) (PDFiumHandle?) -> Int32
    let textObjectText: @convention(c) (PDFiumHandle?, PDFiumHandle?, UnsafeMutablePointer<UInt16>?, UInt) -> UInt
    let textObjectFont: @convention(c) (PDFiumHandle?) -> PDFiumHandle?
    let fontBaseName: @convention(c) (PDFiumHandle?, UnsafeMutablePointer<CChar>?, UInt) -> UInt
    let fontIsEmbedded: @convention(c) (PDFiumHandle?) -> Int32
    let fontGlyphWidth: @convention(c) (PDFiumHandle?, UInt32, Float, UnsafeMutablePointer<Float>?) -> Int32
    let fontGlyphPath: @convention(c) (PDFiumHandle?, UInt32, Float) -> PDFiumHandle?
    let setText: @convention(c) (PDFiumHandle?, UnsafePointer<UInt16>?) -> Int32
    let setCharcodes: @convention(c) (PDFiumHandle?, UnsafePointer<UInt32>?, Int) -> Int32
    let loadCIDFont: @convention(c) (PDFiumHandle?, UnsafePointer<UInt8>?, UInt32, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, UInt32) -> PDFiumHandle?
    let closeFont: @convention(c) (PDFiumHandle?) -> Void
    let createTextObject: @convention(c) (PDFiumHandle?, PDFiumHandle?, Float) -> PDFiumHandle?
    let removePageObject: @convention(c) (PDFiumHandle?, PDFiumHandle?) -> Int32
    let insertPageObject: @convention(c) (PDFiumHandle?, PDFiumHandle?, Int) -> Int32
    let destroyPageObject: @convention(c) (PDFiumHandle?) -> Void
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
        textCharOrigin = try Self.symbol(handle, "FPDFText_GetCharOrigin")
        pageObjectCount = try Self.symbol(handle, "FPDFPage_CountObjects")
        pageObject = try Self.symbol(handle, "FPDFPage_GetObject")
        pageObjectType = try Self.symbol(handle, "FPDFPageObj_GetType")
        pageObjectBounds = try Self.symbol(handle, "FPDFPageObj_GetBounds")
        pageHasTransparency = try Self.symbol(handle, "FPDFPage_HasTransparency")
        pageObjectHasTransparency = try Self.symbol(handle, "FPDFPageObj_HasTransparency")
        pageObjectMatrix = try Self.symbol(handle, "FPDFPageObj_GetMatrix")
        setPageObjectMatrix = try Self.symbol(handle, "FPDFPageObj_SetMatrix")
        pageObjectMarkCount = try Self.symbol(handle, "FPDFPageObj_CountMarks")
        pageObjectClipPath = try Self.symbol(handle, "FPDFPageObj_GetClipPath")
        clipPathCountPaths = try Self.symbol(handle, "FPDFClipPath_CountPaths")
        pageObjectFillColor = try Self.symbol(handle, "FPDFPageObj_GetFillColor")
        setPageObjectFillColor = try Self.symbol(handle, "FPDFPageObj_SetFillColor")
        pageObjectStrokeColor = try Self.symbol(handle, "FPDFPageObj_GetStrokeColor")
        textObjectFontSize = try Self.symbol(handle, "FPDFTextObj_GetFontSize")
        textRenderMode = try Self.symbol(handle, "FPDFTextObj_GetTextRenderMode")
        textObjectText = try Self.symbol(handle, "FPDFTextObj_GetText")
        textObjectFont = try Self.symbol(handle, "FPDFTextObj_GetFont")
        fontBaseName = try Self.symbol(handle, "FPDFFont_GetBaseFontName")
        fontIsEmbedded = try Self.symbol(handle, "FPDFFont_GetIsEmbedded")
        fontGlyphWidth = try Self.symbol(handle, "FPDFFont_GetGlyphWidth")
        fontGlyphPath = try Self.symbol(handle, "FPDFFont_GetGlyphPath")
        setText = try Self.symbol(handle, "FPDFText_SetText")
        setCharcodes = try Self.symbol(handle, "FPDFText_SetCharcodes")
        loadCIDFont = try Self.symbol(handle, "FPDFText_LoadCidType2Font")
        closeFont = try Self.symbol(handle, "FPDFFont_Close")
        createTextObject = try Self.symbol(handle, "FPDFPageObj_CreateTextObj")
        removePageObject = try Self.symbol(handle, "FPDFPage_RemoveObject")
        insertPageObject = try Self.symbol(handle, "FPDFPage_InsertObjectAtIndex")
        destroyPageObject = try Self.symbol(handle, "FPDFPageObj_Destroy")
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

    func characterOrigin(_ textPage: PDFiumHandle, index: Int32) -> CGPoint? {
        var x: Double = 0
        var y: Double = 0
        guard textCharOrigin(textPage, index, &x, &y) != 0, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    func clipPathCount(_ object: PDFiumHandle) -> Int32 {
        guard let clipPath = pageObjectClipPath(object) else { return 0 }
        return max(0, clipPathCountPaths(clipPath))
    }

    func objectColor(
        _ object: PDFiumHandle,
        getter: @convention(c) (
            PDFiumHandle?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
            UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?
        ) -> Int32
    ) -> PDFInternalTextEditEngine.ObjectColor? {
        var red: UInt32 = 0
        var green: UInt32 = 0
        var blue: UInt32 = 0
        var alpha: UInt32 = 0
        guard getter(object, &red, &green, &blue, &alpha) != 0 else { return nil }
        return PDFInternalTextEditEngine.ObjectColor(red: red, green: green, blue: blue, alpha: alpha)
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

private extension PDFiumMatrix {
    func approximatelyEquals(_ other: PDFiumMatrix, tolerance: Float = 0.0001) -> Bool {
        abs(a - other.a) <= tolerance && abs(b - other.b) <= tolerance
            && abs(c - other.c) <= tolerance && abs(d - other.d) <= tolerance
            && abs(e - other.e) <= tolerance && abs(f - other.f) <= tolerance
    }
}
