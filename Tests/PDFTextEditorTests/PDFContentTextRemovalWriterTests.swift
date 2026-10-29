import AppKit
import CoreText
import PDFKit
import Testing
@testable import PDFTextEditor

@Suite("元streamを保持する文字削除", .serialized)
struct PDFContentTextRemovalWriterTests {
    private func hasPDFium() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return (environment["PDFIUM_LIBRARY_PATH"] ?? environment["PDFIUM_PATH"])
            .map { FileManager.default.fileExists(atPath: $0) } == true
    }

    @Test("ICCBased灰色背景と罫線を保ち日本語CFF全showを除去する")
    func removingJapaneseOnICCBackground() throws {
        guard hasPDFium() else { return }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("raw-cff-source-\(UUID()).pdf")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("raw-cff-output-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let bytes = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 240, height: 100)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor(calibratedWhite: 0.8, alpha: 1).cgColor)
        context.fill(CGRect(x: 10, y: 35, width: 220, height: 35))
        context.setStrokeColor(NSColor.black.cgColor)
        context.move(to: CGPoint(x: 10, y: 35)); context.addLine(to: CGPoint(x: 230, y: 35)); context.strokePath()
        context.setFillColor(NSColor.black.cgColor)
        context.textPosition = CGPoint(x: 20, y: 48)
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 14, nil)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "東京", attributes: [.font: font])), context)
        context.endPDFPage(); context.closePDF()
        let bounds = CGRect(x: 20, y: 46, width: 28, height: 14)
        let target = TextTarget(
            pageIndex: 0, bounds: bounds, baseline: 48, originalText: "", fontSize: 14,
            fontColor: .black, fontKey: nil, fontIsExact: false, coverBounds: bounds, maxWidth: 200
        )
        var foreground = ReplacementEdit(target: target, replacement: "東京", resolvedFont: font, fontIsExact: false)
        foreground.storage = .reconstructed
        try PDFVisibleTextUnicodeWriter.addingMappings(in: bytes as Data, edits: [foreground]).write(to: source)
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let index = PDFGlyphIndex.makeIndex(for: try #require(document.page(at: 0)))
        let run = try #require(index.runs.first { $0.text == "東京" })
        var deletion = ReplacementEdit(deleting: try #require(index.target(in: run, range: 0..<2, pageIndex: 0)))
        deletion.storage = .internalPDFium
        #expect(PDFInternalTextEditEngine.eligibility(sourceURL: source, edit: deletion) == .supported)
        try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [deletion], to: output)
        let saved = try #require(PDFDocument(url: output))
        defer { withExtendedLifetime(saved) {} }
        let savedPage = try #require(saved.page(at: 0))
        // PDFKitの版によって空showの位置を空白として抽出する。描画命令から
        // glyphが除去されたことを別途検証し、抽出のレイアウト用空白だけを許容する。
        #expect((savedPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(PDFGlyphIndex.makeIndex(for: savedPage).runs.flatMap(\.glyphs).isEmpty)
        try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: output, edits: [deletion])
    }

    @Test("単一文字列TJと画像XObjectを許容し非ASCIIの元byteを保持する")
    func preservingBinaryContentAndImage() throws {
        let source = fixture(show: "[(ABCD)] TJ", xobjectSubtype: "Image", extra: "BT /F1 14 Tf 1 0 0 1 120 50 Tm (é) Tj ET")
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let edit = try deletion(in: document)
        let original = try decodedContent(document)
        let result = try PDFContentTextRemovalWriter.rewritingTextShows(sourceURL: source, sourcePDF: document, edits: [edit])
        let rewritten = try #require(result)
        let output = try #require(PDFDocument(data: rewritten))
        let expected = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "(ABCD)", with: "<>").utf8)
        #expect(try decodedContent(output) == expected)
        #expect(try decodedContent(output).contains(Data("é".utf8)))
    }

    @Test("Form・inline image・削除後の相対showは元stream書換え対象にしない")
    func rejectsComplexContent() throws {
        for source in [
            fixture(show: "(ABCD) Tj", xobjectSubtype: "Form"),
            fixture(show: "(ABCD) Tj", extra: "q BI /W 1 /H 1 /BPC 8 /CS /G ID x EI Q"),
            fixture(show: "(ABCD) Tj (EF) Tj")
        ] {
            defer { try? FileManager.default.removeItem(at: source) }
            let document = try #require(PDFDocument(url: source))
            defer { withExtendedLifetime(document) {} }
            let edit = try deletion(in: document)
            #expect(try PDFContentTextRemovalWriter.rewritingTextShows(sourceURL: source, sourcePDF: document, edits: [edit]) == nil)
        }
    }

    @Test("Contents配列の調整TJ末尾だけを除去しprefixと別streamを保持する")
    func preservingAdjustedPrefixAndOtherStream() throws {
        guard hasPDFium() else { return }
        let source = fixture(show: "[(AB) -11 (CD)] TJ", streamArray: true)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("raw-suffix-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        var edit = try deletion(in: document, range: 2..<4)
        edit.storage = .internalPDFium
        let rewritten = try PDFContentTextRemovalWriter.rewritingTextShows(sourceURL: source, sourcePDF: document, edits: [edit])
        let data = try #require(rewritten)
        let saved = try #require(PDFDocument(data: data))
        defer { withExtendedLifetime(saved) {} }
        let originalContent = try decodedContents(document)
        let savedContent = try decodedContents(saved)
        #expect(savedContent.count == 2)
        #expect(savedContent[1] == originalContent[1])
        #expect(String(decoding: savedContent[0], as: UTF8.self).contains("[(AB) -11 <>] TJ"))
        let originalGlyphs = PDFGlyphIndex.makeIndex(for: try #require(document.page(at: 0))).runs.flatMap(\.glyphs)
        let savedGlyphs = PDFGlyphIndex.makeIndex(for: try #require(saved.page(at: 0))).runs.flatMap(\.glyphs)
        for text in ["A", "B"] {
            let before = try #require(originalGlyphs.first { $0.text == text })
            let after = try #require(savedGlyphs.first { $0.text == text })
            #expect(before.advanceBox == after.advanceBox)
            #expect(before.sourceCharacterCode == after.sourceCharacterCode)
        }
        try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [edit], to: output)
        try PDFInternalTextEditEngine.verifyFinalOutput(sourceURL: source, outputURL: output, edits: [edit])
        try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: output, edits: [edit])
    }

    @Test("show中間だけのraw削除とmarked内の選択は拒否する")
    func rejectsMiddleAndMarkedSelection() throws {
        let source = fixture(show: "[(AB) 11 (CD)] TJ")
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let middle = try deletion(in: document, range: 1..<3)
        #expect(try PDFContentTextRemovalWriter.rewritingTextShows(sourceURL: source, sourcePDF: document, edits: [middle]) == nil)
        let marked = fixture(show: "/Span << /ActualText (ABCD) >> BDC (ABCD) Tj EMC")
        defer { try? FileManager.default.removeItem(at: marked) }
        let markedDocument = try #require(PDFDocument(url: marked))
        defer { withExtendedLifetime(markedDocument) {} }
        #expect(try PDFContentTextRemovalWriter.rewritingTextShows(sourceURL: marked, sourcePDF: markedDocument, edits: [deletion(in: markedDocument)]) == nil)
    }

    @Test("元charcodeがUnicodeと異なるfontで末尾を置換し不可視文字と字間を保持する")
    func nativeSuffixWithNonUnicodeCodes() throws {
        guard hasPDFium() else { return }
        let fontURL = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        let fontData = try Data(contentsOf: fontURL)
        let provider = try #require(CGDataProvider(url: fontURL as CFURL))
        let graphicsFont = try #require(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 1000, nil, nil)
        let characters = Array("ABCDEF2".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        #expect(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
        #expect(glyphs[0] != characters[0])
        let widths = glyphs.map { glyph -> String in
            var glyph = glyph
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            return "\(glyph) [\(Int(advance.width.rounded()))]"
        }.joined(separator: " ")
        func hex(_ indices: Range<Int>) -> String { indices.map { String(format: "%04X", glyphs[$0]) }.joined() }
        let mappings = zip(glyphs, characters).map { String(format: "<%04X> <%04X>", $0.0, $0.1) }.joined(separator: "\n")
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /NonUnicode def /CMapType 2 def "
            + "1 begincodespacerange <0000> <FFFF> endcodespacerange 7 beginbfchar\n\(mappings)\nendbfchar "
            + "endcmap CMapName currentdict /CMap defineresource pop end end"
        let box = CTFontGetBoundingBox(font)
        let source = RawPDFBuilder.build(objects: [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8), Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 9 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type0 /BaseFont /ArialMT /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 8 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ArialMT /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /CIDToGIDMap /Identity /DW 1000 /W [\(widths)] >>".utf8),
            Data("<< /Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [\(Int(box.minX)) \(Int(box.minY)) \(Int(box.maxX)) \(Int(box.maxY))] /ItalicAngle 0 /Ascent \(Int(CTFontGetAscent(font))) /Descent \(-Int(CTFontGetDescent(font))) /CapHeight 700 /StemV 80 /FontFile2 7 0 R >>".utf8),
            RawPDFBuilder.streamObject(dict: "/Length1 \(fontData.count)", streamData: fontData),
            RawPDFBuilder.streamObject(dict: "", streamData: Data(cmap.utf8)),
            RawPDFBuilder.streamObject(dict: "", streamData: Data((
                "0.8 g 10 35 200 35 re f 0 g BT /F1 14 Tf .25 Tc 1 0 0 1 20 50 Tm [<\(hex(0..<2))> -11 <\(hex(2..<4))>] TJ ET "
                + "BT /F1 8 Tf 3 Tr 1 0 0 1 180 20 Tm <\(hex(6..<7))> Tj ET").utf8))
        ])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("raw-non-unicode-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let document = try #require(PDFDocument(url: source))
        defer { withExtendedLifetime(document) {} }
        let index = PDFGlyphIndex.makeIndex(for: try #require(document.page(at: 0)))
        let run = try #require(index.runs.first { $0.text == "ABCD" })
        let target = try #require(index.target(in: run, range: 2..<4, pageIndex: 0))
        var edit = ReplacementEdit(target: target, replacement: "EF", resolvedFont: CTFontCreateWithGraphicsFont(graphicsFont, 14, nil, nil), fontIsExact: true)
        edit.storage = .internalPDFium
        #expect(PDFInternalTextEditEngine.eligibility(sourceURL: source, edit: edit) == .supported)
        try PDFInternalTextEditEngine.apply(sourceURL: source, edits: [edit], to: output)
        try PDFInternalTextEditEngine.verifyFinalOutput(sourceURL: source, outputURL: output, edits: [edit])
        let saved = try #require(PDFDocument(url: output))
        defer { withExtendedLifetime(saved) {} }
        let content = String(decoding: try decodedContent(saved), as: UTF8.self)
        #expect(content.contains("<\(hex(0..<2))> -11 <\(hex(4..<6))>"))
        #expect(content.contains("3 Tr 1 0 0 1 180 20 Tm <\(hex(6..<7))> Tj"))
        #expect(saved.page(at: 0)?.string?.contains("2") == true)
        try PDFVisualIntegrityValidator.verify(sourceURL: source, outputURL: output, edits: [edit])
    }

    @Test("別領域のmarked辞書と画像だけのFormをbyte保持し文字を含むFormは拒否する")
    func preservesImageOnlyFormAndOtherMarkedText() throws {
        for subtype in ["ImageOnlyForm", "TextForm"] {
            let source = fixture(show: "(ABCD) Tj", xobjectSubtype: subtype,
                                 extra: "/Span << /ActualText (EF) >> BDC BT /F1 14 Tf 1 0 0 1 140 20 Tm (EF) Tj ET EMC")
            defer { try? FileManager.default.removeItem(at: source) }
            let document = try #require(PDFDocument(url: source))
            defer { withExtendedLifetime(document) {} }
            let result = try PDFContentTextRemovalWriter.rewritingTextShows(sourceURL: source, sourcePDF: document, edits: [deletion(in: document)])
            if subtype == "ImageOnlyForm" {
                let data = try #require(result)
                let saved = try #require(PDFDocument(data: data))
                #expect(String(decoding: try decodedContent(saved), as: UTF8.self).contains("/Span << /ActualText (EF) >> BDC"))
            } else { #expect(result == nil) }
        }
    }

    private func fixture(show: String, xobjectSubtype: String? = nil, extra: String = "", streamArray: Bool = false) -> URL {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /RawRemoval def /CMapType 2 def "
            + "1 begincodespacerange <00> <FF> endcodespacerange "
            + "6 beginbfchar\n<41><0041>\n<42><0042>\n<43><0043>\n<44><0044>\n<45><0045>\n<46><0046>\nendbfchar "
            + "endcmap CMapName currentdict /CMap defineresource pop end end"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] /Resources << /Font << /F1 4 0 R >> "
                + (xobjectSubtype == nil ? "" : "/XObject << /I1 7 0 R >> ")
                + ">> /Contents \(streamArray ? "[5 0 R 7 0 R]" : "5 0 R") >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            RawPDFBuilder.streamObject(dict: "", streamContent: (xobjectSubtype == nil ? "" : "q /I1 Do Q ")
                + "BT /F1 14 Tf 1 0 0 1 20 50 Tm \(show) ET \(extra)"),
            RawPDFBuilder.streamObject(dict: "", streamContent: cmap)
        ]
        if streamArray {
            objects.append(RawPDFBuilder.streamObject(dict: "", streamContent: "q 0.5 g 180 10 10 10 re f Q"))
        }
        if let subtype = xobjectSubtype {
            let isFormWithImage = subtype == "ImageOnlyForm" || subtype == "TextForm"
            objects.append(RawPDFBuilder.streamObject(
                dict: "/Type /XObject /Subtype /\(isFormWithImage ? "Form" : subtype) " + (subtype == "Image"
                    ? "/Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /ASCIIHexDecode"
                    : "/BBox [0 0 1 1] /Resources << \(isFormWithImage ? "/XObject << /I2 8 0 R >>" : "") >>"),
                streamContent: subtype == "Image" ? "80>" : isFormWithImage
                    ? "q /I2 Do Q \(subtype == "TextForm" ? "BT (A) Tj ET" : "")" : "0 0 1 1 re f"
            ))
            if isFormWithImage {
                objects.append(RawPDFBuilder.streamObject(dict: "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /ASCIIHexDecode", streamContent: "80>"))
            }
        }
        return RawPDFBuilder.build(objects: objects)
    }

    private func deletion(in document: PDFDocument, range: Range<Int> = 0..<4) throws -> ReplacementEdit {
        let index = PDFGlyphIndex.makeIndex(for: try #require(document.page(at: 0)))
        let run = try #require(index.runs.first { $0.text.hasPrefix("ABCD") })
        return ReplacementEdit(deleting: try #require(index.target(in: run, range: range, pageIndex: 0)))
    }

    private func decodedContents(_ document: PDFDocument) throws -> [Data] {
        let dictionary = try #require(document.documentRef?.page(at: 1)?.dictionary)
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array else { return [try decodedContent(document)] }
        return try (0..<CGPDFArrayGetCount(array)).map { index in
            var stream: CGPDFStreamRef?
            var format = CGPDFDataFormat.raw
            #expect(CGPDFArrayGetStream(array, index, &stream))
            let contentStream = try #require(stream)
            return try #require(CGPDFStreamCopyData(contentStream, &format) as Data?)
        }
    }

    private func decodedContent(_ document: PDFDocument) throws -> Data {
        let dictionary = try #require(document.documentRef?.page(at: 1)?.dictionary)
        var stream: CGPDFStreamRef?
        var format = CGPDFDataFormat.raw
        #expect(CGPDFDictionaryGetStream(dictionary, "Contents", &stream))
        let contentStream = try #require(stream)
        return try #require(CGPDFStreamCopyData(contentStream, &format) as Data?)
    }
}
