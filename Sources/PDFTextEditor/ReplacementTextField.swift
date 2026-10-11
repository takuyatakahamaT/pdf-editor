import AppKit
import SwiftUI

struct ReplacementTextField: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let focusRequest: Int
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "新しい文字を入力"
        field.font = NSFont(name: "Hiragino Sans", size: 15)
            ?? NSFont.systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 3
        field.usesSingleLineMode = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self

        if field.stringValue != text {
            field.stringValue = text
        }
        field.isEnabled = isEnabled

        guard isEnabled,
              context.coordinator.lastHandledFocusRequest != focusRequest else { return }

        context.coordinator.lastHandledFocusRequest = focusRequest
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReplacementTextField
        var lastHandledFocusRequest = 0

        init(parent: ReplacementTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            parent.onSubmit()
            return true
        }
    }
}
