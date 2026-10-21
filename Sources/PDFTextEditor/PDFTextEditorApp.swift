import SwiftUI

@main
struct PDFTextEditorApp: App {
    @StateObject private var model: EditorModel
    @StateObject private var updater: AppUpdateController

    init() {
        let initialURL = CommandLine.arguments
            .dropFirst()
            .first
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? AppUpdateController.takeReopenURL()
        let model = EditorModel(initialURL: initialURL)
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: AppUpdateController(model: model))
    }

    var body: some Scene {
        WindowGroup("PDF editor") {
            EditorScreen()
                .environmentObject(model)
                .frame(minWidth: 1_080, minHeight: 720)
                .task { updater.start() }
        }
        .defaultSize(width: 1_280, height: 840)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("PDF内を検索…") {
                    model.showSearchSheet()
                }
                .keyboardShortcut("f")
                .disabled(model.document == nil)
            }

            CommandGroup(replacing: .newItem) {
                Button("PDFを開く…") {
                    model.openFromPanel()
                }
                .keyboardShortcut("o")

                Button("PDFを結合…") {
                    model.showMergeSheet()
                }

                Button("ページサイズを変更…") {
                    model.showResizeSheet()
                }
                .disabled(model.document == nil)

                Button("PDFを圧縮…") {
                    model.showCompressionSheet()
                }
                .disabled(model.document == nil)
            }

            CommandGroup(replacing: .saveItem) {
                Button("編集済みPDFを書き出す…") {
                    model.exportFromPanel()
                }
                .keyboardShortcut("s")
                .disabled(model.document == nil)
            }

            CommandGroup(replacing: .undoRedo) {
                Button("直前の変更を取り消す") {
                    model.undoLastEdit()
                }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)

                Button("やり直す") {
                    model.redoLastEdit()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }

            CommandGroup(replacing: .printItem) {
                Button("印刷…") {
                    model.printFromPanel()
                }
                .keyboardShortcut("p")
                .disabled(!model.canPrint)
            }
        }
    }
}
