import AppKit
import SwiftUI

/// The launcher's search field: a borderless NSTextField that takes focus (and optionally selects
/// its text) whenever `focusRequest` changes. Navigation keys are handled by the controller's
/// key monitor before they reach the field.
struct LauncherTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont = .systemFont(ofSize: 20, weight: .regular)
    var focusRequest: Int
    var selectAll: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setPlaceholder(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if field.stringValue != text && !composing {
            field.stringValue = text
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
        if field.font != font { field.font = font }
        setPlaceholder(field)
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            let select = selectAll
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() {
                    let length = (field.stringValue as NSString).length
                    editor.selectedRange = select ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
                }
            }
        }
    }

    private func setPlaceholder(_ field: NSTextField) {
        guard field.placeholderString != placeholder else { return }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: font,
        ])
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherTextField
        var lastFocus = -1

        init(_ parent: LauncherTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
