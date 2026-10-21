import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

struct PDFMarkupEngineTests {
    @Test("markup and signature bounds stay inside the page")
    func clampsMarkupBoundsToPage() {
        let pageBounds = CGRect(x: 12, y: 18, width: 200, height: 100)
        let signature = PDFMarkupEngine.clampedBounds(
            CGRect(x: 205, y: 112, width: 140, height: 40),
            to: pageBounds,
            minimumSize: CGSize(width: 80, height: 24)
        )
        #expect(signature == CGRect(x: 72, y: 78, width: 140, height: 40))

        let oversizedResize = PDFMarkupEngine.clampedBounds(
            CGRect(x: 50, y: 60, width: 320, height: 120),
            to: pageBounds,
            minimumSize: CGSize(width: 8, height: 8)
        )
        #expect(oversizedResize == pageBounds)
    }

    @Test("markup tools produce editable PDF annotations")
    func annotationTypesAndPayloads() {
        let bounds = CGRect(x: 12, y: 18, width: 80, height: 24)
        let expected: [(PDFMarkupTool, PDFAnnotationSubtype)] = [
            (.highlight, .highlight), (.underline, .underline), (.strikeOut, .strikeOut),
            (.note, .text), (.rectangle, .square), (.ellipse, .circle),
            (.arrow, .line), (.ink, .ink), (.signature, .freeText)
        ]

        for (tool, subtype) in expected {
            let edit = PDFMarkupEdit(
                pageIndex: 0, tool: tool, bounds: bounds,
                points: [CGPoint(x: 12, y: 18), CGPoint(x: 90, y: 40)],
                text: tool.usesTextInput ? "Test" : ""
            )
            let annotation = PDFMarkupEngine.makeAnnotation(for: edit)
            #expect(annotation.type == subtype.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            #expect(annotation.userName == PDFMarkupEngine.markerPrefix + edit.id.uuidString)
            #expect(annotation.shouldPrint)
            if tool.usesTextInput { #expect(annotation.contents == "Test") }
            if tool.isTextMarkup { #expect(annotation.quadrilateralPoints?.count == 4) }
            if tool == .arrow {
                #expect(annotation.startPoint == CGPoint.zero)
                #expect(annotation.endPoint == CGPoint(x: 78, y: 22))
            }
        }
    }

    @Test("annotations survive export as editable PDF objects")
    func exportRetainsAnnotations() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (SOURCE) Tj ET"
        )
        let sourceWithAnnotation = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-markup-source-\(UUID().uuidString).pdf")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-markup-export-\(UUID().uuidString).pdf")
        let printOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-markup-print-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: sourceWithAnnotation)
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: printOutput)
        }

        let sourceDocument = try #require(PDFDocument(url: source))
        let sourcePage = try #require(sourceDocument.page(at: 0))
        let externalNote = PDFAnnotation(bounds: CGRect(x: 24, y: 40, width: 20, height: 20), forType: .text, withProperties: nil)
        externalNote.userName = "Another PDF app"
        externalNote.contents = "Original review note"
        sourcePage.addAnnotation(externalNote)
        #expect(sourcePage.annotations.contains { $0.contents == "Original review note" })
        #expect(sourceDocument.write(to: sourceWithAnnotation))
        let reopenedSource = try #require(PDFDocument(url: sourceWithAnnotation))
        #expect(reopenedSource.page(at: 0)?.annotations.contains { $0.contents == "Original review note" } == true)

        let markups = [
            PDFMarkupEdit(pageIndex: 0, tool: .highlight,
                          bounds: CGRect(x: 18, y: 112, width: 50, height: 18)),
            PDFMarkupEdit(pageIndex: 0, tool: .note,
                          bounds: CGRect(x: 150, y: 80, width: 20, height: 20), text: "Review this")
        ]
        try PDFExportEngine.export(sourceURL: sourceWithAnnotation, edits: [], markups: markups, to: output)

        let exported = try #require(PDFDocument(url: output))
        let page = try #require(exported.page(at: 0))
        #expect(page.string?.contains("SOURCE") == true)
        let editorAnnotations = page.annotations.filter {
            $0.userName?.hasPrefix(PDFMarkupEngine.markerPrefix) == true
        }
        #expect(editorAnnotations.count == 2)
        #expect(editorAnnotations.contains {
            $0.type == PDFAnnotationSubtype.highlight.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        })
        #expect(editorAnnotations.contains { $0.contents == "Review this" })
        let externalNotes = page.annotations.filter {
            $0.type == PDFAnnotationSubtype.text.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                && $0.userName == "Another PDF app" && $0.contents == "Original review note"
        }
        #expect(externalNotes.count == 1)

        let printPageCopy = try #require(page.copy() as? PDFPage)
        PDFMarkupEngine.replaceManagedAnnotations(on: printPageCopy, with: markups)
        #expect(markedAnnotations(on: printPageCopy).count == 2)
        #expect(printPageCopy.annotations.filter {
            $0.type == PDFAnnotationSubtype.text.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                && $0.userName == "Another PDF app" && $0.contents == "Original review note"
        }.count == 1)

        let deletedMarkupCopy = try #require(page.copy() as? PDFPage)
        PDFMarkupEngine.replaceManagedAnnotations(
            on: deletedMarkupCopy,
            with: markups.filter { $0.tool != .note }
        )
        #expect(markedAnnotations(on: deletedMarkupCopy).count == 1)
        #expect(markedAnnotations(on: deletedMarkupCopy).allSatisfy { $0.contents != "Review this" })

        try PDFExportEngine.exportForPrinting(sourceURL: output, edits: [], markups: markups, to: printOutput)
        let preparedForPrint = try #require(PDFDocument(url: printOutput))
        #expect(preparedForPrint.pageCount == 1)
        #expect(preparedForPrint.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test("markup add, update, delete, undo and redo keep model and page in sync")
    @MainActor
    func modelMarkupHistory() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (SOURCE) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        model.setMode(.markup)
        model.setMarkupTool(.note)
        model.setMarkupText("First note")
        model.addMarkup(pageIndex: 0, bounds: CGRect(x: 20, y: 30, width: 20, height: 20))
        let id = try #require(model.selectedMarkupID)
        let page = try #require(model.document?.page(at: 0))
        #expect(model.activeMarkupEdits.count == 1)
        #expect(markedAnnotations(on: page).count == 1)

        model.updateSelectedMarkupText("Updated note")
        #expect(model.selectedMarkup?.text == "Updated note")
        #expect(markedAnnotations(on: page).first?.contents == "Updated note")
        model.undoLastEdit()
        #expect(model.activeMarkupEdits.first?.text == "First note")
        #expect(markedAnnotations(on: page).first?.contents == "First note")
        model.redoLastEdit()
        #expect(model.activeMarkupEdits.first?.text == "Updated note")

        model.selectMarkup(id)
        model.deleteSelectedMarkup()
        #expect(model.activeMarkupEdits.isEmpty)
        #expect(markedAnnotations(on: page).isEmpty)
        model.undoLastEdit()
        #expect(model.activeMarkupEdits.count == 1)
        #expect(markedAnnotations(on: page).first?.contents == "Updated note")
        model.undoLastEdit()
        #expect(model.activeMarkupEdits.first?.text == "First note")
        #expect(markedAnnotations(on: page).first?.contents == "First note")
        model.redoLastEdit()
        #expect(model.activeMarkupEdits.first?.text == "Updated note")
        model.undoLastEdit()
        model.undoLastEdit()
        #expect(model.activeMarkupEdits.isEmpty)
        #expect(markedAnnotations(on: page).isEmpty)
        model.redoLastEdit()
        #expect(model.activeMarkupEdits.first?.text == "First note")
    }

    @Test("reopened PDFs restore editor markups for editing")
    @MainActor
    func reloadRestoresEditableMarkups() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (SOURCE) Tj ET"
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-markup-reopen-\(UUID().uuidString).pdf")
        let editedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-markup-reopen-edited-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: editedOutput)
        }

        let original = EditorModel(initialURL: source)
        original.setMode(.markup)
        original.setMarkupTool(.note)
        original.setMarkupText("Saved note")
        original.addMarkup(pageIndex: 0, bounds: CGRect(x: 20, y: 30, width: 40, height: 24))
        let noteID = try #require(original.selectedMarkupID)

        original.setMarkupTool(.arrow)
        original.addMarkup(pageIndex: 0, bounds: CGRect(x: 60, y: 70, width: 50, height: 40),
                           points: [CGPoint(x: 65, y: 72), CGPoint(x: 105, y: 105)])
        let arrowID = try #require(original.selectedMarkupID)

        original.setMarkupTool(.ink)
        original.addMarkup(pageIndex: 0, bounds: CGRect(x: 120, y: 20, width: 40, height: 36),
                           points: [CGPoint(x: 122, y: 22), CGPoint(x: 140, y: 38), CGPoint(x: 158, y: 54)])
        let inkID = try #require(original.selectedMarkupID)

        try PDFExportEngine.export(sourceURL: source, edits: [], markups: original.activeMarkupEdits, to: output)
        let reopened = EditorModel(initialURL: output)
        #expect(reopened.activeMarkupEdits.count == 3)
        #expect(reopened.activeMarkupEdits.first(where: { $0.id == noteID })?.text == "Saved note")
        #expect(reopened.activeMarkupEdits.first(where: { $0.id == arrowID })?.points == [
            CGPoint(x: 65, y: 72), CGPoint(x: 105, y: 105)
        ])
        #expect(reopened.activeMarkupEdits.first(where: { $0.id == inkID })?.points == [
            CGPoint(x: 122, y: 22), CGPoint(x: 140, y: 38), CGPoint(x: 158, y: 54)
        ])

        reopened.setMode(.markup)
        reopened.selectMarkup(noteID)
        reopened.updateSelectedMarkupText("Updated after reopening")
        let reopenedPage = try #require(reopened.document?.page(at: 0))
        #expect(markedAnnotations(on: reopenedPage).first(where: { $0.userName == PDFMarkupEngine.markerPrefix + noteID.uuidString })?.contents
            == "Updated after reopening")

        try PDFExportEngine.export(sourceURL: output, edits: [], markups: reopened.activeMarkupEdits, to: editedOutput)
        let savedAgain = try #require(PDFDocument(url: editedOutput))
        let savedAgainPage = try #require(savedAgain.page(at: 0))
        #expect(markedAnnotations(on: savedAgainPage).count == 3)
        #expect(markedAnnotations(on: savedAgainPage).first(where: {
            $0.userName == PDFMarkupEngine.markerPrefix + noteID.uuidString
        })?.contents == "Updated after reopening")
    }

    @Test("moving and resizing ink and arrows updates their paths and undo restores the old geometry")
    @MainActor
    func moveAndResizeMarkupGeometry() throws {
        let source = RawPDFBuilder.singlePagePDF(
            pageBounds: CGRect(x: 0, y: 0, width: 240, height: 160),
            contentStream: "BT /F1 12 Tf 20 120 Td (SOURCE) Tj ET"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let model = EditorModel(initialURL: source)
        model.setMode(.markup)
        model.setMarkupTool(.arrow)
        model.addMarkup(pageIndex: 0, bounds: CGRect(x: 20, y: 30, width: 50, height: 40),
                        points: [CGPoint(x: 20, y: 30), CGPoint(x: 70, y: 70)])
        let id = try #require(model.selectedMarkupID)
        let movedBounds = CGRect(x: 60, y: 80, width: 50, height: 40)
        model.moveMarkup(id: id, to: movedBounds)
        #expect(model.selectedMarkup?.bounds == movedBounds)
        #expect(model.selectedMarkup?.points == [CGPoint(x: 60, y: 80), CGPoint(x: 110, y: 120)])

        model.undoLastEdit()
        #expect(model.activeMarkupEdits.first?.bounds == CGRect(x: 20, y: 30, width: 50, height: 40))
        let page = try #require(model.document?.page(at: 0))
        let restored = try #require(markedAnnotations(on: page).first)
        #expect(restored.bounds == CGRect(x: 20, y: 30, width: 50, height: 40))
        #expect(restored.startPoint == .zero)
        #expect(restored.endPoint == CGPoint(x: 50, y: 40))

        model.redoLastEdit()
        let resizedBounds = CGRect(x: 60, y: 80, width: 100, height: 80)
        model.moveMarkup(id: id, to: resizedBounds)
        #expect(model.activeMarkupEdits.first?.points == [CGPoint(x: 60, y: 80), CGPoint(x: 160, y: 160)])
    }

    private func markedAnnotations(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { $0.userName?.hasPrefix(PDFMarkupEngine.markerPrefix) == true }
    }
}
