import Foundation
import PDFKit

/// PDFiumのcontent再生成がICCBased色を省略する場合にも、元の描画命令を保持する。
/// 1ページの既知stream列で、show末尾を削除し、直後にETがある場合だけ。
enum PDFContentTextRemovalWriter {
    private struct Token {
        let range: Range<Int>
        let word: String
        let bytes: [UInt8]?
    }

    private struct Removal {
        let originalCodes: [UInt8]
        let deletedByteCount: Int
        let replacementCodes: [UInt8]
    }

    static func rewritingTextShows(sourceURL: URL, sourcePDF: PDFDocument, edits: [ReplacementEdit]) throws -> Data? {
        guard sourcePDF.pageCount == 1, !edits.isEmpty,
              edits.allSatisfy({ $0.pageIndex == 0 }),
              let page = sourcePDF.page(at: 0), let cgPage = sourcePDF.documentRef?.page(at: 1),
              let pageDictionary = cgPage.dictionary else { return nil }
        let original = try Data(contentsOf: sourceURL)
        guard let pdf = try? PDFObjectEditor(data: original), pdf.pageObjects().count == 1,
              let pageObject = pdf.pageObjects().first,
              pageObject.dictionary.utf8.allSatisfy({ $0 < 128 }),
              let contents = pdf.value(named: "Contents", in: pageObject.dictionary) else { return nil }
        let referencePattern = #"\d+\s+0\s+R"#
        let referenceRegex = try NSRegularExpression(pattern: referencePattern)
        let referenceSource = contents as NSString
        let references = referenceRegex.matches(in: contents, range: NSRange(location: 0, length: referenceSource.length))
            .map { referenceSource.substring(with: $0.range) }
        let residue = contents.replacingOccurrences(of: referencePattern, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace && $0 != "[" && $0 != "]" }
        guard !references.isEmpty, residue.isEmpty else { return nil }
        var streams: [[UInt8]] = []
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(pageDictionary, "Contents", &array), let array {
            guard CGPDFArrayGetCount(array) == references.count else { return nil }
            for index in references.indices {
                var stream: CGPDFStreamRef?
                var format = CGPDFDataFormat.raw
                guard CGPDFArrayGetStream(array, index, &stream), let stream,
                      let decoded = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
                streams.append(Array(decoded))
            }
        } else {
            var stream: CGPDFStreamRef?
            var format = CGPDFDataFormat.raw
            guard references.count == 1, CGPDFDictionaryGetStream(pageDictionary, "Contents", &stream), let stream,
                  let decoded = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
            streams.append(Array(decoded))
        }
        var bytes: [UInt8] = []
        var streamRanges: [Range<Int>] = []
        for stream in streams {
            streamRanges.append(bytes.count..<(bytes.count + stream.count))
            bytes += stream
            bytes.append(10)
        }
        guard let tokens = tokenize(bytes) else { return nil }
        let glyphs = PDFGlyphIndex.makeIndex(for: page).runs.flatMap(\.glyphs)
        var requested: [Int: Removal] = [:]
        for edit in edits {
            guard let key = edit.sourceFontKey,
                  let dictionary = PDFGlyphIndex.fontDictionary(for: key, page: page) else { return nil }
            let selected = glyphs.filter { glyph in
                glyph.isVisible && glyph.fontKey == key && edit.sourceGlyphBounds.contains(where: {
                    abs($0.minX - glyph.advanceBox.minX) <= 0.001
                        && abs($0.minY - glyph.advanceBox.minY) <= 0.001
                        && abs($0.width - glyph.advanceBox.width) <= 0.001
                        && abs($0.height - glyph.advanceBox.height) <= 0.001
                })
            }.sorted { $0.paintOrder < $1.paintOrder }
            guard !selected.isEmpty, selected.count == edit.sourceGlyphBounds.count,
                  selected.allSatisfy({ !$0.isInsideForm && !$0.isInsideMarkedContent && !$0.isClipped }),
                  Set(selected.map(\.showOperationID)).count == 1,
                  let operation = selected.first?.showOperationID, operation >= 0,
                  requested[operation] == nil,
                  selected.map(\.text).joined() == edit.sourceText else { return nil }
            let wholeShow = glyphs.filter { $0.showOperationID == operation }.sorted { $0.paintOrder < $1.paintOrder }
            guard wholeShow.suffix(selected.count).map(\.paintOrder) == selected.map(\.paintOrder),
                  wholeShow.allSatisfy({ $0.fontKey == key && !$0.isInsideForm && !$0.isInsideMarkedContent && !$0.isClipped }) else { return nil }
            let fontInfo = PDFFontInfoLoader.load(from: dictionary)
            let width = fontInfo.bytesPerCode
            guard width == 1 || width == 2 else { return nil }
            var codes: [UInt8] = []
            for glyph in wholeShow {
                guard let code = glyph.sourceCharacterCode, code >= 0,
                      code <= (width == 1 ? 0xFF : 0xFFFF) else { return nil }
                if width == 2 { codes.append(UInt8(code >> 8)) }
                codes.append(UInt8(code & 0xFF))
            }
            let groups = Dictionary(grouping: fontInfo.toUnicode, by: \.value)
            var replacementCodes: [UInt8] = []
            for scalar in edit.replacement.unicodeScalars {
                guard let entries = groups[String(scalar)], entries.count == 1,
                      let code = entries.first?.key, fontInfo.explicitToUnicodeCodes.contains(code),
                      code >= 0, code <= (width == 1 ? 0xFF : 0xFFFF) else { return nil }
                if width == 2 { replacementCodes.append(UInt8(code >> 8)) }
                replacementCodes.append(UInt8(code & 0xFF))
            }
            requested[operation] = Removal(originalCodes: codes, deletedByteCount: selected.count * width,
                                           replacementCodes: replacementCodes)
        }

        var operation = 0
        var inText = false
        var hasIndependentMatrix = false
        var dictionaryDepth = 0
        var markedDepth = 0
        var replacements: [(range: Range<Int>, bytes: [UInt8])] = []
        var matchedOperations = Set<Int>()
        for (position, token) in tokens.enumerated() where token.bytes == nil {
            if token.word == "<<" { dictionaryDepth += 1; continue }
            if token.word == ">>" {
                guard dictionaryDepth > 0 else { return nil }
                dictionaryDepth -= 1
                continue
            }
            if dictionaryDepth > 0 { continue }
            switch token.word {
            case "Do":
                guard !inText, position >= 1, tokens[position - 1].word.hasPrefix("/"),
                      isImageOnlyXObject(named: String(tokens[position - 1].word.dropFirst()), page: cgPage) else { return nil }
            case "BI", "ID", "EI", "'", "\"": return nil
            case "BMC", "BDC": markedDepth += 1
            case "EMC":
                guard markedDepth > 0 else { return nil }
                markedDepth -= 1
            case "BT":
                guard !inText else { return nil }
                inText = true
                hasIndependentMatrix = false
            case "ET":
                guard inText else { return nil }
                inText = false
            case "Tm": hasIndependentMatrix = true
            case "Tj", "TJ":
                guard inText else { return nil }
                defer { operation += 1 }
                guard let expected = requested[operation] else { continue }
                // 空showは送りを消すため、同じtext matrixを後続文字が使わないことを要求する。
                guard markedDepth == 0, hasIndependentMatrix, position + 1 < tokens.count,
                      tokens[position + 1].word == "ET" else { return nil }
                let operands: [Token]
                if token.word == "Tj" {
                    guard position >= 1 else { return nil }
                    operands = [tokens[position - 1]]
                } else {
                    guard position >= 3, tokens[position - 1].word == "]",
                          let start = tokens[..<(position - 1)].lastIndex(where: { $0.word == "[" }) else { return nil }
                    let elements = tokens[(start + 1)..<(position - 1)]
                    guard elements.allSatisfy({ $0.bytes != nil || Double($0.word)?.isFinite == true }) else { return nil }
                    operands = elements.filter { $0.bytes != nil }
                }
                guard operands.allSatisfy({ $0.bytes != nil }),
                      operands.flatMap({ $0.bytes ?? [] }) == expected.originalCodes else { return nil }
                var remaining = expected.deletedByteCount
                for operand in operands.reversed() where remaining > 0 {
                    let original = operand.bytes ?? []
                    let removed = min(remaining, original.count)
                    var kept = Array(original.prefix(original.count - removed))
                    if removed == remaining { kept += expected.replacementCodes }
                    let replacement = "<" + kept.map { String(format: "%02X", $0) }.joined() + ">"
                    replacements.append((operand.range, Array(replacement.utf8)))
                    remaining -= removed
                }
                guard remaining == 0 else { return nil }
                matchedOperations.insert(operation)
            default: break
            }
        }
        guard !inText, dictionaryDepth == 0, markedDepth == 0,
              matchedOperations.count == requested.count else { return nil }
        // appendingはStringをUTF8で書く。非ASCII literalも元byte列のまま維持する。
        var objects: [Int: String] = [:]
        var rewrittenReferences = references
        for (index, range) in streamRanges.enumerated() {
            let local = replacements.filter { range.contains($0.range.lowerBound) && $0.range.upperBound <= range.upperBound }
            guard !local.isEmpty else { continue }
            var rewritten = streams[index]
            for replacement in local.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                let start = replacement.range.lowerBound - range.lowerBound
                let end = replacement.range.upperBound - range.lowerBound
                rewritten.replaceSubrange(start..<end, with: replacement.bytes)
            }
            let hex = rewritten.map { String(format: "%02X", $0) }.joined() + ">"
            let number = pdf.nextObjectNumber + objects.count
            objects[number] = "<< /Length \(hex.utf8.count) /Filter /ASCIIHexDecode >>\nstream\n\(hex)\nendstream"
            rewrittenReferences[index] = "\(number) 0 R"
        }
        guard replacements.allSatisfy({ replacement in streamRanges.contains { $0.contains(replacement.range.lowerBound) && replacement.range.upperBound <= $0.upperBound } }) else { return nil }
        let contentsValue = streams.count == 1 ? rewrittenReferences[0] : "[" + rewrittenReferences.joined(separator: " ") + "]"
        objects[pageObject.number] = pdf.settingValue(named: "Contents", in: pageObject.dictionary, with: contentsValue)
        return try pdf.appending(objects: objects)
    }

    private static func isImageOnlyXObject(named name: String, page: CGPDFPage) -> Bool {
        guard !name.contains("#") else { return false }
        var current = page.dictionary
        for _ in 0..<16 {
            guard let dictionary = current else { return false }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources {
                var objects: CGPDFDictionaryRef?
                var stream: CGPDFStreamRef?
                guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects,
                      CGPDFDictionaryGetStream(objects, name, &stream), let stream,
                      let object = CGPDFStreamGetDictionary(stream) else { return false }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(object, "Subtype", &subtype), let subtype else { return false }
                if String(cString: subtype) == "Image" { return true }
                guard String(cString: subtype) == "Form" else { return false }
                // 編集しない画像だけのFormはshow番号を増やさない。再帰Formや文字命令は
                // 対象の原codeとの対応を曖昧にするため、元byteを保持する場合も拒否する。
                var format = CGPDFDataFormat.raw
                var formResources: CGPDFDictionaryRef?
                var formObjects: CGPDFDictionaryRef?
                guard let data = CGPDFStreamCopyData(stream, &format) as Data?,
                      let tokens = tokenize(Array(data)),
                      CGPDFDictionaryGetDictionary(object, "Resources", &formResources), let formResources,
                      CGPDFDictionaryGetDictionary(formResources, "XObject", &formObjects), let formObjects else { return false }
                var hasImage = false
                for (index, token) in tokens.enumerated() where token.bytes == nil {
                    if ["BT", "ET", "Tj", "TJ", "'", "\"", "BI", "ID", "EI", "BMC", "BDC", "EMC", "<<", ">>"].contains(token.word) { return false }
                    if token.word == "Do" {
                        guard index > 0, tokens[index - 1].word.hasPrefix("/"),
                              !tokens[index - 1].word.contains("#") else { return false }
                        let imageName = String(tokens[index - 1].word.dropFirst())
                        var image: CGPDFStreamRef?
                        guard CGPDFDictionaryGetStream(formObjects, imageName, &image), let image,
                              let dictionary = CGPDFStreamGetDictionary(image) else { return false }
                        var kind: UnsafePointer<CChar>?
                        guard CGPDFDictionaryGetName(dictionary, "Subtype", &kind), let kind,
                              String(cString: kind) == "Image" else { return false }
                        hasImage = true
                    }
                }
                return hasImage
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent) else { return false }
            current = parent
        }
        return false
    }

    private static func tokenize(_ bytes: [UInt8]) -> [Token]? {
        func space(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(byte) }
        func delimiter(_ byte: UInt8) -> Bool { space(byte) || Array("()<>[]{}/%".utf8).contains(byte) }
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        var result: [Token] = []
        var position = 0
        while position < bytes.count {
            if space(bytes[position]) { position += 1; continue }
            if bytes[position] == 37 {
                while position < bytes.count && bytes[position] != 10 && bytes[position] != 13 { position += 1 }
                continue
            }
            let start = position
            let first = bytes[position]
            position += 1
            var value: [UInt8]?
            if first == 40 {
                var depth = 1
                var content: [UInt8] = []
                while position < bytes.count && depth > 0 {
                    var byte = bytes[position]; position += 1
                    if byte == 92 {
                        guard position < bytes.count else { return nil }
                        byte = bytes[position]; position += 1
                        if byte == 10 { continue }
                        if byte == 13 {
                            if position < bytes.count && bytes[position] == 10 { position += 1 }
                            continue
                        }
                        if (48...55).contains(byte) {
                            var octal = Int(byte - 48)
                            for _ in 0..<2 where position < bytes.count && (48...55).contains(bytes[position]) {
                                octal = octal * 8 + Int(bytes[position] - 48); position += 1
                            }
                            content.append(UInt8(octal & 0xFF)); continue
                        }
                        content.append([110: 10, 114: 13, 116: 9, 98: 8, 102: 12][byte] ?? byte)
                        continue
                    }
                    if byte == 40 { depth += 1 }
                    if byte == 41 { depth -= 1; if depth == 0 { break } }
                    // PDF literalの裸CR/CRLFはLFへ正規化する。
                    if byte == 13 {
                        if position < bytes.count && bytes[position] == 10 { position += 1 }
                        byte = 10
                    }
                    content.append(byte)
                }
                guard depth == 0 else { return nil }
                value = content
            } else if first == 60 {
                guard position < bytes.count else { return nil }
                if bytes[position] == 60 {
                    position += 1
                    result.append(Token(range: start..<position, word: "<<", bytes: nil))
                    continue
                }
                var nibbles: [UInt8] = []
                while position < bytes.count && bytes[position] != 62 {
                    let byte = bytes[position]; position += 1
                    if space(byte) { continue }
                    guard let nibble = hex(byte) else { return nil }
                    nibbles.append(nibble)
                }
                guard position < bytes.count else { return nil }
                position += 1
                if !nibbles.count.isMultiple(of: 2) { nibbles.append(0) }
                value = stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] * 16 + nibbles[$0 + 1] }
            } else if first == 62 {
                guard position < bytes.count, bytes[position] == 62 else { return nil }
                position += 1
            } else if first == 47 {
                while position < bytes.count && !delimiter(bytes[position]) { position += 1 }
            } else if !delimiter(first) {
                while position < bytes.count && !delimiter(bytes[position]) { position += 1 }
            } else if ![91, 93].contains(first) { return nil }
            result.append(Token(range: start..<position, word: String(decoding: bytes[start..<position], as: UTF8.self), bytes: value))
        }
        return result
    }
}
