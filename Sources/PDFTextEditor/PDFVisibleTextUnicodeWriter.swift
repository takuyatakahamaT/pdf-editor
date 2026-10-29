import Foundation
import PDFKit

/// Quartzが可視文字のToUnicodeを省略・誤符号化した場合にも、自分が描いた
/// CTRunから対応を確定する。不可視文字を重ねず、次回も同じ文字を編集できる。
enum PDFVisibleTextUnicodeWriter {
    static func addingMappings(in data: Data, edits: [ReplacementEdit]) throws -> Data {
        let foreground = edits.filter { $0.storage.needsForeground }
        guard !foreground.isEmpty else { return data }
        let pdf = try PDFObjectEditor(data: data)
        guard let document = PDFDocument(data: data) else { throw PDFExportError.unreadableSource }
        let pages = pdf.pageObjects()
        guard pages.count == document.pageCount else { throw PDFExportError.unreadableSource }
        var requiredFonts: Set<Int> = []
        var emitted: [Int: [Int: String]] = [:]
        var existing: [Int: [Int: String]] = [:]
        var fontReferences: [Int: [String: Int]] = [:]
        var indexes: [Int: PageTextIndex] = [:]
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let resourcesValue = pdf.inheritedValue(named: "Resources", in: pages[pageIndex].dictionary),
                  let resources = pdf.dictionaryValue(resourcesValue),
                  let fontsValue = pdf.value(named: "Font", in: resources),
                  let fonts = pdf.dictionaryValue(fontsValue) else { continue }
            let index = PDFGlyphIndex.makeIndex(for: page)
            indexes[pageIndex] = index
            for run in index.runs {
                guard let reference = pdf.value(named: run.fontKey, in: fonts),
                      let number = pdf.referenceNumber(in: reference),
                      let font = pdf.dictionary(for: number),
                      pdf.value(named: "Subtype", in: font) == "/Type0" else { continue }
                fontReferences[pageIndex, default: [:]][run.fontKey] = number
                if let dictionary = index.fontDictionaries[run.fontKey] {
                    existing[number] = PDFFontInfoLoader.load(from: dictionary).toUnicode
                }
            }
            for edit in foreground where edit.pageIndex == pageIndex {
                for expected in try PDFTextRenderer.emittedGlyphs(for: edit) {
                    let matches = index.runs.flatMap(\.glyphs).filter { glyph in
                        guard glyph.isVisible, !glyph.isInsideForm,
                              abs(glyph.advanceBox.minX - expected.origin.x) <= 0.05,
                              abs(glyph.baseline - expected.origin.y) <= 0.05,
                              abs(glyph.fontSize - expected.fontSize) <= 0.05,
                              let dictionary = index.fontDictionaries[glyph.fontKey] else { return false }
                        let description = PDFEmbeddedFontLoader.describe(fontDict: dictionary)
                        return description.pdfName.map { cleanFontName($0) == cleanFontName(expected.fontName) } == true
                    }
                    guard matches.count == 1, let glyph = matches.first else {
                        throw PDFInternalTextEditError.failed("保存した文字の描画位置を確認できませんでした。")
                    }
                    // 単純fontの正しいUnicodeは既存writerに任せ、CID fontだけを修復する。
                    guard let number = fontReferences[pageIndex]?[glyph.fontKey] else { continue }
                    guard let code = glyph.sourceCharacterCode else { throw PDFExportError.cannotCreateContext }
                    if let previous = emitted[number]?[code], previous != expected.text {
                        throw PDFInternalTextEditError.failed("保存した文字の対応が一意ではありません。")
                    }
                    requiredFonts.insert(number)
                    emitted[number, default: [:]][code] = expected.text
                }
            }
        }
        guard !requiredFonts.isEmpty else { return data }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-editor-unicode-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let evidence = try PDFInternalTextEditEngine.visibleUnicodeMappings(sourceURL: url)
        var mappings = existing
        var requiredCodes: [Int: Set<Int>] = [:]
        for (pageIndex, references) in fontReferences {
            for (key, number) in references where requiredFonts.contains(number) {
                let glyphs = indexes[pageIndex]?.runs.filter { $0.fontKey == key }.flatMap(\.glyphs) ?? []
                for glyph in glyphs {
                    guard let code = glyph.sourceCharacterCode, (0...0xFFFF).contains(code) else {
                        throw PDFInternalTextEditError.failed("保存した文字のコードを確認できませんでした。")
                    }
                    requiredCodes[number, default: []].insert(code)
                }
                for (code, text) in evidence[pageIndex]?[key] ?? [:] {
                    if mappings[number]?[code] == nil { mappings[number, default: [:]][code] = text }
                }
            }
        }
        for (number, codes) in emitted {
            // QuartzのCID CFFにはGIDをキーにした誤ったToUnicodeが付く場合もある。
            // 自分が描いたCTRunと一致した実codeの対応を優先し、他のcodeは保持する。
            mappings[number, default: [:]].merge(codes) { _, emitted in emitted }
        }
        var objects: [Int: String] = [:]
        var next = pdf.nextObjectNumber
        for number in requiredFonts.sorted() {
            guard let mapping = mappings[number], let codes = requiredCodes[number], !codes.isEmpty,
                  codes.isSubset(of: Set(mapping.keys)), let font = pdf.dictionary(for: number) else {
                throw PDFInternalTextEditError.failed("保存した文字のUnicodeを確認できませんでした。")
            }
            // 誤符号化された未使用GIDの別名を残すと逆引きが曖昧になる。
            // このfontで実際に使われているcodeを全て保存する。
            let entries = codes.sorted().map { code in
                let unicode = mapping[code]!.utf16.map { String(format: "%04X", $0) }.joined()
                return "<\(String(format: "%04X", code))> <\(unicode)>"
            }
            var groups: [String] = []
            for offset in stride(from: 0, to: entries.count, by: 100) {
                let chunk = entries[offset..<min(offset + 100, entries.count)]
                groups.append("\(chunk.count) beginbfchar\n\(chunk.joined(separator: "\n"))\nendbfchar")
            }
            let cmap = """
            /CIDInit /ProcSet findresource begin 12 dict begin begincmap
            /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            /CMapName /PDFEditorVisibleUnicode def /CMapType 2 def
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            \(groups.joined(separator: "\n"))
            endcmap CMapName currentdict /CMap defineresource pop end end
            """
            objects[next] = "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream"
            objects[number] = pdf.settingValue(named: "ToUnicode", in: font, with: "\(next) 0 R")
            next += 1
        }
        return try pdf.appending(objects: objects)
    }

    private static func cleanFontName(_ name: String) -> String {
        name.replacingOccurrences(of: "^[A-Z]{6}\\+", with: "", options: .regularExpression)
    }
}
