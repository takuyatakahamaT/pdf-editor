import Foundation
import PDFKit

struct PDFSearchHit: Identifiable {
    let id: UUID
    let pageIndex: Int
    let matchText: String
    let context: String
    let selection: PDFSelection
    let editTarget: TextTarget?

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        matchText: String,
        context: String,
        selection: PDFSelection,
        editTarget: TextTarget?
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.matchText = matchText
        self.context = context
        self.selection = selection
        self.editTarget = editTarget
    }
}

enum PDFSearchEngine {
    static func search(document: PDFDocument, query: String) -> [PDFSearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, document.pageCount > 0 else { return [] }

        let selections = document.findString(query, withOptions: [.caseInsensitive, .literal])
        var pageIndexes: [Int: PageTextIndex] = [:]
        var nextContextOffsetByPage: [Int: Int] = [:]

        return selections.compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return nil }

            let pageText = page.string ?? ""
            let matchText = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? query
            let (context, nextContextOffset) = contextSnippet(
                in: pageText,
                matching: query,
                startingAt: nextContextOffsetByPage[pageIndex] ?? 0
            )
            nextContextOffsetByPage[pageIndex] = nextContextOffset
            let textIndex = pageIndexes[pageIndex] ?? PDFGlyphIndex.makeIndex(for: page)
            pageIndexes[pageIndex] = textIndex
            let editTarget = matchingTarget(
                query: query,
                in: textIndex,
                pageIndex: pageIndex,
                near: selection.bounds(for: page)
            )

            return PDFSearchHit(
                pageIndex: pageIndex,
                matchText: matchText,
                context: context,
                selection: selection,
                editTarget: editTarget
            )
        }
    }

    private static func matchingTarget(
        query: String,
        in index: PageTextIndex,
        pageIndex: Int,
        near matchBounds: CGRect
    ) -> TextTarget? {
        let candidates = index.runs.flatMap { run -> [TextTarget] in
            var targets: [TextTarget] = []
            var searchRange = run.text.startIndex..<run.text.endIndex

            while let range = run.text.range(of: query, options: [.caseInsensitive, .literal], range: searchRange) {
                let lowerOffset = run.text.distance(from: run.text.startIndex, to: range.lowerBound)
                let upperOffset = run.text.distance(from: run.text.startIndex, to: range.upperBound)
                var characterOffset = 0
                var selectedStart: Int?
                var selectedEnd: Int?

                for (glyphIndex, glyph) in run.glyphs.enumerated() {
                    let glyphEnd = characterOffset + glyph.text.count
                    if characterOffset < upperOffset && glyphEnd > lowerOffset {
                        if selectedStart == nil { selectedStart = glyphIndex }
                        selectedEnd = glyphIndex + 1
                    }
                    characterOffset = glyphEnd
                }

                if let selectedStart, let selectedEnd,
                   let target = index.target(in: run, range: selectedStart..<selectedEnd, pageIndex: pageIndex) {
                    targets.append(target)
                }

                guard range.upperBound < run.text.endIndex else { break }
                searchRange = run.text.index(after: range.lowerBound)..<run.text.endIndex
            }
            return targets
        }

        guard !candidates.isEmpty else { return nil }
        guard !matchBounds.isNull, !matchBounds.isEmpty else { return candidates.first }
        return candidates.min { distance($0.bounds, to: matchBounds) < distance($1.bounds, to: matchBounds) }
    }

    private static func distance(_ lhs: CGRect, to rhs: CGRect) -> CGFloat {
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        return dx * dx + dy * dy
    }

    private static func contextSnippet(
        in pageText: String,
        matching query: String,
        startingAt offset: Int
    ) -> (snippet: String, nextOffset: Int) {
        let text = pageText as NSString
        guard text.length > 0 else { return (query, offset) }
        let startOffset = min(max(offset, 0), text.length)
        let range = text.range(
            of: query,
            options: [.caseInsensitive, .literal],
            range: NSRange(location: startOffset, length: text.length - startOffset)
        )
        let matchRange = range.location == NSNotFound
            ? text.range(of: query, options: [.caseInsensitive, .literal])
            : range
        guard matchRange.location != NSNotFound else {
            return (String(pageText.prefix(72)).replacingOccurrences(of: "\n", with: " "), offset)
        }
        let start = max(0, matchRange.location - 38)
        let end = min(text.length, NSMaxRange(matchRange) + 38)
        var snippet = text.substring(with: NSRange(location: start, length: end - start))
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if start > 0 { snippet = "…" + snippet }
        if end < text.length { snippet += "…" }
        return (snippet, NSMaxRange(matchRange))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
