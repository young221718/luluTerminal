import AppKit
import SwiftUI

struct SearchInputField: NSViewRepresentable {
    @EnvironmentObject private var appearance: AppearancePreferences
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let focusRequest: UUID
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var onMove: ((Int) -> Void)? = nil
    var rounded = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchInputTextField {
        let field = SearchInputTextField()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: SearchInputTextField, context: Context) {
        context.coordinator.input = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.isBezeled = rounded
        field.isBordered = false
        field.bezelStyle = .roundedBezel
        field.drawsBackground = rounded
        field.textColor = NSColor(appearance.colors.text)
        field.requestFocus(focusRequest)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var input: SearchInputField
        init(_ input: SearchInputField) { self.input = input }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            input.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            routeCommand(commandSelector, textView: textView, modifiers: NSApp?.currentEvent?.modifierFlags ?? [])
        }

        func routeCommand(_ command: Selector, textView: NSTextView, modifiers: NSEvent.ModifierFlags) -> Bool {
            guard !textView.hasMarkedText(), modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)):
                guard let onMove = input.onMove else { return false }
                onMove(1)
            case #selector(NSResponder.moveUp(_:)):
                guard let onMove = input.onMove else { return false }
                onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): input.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): input.onCancel()
            default: return false
            }
            return true
        }
    }
}

final class SearchInputTextField: NSTextField {
    private var requestedFocus: UUID?
    private var appliedFocus: UUID?

    func requestFocus(_ token: UUID) {
        requestedFocus = token
        focusAfterAttachment()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusAfterAttachment()
    }

    private func focusAfterAttachment() {
        guard let window, let token = requestedFocus, appliedFocus != token else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, window.attachedSheet == nil,
                  self.requestedFocus == token, self.appliedFocus != token else { return }
            if window.makeFirstResponder(self) { self.appliedFocus = token }
        }
    }
}
