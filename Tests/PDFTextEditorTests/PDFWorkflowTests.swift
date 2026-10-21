import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

struct PDFWorkflowTests {
    @Test("page organizer moves a nonadjacent multi selection in document order")
    @MainActor
    func pageOrganizerMovesMultiplePages() throws {
        let inputs = try ["ONE", "TWO", "THREE", "FOUR"].map {
            try makePDF(label: $0, bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let source = try makeMultiPagePDF(from: inputs)
        defer { remove(inputs + [source]) }
        let document = try #require(PDFDocument(url: source))
        let model = PDFPageOrganizerModel(document: document, sourceURL: source)
        let ids = model.pages.map(\.id)
        model.select(id: ids[0])
        model.select(id: ids[2], extending: true)
        #expect(model.move(model.selectedIDs, to: ids[3]))
        #expect(model.pages.map(\.id) == [ids[1], ids[0], ids[2], ids[3]])
        #expect(model.selectedIDs == Set([ids[0], ids[2]]))
        model.undo()
        #expect(model.pages.map(\.id) == ids)

        #expect(model.move([ids[0]], to: ids[3], after: true))
        #expect(model.pages.map(\.id) == [ids[1], ids[2], ids[3], ids[0]])
        model.undo()
        #expect(model.pages.map(\.id) == ids)
    }

    @Test("page organizer reorders, rotates, duplicates, deletes, and restores without changing input")
    @MainActor
    func pageOrganizerEditsAreStagedAndUndoable() throws {
        let first = try makePDF(label: "FIRST", bounds: CGRect(x: 0, y: 0, width: 210, height: 120), rotation: 90, withAnnotation: true)
        let second = try makePDF(label: "SECOND", bounds: CGRect(x: 0, y: 0, width: 330, height: 190), rotation: 270)
        let source = try makeMultiPagePDF(from: [first, second])
        let output = temporaryPDFURL(prefix: "organized")
        defer { remove([first, second, source, output]) }
        let originalBytes = try Data(contentsOf: source)
        let document = try #require(PDFDocument(url: source))
        let firstPage = try #require(document.page(at: 0))
        firstPage.setBounds(CGRect(x: 8, y: 6, width: 170, height: 95), for: .cropBox)
        let model = PDFPageOrganizerModel(document: document, sourceURL: source)
        let ids = model.pages.map(\.id)

        model.select(id: ids[0])
        model.select(id: ids[1], extending: true)
        #expect(model.selectedIDs.count == 2)
        model.rotateSelected(by: 90)
        #expect(model.pages.map(\.rotation) == [180, 0])
        model.undo()
        #expect(model.pages.map(\.rotation) == [90, 270])
        model.redo()
        #expect(model.pages.map(\.rotation) == [180, 0])
        model.select(id: ids[0])
        model.duplicateSelected()
        #expect(model.pages.count == 3)
        #expect(model.selectedIDs.count == 1)
        model.deleteSelected()
        #expect(model.pages.count == 2)
        model.undo()
        #expect(model.pages.count == 3)
        model.undo()
        #expect(model.pages.count == 2)
        #expect(model.move([ids[1]], to: ids[0]))
        #expect(model.pages.map(\.id) == [ids[1], ids[0]])
        #expect(document.page(at: 0)?.rotation == 90)
        #expect(try Data(contentsOf: source) == originalBytes)

        try model.save(to: output)
        let result = try #require(PDFDocument(url: output))
        #expect(result.pageCount == 2)
        #expect(result.page(at: 0)?.string?.contains("SECOND") == true)
        let moved = try #require(result.page(at: 1))
        #expect(moved.string?.contains("FIRST") == true)
        #expect(moved.rotation == 180)
        #expect(moved.bounds(for: .mediaBox).size == CGSize(width: 210, height: 120))
        #expect(moved.bounds(for: .cropBox) == CGRect(x: 8, y: 6, width: 170, height: 95))
        #expect(moved.annotations.count == firstPage.annotations.count)
        #expect(try Data(contentsOf: source) == originalBytes)
    }

    @Test("page organizer inserts and extracts selected pages while protecting all inputs")
    @MainActor
    func pageOrganizerInsertExtractAndProtectSources() throws {
        let first = try makePDF(label: "BASE", bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let imported = try makePDF(label: "IMPORTED", bounds: CGRect(x: 0, y: 0, width: 300, height: 180), rotation: 90, withAnnotation: true)
        let output = temporaryPDFURL(prefix: "extracted")
        let alias = temporaryPDFURL(prefix: "organizer-alias")
        defer { remove([first, imported, output, alias]) }
        try FileManager.default.linkItem(at: imported, to: alias)
        let firstBytes = try Data(contentsOf: first)
        let importedBytes = try Data(contentsOf: imported)
        let sourceDocument = try #require(PDFDocument(url: first))
        let model = PDFPageOrganizerModel(document: sourceDocument, sourceURL: first)
        try model.insert(from: imported)
        #expect(model.pages.count == 2)
        #expect(model.selectedPages.count == 1)
        #expect(throws: PDFPageOrganizerError.self) { try model.save(to: first) }
        #expect(throws: PDFPageOrganizerError.self) { try model.save(to: alias) }
        try model.save(to: output, selectedOnly: true)
        let extracted = try #require(PDFDocument(url: output))
        let page = try #require(extracted.page(at: 0))
        #expect(extracted.pageCount == 1)
        #expect(page.string?.contains("IMPORTED") == true)
        #expect(page.rotation == 90)
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 300, height: 180))
        #expect(page.annotations.count == 1)
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: imported) == importedBytes)
        model.undo()
        #expect(model.pages.count == 1)
        model.redo()
        #expect(model.pages.count == 2)
    }

    @Test("thumbnail reorder preserves duplicate files and drives the saved page order")
    @MainActor
    func thumbnailReorderDrivesMergeOrder() throws {
        let first = try makePDF(label: "FIRST", bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        let second = try makePDF(label: "SECOND", bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        let third = try makePDF(label: "THIRD", bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        let output = temporaryPDFURL(prefix: "reordered")
        defer { remove([first, second, third, output]) }
        let model = PDFMergeModel()
        model.add(urls: [first, second, third, first])
        let ids = model.items.map(\.id)
        #expect(Set(ids).count == 4)
        #expect(model.move(id: ids[3], to: ids[0]))
        #expect(model.items.map(\.id) == [ids[3], ids[0], ids[1], ids[2]])
        #expect(model.move(id: ids[0], to: ids[2]))
        #expect(model.items.map(\.id) == [ids[3], ids[1], ids[2], ids[0]])
        #expect(!model.move(id: UUID(), to: ids[0]))
        #expect(!model.move(id: ids[0], to: ids[0]))
        model.merge(to: output)
        let merged = try #require(PDFDocument(url: output))
        #expect(merged.pageCount == 4)
        for (index, label) in ["FIRST", "SECOND", "THIRD", "FIRST"].enumerated() {
            #expect(merged.page(at: index)?.string?.contains(label) == true)
        }
        #expect(model.totalPageCount == 4)
        #expect(model.completedResult != nil)
        #expect(model.move(id: ids[1], to: ids[0]))
        #expect(model.completedResult == nil)
    }

    @Test("merge preserves order, page geometry, rotation, annotations, and input bytes")
    func mergePreservesPagesAndInputs() throws {
        let first = try makePDF(label: "FIRST", bounds: CGRect(x: 0, y: 0, width: 210, height: 120), rotation: 90, withAnnotation: true)
        let second = try makePDF(label: "SECOND", bounds: CGRect(x: 0, y: 0, width: 330, height: 190), rotation: 270)
        let output = temporaryPDFURL(prefix: "merged")
        defer { remove([first, second, output]) }
        let before = try [Data(contentsOf: first), Data(contentsOf: second)]
        let source = try #require(PDFDocument(url: first))
        let sourceFirstPage = try #require(source.page(at: 0))
        let sourceAnnotationCount = sourceFirstPage.annotations.count

        let result = try PDFMergeEngine.merge(inputURLs: [first, second], to: output)

        #expect(result.pageCount == 2)
        let merged = try #require(PDFDocument(url: output))
        #expect(merged.pageCount == 2)
        let firstPage = try #require(merged.page(at: 0))
        let secondPage = try #require(merged.page(at: 1))
        #expect(firstPage.string?.contains("FIRST") == true)
        #expect(secondPage.string?.contains("SECOND") == true)
        #expect(firstPage.bounds(for: .mediaBox).size == CGSize(width: 210, height: 120))
        #expect(secondPage.bounds(for: .mediaBox).size == CGSize(width: 330, height: 190))
        #expect(firstPage.rotation == 90)
        #expect(secondPage.rotation == 270)
        #expect(firstPage.annotations.count == sourceAnnotationCount)
        #expect(try Data(contentsOf: first) == before[0])
        #expect(try Data(contentsOf: second) == before[1])
    }

    @Test("merge rejects output aliases of every input")
    func mergeRejectsSameOutputThroughLinks() throws {
        let first = try makePDF(label: "ONE", bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let second = try makePDF(label: "TWO", bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let hardLink = temporaryPDFURL(prefix: "hard-link")
        let symbolicLink = temporaryPDFURL(prefix: "symbolic-link")
        defer { remove([first, second, hardLink, symbolicLink]) }
        try FileManager.default.linkItem(at: first, to: hardLink)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: second)
        let firstBytes = try Data(contentsOf: first)
        let secondBytes = try Data(contentsOf: second)

        #expect(throws: PDFMergeError.outputMatchesInput(first)) {
            try PDFMergeEngine.merge(inputURLs: [first, second], to: hardLink)
        }
        #expect(throws: PDFMergeError.outputMatchesInput(second)) {
            try PDFMergeEngine.merge(inputURLs: [first, second], to: symbolicLink)
        }
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: second) == secondBytes)
    }

    @Test("merge reports unreadable and locked inputs separately")
    func mergeRejectsUnreadableAndLockedFiles() throws {
        let unreadable = try makePDF(label: "UNREADABLE", bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let unlocked = try makePDF(label: "LOCK", bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let locked = temporaryPDFURL(prefix: "locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
            remove([unreadable, unlocked, locked])
        }
        let document = try #require(PDFDocument(url: unlocked))
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: "owner-password",
            .userPasswordOption: "user-password"
        ]
        #expect(document.write(to: locked, withOptions: options))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        #expect(throws: PDFMergeError.unreadableFile(unreadable)) {
            try PDFMergeEngine.inspect(url: unreadable)
        }
        #expect(throws: PDFMergeError.lockedFile(locked)) {
            try PDFMergeEngine.inspect(url: locked)
        }
    }

    @Test("merge and print honor PDF access permissions")
    func workflowsHonorDocumentPermissions() throws {
        let source = try makePDF(label: "PERMISSIONS", bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let copyBlocked = try makeRestrictedPDF(from: source, permissions: .allowsDocumentAssembly)
        let assemblyBlocked = try makeRestrictedPDF(from: source, permissions: .allowsContentCopying)
        let printBlocked = try makeRestrictedPDF(
            from: source,
            permissions: PDFAccessPermissions(rawValue:
                PDFAccessPermissions.allowsDocumentAssembly.rawValue
                    | PDFAccessPermissions.allowsContentCopying.rawValue
            )!
        )
        defer { remove([source, copyBlocked, assemblyBlocked, printBlocked]) }

        #expect(throws: PDFMergeError.copyingNotAllowed(copyBlocked)) {
            try PDFMergeEngine.inspect(url: copyBlocked)
        }
        #expect(throws: PDFMergeError.assemblyNotAllowed(assemblyBlocked)) {
            try PDFMergeEngine.inspect(url: assemblyBlocked)
        }
        #expect(throws: PDFPrintPreparationError.printingNotAllowed) {
            try PDFPrintPreparationEngine.prepare(sourceURL: printBlocked, edits: [])
        }
    }

    @Test("print preparation preserves unedited bytes and rotated page geometry")
    func printPreparationWithoutEditsCopiesOriginal() throws {
        let first = try makePDF(label: "PORTRAIT", bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        let rotated = try makePDF(label: "ROTATED", bounds: CGRect(x: 0, y: 0, width: 420, height: 210), rotation: 90)
        let source = try makeMultiPagePDF(from: [first, rotated])
        defer { remove([first, rotated, source]) }
        let originalBytes = try Data(contentsOf: source)

        let prepared = try PDFPrintPreparationEngine.prepare(sourceURL: source, edits: [])
        let temporaryURL = prepared.url
        #expect(try Data(contentsOf: temporaryURL) == originalBytes)
        let printedRotatedPage = try #require(prepared.document.page(at: 1))
        #expect(printedRotatedPage.bounds(for: .mediaBox).size == CGSize(width: 420, height: 210))
        #expect(printedRotatedPage.rotation == 90)
        prepared.cleanup()
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test("print preparation applies edits and keeps an unedited rotated page intact")
    func printPreparationAppliesEditsWithoutFlatteningOtherPages() throws {
        let editable = try makePDF(label: nil, bounds: CGRect(x: 0, y: 0, width: 240, height: 160), rotation: 270)
        let rotated = try makePDF(label: nil, bounds: CGRect(x: 0, y: 0, width: 480, height: 240), rotation: 90)
        let source = try makeMultiPagePDF(from: [editable, rotated])
        defer { remove([editable, rotated, source]) }
        let edit = ReplacementEdit(
            insertionOn: 0,
            bounds: CGRect(x: 30, y: 55, width: 140, height: 30),
            text: "PRINT",
            fontName: "Helvetica",
            fontSize: 18,
            fontColor: .black
        )

        let prepared = try PDFPrintPreparationEngine.prepare(sourceURL: source, edits: [edit])
        let editedPage = try #require(prepared.document.page(at: 0))
        #expect(editedPage.string?.contains("PRINT") == true)
        #expect(editedPage.bounds(for: .mediaBox).size == CGSize(width: 240, height: 160))
        #expect(editedPage.rotation == 270)
        let untouchedPage = try #require(prepared.document.page(at: 1))
        #expect(untouchedPage.bounds(for: .mediaBox).size == CGSize(width: 480, height: 240))
        #expect(untouchedPage.rotation == 90)
        #expect(untouchedPage.annotations.isEmpty)
    }

    @Test("canceling print with pending input does not change editor state")
    @MainActor
    func printCancelKeepsPendingInput() throws {
        let source = try makePDF(label: nil, bounds: CGRect(x: 0, y: 0, width: 240, height: 160))
        defer { remove([source]) }
        let model = EditorModel(initialURL: source)
        model.setMode(.insertion)
        model.beginInsertion(pageIndex: 0, point: CGPoint(x: 30, y: 60))
        model.updateEditorText("PENDING")
        let draft = try #require(model.insertionDraft)
        let revision = model.revision
        let annotationCount = model.document?.page(at: 0)?.annotations.count

        #expect(!model.resolvePendingPrintInput(.cancel))
        #expect(model.insertionDraft?.annotation === draft.annotation)
        #expect(model.replacementText == "PENDING")
        #expect(model.edits.isEmpty)
        #expect(model.revision == revision)
        #expect(model.document?.page(at: 0)?.annotations.count == annotationCount)
    }

    private func makePDF(
        label: String?,
        bounds: CGRect,
        rotation: Int = 0,
        withAnnotation: Bool = false
    ) throws -> URL {
        let escapedLabel = label?.replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)") ?? ""
        let content = label == nil ? "" : "BT /F1 16 Tf 1 0 0 1 20 40 Tm (\(escapedLabel)) Tj ET"
        let rawURL = RawPDFBuilder.singlePagePDF(pageBounds: bounds, contentStream: content)
        defer { try? FileManager.default.removeItem(at: rawURL) }
        let document = try #require(PDFDocument(url: rawURL))
        let page = try #require(document.page(at: 0))
        page.rotation = rotation
        if withAnnotation {
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 12, y: 12, width: 24, height: 24),
                forType: .text,
                withProperties: nil
            )
            annotation.contents = "test note"
            page.addAnnotation(annotation)
        }
        let output = temporaryPDFURL(prefix: "fixture")
        guard document.write(to: output) else {
            throw FixtureFailure.cannotWrite
        }
        return output
    }

    private func makeMultiPagePDF(from urls: [URL]) throws -> URL {
        let outputDocument = PDFDocument()
        for url in urls {
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0).flatMap { $0.copy() as? PDFPage })
            outputDocument.insert(page, at: outputDocument.pageCount)
        }
        let output = temporaryPDFURL(prefix: "multipage")
        guard outputDocument.write(to: output) else {
            throw FixtureFailure.cannotWrite
        }
        return output
    }

    private func makeRestrictedPDF(from sourceURL: URL, permissions: PDFAccessPermissions) throws -> URL {
        let document = try #require(PDFDocument(url: sourceURL))
        let output = temporaryPDFURL(prefix: "restricted")
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: "owner-password",
            .accessPermissionsOption: NSNumber(value: permissions.rawValue)
        ]
        guard document.write(to: output, withOptions: options) else {
            throw FixtureFailure.cannotWrite
        }
        let reopened = try #require(PDFDocument(url: output))
        #expect(!reopened.isLocked)
        return output
    }

    private func temporaryPDFURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
    }

    private func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private enum FixtureFailure: Error {
        case cannotWrite
    }
}
