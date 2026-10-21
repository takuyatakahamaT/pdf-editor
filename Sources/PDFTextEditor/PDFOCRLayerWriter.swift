import Foundation
import PDFKit

/// Adds OCR as a separate page content stream. The original Contents value (a stream
/// reference or an array of references) and page-level Resources value are recorded on
/// each changed page, so the layer can be removed without retaining a copy of the source PDF.
enum PDFOCRLayerWriter {
    private static let marker = "/PDFTextEditorOCRLayer 1"

    static func hasLayer(in data: Data) -> Bool {
        guard let pdf = try? PDFObjectEditor(data: data) else { return false }
        return pdf.pageObjects().contains { $0.dictionary.contains(marker) }
    }

    static func layeredPageIndexes(in data: Data) throws -> [Int] {
        let pdf = try PDFObjectEditor(data: data)
        return pdf.pageObjects().enumerated().compactMap { $0.element.dictionary.contains(marker) ? $0.offset : nil }
    }

    static func add(linesByPage: [Int: [PDFOCRLine]], to data: Data) throws -> Data {
        try add(linesByPage: linesByPage, to: data, allowPDFKitNormalization: true)
    }

    private static func add(
        linesByPage: [Int: [PDFOCRLine]],
        to data: Data,
        allowPDFKitNormalization: Bool
    ) throws -> Data {
        let pdf: PDFObjectEditor
        do {
            pdf = try PDFObjectEditor(data: data)
        } catch {
            // Incremental edits require a classic xref table. PDF 1.5+ cross-reference
            // streams cannot be patched by the small append-only writer below, so ask
            // PDFKit to rewrite the separate output copy into a classic-xref PDF first.
            guard allowPDFKitNormalization,
                  let document = PDFDocument(data: data), !document.isLocked,
                  let normalized = document.dataRepresentation(), normalized != data else {
                throw PDFOCRError.cannotSave
            }
            return try add(linesByPage: linesByPage, to: normalized, allowPDFKitNormalization: false)
        }
        let pages = pdf.pageObjects()
        let allCharacters = Array(Set(linesByPage.values.flatMap { $0.flatMap { $0.text.unicodeScalars } }))
            .sorted { $0.value < $1.value }
        guard !allCharacters.isEmpty, allCharacters.count < 65_535 else { throw PDFOCRError.cannotSave }
        let codes = Dictionary(uniqueKeysWithValues: allCharacters.enumerated().map { ($0.element.value, $0.offset + 1) })
        var next = pdf.nextObjectNumber
        let cmapNumber = next; next += 1
        var objects: [Int: String] = [:]
        let fontNames = Set(linesByPage.values.flatMap { $0.map { fontNameKey($0.fontPostScriptName) } })
        var fontNumbers: [String: Int] = [:]
        for fontName in fontNames.sorted() {
            let fontNumber = next; next += 1
            let cidNumber = next; next += 1
            let descriptorNumber = next; next += 1
            fontNumbers[fontName] = fontNumber
            objects[fontNumber] = "<< /Type /Font /Subtype /Type0 /BaseFont /PDFEditorOCR /Encoding /Identity-H /DescendantFonts [\(cidNumber) 0 R] /ToUnicode \(cmapNumber) 0 R >>"
            objects[cidNumber] = "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /PDFEditorOCR /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor \(descriptorNumber) 0 R /DW 1000 /CIDToGIDMap /Identity >>"
            objects[descriptorNumber] = "<< /Type /FontDescriptor /FontName /PDFEditorOCR /Flags 4 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>"
        }
        let cmap = makeToUnicode(characters: allCharacters)
        objects[cmapNumber] = stream(cmap)
        for (pageIndex, lines) in linesByPage.sorted(by: { $0.key < $1.key }) {
            guard pages.indices.contains(pageIndex), !lines.isEmpty else { continue }
            let page = pages[pageIndex]
            guard let contents = pdf.value(named: "Contents", in: page.dictionary) else {
                throw PDFOCRError.cannotSave
            }
            let resourcesDictionaryValue = pdf.value(named: "Resources", in: page.dictionary)
                ?? pdf.inheritedValue(named: "Resources", in: page.dictionary) ?? "<< >>"
            guard var resourcesDictionary = pdf.dictionaryValue(resourcesDictionaryValue) else {
                throw PDFOCRError.cannotSave
            }

            let originalResourcesValue = pdf.value(named: "Resources", in: page.dictionary)
            let originalResourcesMarker: String
            let originalResourcesWereDirect: Bool
            if let originalResourcesValue {
                if originalResourcesValue.hasPrefix("<<") {
                    let baseResourcesNumber = next; next += 1
                    objects[baseResourcesNumber] = originalResourcesValue
                    originalResourcesMarker = "\(baseResourcesNumber) 0 R"
                    originalResourcesWereDirect = true
                } else {
                    originalResourcesMarker = originalResourcesValue
                    originalResourcesWereDirect = false
                }
            } else {
                // A missing page-level key means Resources is inherited from /Pages, or
                // defaults to an empty dictionary. Removing OCR must restore that state.
                originalResourcesMarker = "null"
                originalResourcesWereDirect = false
            }

            var fontResourceNames: [String: String] = [:]
            for fontName in Set(lines.map { fontNameKey($0.fontPostScriptName) }).sorted() {
                guard let fontNumber = fontNumbers[fontName] else { throw PDFOCRError.cannotSave }
                var fontResourceName = "Focr"
                resourcesDictionary = try addFontReference(
                    fontNumber,
                    to: resourcesDictionary,
                    using: pdf,
                    objects: &objects,
                    nextObjectNumber: &next,
                    fontResourceName: &fontResourceName
                )
                fontResourceNames[fontName] = fontResourceName
            }
            let resourceNumber = next; next += 1
            let streamNumber = next; next += 1
            objects[resourceNumber] = resourcesDictionary
            let mediaBox = page.mediaBox
            let commands = lines.map { line -> String in
                let rect = CGRect(x: mediaBox.minX + line.bounds.minX * mediaBox.width,
                                  y: mediaBox.minY + line.bounds.minY * mediaBox.height,
                                  width: line.bounds.width * mediaBox.width,
                                  height: line.bounds.height * mediaBox.height)
                let fontHeight: CGFloat
                if let preservedFontSize = line.fontSize, preservedFontSize.isFinite, preservedFontSize > 0 {
                    fontHeight = preservedFontSize
                } else {
                    fontHeight = max(1, rect.height * 0.8)
                }
                let characters = Array(line.text.unicodeScalars)
                let encoded = characters.map { String(format: "%04X", codes[$0.value]!) }.joined()
                let advance = max(0.1, rect.width / CGFloat(max(1, characters.count)))
                let fontName = fontNameKey(line.fontPostScriptName)
                guard let fontResourceName = fontResourceNames[fontName] else { return "" }
                return "BT /\(fontResourceName) 1 Tf 3 Tr \(number(advance)) 0 0 \(number(fontHeight)) \(number(rect.minX)) \(number(rect.minY + rect.height * 0.12)) Tm <\(encoded)> Tj ET"
            }.joined(separator: "\n")
            objects[streamNumber] = stream("q\n\(commands)\nQ\n")
            var replacement = page.dictionary
            let existingContentStreams: String
            if contents.hasPrefix("["), contents.hasSuffix("]") {
                existingContentStreams = String(contents.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                existingContentStreams = contents
            }
            replacement = pdf.settingValue(named: "Contents", in: replacement,
                with: "[\(existingContentStreams) \(streamNumber) 0 R]")
            replacement = pdf.settingValue(named: "Resources", in: replacement,
                with: "\(resourceNumber) 0 R")
            let fontNameMap = fontResourceNames
                .filter { $0.key != defaultFontNameKey }
                .sorted { $0.value < $1.value }
                .map { "/\($0.value) /\(pdfNameToken($0.key))" }
                .joined(separator: " ")
            let fontNameMarker = fontNameMap.isEmpty ? "" : " /PDFTextEditorOCRFontNames [\(fontNameMap)]"
            replacement = replacement.replacingOccurrences(of: ">>", with:
                "\(marker) /PDFTextEditorOCRBaseContents \(contents) /PDFTextEditorOCRBaseResources \(originalResourcesMarker) "
                    + (originalResourcesWereDirect ? "/PDFTextEditorOCRBaseResourcesWasDirect true " : "")
                    + fontNameMarker + ">>",
                options: [], range: replacement.range(of: ">>", options: .backwards))
            objects[page.number] = replacement
        }
        return try pdf.appending(objects: objects)
    }

    static func removingLayer(from data: Data) throws -> Data {
        let pdf = try PDFObjectEditor(data: data)
        var objects: [Int: String] = [:]
        for page in pdf.pageObjects() where page.dictionary.contains(marker) {
            guard let contents = pdf.value(named: "PDFTextEditorOCRBaseContents", in: page.dictionary),
                  let resources = pdf.value(named: "PDFTextEditorOCRBaseResources", in: page.dictionary) else {
                throw PDFOCRError.cannotSave
            }
            var replacement = page.dictionary
            replacement = pdf.replacingValue(named: "Contents", in: replacement, with: contents)
            if resources == "null" {
                replacement = pdf.removingValue(named: "Resources", in: replacement)
            } else if pdf.value(named: "PDFTextEditorOCRBaseResourcesWasDirect", in: page.dictionary) == "true" {
                guard let resourceNumber = pdf.referenceNumber(in: resources),
                      let directResources = pdf.dictionary(for: resourceNumber) else { throw PDFOCRError.cannotSave }
                replacement = pdf.settingValue(named: "Resources", in: replacement, with: directResources)
            } else {
                replacement = pdf.settingValue(named: "Resources", in: replacement, with: resources)
            }
            for key in ["PDFTextEditorOCRLayer", "PDFTextEditorOCRBaseContents", "PDFTextEditorOCRBaseResources", "PDFTextEditorOCRBaseResourcesWasDirect", "PDFTextEditorOCRFontNames"] {
                replacement = replacement.replacingOccurrences(
                    of: "/\(key)\\s+(?:\\[[^]]*\\]|\\d+\\s+0\\s+R|\\d+|true|false|null)", with: "",
                    options: .regularExpression)
            }
            objects[page.number] = replacement
        }
        guard !objects.isEmpty else { throw PDFOCRError.unreadableSource }
        return try pdf.appending(objects: objects)
    }

    private static func addFontReference(
        _ fontNumber: Int,
        to dictionary: String,
        using pdf: PDFObjectEditor,
        objects: inout [Int: String],
        nextObjectNumber: inout Int,
        fontResourceName: inout String
    ) throws -> String {
        let fontDictionary: String
        let originalFontReference: Int?
        if let fontValue = pdf.value(named: "Font", in: dictionary) {
            if fontValue.hasPrefix("<<") {
                fontDictionary = fontValue
                originalFontReference = nil
            } else if let reference = pdf.referenceNumber(in: fontValue),
                      let referencedDictionary = pdf.dictionary(for: reference) {
                fontDictionary = referencedDictionary
                originalFontReference = reference
            } else {
                throw PDFOCRError.cannotSave
            }
        } else {
            fontDictionary = "<< >>"
            originalFontReference = nil
        }

        var suffix = 0
        repeat {
            fontResourceName = suffix == 0 ? "Focr" : "Focr\(suffix)"
            suffix += 1
        } while pdf.value(named: fontResourceName, in: fontDictionary) != nil

        let updatedFontDictionary = pdf.settingValue(
            named: fontResourceName,
            in: fontDictionary,
            with: "\(fontNumber) 0 R"
        )
        if originalFontReference != nil {
            let copiedFontNumber = nextObjectNumber; nextObjectNumber += 1
            objects[copiedFontNumber] = updatedFontDictionary
            return pdf.settingValue(named: "Font", in: dictionary, with: "\(copiedFontNumber) 0 R")
        }
        return pdf.settingValue(named: "Font", in: dictionary, with: updatedFontDictionary)
    }

    private static let defaultFontNameKey = "\u{0}PDFEditorOCR"

    private static func fontNameKey(_ postScriptName: String?) -> String {
        guard let name = postScriptName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return defaultFontNameKey
        }
        return name
    }

    private static func pdfNameToken(_ name: String) -> String {
        let delimiters: Set<UInt8> = [0x23, 0x25, 0x28, 0x29, 0x2F, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D]
        return name.utf8.map { byte in
            if byte <= 0x20 || byte >= 0x7F || delimiters.contains(byte) {
                return String(format: "#%02X", byte)
            }
            return String(UnicodeScalar(byte))
        }.joined()
    }

    private static func makeToUnicode(characters: [Unicode.Scalar]) -> String {
        var result = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /PDFEditorOCRUnicode def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        for start in stride(from: 0, to: characters.count, by: 100) {
            let chunk = characters[start..<min(start + 100, characters.count)]
            result += "\(chunk.count) beginbfchar\n"
            for (offset, scalar) in chunk.enumerated() {
                let code = String(format: "%04X", start + offset + 1)
                let utf16 = String(scalar).utf16.map { String(format: "%04X", $0) }.joined()
                result += "<\(code)> <\(utf16)>\n"
            }
            result += "endbfchar\n"
        }
        result += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return result
    }

    private static func stream(_ content: String) -> String {
        "<< /Length \(content.utf8.count) /PDFTextEditorOCRStream 1 >>\nstream\n\(content)endstream"
    }

    private static func number(_ value: CGFloat) -> String { String(format: "%.4f", Double(value)) }
}

private struct PDFObjectEditor {
    struct PageObject { let number: Int; let dictionary: String; let mediaBox: CGRect }
    let data: Data
    let source: NSString
    let offsets: [Int: Int]
    let latestXref: Int
    let root: Int
    let nextObjectNumber: Int

    init(data: Data) throws {
        self.data = data
        guard let string = String(data: data, encoding: .isoLatin1) else { throw PDFOCRError.cannotSave }
        source = string as NSString
        let matches = Self.matches("startxref\\s+(\\d+)", in: source)
        guard let last = matches.last, let start = Int(source.substring(with: last.range(at: 1))) else {
            throw PDFOCRError.cannotSave
        }
        latestXref = start
        var all: [Int: Int] = [:]
        var current: Int? = start
        var visited: Set<Int> = []
        var rootNumber: Int?
        while let xref = current {
            guard visited.insert(xref).inserted else { throw PDFOCRError.cannotSave }
            guard xref < data.count else { throw PDFOCRError.cannotSave }
            let tail = source.substring(from: xref) as NSString
            guard tail.hasPrefix("xref") else { throw PDFOCRError.cannotSave }
            let trailerRange = tail.range(of: "trailer")
            guard trailerRange.location != NSNotFound else { throw PDFOCRError.cannotSave }
            let entries = tail.substring(with: NSRange(location: 4, length: trailerRange.location - 4))
            let lines = entries.split(whereSeparator: \.isNewline).map(String.init)
            var position = 0
            while position < lines.count {
                let header = lines[position].split(separator: " ").compactMap { Int($0) }
                guard header.count == 2 else { throw PDFOCRError.cannotSave }
                position += 1
                for number in header[0]..<(header[0] + header[1]) {
                    guard position < lines.count else { throw PDFOCRError.cannotSave }
                    let fields = lines[position].split(separator: " ")
                    if fields.count >= 3, fields[2] == "n", all[number] == nil,
                       let offset = Int(fields[0]) { all[number] = offset }
                    position += 1
                }
            }
            let endRange = tail.range(of: "startxref", options: [],
                                      range: NSRange(location: trailerRange.location,
                                                     length: tail.length - trailerRange.location))
            guard endRange.location != NSNotFound else { throw PDFOCRError.cannotSave }
            let trailer = tail.substring(with: NSRange(location: trailerRange.location,
                                                       length: endRange.location - trailerRange.location))
            if rootNumber == nil { rootNumber = Self.firstCapture("/Root\\s+(\\d+)\\s+0\\s+R", in: trailer) }
            current = Self.firstCapture("/Prev\\s+(\\d+)", in: trailer)
        }
        guard let rootNumber else { throw PDFOCRError.cannotSave }
        offsets = all
        root = rootNumber
        nextObjectNumber = (all.keys.max() ?? 0) + 1
    }

    func pageObjects() -> [PageObject] {
        offsets.keys.sorted().compactMap { number in
            guard let dictionary = dictionary(for: number),
                  dictionary.range(of: "/Type\\s*/Page(?!s)", options: .regularExpression) != nil else { return nil }
            let box = mediaBox(in: dictionary) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
            return PageObject(number: number, dictionary: dictionary, mediaBox: box)
        }
        // Quartz/PDFKit writes page objects in page order in the normalized file.
    }

    private func mediaBox(in dictionary: String, depth: Int = 0) -> CGRect? {
        guard depth < 8 else { return nil }
        if let match = Self.matches("/MediaBox\\s*\\[([^]]+)\\]", in: dictionary as NSString).first {
            let values = (dictionary as NSString).substring(with: match.range(at: 1))
                .split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            if values.count == 4 {
                return CGRect(x: values[0], y: values[1],
                              width: values[2] - values[0], height: values[3] - values[1])
            }
        }
        guard let parent = reference(named: "Parent", in: dictionary),
              let parentDictionary = self.dictionary(for: parent) else { return nil }
        return mediaBox(in: parentDictionary, depth: depth + 1)
    }

    func dictionary(for number: Int) -> String? {
        guard let offset = offsets[number], offset < source.length,
              let start = source.range(of: "<<", options: [], range: NSRange(location: offset, length: min(80, source.length - offset))).location.nonNotFound else { return nil }
        var position = start
        var depth = 0
        while position + 1 < source.length {
            let pair = source.substring(with: NSRange(location: position, length: 2))
            if pair == "<<" { depth += 1; position += 2; continue }
            if pair == ">>" {
                depth -= 1
                position += 2
                if depth == 0 { return source.substring(with: NSRange(location: start, length: position - start)) }
                continue
            }
            position += 1
        }
        return nil
    }

    func reference(named key: String, in dictionary: String) -> Int? {
        Self.firstCapture("/\(key)\\s+(\\d+)\\s+0\\s+R", in: dictionary)
    }

    func value(named key: String, in dictionary: String) -> String? {
        guard let range = valueRange(named: key, in: dictionary) else { return nil }
        return (dictionary as NSString).substring(with: range)
    }

    func inheritedValue(named key: String, in dictionary: String, depth: Int = 0) -> String? {
        guard depth < 16 else { return nil }
        if let value = value(named: key, in: dictionary) { return value }
        guard let parent = reference(named: "Parent", in: dictionary),
              let parentDictionary = self.dictionary(for: parent) else { return nil }
        return inheritedValue(named: key, in: parentDictionary, depth: depth + 1)
    }

    func dictionaryValue(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<<"), value.hasSuffix(">>") { return value }
        guard let number = referenceNumber(in: value) else { return nil }
        return dictionary(for: number)
    }

    func referenceNumber(in value: String) -> Int? {
        Self.firstCapture("^(\\d+)\\s+0\\s+R$", in: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func replacingValue(named key: String, in dictionary: String, with value: String) -> String {
        guard let range = valueRange(named: key, in: dictionary) else { return dictionary }
        let source = dictionary as NSString
        return source.substring(to: range.location) + value
            + source.substring(from: NSMaxRange(range))
    }

    func settingValue(named key: String, in dictionary: String, with value: String) -> String {
        if valueRange(named: key, in: dictionary) != nil {
            return replacingValue(named: key, in: dictionary, with: value)
        }
        guard let closingRange = dictionary.range(of: ">>", options: .backwards) else { return dictionary }
        var result = dictionary
        result.insert(contentsOf: " /\(key) \(value) ", at: closingRange.lowerBound)
        return result
    }

    func removingValue(named key: String, in dictionary: String) -> String {
        let source = dictionary as NSString
        guard let keyMatch = Self.matches("/\(key)\\s+", in: source).first,
              let valueRange = valueRange(named: key, in: dictionary) else { return dictionary }
        let propertyRange = NSRange(location: keyMatch.range.location,
                                    length: NSMaxRange(valueRange) - keyMatch.range.location)
        return source.replacingCharacters(in: propertyRange, with: "")
    }

    private func valueRange(named key: String, in dictionary: String) -> NSRange? {
        let source = dictionary as NSString
        let pattern = "/\(key)\\s+"
        guard let keyMatch = Self.matches(pattern, in: source).first else { return nil }
        var start = NSMaxRange(keyMatch.range)
        while start < source.length, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(source.character(at: start))!) {
            start += 1
        }
        guard start < source.length else { return nil }
        let first = source.character(at: start)
        if first == 0x5B { // [ ... ]
            var depth = 0
            var index = start
            while index < source.length {
                let character = source.character(at: index)
                if character == 0x5B { depth += 1 }
                if character == 0x5D {
                    depth -= 1
                    if depth == 0 { return NSRange(location: start, length: index - start + 1) }
                }
                index += 1
            }
            return nil
        }
        if first == 0x3C, start + 1 < source.length, source.character(at: start + 1) == 0x3C { // << ... >>
            var depth = 0
            var index = start
            while index + 1 < source.length {
                let left = source.character(at: index)
                let right = source.character(at: index + 1)
                if left == 0x3C, right == 0x3C { depth += 1; index += 2; continue }
                if left == 0x3E, right == 0x3E {
                    depth -= 1
                    index += 2
                    if depth == 0 { return NSRange(location: start, length: index - start) }
                    continue
                }
                index += 1
            }
            return nil
        }
        let tail = source.substring(from: start) as NSString
        let tokenPattern = "^(?:\\d+\\s+\\d+\\s+R|/[^\\s<>\\[\\]()]+|null|true|false|[-+]?(?:\\d+\\.?\\d*|\\.\\d+))"
        guard let token = Self.matches(tokenPattern, in: tail).first else { return nil }
        return NSRange(location: start, length: token.range.length)
    }

    func appending(objects: [Int: String]) throws -> Data {
        var result = data
        if result.last != 10 { result.append(10) }
        var newOffsets: [Int: Int] = [:]
        for number in objects.keys.sorted() {
            newOffsets[number] = result.count
            result.append(Data("\(number) 0 obj\n\(objects[number]!)\nendobj\n".utf8))
        }
        let xrefOffset = result.count
        let numbers = newOffsets.keys.sorted()
        var xref = "xref\n"
        var index = 0
        while index < numbers.count {
            let start = numbers[index]
            var end = index + 1
            while end < numbers.count, numbers[end] == numbers[end - 1] + 1 { end += 1 }
            xref += "\(start) \(end - index)\n"
            for number in numbers[index..<end] {
                xref += String(format: "%010d 00000 n \n", newOffsets[number]!)
            }
            index = end
        }
        xref += "trailer\n<< /Size \(max(nextObjectNumber, numbers.last! + 1)) /Root \(root) 0 R /Prev \(latestXref) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        result.append(Data(xref.utf8))
        return result
    }

    private static func matches(_ pattern: String, in string: NSString) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: string as String, range: NSRange(location: 0, length: string.length))
    }

    private static func firstCapture(_ pattern: String, in string: String) -> Int? {
        let value = string as NSString
        guard let match = matches(pattern, in: value).first else { return nil }
        return Int(value.substring(with: match.range(at: 1)))
    }
}

private extension Int {
    var nonNotFound: Int? { self == NSNotFound ? nil : self }
}
