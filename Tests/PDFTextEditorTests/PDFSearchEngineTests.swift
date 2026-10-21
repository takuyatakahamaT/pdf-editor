import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

struct PDFSearchEngineTests {
    @Test("search returns page context and an editable glyph target")
    func searchFindsContextAndEditableTarget() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 300, height: 200),
            contentStream: "BT /F1 16 Tf 1 0 0 1 20 80 Tm (ALPHA TARGET OMEGA) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))

        let results = PDFSearchEngine.search(document: document, query: "target")

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.pageIndex == 0)
        #expect(result.matchText.caseInsensitiveCompare("target") == .orderedSame)
        #expect(result.context.localizedCaseInsensitiveContains("alpha"))
        #expect(result.context.localizedCaseInsensitiveContains("omega"))
        #expect(result.editTarget?.originalText.caseInsensitiveCompare("target") == .orderedSame)
    }

    @Test("empty and missing queries return no search hits")
    func emptyAndMissingQueriesReturnNoHits() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 300, height: 200),
            contentStream: "BT /F1 16 Tf 1 0 0 1 20 80 Tm (KNOWN TEXT) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))

        #expect(PDFSearchEngine.search(document: document, query: "   ").isEmpty)
        #expect(PDFSearchEngine.search(document: document, query: "absent phrase").isEmpty)
    }

    @Test("closing search preserves the selected edit target and current search result")
    @MainActor
    func closingSearchPreservesEditingState() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 300, height: 200),
            contentStream: "BT /F1 16 Tf 1 0 0 1 20 80 Tm (ALPHA TARGET OMEGA) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)

        model.showSearchSheet()
        model.search("target")
        let result = try #require(model.searchResults.first)
        model.focusSearchResult(result)
        let selectedTarget = try #require(model.selectedTarget)
        let focusedResultID = model.focusedSearchResultID
        let navigationRevision = model.searchNavigationRevision

        model.closeSearchSheet()

        #expect(!model.isShowingSearchSheet)
        #expect(model.selectedTarget == selectedTarget)
        #expect(model.focusedSearchResultID == focusedResultID)
        #expect(model.focusedSearchSelection != nil)
        #expect(model.searchNavigationRevision == navigationRevision)
        #expect(model.searchResults.count == 1)
        #expect(model.highlightedSearchSelections.isEmpty)

        model.showSearchSheet()
        #expect(model.isShowingSearchSheet)
        #expect(model.highlightedSearchSelections.count == 1)
        #expect(model.selectedTarget == selectedTarget)
    }
}
