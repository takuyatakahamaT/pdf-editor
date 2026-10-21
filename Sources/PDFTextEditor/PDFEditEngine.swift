import AppKit
import CoreText
import PDFKit

enum PDFEditEngine {
    static let annotationMarkerPrefix = "PDFTextBench:"
    static let draftMarker = "PDFTextBench:draft"

    /// 置換を確定する。フォント解決 (`PDFEmbeddedFontLoader`) はここで一度だけ行い、
    /// プレビュー用の `ReplacementTextAnnotation` と書き出し用の `ReplacementEdit` の
    /// 両方に同じ結果を焼き込む（プレビューと書き出しの描画・フォントを一致させるため）。
    static func applyReplacement(
        _ replacement: String,
        to page: PDFPage,
        target: TextTarget,
        preferredFontName: String? = nil
    ) -> (annotation: PDFAnnotation, edit: ReplacementEdit, fontIsExact: Bool) {
        let resolution = resolveFont(for: target, on: page, replacement: replacement,
                                     preferredFontName: preferredFontName)
        let lineFont: CTFont
        if target.fontPostScriptNameOverride != nil {
            lineFont = resolution.font
        } else if let layout = target.lineLayout,
           let fontKey = target.fontKey,
           let fontDict = PDFGlyphIndex.fontDictionary(for: fontKey, page: page) {
            // 選択した置換文字の描画には埋め込み subset の GID を使えるが、
            // 行末の未編集文字は Unicode で描くため、全行を描けるローカル書体を選ぶ。
            lineFont = PDFEmbeddedFontLoader.unicodeFontForLine(
                fontDict: fontDict,
                size: target.fontSize,
                text: layout.text(replacingWith: target.originalText)
            )
        } else {
            lineFont = resolution.font
        }
        let edit = ReplacementEdit(
            target: target,
            replacement: replacement,
            resolvedFont: resolution.font,
            fontIsExact: resolution.isExact,
            exactGlyphs: resolution.exactGlyphs,
            lineFont: lineFont
        )
        let annotation = ReplacementTextAnnotation(edit: edit)
        page.addAnnotation(annotation)
        return (annotation, edit, resolution.isExact)
    }

    static func applyDeletion(to page: PDFPage, target: TextTarget) -> (annotation: PDFAnnotation, edit: ReplacementEdit) {
        let edit = ReplacementEdit(deleting: target)
        let annotation = ReplacementTextAnnotation(edit: edit)
        page.addAnnotation(annotation)
        return (annotation, edit)
    }

    static func applyMovement(
        to page: PDFPage,
        target: TextTarget,
        destination: CGPoint
    ) -> (annotations: [PDFAnnotation], edit: ReplacementEdit) {
        let resolution = resolveFont(for: target, on: page, replacement: target.originalText)
        let edit = ReplacementEdit(
            target: target,
            replacement: target.originalText,
            resolvedFont: resolution.font,
            fontIsExact: resolution.isExact,
            exactGlyphs: resolution.exactGlyphs,
            lineFont: resolution.font
        ).movingSelection(to: destination)
        return (addMovementAnnotations(for: edit, to: page), edit)
    }

    @discardableResult
    static func addMovementAnnotations(for edit: ReplacementEdit, to page: PDFPage) -> [PDFAnnotation] {
        let cover = ReplacementCoverAnnotation(edit: edit)
        let text = ReplacementTextAnnotation(edit: edit, drawsMovedTextOnly: true)
        page.addAnnotation(cover)
        page.addAnnotation(text)
        return [cover, text]
    }

    static func resolveFont(
        for target: TextTarget,
        on page: PDFPage,
        replacement: String,
        preferredFontName: String? = nil
    ) -> PDFEmbeddedFontLoader.Resolution {
        if preferredFontName == nil,
           let searchableFontName = target.fontPostScriptNameOverride,
           let resolution = PDFEmbeddedFontLoader.resolveSearchableFont(
               named: searchableFontName,
               size: target.fontSize,
               replacementText: replacement,
               supportingText: target.lineLayout?.text(replacingWith: replacement)
           ) {
            return resolution
        }
        guard let fontKey = target.fontKey,
              let fontDict = PDFGlyphIndex.fontDictionary(for: fontKey, page: page) else {
            PDFEmbeddedFontLoader.registerBundledFonts()
            let requiredText = target.lineLayout?.text(replacingWith: replacement) ?? replacement
            let containsJapanese = requiredText.unicodeScalars.contains { scalar in
                let value = scalar.value
                return (0x3040...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value)
                    || (0x3400...0x4DBF).contains(value) || (0xFF66...0xFF9F).contains(value)
            }
            let fallbackName = containsJapanese ? "Noto Sans JP" : "Helvetica Neue"
            let fallback = PDFEmbeddedFontLoader.availableFont(named: fallbackName, size: target.fontSize)
                ?? CTFontCreateWithName(fallbackName as CFString, target.fontSize, nil)
            let requestedFont = preferredFontName.flatMap {
                PDFEmbeddedFontLoader.availableFont(named: $0, size: target.fontSize)
            }
            let missing = requestedFont.map {
                PDFEmbeddedFontLoader.missingCharacters(in: requiredText, font: $0)
            } ?? []
            let chosen: CTFont
            if let requestedFont, missing.isEmpty { chosen = requestedFont }
            else { chosen = fallback }
            let requestedName = preferredFontName ?? ""
            let reason = preferredFontName == nil
                ? "元のPDFフォント情報を取得できないため代替します。"
                : requestedFont == nil
                    ? "指定フォント「\(requestedName)」がこのMacで利用できないため代替します。"
                    : missing.isEmpty ? nil : "指定フォントに入力文字のグリフがないため代替します。"
            return PDFEmbeddedFontLoader.Resolution(font: chosen, isExact: false,
                                                     exactGlyphs: nil, reason: reason)
        }
        return PDFEmbeddedFontLoader.resolveFont(
            fontDict: fontDict,
            size: target.fontSize,
            replacementText: replacement,
            supportingText: target.lineLayout?.text(replacingWith: replacement),
            selectedWidth: target.lineLayout?.selectedAdvance ?? target.bounds.width,
            preferredFontName: preferredFontName
        )
    }

    static func insertionBounds(
        at point: CGPoint,
        text: String,
        fontName: String,
        fontSize: CGFloat,
        pageBounds: CGRect
    ) -> CGRect {
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let content = text.isEmpty ? "テキストを入力" : text
        let measured = (content as NSString).size(withAttributes: [.font: font])
        let width = min(max(measured.width + 12, 72), max(pageBounds.width, 72))
        let height = max(measured.height + 8, fontSize * 1.45)
        var origin = CGPoint(x: point.x, y: point.y - height / 2)
        origin.x = min(max(origin.x, pageBounds.minX), max(pageBounds.maxX - width, pageBounds.minX))
        origin.y = min(max(origin.y, pageBounds.minY), max(pageBounds.maxY - height, pageBounds.minY))
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    static func makeInsertionAnnotation(
        bounds: CGRect,
        text: String,
        fontName: String,
        fontSize: CGFloat,
        fontColor: NSColor,
        marker: String = draftMarker
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.userName = marker
        annotation.color = .clear
        annotation.fontColor = text.isEmpty ? .secondaryLabelColor : fontColor
        annotation.alignment = .left
        annotation.font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        annotation.contents = text.isEmpty ? "テキストを入力" : text
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        return annotation
    }

    static func updateInsertionAnnotation(
        _ annotation: PDFAnnotation,
        page: PDFPage,
        text: String,
        fontName: String,
        fontSize: CGFloat,
        fontColor: NSColor
    ) {
        let oldBounds = annotation.bounds
        let pageBounds = page.bounds(for: .mediaBox)
        let point = CGPoint(x: oldBounds.minX, y: oldBounds.midY)
        annotation.bounds = insertionBounds(
            at: point,
            text: text,
            fontName: fontName,
            fontSize: fontSize,
            pageBounds: pageBounds
        )
        annotation.contents = text.isEmpty ? "テキストを入力" : text
        annotation.font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        annotation.fontColor = text.isEmpty ? .secondaryLabelColor : fontColor
    }

    static func fittedFont(
        named fontName: String?,
        preferredSize: CGFloat,
        text: String,
        bounds: CGRect
    ) -> NSFont {
        var size = min(max(preferredSize, 6), max(bounds.height * 0.86, 6))
        let usableWidth = max(bounds.width - 3, 4)

        while size > 6 {
            let font = fontName.flatMap { NSFont(name: $0, size: size) }
                ?? NSFont.systemFont(ofSize: size)
            let measured = (text as NSString).size(withAttributes: [.font: font]).width
            if measured <= usableWidth {
                return font
            }
            size -= 0.5
        }

        return fontName.flatMap { NSFont(name: $0, size: 6) }
            ?? NSFont.systemFont(ofSize: 6)
    }
}
