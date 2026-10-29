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

    /// QuartzがToUnicodeを省略した可視fontへ、実際の描画とPDFiumのUnicodeが
    /// 一対一に一致した対応だけを返す。fontKeyはページのresource名であり、
    /// Form内のfontや不可視の検索層をページ直下のfontへ混ぜない。
    static func visibleUnicodeMappings(sourceURL: URL) throws -> [Int: [String: [Int: String]]] {
        lock.lock()
        defer { lock.unlock() }
        let api = try PDFiumAPI.load()
        api.initialize()
        defer { api.destroyLibrary() }
        let document = try api.openDocument(sourceURL)
        defer { api.closeDocument(document) }
        guard let pdf = PDFDocument(url: sourceURL), pdf.pageCount == Int(api.pageCount(document)) else {
            throw PDFInternalTextEditError.failed("可視文字のページ情報を照合できません。")
        }

        struct VisibleCharacter {
            let index: Int32
            let unicode: String
            let origin: CGPoint
            let size: CGFloat
            let color: ObjectColor
            let font: PDFiumHandle
            let fontName: String
        }
        var result: [Int: [String: [Int: String]]] = [:]
        for pageIndex in 0..<pdf.pageCount {
            guard let pdfPage = pdf.page(at: pageIndex), pdfPage.rotation == 0 else { continue }
            guard let page = api.loadPage(document, Int32(pageIndex)) else {
                throw PDFInternalTextEditError.failed("可視文字のページを開けません。")
            }
            defer { api.closePage(page) }
            guard let textPage = api.loadTextPage(page) else {
                throw PDFInternalTextEditError.failed("可視文字のUnicodeを取得できません。")
            }
            defer { api.closeTextPage(textPage) }
            let index = PDFGlyphIndex.makeIndex(for: pdfPage)
            var fontsByObject: [UInt: PDFiumHandle] = [:]
            for objectIndex in 0..<max(0, api.pageObjectCount(page)) {
                guard let object = api.pageObject(page, objectIndex),
                      api.pageObjectType(object) == 1,
                      api.textRenderMode(object) == 0,
                      api.pageObjectHasTransparency(object) == 0,
                      api.pageObjectMarkCount(object) == 0,
                      api.clipPathCount(object) == 0,
                      let font = api.textObjectFont(object) else { continue }
                var matrix = PDFiumMatrix()
                guard withUnsafeMutablePointer(to: &matrix, {
                    api.pageObjectMatrix(object, UnsafeMutableRawPointer($0))
                }) != 0, matrix.a.isFinite, matrix.a > 0,
                    abs(matrix.a - matrix.d) <= 0.0001,
                    abs(matrix.b) <= 0.0001, abs(matrix.c) <= 0.0001 else { continue }
                fontsByObject[UInt(bitPattern: object)] = font
            }
            var characters: [VisibleCharacter] = []
            for charIndex in 0..<max(0, api.textCountChars(textPage)) {
                guard api.textIsGenerated(textPage, charIndex) == 0,
                      api.textHasUnicodeMapError(textPage, charIndex) == 0,
                      let object = api.textObjectForCharacter(textPage, charIndex),
                      let font = fontsByObject[UInt(bitPattern: object)],
                      let scalar = Unicode.Scalar(api.textUnicode(textPage, charIndex)),
                      scalar.value != 0, !CharacterSet.controlCharacters.contains(scalar),
                      let origin = api.characterOrigin(textPage, index: charIndex),
                      abs(api.textCharAngle(textPage, charIndex)) <= 0.0001 else { continue }
                var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 0
                let size = CGFloat(api.effectiveCharacterFontSize(textPage, index: charIndex))
                guard size.isFinite, size > 0,
                      api.textFillColor(textPage, charIndex, &red, &green, &blue, &alpha) != 0,
                      alpha == 255 else { continue }
                characters.append(VisibleCharacter(
                    index: charIndex, unicode: String(scalar), origin: origin, size: size,
                    color: ObjectColor(red: red, green: green, blue: blue, alpha: alpha),
                    font: font, fontName: api.baseFontName(font)
                ))
            }

            var mappings: [String: [Int: String]] = [:]
            var rejected: [String: Set<Int>] = [:]
            var claimed: [Int32: (fontKey: String, code: Int)] = [:]
            for glyph in index.runs.flatMap(\.glyphs) where glyph.isVisible && !glyph.isInsideForm {
                guard let code = glyph.sourceCharacterCode else { continue }
                func reject() {
                    rejected[glyph.fontKey, default: []].insert(code)
                }
                guard !glyph.isInsideMarkedContent, !glyph.isClipped,
                      glyph.textRenderingMode == 0,
                      let dictionary = index.fontDictionaries[glyph.fontKey],
                      let color = glyph.fillColor.usingColorSpace(.deviceRGB) else {
                    reject(); continue
                }
                var baseFont: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "BaseFont", &baseFont), let baseFont else {
                    reject(); continue
                }
                let fontName = String(cString: baseFont)
                let candidates = characters.filter {
                    $0.fontName == fontName
                        && abs($0.origin.x - glyph.advanceBox.minX) <= 0.05
                        && abs($0.origin.y - glyph.baseline) <= 0.05
                        && abs($0.size - glyph.fontSize) <= 0.05
                        && abs(color.redComponent - CGFloat($0.color.red) / 255) <= 0.01
                        && abs(color.greenComponent - CGFloat($0.color.green) / 255) <= 0.01
                        && abs(color.blueComponent - CGFloat($0.color.blue) / 255) <= 0.01
                        && abs(color.alphaComponent - CGFloat($0.color.alpha) / 255) <= 0.01
                }
                guard candidates.count == 1, let character = candidates.first,
                      let scalar = character.unicode.unicodeScalars.first,
                      glyph.text.isEmpty || glyph.text == character.unicode else {
                    reject(); continue
                }
                // charcodeが同じfontの実glyphを指すことも確認する。UnicodeからGIDを推測しない。
                var width: Float = 0
                guard api.fontGlyphWidth(character.font, scalar.value, Float(character.size), &width) != 0,
                      width.isFinite, width >= 0,
                      abs(CGFloat(width) - glyph.advanceBox.width) <= 0.1,
                      api.fontGlyphPath(character.font, scalar.value, Float(character.size)) != nil
                        || character.unicode.unicodeScalars.allSatisfy({ isBlankUnicode($0.value) }) else {
                    reject(); continue
                }
                if let previous = claimed[character.index] {
                    rejected[previous.fontKey, default: []].insert(previous.code)
                    reject(); continue
                }
                claimed[character.index] = (glyph.fontKey, code)
                if let previous = mappings[glyph.fontKey]?[code], previous != character.unicode {
                    reject(); continue
                }
                mappings[glyph.fontKey, default: [:]][code] = character.unicode
            }
            for (fontKey, codes) in rejected {
                for code in codes { mappings[fontKey]?[code] = nil }
            }
            mappings = mappings.filter { !$0.value.isEmpty }
            if !mappings.isEmpty { result[pageIndex] = mappings }
        }
        return result
    }

    static func eligibility(sourceURL: URL, edit: ReplacementEdit) -> PDFInternalTextEligibility {
        let trialURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-pdfium-eligibility-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: trialURL) }
        var trialEdit = edit
        trialEdit.storage = .internalPDFium
        do {
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
        let edits = try expandedSourceRemovals(edits, sourcePDF: sourcePDF)
        try validateEditSet(edits)
        let fontEvidenceByID = try Dictionary(uniqueKeysWithValues: edits.map { edit in
            (edit.id, try sourceFontEvidence(sourcePDF: sourcePDF, edit: edit))
        })
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
            api.closeTextPage(textPage)
            // 独立show末尾なら、元streamとfont codeを保って局所置換できる。
            // ICCBased色や対象外fontのUnicodeを再生成せず文字列tokenだけを書き換える。
            if sourcePDF.pageCount == 1, pageEdits.count == edits.count,
               Set(matches.map(\.objectIndex)).count == matches.count,
               let data = try PDFContentTextRemovalWriter.rewritingTextShows(
                   sourceURL: sourceURL, sourcePDF: sourcePDF, edits: edits
               ) {
                try writeVerified(data: data, sourceURL: sourceURL, outputURL: outputURL, edits: edits, api: api, preservesRetainedGrouping: true)
                return
            }
            let objectEdits = Dictionary(grouping: Array(zip(pageEdits, matches)), by: { $0.1.objectIndex })
            // 後方から適用し、object分割や削除による後続indexのずれを避ける。
            for (_, group) in objectEdits.sorted(by: { $0.key > $1.key }) {
                if group.count > 1 {
                    try reconstructCombinedTextObject(group, document: document, page: page, api: api)
                    continue
                }
                guard let (edit, matched) = group.first else { continue }
                if edit.replacement.isEmpty || matched.requiresReconstruction {
                    let font = try reconstructTextObject(edit: edit, match: matched, document: document, page: page, api: api)
                    if let font { replacementFonts.append(font) }
                    continue
                }
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
        try writeVerified(data: writer.data, sourceURL: sourceURL, outputURL: outputURL, edits: edits, api: api)
    }

    private static func writeVerified(
        data: Data, sourceURL: URL, outputURL: URL, edits: [ReplacementEdit], api: PDFiumAPI,
        preservesRetainedGrouping: Bool = false
    ) throws {
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-pdfium-stage-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        do { try data.write(to: stagedURL, options: .atomic) }
        catch { throw PDFInternalTextEditError.failed("一時PDFを書き出せませんでした。") }

        try verify(sourceURL: sourceURL, outputURL: stagedURL, edits: edits, api: api, requireObjectGeometry: true, preservesRetainedGrouping: preservesRetainedGrouping)
        do { try data.write(to: outputURL, options: .atomic) }
        catch { throw PDFInternalTextEditError.failed("検証済みPDFを一時出力へ配置できませんでした。") }
    }

    /// 同じobject内の非重複編集を、同じ原本座標から一度だけ再構成する。
    private static func reconstructCombinedTextObject(
        _ edits: [(ReplacementEdit, Match)],
        document: PDFiumHandle, page: PDFiumHandle, api: PDFiumAPI
    ) throws {
        guard let first = edits.first, let sourceFont = api.textObjectFont(first.1.object) else {
            throw PDFInternalTextEditError.failed("集約対象の元fontを取得できません。")
        }
        var selectedIndices = Set<Int32>()
        for (_, match) in edits {
            guard selectedIndices.isDisjoint(with: match.selectedCharacterIndices) else {
                throw PDFInternalTextEditError.unsupported("同じ文字範囲への複数編集は保存できません。")
            }
            guard match.fontEvidence.replacementFontData == nil else {
                throw PDFInternalTextEditError.unsupported("同じobject内で別subsetのfontを混ぜる複数編集は対象外です。")
            }
            selectedIndices.formUnion(match.selectedCharacterIndices)
        }
        var pending: [(index: Int32, object: PDFiumHandle)] = []
        defer { pending.forEach { api.destroyPageObject($0.object) } }
        for glyph in first.1.retainedGlyphs where !selectedIndices.contains(glyph.sourceIndex) {
            let object = try createPositionedObject(
                document: document, font: sourceFont, size: first.0.sourceFontSize,
                codes: [glyph.code], origin: glyph.origin, color: first.1.fillColor, api: api
            )
            pending.append((glyph.sourceIndex, object))
        }
        for (edit, match) in edits where !edit.replacement.isEmpty {
            guard let firstIndex = match.selectedCharacterIndices.min() else {
                throw PDFInternalTextEditError.failed("集約する選択文字位置がありません。")
            }
            let object = try createPositionedObject(
                document: document, font: sourceFont, size: edit.sourceFontSize,
                codes: match.fontEvidence.replacementCharcodes ?? match.fontEvidence.replacementGlyphs,
                origin: match.sourceOrigin, color: match.fillColor, api: api
            )
            pending.append((firstIndex, object))
        }
        guard api.removePageObject(page, first.1.object) != 0 else {
            throw PDFInternalTextEditError.failed("集約対象の元objectを外せませんでした。")
        }
        api.destroyPageObject(first.1.object)
        pending.sort { $0.index < $1.index }
        var outputIndex = Int(first.1.objectIndex)
        while !pending.isEmpty {
            // InsertObjectAtIndexは失敗時にもobjectを解放するため、呼出前に手元の所有権を外す。
            let item = pending.removeFirst()
            guard api.insertPageObject(page, item.object, outputIndex) != 0 else {
                throw PDFInternalTextEditError.failed("集約した文字objectを挿入できませんでした。")
            }
            outputIndex += 1
        }
    }

    /// 選択外の文字を実originへ独立配置する。字間調整・Tc/Twを再推定しない。
    private static func reconstructTextObject(
        edit: ReplacementEdit,
        match: Match,
        document: PDFiumHandle,
        page: PDFiumHandle,
        api: PDFiumAPI
    ) throws -> PDFiumHandle? {
        guard let sourceFont = api.textObjectFont(match.object) else {
            throw PDFInternalTextEditError.unsupported("元のPDF fontを保持できません。")
        }
        var pending: [(object: PDFiumHandle, before: Bool)] = []
        defer { pending.forEach { api.destroyPageObject($0.object) } }
        for glyph in match.retainedGlyphs {
            let object = try createPositionedObject(
                document: document, font: sourceFont, size: edit.sourceFontSize,
                codes: [glyph.code], origin: glyph.origin, color: match.fillColor, api: api
            )
            pending.append((object, glyph.beforeSelection))
        }
        var replacementFont: PDFiumHandle?
        var completed = false
        defer { if !completed, let replacementFont { api.closeFont(replacementFont) } }
        let hasReplacement = !edit.replacement.isEmpty
        if !hasReplacement {
            guard api.removePageObject(page, match.object) != 0 else {
                throw PDFInternalTextEditError.failed("削除対象objectを外せませんでした。")
            }
            api.destroyPageObject(match.object)
        } else if let fontData = match.fontEvidence.replacementFontData {
            replacementFont = try replaceTextObject(edit: edit, match: match, fontData: fontData, document: document, page: page, api: api)
        } else {
            let codes = match.fontEvidence.replacementCharcodes ?? match.fontEvidence.replacementGlyphs
            let object = try createPositionedObject(
                document: document, font: sourceFont, size: edit.sourceFontSize,
                codes: codes, origin: match.sourceOrigin, color: match.fillColor, api: api
            )
            guard api.removePageObject(page, match.object) != 0 else {
                api.destroyPageObject(object)
                throw PDFInternalTextEditError.failed("元のtext objectを外せませんでした。")
            }
            api.destroyPageObject(match.object)
            guard api.insertPageObject(page, object, Int(match.objectIndex)) != 0 else {
                throw PDFInternalTextEditError.failed("置換文字objectを挿入できませんでした。")
            }
        }
        var position = Int(match.objectIndex)
        // before → replacement → after のcontent順を維持する。
        while !pending.isEmpty {
            // 失敗時もPDFiumへ所有権が移る（pendingに残すと二重解放になる）。
            let item = pending.removeFirst()
            if hasReplacement && !item.before && position == Int(match.objectIndex) + match.retainedGlyphs.filter(\.beforeSelection).count {
                position += 1
            }
            guard api.insertPageObject(page, item.object, position) != 0 else {
                throw PDFInternalTextEditError.failed("未選択文字objectを挿入できませんでした。")
            }
            position += 1
        }
        completed = true
        return replacementFont
    }

    private static func createPositionedObject(
        document: PDFiumHandle, font: PDFiumHandle, size: CGFloat,
        codes: [UInt32], origin: CGPoint, color: ObjectColor, api: PDFiumAPI
    ) throws -> PDFiumHandle {
        guard !codes.isEmpty, let object = api.createTextObject(document, font, Float(size)) else {
            throw PDFInternalTextEditError.failed("文字objectを再構成できませんでした。")
        }
        var success = false
        defer { if !success { api.destroyPageObject(object) } }
        var matrix = PDFiumMatrix(a: 1, d: 1, e: Float(origin.x), f: Float(origin.y))
        let didSet = codes.withUnsafeBufferPointer { api.setCharcodes(object, $0.baseAddress, $0.count) }
        guard didSet != 0,
              withUnsafePointer(to: &matrix, { api.setPageObjectMatrix(object, UnsafeRawPointer($0)) }) != 0,
              api.setPageObjectFillColor(object, color.red, color.green, color.blue, color.alpha) != 0 else {
            throw PDFInternalTextEditError.failed("再構成文字のcode・origin・色を設定できませんでした。")
        }
        success = true
        return object
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
        guard Set(edits.map(\.id)).count == edits.count else {
            throw PDFInternalTextEditError.unsupported("同じ編集が重複しています。")
        }
    }

    /// UI上の選択は一つのまま、原文除去だけを元indexのshowごとへ分割する。
    /// 通常置換は単一objectのまま扱い、複数showの新文字はplannerの前景描画へ渡す。
    private static func expandedSourceRemovals(
        _ edits: [ReplacementEdit], sourcePDF: PDFDocument
    ) throws -> [ReplacementEdit] {
        var indexes: [Int: PageTextIndex] = [:]
        return try edits.flatMap { edit -> [ReplacementEdit] in
            guard edit.replacement.isEmpty, !edit.sourceIsPlainTextObject else { return [edit] }
            guard edit.kind == .replacement, edit.destinationOrigin == nil, !edit.composesLineEdits,
                  edit.lineReplacements.count <= 1, !edit.sourceSelectionIsAmbiguous,
                  edit.hasExplicitSourceMapping, let key = edit.sourceFontKey,
                  let page = sourcePDF.page(at: edit.pageIndex),
                  let color = edit.fontColor.usingColorSpace(.deviceRGB) else {
                throw PDFInternalTextEditError.unsupported("複数showの削除対象を一意に照合できません。")
            }
            let scalars = Array(edit.sourceText.unicodeScalars)
            guard !scalars.isEmpty, scalars.count == edit.sourceGlyphBounds.count else {
                throw PDFInternalTextEditError.unsupported("複数showの元文字とbboxの対応がありません。")
            }
            let index: PageTextIndex
            if let cached = indexes[edit.pageIndex] { index = cached }
            else {
                index = PDFGlyphIndex.makeIndex(for: page)
                indexes[edit.pageIndex] = index
            }
            let glyphs = index.runs.flatMap(\.glyphs).filter(\.isVisible)
            var selected: [ScannedGlyph] = []
            var orders = Set<Int>()
            for (scalar, box) in zip(scalars, edit.sourceGlyphBounds) {
                let candidates = glyphs.filter {
                    $0.fontKey == key && $0.advanceBox.approximatelyEquals(box, tolerance: 0.001)
                }
                guard candidates.count == 1, let glyph = candidates.first,
                      glyph.text == String(scalar), glyph.hasExplicitToUnicodeMapping,
                      glyph.sourceCharacterCode != nil, glyph.showOperationID >= 0,
                      glyph.showOperator != .unknown, glyph.textRenderingMode == 0,
                      !glyph.isInsideForm, !glyph.isInsideMarkedContent, !glyph.isClipped,
                      abs(glyph.fontSize - edit.sourceFontSize) <= 0.01,
                      abs(glyph.baseline - edit.baseline) <= 0.01,
                      let glyphColor = glyph.fillColor.usingColorSpace(.deviceRGB),
                      abs(glyphColor.redComponent - color.redComponent) <= 0.01,
                      abs(glyphColor.greenComponent - color.greenComponent) <= 0.01,
                      abs(glyphColor.blueComponent - color.blueComponent) <= 0.01,
                      abs(glyphColor.alphaComponent - color.alphaComponent) <= 0.01,
                      orders.insert(glyph.paintOrder).inserted else {
                    throw PDFInternalTextEditError.unsupported("複数showの元文字・位置・font・styleが一致しません。")
                }
                selected.append(glyph)
            }
            guard !glyphs.contains(where: { glyph in
                !orders.contains(glyph.paintOrder)
                    && selected.contains(where: { $0.advanceBox.intersects(glyph.advanceBox) })
            }) else {
                throw PDFInternalTextEditError.unsupported("複数showの選択位置に別の可視文字が重なっています。")
            }
            let byOperation = Dictionary(grouping: glyphs, by: \.showOperationID)
            var groups: [[ScannedGlyph]] = []
            for glyph in selected {
                if let last = groups.last?.last,
                   last.showOperationID == glyph.showOperationID,
                   let operationGlyphs = byOperation[glyph.showOperationID]?.sorted(by: { $0.paintOrder < $1.paintOrder }),
                   let previous = operationGlyphs.firstIndex(where: { $0.paintOrder == last.paintOrder }),
                   previous + 1 < operationGlyphs.count,
                   operationGlyphs[previous + 1].paintOrder == glyph.paintOrder {
                    groups[groups.count - 1].append(glyph)
                } else { groups.append([glyph]) }
            }
            return groups.enumerated().map { position, group in
                let first = group[0]
                let bounds = group.dropFirst().reduce(first.advanceBox) { $0.union($1.advanceBox) }
                let target = TextTarget(
                    pageIndex: edit.pageIndex, bounds: bounds, baseline: first.baseline,
                    originalText: group.map(\.text).joined(), fontSize: first.fontSize,
                    fontColor: first.fillColor, fontKey: first.fontKey, fontIsExact: edit.sourceFontIsExact,
                    coverBounds: bounds, maxWidth: bounds.width,
                    hasExplicitSourceMapping: true,
                    fontPostScriptNameOverride: edit.fontPostScriptNameOverride,
                    nearbyTextBounds: edit.sourceNearbyTextBounds,
                    sourceGlyphBounds: group.map(\.advanceBox),
                    sourceSelectionIsAmbiguous: false, sourceIsPlainTextObject: true
                )
                var removal = ReplacementEdit(deleting: target, id: position == 0 ? edit.id : UUID())
                removal.storage = edit.storage
                return removal
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
        let sourceCodesByUnicode: [UInt32: UInt32]
        let sourceWidthsByUnicode: [UInt32: CGFloat]
        var rawCharacterSpacing: CGFloat = 0
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
        let retainedGlyphs: [RetainedGlyph]
        let requiresReconstruction: Bool
        let sourceFontName: String
        let selectedCharacterIndices: Set<Int32>
        let replacementAdvances: [CGFloat]
    }

    private struct RetainedGlyph {
        let unicode: UInt32
        let code: UInt32
        let origin: CGPoint
        let beforeSelection: Bool
        let sourceIndex: Int32
        let declaredWidth: CGFloat
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
        let rawCharacterSpacing: CGFloat
        if let firstBox = edit.sourceGlyphBounds.first,
           let first = PDFGlyphIndex.makeIndex(for: page).runs.flatMap(\.glyphs).first(where: {
               $0.fontKey == fontKey && abs($0.advanceBox.minX - firstBox.minX) <= 0.001
                   && abs($0.advanceBox.minY - firstBox.minY) <= 0.001
           }), let code = first.sourceCharacterCode {
            rawCharacterSpacing = first.advance - info.width(for: code) * edit.sourceFontSize
        } else { rawCharacterSpacing = 0 }
        let description = PDFEmbeddedFontLoader.describe(fontDict: fontDictionary)
        // 同じUnicodeへ複数codeが写るfontは逆引きで元glyphを推測しない。
        let codeGroups = Dictionary(grouping: info.toUnicode.filter { $0.value.unicodeScalars.count == 1 }, by: { $0.value })
        var sourceCodesByUnicode: [UInt32: UInt32] = [:]
        var sourceWidthsByUnicode: [UInt32: CGFloat] = [:]
        for (text, entries) in codeGroups where entries.count == 1 {
            guard let entry = entries.first, let scalar = text.unicodeScalars.first,
                  info.explicitToUnicodeCodes.contains(entry.key), entry.key >= 0 else { continue }
            sourceCodesByUnicode[scalar.value] = UInt32(entry.key)
            sourceWidthsByUnicode[scalar.value] = info.width(for: entry.key) * edit.sourceFontSize
        }

        if description.hasEmbeddedProgram {
            if edit.replacement.isEmpty {
                // 削除と選択外glyphの保持には、元PDF fontの一意なcharcodeを使う。
                // CFFをCoreTextのGIDへ再解釈せず、後段でPDFiumの実path/widthと照合する。
                let scalars = Array(edit.sourceText.unicodeScalars)
                let codes = scalars.compactMap { sourceCodesByUnicode[$0.value] }
                let widths = scalars.compactMap { sourceWidthsByUnicode[$0.value] }
                guard !scalars.isEmpty, codes.count == scalars.count, widths.count == scalars.count else {
                    throw PDFInternalTextEditError.unsupported("削除対象の一意な明示ToUnicode charcodeを取得できません。")
                }
                return SourceFontEvidence(
                    isEmbedded: true, replacementCharcodes: [], replacementFontData: nil,
                    replacementTrueTypeGlyphs: nil, sourceGlyphs: scalars.map(\.value), replacementGlyphs: [],
                    savedReplacementGlyphs: [], sourceDeclaredWidths: widths,
                    replacementDeclaredWidths: [], sourceCodesByUnicode: sourceCodesByUnicode,
                    sourceWidthsByUnicode: sourceWidthsByUnicode, rawCharacterSpacing: rawCharacterSpacing
                )
            }
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
            if replacementCharacters.isEmpty {
                replacementExact = []
                replacementFontData = nil
            } else if replacementHasExplicitCodes {
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
                // FPDFFont_GetGlyphPath/WidthはUnicodeからfont内charcodeへ逆引きする。
                // SetCharcodesの実code、CoreTextのGID証明とは別に保持する。
                sourceGlyphs: edit.sourceText.unicodeScalars.map(\.value),
                replacementGlyphs: replacementHasExplicitCodes ? edit.replacement.unicodeScalars.map(\.value) : [],
                savedReplacementGlyphs: edit.replacement.unicodeScalars.map(\.value),
                sourceDeclaredWidths: sourceExact.map { $0.emWidth * edit.sourceFontSize },
                replacementDeclaredWidths: replacementExact.map { $0.emWidth * edit.sourceFontSize },
                sourceCodesByUnicode: sourceCodesByUnicode,
                sourceWidthsByUnicode: sourceWidthsByUnicode, rawCharacterSpacing: rawCharacterSpacing
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
              sourceScalars.allSatisfy({
                  ((edit.replacement.isEmpty ? 0x20 : 0x21)...0x7E).contains($0.value)
              }),
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
            replacementDeclaredWidths: widths(for: replacementScalars),
            sourceCodesByUnicode: sourceCodesByUnicode,
            sourceWidthsByUnicode: sourceWidthsByUnicode, rawCharacterSpacing: rawCharacterSpacing
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
        return try matchByLoadingPage(
            edit: edit,
            fontEvidence: fontEvidence,
            document: document,
            api: api
        )
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
            throw PDFInternalTextEditError.unsupported("複数show・Form・marked content・clipは対象外です。")
        }
        guard edit.hasExplicitSourceMapping else {
            throw PDFInternalTextEditError.unsupported("選択文字の明示ToUnicodeがありません。")
        }
        let sourceScalars = Array(edit.sourceText.unicodeScalars)
        guard !sourceScalars.isEmpty,
              sourceScalars.count == edit.sourceGlyphBounds.count else {
            throw PDFInternalTextEditError.unsupported("元文字の文字単位bboxを一意に照合できません。")
        }
        guard edit.sourceText != edit.replacement else {
            throw PDFInternalTextEditError.unsupported("元文字と置換文字が同一です。")
        }
        guard edit.outputFontSelection == .automatic,
              abs(edit.fontSize - edit.sourceFontSize) <= 0.01 else {
            throw PDFInternalTextEditError.unsupported("書体または文字サイズを変更した編集です。")
        }
        guard api.pageHasTransparency(page) == 0 else {
            throw PDFInternalTextEditError.unsupported("透明効果を含むページは対象外です。")
        }

        let charCount = api.textCountChars(textPage)
        guard charCount > 0 else { throw PDFInternalTextEditError.unsupported("文字を抽出できません。") }
        let indicesByObject = api.characterIndicesByObject(textPage)

        var candidates: [Match] = []
        let objectCount = api.pageObjectCount(page)
        guard objectCount >= 0 else { throw PDFInternalTextEditError.unsupported("page objectを列挙できません。") }
        for objectIndex in 0..<objectCount {
            guard let object = api.pageObject(page, objectIndex) else {
                throw PDFInternalTextEditError.unsupported("page objectを取得できません。")
            }
            guard api.pageObjectType(object) == 1 else { continue }
            guard let charIndices = indicesByObject[UInt(bitPattern: object)],
                  charIndices.count >= sourceScalars.count else { continue }
            for start in 0...(charIndices.count - sourceScalars.count) {
                let selection = Array(charIndices[start..<(start + sourceScalars.count)])
                guard zip(selection, sourceScalars).allSatisfy({ api.textUnicode(textPage, $0.0) == $0.1.value }) else { continue }
                if let match = try objectMatch(
                object: object,
                objectIndex: objectIndex,
                charIndices: selection,
                allCharIndices: charIndices,
                sourceScalars: sourceScalars,
                fontEvidence: fontEvidence,
                edit: edit,
                textPage: textPage,
                api: api
            ) {
                    candidates.append(match)
                }
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
        allCharIndices: [Int32],
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
        guard hasMatrix != 0, matrix.a.isFinite, matrix.a > 0,
              abs(matrix.a - matrix.d) <= 0.0001,
              abs(matrix.b) <= 0.0001, abs(matrix.c) <= 0.0001 else {
            return reject("matrix=\(matrix)")
        }
        var objectFontSize: Float = 0
        guard api.textObjectFontSize(object, &objectFontSize) != 0,
              objectFontSize > 0,
              abs(CGFloat(objectFontSize * matrix.a) - edit.sourceFontSize) <= 0.05,
              let font = api.textObjectFont(object),
              (api.fontIsEmbedded(font) != 0) == fontEvidence.isEmbedded else {
            return reject("font sizeまたは埋込状態: object=\(objectFontSize), source=\(edit.sourceFontSize)")
        }
        let effectiveFontSize = objectFontSize * matrix.a

        let sourceColor = edit.fontColor.usingColorSpace(.deviceRGB)
        for (offset, charIndex) in charIndices.enumerated() {
            guard api.textIsGenerated(textPage, charIndex) == 0,
                  api.textHasUnicodeMapError(textPage, charIndex) == 0,
                  api.textUnicode(textPage, charIndex) == sourceScalars[offset].value,
                  abs(api.effectiveCharacterFontSize(textPage, index: charIndex) - Double(edit.sourceFontSize)) <= 0.05,
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

        guard fontEvidence.sourceGlyphs.count == sourceScalars.count,
              fontEvidence.sourceDeclaredWidths.count == sourceScalars.count else { return nil }
        var sourceWidth: CGFloat = 0
        for offset in sourceScalars.indices {
            guard let width = provenGlyphWidth(
                glyphs: [fontEvidence.sourceGlyphs[offset]],
                declaredWidths: [fontEvidence.sourceDeclaredWidths[offset]],
                font: font, fontSize: effectiveFontSize, api: api,
                allowEmptyPath: isBlankUnicode(sourceScalars[offset].value)
            ) else { return reject("元glyphのpath・幅を証明できません") }
            sourceWidth += width
        }
        let replacementWidth: CGFloat
        let replacementAdvances: [CGFloat]
        if edit.replacement.isEmpty {
            replacementWidth = 0
            replacementAdvances = []
        } else if fontEvidence.replacementFontData != nil {
            guard !fontEvidence.replacementDeclaredWidths.isEmpty,
                  fontEvidence.replacementDeclaredWidths.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                return reject("同一書体の置換glyph幅を証明できません")
            }
            replacementWidth = fontEvidence.replacementDeclaredWidths.reduce(0, +)
            replacementAdvances = fontEvidence.replacementDeclaredWidths
        } else if let width = provenGlyphWidth(
            glyphs: fontEvidence.replacementGlyphs,
            declaredWidths: fontEvidence.replacementDeclaredWidths,
            font: font,
            fontSize: effectiveFontSize,
            api: api
        ) {
            replacementWidth = width
            replacementAdvances = fontEvidence.replacementGlyphs.map { glyph in
                var advance: Float = 0
                _ = api.fontGlyphWidth(font, glyph, effectiveFontSize, &advance)
                return CGFloat(advance)
            }
        } else {
            return reject("glyph path・幅を証明できないか、置換後の幅が元objectを超えます")
        }
        let selectedIndices = Set(charIndices)
        var retained: [RetainedGlyph] = []
        for index in allCharIndices where !selectedIndices.contains(index) {
            let unicode = api.textUnicode(textPage, index)
            guard api.textIsGenerated(textPage, index) == 0,
                  api.textHasUnicodeMapError(textPage, index) == 0,
                  let code = fontEvidence.sourceCodesByUnicode[unicode],
                  let width = fontEvidence.sourceWidthsByUnicode[unicode],
                  provenGlyphWidth(glyphs: [unicode], declaredWidths: [width], font: font, fontSize: effectiveFontSize, api: api, allowEmptyPath: isBlankUnicode(unicode)) != nil,
                  let origin = api.characterOrigin(textPage, index: index),
                  abs(api.textCharAngle(textPage, index)) <= 0.0001,
                  abs(api.effectiveCharacterFontSize(textPage, index: index) - Double(edit.sourceFontSize)) <= 0.05 else {
                return reject("未選択glyphの元charcode・幅・originを証明できません")
            }
            retained.append(RetainedGlyph(
                unicode: unicode, code: code, origin: origin,
                beforeSelection: index < charIndices[0], sourceIndex: index, declaredWidth: width
            ))
        }
        let actualSelectionWidth: CGFloat
        if let first = charIndices.first, let last = charIndices.last,
           let firstOrigin = api.characterOrigin(textPage, index: first),
           let lastOrigin = api.characterOrigin(textPage, index: last),
           let lastWidth = fontEvidence.sourceDeclaredWidths.last {
            actualSelectionWidth = lastOrigin.x + lastWidth - firstOrigin.x
        } else { return reject("選択範囲の実送り幅を取得できません") }
        let allowedWidth = min(sourceWidth, actualSelectionWidth)
        guard replacementWidth <= allowedWidth + max(0.1, CGFloat(effectiveFontSize) * 0.02) else {
            return reject("置換後の幅が元objectを超えます")
        }
        guard let firstIndex = charIndices.first,
              let sourceOrigin = api.characterOrigin(textPage, index: firstIndex),
              abs(sourceOrigin.x - edit.bounds.minX) <= max(0.75, edit.sourceFontSize * 0.08),
              abs(sourceOrigin.y - edit.baseline) <= max(0.75, edit.sourceFontSize * 0.08),
              let fillColor = api.objectColor(object, getter: api.pageObjectFillColor) else {
            return reject("文字原点・baselineを照合できません")
        }
        var expectedX = sourceOrigin.x
        var hasAdjustedOrigins = false
        for (index, width) in zip(charIndices, fontEvidence.sourceDeclaredWidths) {
            guard let origin = api.characterOrigin(textPage, index: index) else { return nil }
            if abs(origin.x - expectedX) > 0.02 { hasAdjustedOrigins = true }
            expectedX = origin.x + width
        }
        let reconstruct = !retained.isEmpty || hasAdjustedOrigins
        if reconstruct || fontEvidence.replacementFontData != nil {
            matrix = PDFiumMatrix(a: 1, d: 1, e: Float(sourceOrigin.x), f: Float(sourceOrigin.y))
        }
        return Match(
            object: object,
            objectIndex: objectIndex,
            fontEvidence: fontEvidence,
            sourceOrigin: sourceOrigin,
            sourceMatrix: matrix,
            fillColor: fillColor,
            sourceWidth: allowedWidth,
            replacementWidth: replacementWidth,
            retainedGlyphs: retained,
            requiresReconstruction: reconstruct,
            sourceFontName: api.baseFontName(font),
            selectedCharacterIndices: selectedIndices,
            replacementAdvances: replacementAdvances
        )
    }

    private static func provenGlyphWidth(
        glyphs: [UInt32],
        declaredWidths: [CGFloat],
        font: PDFiumHandle,
        fontSize: Float,
        api: PDFiumAPI,
        allowEmptyPath: Bool = false
    ) -> CGFloat? {
        guard !glyphs.isEmpty, glyphs.count == declaredWidths.count else { return nil }
        var total: CGFloat = 0
        for (glyph, declaredWidth) in zip(glyphs, declaredWidths) {
            var width: Float = 0
            let path = api.fontGlyphPath(font, glyph, fontSize)
            let gotWidth = api.fontGlyphWidth(font, glyph, fontSize, &width)
            guard (path != nil || allowEmptyPath),
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

    private static func isBlankUnicode(_ unicode: UInt32) -> Bool {
        unicode == 0x20 || unicode == 0xA0 || unicode == 0x3000
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
        requireObjectGeometry: Bool,
        preservesRetainedGrouping: Bool = false
    ) throws {
        guard let sourcePDF = PDFDocument(url: sourceURL), let outputPDF = PDFDocument(url: outputURL),
              sourcePDF.pageCount == outputPDF.pageCount else {
            throw PDFInternalTextEditError.failed("保存後のページ数が一致しません。")
        }
        let edits = try expandedSourceRemovals(edits.map { edit in
            guard !requireObjectGeometry, edit.storage.needsForeground else { return edit }
            var removal = edit.sourceRemoval()
            // 新しい前景の検証はplannerが行う。分割後もその役割を保持する。
            removal.storage = edit.storage
            return removal
        }, sourcePDF: sourcePDF)
        try validateEditSet(edits)
        let rawCandidate: Data? = !requireObjectGeometry && !preservesRetainedGrouping
            ? try PDFContentTextRemovalWriter.rewritingTextShows(
                sourceURL: sourceURL, sourcePDF: sourcePDF,
                edits: edits.map { $0.storage.needsForeground ? $0.sourceRemoval() : $0 }
            ) : nil
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
        do {
            let openedSource = try api.openDocument(sourceURL)
            sourceDocument = openedSource
            var matches: [UUID: Match] = [:]
            do {
                for edit in edits {
                    let proofEdit = !requireObjectGeometry && edit.storage.needsForeground ? edit.sourceRemoval() : edit
                    let evidence = try sourceFontEvidence(sourcePDF: sourcePDF, edit: proofEdit)
                    matches[edit.id] = try match(
                        edit: proofEdit,
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
        }
        defer { if let sourceDocument { api.closeDocument(sourceDocument) } }
        let usesRawTextShows = preservesRetainedGrouping || (rawCandidate != nil
            && Set(sourceMatches.values.map(\.objectIndex)).count == sourceMatches.count)

        for pageIndex in 0..<sourcePDF.pageCount {
            guard let page = api.loadPage(outputDocument, Int32(pageIndex)) else {
                throw PDFInternalTextEditError.failed("保存後の文字を再抽出できません。")
            }
            guard let textPage = api.loadTextPage(page) else {
                api.closePage(page)
                throw PDFInternalTextEditError.failed("保存後の文字を再抽出できません。")
            }
            defer { api.closeTextPage(textPage); api.closePage(page) }
            if !requireObjectGeometry {
                guard let sourceDocument else { throw PDFInternalTextEditError.failed("元文書を再読込できません。") }
                try verifyFinalCharacters(
                    pageIndex: pageIndex, sourceDocument: sourceDocument,
                    outputTextPage: textPage, edits: edits,
                    sourceMatches: sourceMatches, api: api, usesRawTextShows: usesRawTextShows,
                    outputPage: page, outputPDFPage: outputPDF.page(at: pageIndex)
                )
                continue
            }
            var outputTargetIndices = Set<Int32>()
            for edit in edits where edit.pageIndex == pageIndex {
                guard let sourceMatch = sourceMatches[edit.id] else {
                    throw PDFInternalTextEditError.failed("保存前の対象objectを再照合できません。")
                }
                outputTargetIndices.formUnion(try verifyEditedGeometry(
                    edit, sourceMatch: sourceMatch,
                    editedSourceIndices: Set(edits.filter { $0.pageIndex == pageIndex }.compactMap {
                        sourceMatches[$0.id]
                    }.filter { $0.objectIndex == sourceMatch.objectIndex }.flatMap(\.selectedCharacterIndices)),
                    page: page, textPage: textPage, pdfPage: outputPDF.page(at: pageIndex), api: api,
                    preservesRetainedGrouping: preservesRetainedGrouping
                ))
            }
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
                    for edit in edits where edit.pageIndex == pageIndex {
                        guard let sourceMatch = sourceMatches[edit.id] else {
                            throw PDFInternalTextEditError.failed("保存前の対象objectを再照合できません。")
                        }
                        sourceTargetIndices.insert(sourceMatch.objectIndex)
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
                    try verifyFinalCharacters(
                        pageIndex: pageIndex, sourceDocument: sourceDocument,
                        outputTextPage: textPage, edits: edits, sourceMatches: sourceMatches, api: api,
                        usesRawTextShows: usesRawTextShows,
                        outputPage: page, outputPDFPage: outputPDF.page(at: pageIndex)
                    )
                } catch {
                    throw error
                }
            }
        }
    }

    private struct CharacterSnapshot {
        let index: Int32
        let unicode: UInt32
        let origin: CGPoint
        let fontSize: Double
        let color: ObjectColor

        func matches(_ other: CharacterSnapshot) -> Bool {
            unicode == other.unicode
                && abs(origin.x - other.origin.x) <= 0.1
                && abs(origin.y - other.origin.y) <= 0.1
                && abs(fontSize - other.fontSize) <= 0.05
                && color == other.color
        }
    }

    private static func characterSnapshots(textPage: PDFiumHandle, api: PDFiumAPI) throws -> [CharacterSnapshot] {
        let count = api.textCountChars(textPage)
        guard count >= 0 else { throw PDFInternalTextEditError.failed("保存後の文字を列挙できません。") }
        return try (0..<count).compactMap { index in
            // PDFiumが字間や改行から生成した文字は実glyphと区別する。
            guard api.textIsGenerated(textPage, index) == 0 else { return nil }
            var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 0
            var matrix = PDFiumMatrix()
            guard let origin = api.characterOrigin(textPage, index: index),
                  withUnsafeMutablePointer(to: &matrix, {
                      api.textMatrix(textPage, index, UnsafeMutableRawPointer($0))
                  }) != 0,
                  api.textFillColor(textPage, index, &red, &green, &blue, &alpha) != 0 else {
                throw PDFInternalTextEditError.failed("保存後の文字原点・色を取得できません。")
            }
            return CharacterSnapshot(
                index: index, unicode: api.textUnicode(textPage, index), origin: origin,
                // Quartzは「1 Tf＋14倍Tm」のように同じ文字サイズを再符号化する。
                // 文字matrixにはFormの変換も含まれるため、実効サイズで比較する。
                fontSize: api.textFontSize(textPage, index) * Double(hypot(matrix.c, matrix.d)),
                color: ObjectColor(red: red, green: green, blue: blue, alpha: alpha)
            )
        }
    }

    /// Quartzの再符号化ではfont key・charcode・object分割が変わるため、
    /// 最終出力だけは文字そのものとページ上の位置・サイズ・色を比較する。
    private static func verifyFinalCharacters(
        pageIndex: Int, sourceDocument: PDFiumHandle, outputTextPage: PDFiumHandle,
        edits: [ReplacementEdit], sourceMatches: [UUID: Match], api: PDFiumAPI,
        usesRawTextShows: Bool = false,
        outputPage: PDFiumHandle, outputPDFPage: PDFPage?
    ) throws {
        guard let sourcePage = api.loadPage(sourceDocument, Int32(pageIndex)) else {
            throw PDFInternalTextEditError.failed("保存前の文字を開けません。")
        }
        defer { api.closePage(sourcePage) }
        guard let sourceTextPage = api.loadTextPage(sourcePage) else {
            throw PDFInternalTextEditError.failed("保存前の文字を抽出できません。")
        }
        defer { api.closeTextPage(sourceTextPage) }
        let pageEdits = edits.filter { $0.pageIndex == pageIndex }
        let selectedIndices = Set(pageEdits.compactMap { sourceMatches[$0.id] }.flatMap(\.selectedCharacterIndices))
        let source = try characterSnapshots(textPage: sourceTextPage, api: api)
        let output = try characterSnapshots(textPage: outputTextPage, api: api)
        let outputByUnicode = Dictionary(grouping: output, by: \.unicode)
        var consumed = Set<Int32>()
        for character in source where !selectedIndices.contains(character.index) {
            guard let saved = outputByUnicode[character.unicode]?.first(where: {
                !consumed.contains($0.index) && character.matches($0)
            }) else {
                // 独立space objectはPDFiumが抽出indexを省略する。この場合も、元の
                // 実code・Unicode・font・origin・size・色をcontentとobjectから証明する。
                if isBlankUnicode(character.unicode),
                   let match = pageEdits.compactMap({ sourceMatches[$0.id] }).first(where: {
                       $0.retainedGlyphs.contains { $0.sourceIndex == character.index }
                   }), let glyph = match.retainedGlyphs.first(where: { $0.sourceIndex == character.index }) {
                    _ = try verifyBlankGlyph(glyph, sourceMatch: match, pdfPage: outputPDFPage,
                                             page: outputPage, api: api)
                    continue
                }
                throw PDFInternalTextEditError.failed("最終出力で対象外文字のUnicode・origin・サイズ・色が変化しました。")
            }
            consumed.insert(saved.index)
        }
        for edit in pageEdits where !edit.storage.needsForeground {
            guard let match = sourceMatches[edit.id] else {
                throw PDFInternalTextEditError.failed("最終出力の対象文字を再照合できません。")
            }
            if edit.replacement.isEmpty {
                for character in source where match.selectedCharacterIndices.contains(character.index) {
                    guard output.allSatisfy({
                        abs($0.origin.x - character.origin.x) > 0.1 || abs($0.origin.y - character.origin.y) > 0.1
                    }) else {
                        throw PDFInternalTextEditError.failed("最終出力の削除対象位置に文字が残っています。")
                    }
                }
                continue
            }
            let scalars = Array(edit.replacement.unicodeScalars)
            guard scalars.count == match.replacementAdvances.count else {
                throw PDFInternalTextEditError.failed("最終出力の文字と送り幅を対応付けられません。")
            }
            var x = match.sourceOrigin.x
            for (scalar, advance) in zip(scalars, match.replacementAdvances) {
                let expected = CharacterSnapshot(
                    index: -1, unicode: scalar.value,
                    origin: CGPoint(x: x, y: match.sourceOrigin.y),
                    fontSize: Double(edit.sourceFontSize), color: match.fillColor
                )
                let candidates = outputByUnicode[scalar.value, default: []].filter {
                    !consumed.contains($0.index) && expected.matches($0)
                }
                guard candidates.count == 1, let saved = candidates.first else {
                    if ProcessInfo.processInfo.environment["PDFIUM_DIAGNOSTICS"] == "1" {
                        fputs("PDFium final expected=\(expected), candidates=\(outputByUnicode[scalar.value, default: []])\n", stderr)
                    }
                    throw PDFInternalTextEditError.failed("最終出力の置換文字をUnicode・origin・サイズ・色から一意に照合できません。")
                }
                consumed.insert(saved.index)
                x += advance + (usesRawTextShows ? match.fontEvidence.rawCharacterSpacing : 0)
            }
        }
    }

    private static func verifyEditedGeometry(
        _ edit: ReplacementEdit,
        sourceMatch: Match,
        editedSourceIndices: Set<Int32>,
        page: PDFiumHandle,
        textPage: PDFiumHandle,
        pdfPage: PDFPage?,
        api: PDFiumAPI,
        preservesRetainedGrouping: Bool = false
    ) throws -> Set<Int32> {
        let replacementScalars = Array(edit.replacement.unicodeScalars)
        let charCount = api.textCountChars(textPage)
        let objectCount = api.pageObjectCount(page)
        guard charCount >= 0, objectCount >= 0 else {
            throw PDFInternalTextEditError.failed("保存後の文字単位geometryを照合できません。")
        }
        let indicesByObject = api.characterIndicesByObject(textPage)
        var retainedIndices = Set<Int32>()
        var retainedCharacterIndices = Set<Int32>()
        let scannedGlyphs = preservesRetainedGrouping
            ? pdfPage.map { PDFGlyphIndex.makeIndex(for: $0).runs.flatMap(\.glyphs) } ?? [] : []
        for glyph in sourceMatch.retainedGlyphs where !editedSourceIndices.contains(glyph.sourceIndex) {
            if isBlankUnicode(glyph.unicode) && !preservesRetainedGrouping {
                let index = try verifyBlankGlyph(glyph, sourceMatch: sourceMatch, pdfPage: pdfPage, page: page, api: api)
                guard retainedIndices.insert(index).inserted else {
                    throw PDFInternalTextEditError.failed("未選択spaceのobjectが重複しています。")
                }
                continue
            }
            var matches: [(object: Int32, character: Int32)] = []
            for objectIndex in 0..<objectCount {
                guard let object = api.pageObject(page, objectIndex), api.pageObjectType(object) == 1,
                      let indices = indicesByObject[UInt(bitPattern: object)],
                      preservesRetainedGrouping || indices.count == 1 else { continue }
                for index in indices {
                guard api.textUnicode(textPage, index) == glyph.unicode,
                      let origin = api.characterOrigin(textPage, index: index),
                      abs(origin.x - glyph.origin.x) <= 0.02, abs(origin.y - glyph.origin.y) <= 0.02,
                      abs(api.effectiveCharacterFontSize(textPage, index: index) - Double(edit.sourceFontSize)) <= 0.02,
                      let font = api.textObjectFont(object),
                      api.baseFontName(font) == sourceMatch.sourceFontName,
                      provenGlyphWidth(glyphs: [glyph.unicode], declaredWidths: [glyph.declaredWidth], font: font, fontSize: Float(edit.sourceFontSize), api: api, allowEmptyPath: isBlankUnicode(glyph.unicode)) != nil,
                      api.objectColor(object, getter: api.pageObjectFillColor) == sourceMatch.fillColor else { continue }
                if preservesRetainedGrouping {
                    let scanned = scannedGlyphs.filter {
                        $0.sourceCharacterCode == Int(glyph.code) && $0.text.unicodeScalars.first?.value == glyph.unicode
                            && $0.fontKey == edit.sourceFontKey
                            && abs($0.advanceBox.minX - glyph.origin.x) <= 0.02
                            && abs($0.baseline - glyph.origin.y) <= 0.02
                            && abs($0.fontSize - edit.sourceFontSize) <= 0.02
                    }
                    guard scanned.count == 1 else { continue }
                }
                matches.append((objectIndex, index))
                }
            }
            guard matches.count == 1, let match = matches.first,
                  retainedCharacterIndices.insert(match.character).inserted,
                  preservesRetainedGrouping || !retainedIndices.contains(match.object) else {
                throw PDFInternalTextEditError.failed("再構成した未選択文字のUnicode・origin・font・サイズ・色が一致しません。")
            }
            retainedIndices.insert(match.object)
        }
        if preservesRetainedGrouping && replacementScalars.isEmpty {
            for objectIndex in retainedIndices {
                guard let object = api.pageObject(page, objectIndex),
                      let indices = indicesByObject[UInt(bitPattern: object)],
                      Set(indices).isSubset(of: retainedCharacterIndices) else {
                    throw PDFInternalTextEditError.failed("保持したprefix objectに未照合の文字が残っています。")
                }
            }
        }
        if replacementScalars.isEmpty {
            // 削除対象と同じ位置に実glyphが残っていないことも確認する。
            for index in 0..<charCount {
                guard let object = api.textObjectForCharacter(textPage, index),
                      let objectIndex = (0..<objectCount).first(where: { api.pageObject(page, $0) == object }),
                      !retainedIndices.contains(objectIndex),
                      api.textIsGenerated(textPage, index) == 0,
                      let origin = api.characterOrigin(textPage, index: index) else { continue }
                if abs(origin.y - sourceMatch.sourceOrigin.y) <= 0.1,
                   origin.x >= sourceMatch.sourceOrigin.x - 0.02,
                   origin.x < sourceMatch.sourceOrigin.x + sourceMatch.sourceWidth - 0.02 {
                    throw PDFInternalTextEditError.failed("削除対象位置に文字glyphが残っています。")
                }
            }
            return retainedIndices
        }
        var candidates: [(index: Int32, object: PDFiumHandle, indices: [Int32])] = []
        for objectIndex in 0..<objectCount {
            guard let object = api.pageObject(page, objectIndex), api.pageObjectType(object) == 1,
                  let indices = indicesByObject[UInt(bitPattern: object)],
                  indices.count >= replacementScalars.count,
                  preservesRetainedGrouping || indices.count == replacementScalars.count else { continue }
            for start in 0...(indices.count - replacementScalars.count) {
            let selected = Array(indices[start..<(start + replacementScalars.count)])
            guard api.unicodeText(textPage, indices: selected) == edit.replacement,
                  let firstIndex = selected.first,
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
            candidates.append((objectIndex, object, selected))
            }
        }
        guard candidates.count == 1, let saved = candidates.first else {
            throw PDFInternalTextEditError.failed("保存後の対象文字objectをorigin・baselineから一意に再特定できません。")
        }
        let object = saved.object
        let indices = saved.indices
        if preservesRetainedGrouping {
            let allowed = retainedCharacterIndices.union(indices)
            for index in retainedIndices.union([saved.index]) {
                guard let object = api.pageObject(page, index),
                      let objectIndices = indicesByObject[UInt(bitPattern: object)],
                      Set(objectIndices).isSubset(of: allowed) else {
                    throw PDFInternalTextEditError.failed("局所置換したobjectに未照合の文字が残っています。")
                }
            }
        }
        for (offset, index) in indices.enumerated() {
            let expectedX = sourceMatch.sourceOrigin.x + sourceMatch.replacementAdvances.prefix(offset).reduce(0, +)
                + (preservesRetainedGrouping ? CGFloat(offset) * sourceMatch.fontEvidence.rawCharacterSpacing : 0)
            guard api.textUnicode(textPage, index) == replacementScalars[offset].value,
                  abs(api.effectiveCharacterFontSize(textPage, index: index) - Double(edit.sourceFontSize)) <= 0.05,
                  let origin = api.characterOrigin(textPage, index: index),
                  abs(origin.x - expectedX) <= 0.1,
                  abs(origin.y - sourceMatch.sourceOrigin.y) <= 0.1,
                  api.objectColor(object, getter: api.pageObjectFillColor) == sourceMatch.fillColor else {
                throw PDFInternalTextEditError.failed("保存後の文字サイズ・位置を維持できませんでした。")
            }
            if preservesRetainedGrouping {
                let code = sourceMatch.fontEvidence.replacementCharcodes?[offset] ?? replacementScalars[offset].value
                let scanned = scannedGlyphs.filter {
                    $0.sourceCharacterCode == Int(code) && $0.text == String(replacementScalars[offset])
                        && $0.fontKey == edit.sourceFontKey
                        && abs($0.advanceBox.minX - expectedX) <= 0.1
                        && abs($0.baseline - sourceMatch.sourceOrigin.y) <= 0.1
                }
                guard scanned.count == 1 else {
                    throw PDFInternalTextEditError.failed("局所置換した実charcode・Unicode・originが一致しません。")
                }
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
                  glyphs.count == replacementScalars.count,
                  replacementScalars.allSatisfy({ api.fontGlyphPath(font, $0.value, Float(edit.sourceFontSize)) != nil }) else {
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
        retainedIndices.insert(saved.index)
        return retainedIndices
    }

    /// spaceだけのobjectにはPDFiumが抽出indexを割り当てないことがある。
    /// この場合もcontentの明示code/Unicodeとobjectのfont/matrix/色を検証する。
    private static func verifyBlankGlyph(
        _ glyph: RetainedGlyph, sourceMatch: Match, pdfPage: PDFPage?,
        page: PDFiumHandle, api: PDFiumAPI
    ) throws -> Int32 {
        guard let pdfPage else { throw PDFInternalTextEditError.failed("未選択spaceを再走査できません。") }
        let scannedGlyphs: [ScannedGlyph] = PDFGlyphIndex.makeIndex(for: pdfPage).runs.flatMap(\.glyphs)
        let scanned: [ScannedGlyph] = scannedGlyphs.filter { scannedGlyph in
            guard scannedGlyph.sourceCharacterCode == Int(glyph.code),
                  scannedGlyph.text.unicodeScalars.count == 1,
                  scannedGlyph.text.unicodeScalars.first?.value == glyph.unicode else { return false }
            return abs(scannedGlyph.advanceBox.minX - glyph.origin.x) <= 0.02
                && abs(scannedGlyph.baseline - glyph.origin.y) <= 0.02
        }
        guard scanned.count == 1 else {
            throw PDFInternalTextEditError.failed("未選択spaceの元charcode・Unicode・originを再照合できません。")
        }
        var candidates: [Int32] = []
        for index in 0..<api.pageObjectCount(page) {
            guard let object = api.pageObject(page, index), api.pageObjectType(object) == 1,
                  let font = api.textObjectFont(object), api.baseFontName(font) == sourceMatch.sourceFontName,
                  api.objectColor(object, getter: api.pageObjectFillColor) == sourceMatch.fillColor else { continue }
            var matrix = PDFiumMatrix()
            var size: Float = 0
            guard withUnsafeMutablePointer(to: &matrix, { api.pageObjectMatrix(object, UnsafeMutableRawPointer($0)) }) != 0,
                  abs(CGFloat(matrix.e) - glyph.origin.x) <= 0.02,
                  abs(CGFloat(matrix.f) - glyph.origin.y) <= 0.02,
                  abs(matrix.a - 1) <= 0.0001, abs(matrix.d - 1) <= 0.0001,
                  abs(matrix.b) <= 0.0001, abs(matrix.c) <= 0.0001,
                  api.textObjectFontSize(object, &size) != 0,
                  abs(CGFloat(size) - scanned[0].fontSize) <= 0.02,
                  provenGlyphWidth(glyphs: [glyph.unicode], declaredWidths: [glyph.declaredWidth], font: font, fontSize: size, api: api, allowEmptyPath: true) != nil else { continue }
            candidates.append(index)
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw PDFInternalTextEditError.failed("未選択spaceのfont・matrix・サイズ・色を再照合できません。")
        }
        return candidate
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
        let fontName: String?
        let fontSize: Float?

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
                && fontName == other.fontName
                && fontSize == other.fontSize
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
        let indicesByObject = api.characterIndicesByObject(textPage)
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
            var fontSize: Float = 0
            let isText = api.pageObjectType(object) == 1
            let hasFontSize = isText && api.textObjectFontSize(object, &fontSize) != 0
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
                text: isText ? api.unicodeText(textPage, indices: indicesByObject[UInt(bitPattern: object), default: []]) : nil,
                fontName: isText ? api.textObjectFont(object).map(api.baseFontName) : nil,
                fontSize: hasFontSize ? fontSize : nil
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
    let textMatrix: @convention(c) (PDFiumHandle?, Int32, UnsafeMutableRawPointer?) -> Int32
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
        textMatrix = try Self.symbol(handle, "FPDFText_GetMatrix")
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

    func characterIndicesByObject(_ textPage: PDFiumHandle) -> [UInt: [Int32]] {
        let count = textCountChars(textPage)
        guard count > 0 else { return [:] }
        var result: [UInt: [Int32]] = [:]
        for index in 0..<count {
            guard textIsGenerated(textPage, index) == 0,
                  let object = textObjectForCharacter(textPage, index) else { continue }
            result[UInt(bitPattern: object), default: []].append(index)
        }
        return result
    }

    func unicodeText(_ textPage: PDFiumHandle, indices: [Int32]) -> String {
        String(String.UnicodeScalarView(indices.compactMap { Unicode.Scalar(textUnicode(textPage, $0)) }))
    }

    func characterOrigin(_ textPage: PDFiumHandle, index: Int32) -> CGPoint? {
        var x: Double = 0
        var y: Double = 0
        guard textCharOrigin(textPage, index, &x, &y) != 0, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    func effectiveCharacterFontSize(_ textPage: PDFiumHandle, index: Int32) -> Double {
        var matrix = PDFiumMatrix()
        guard withUnsafeMutablePointer(to: &matrix, {
            textMatrix(textPage, index, UnsafeMutableRawPointer($0))
        }) != 0 else { return .nan }
        return textFontSize(textPage, index) * Double(hypot(matrix.c, matrix.d))
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
