import AppKit
import Combine
import GhosttyTerminal

@MainActor public final class TerminalHost: ObservableObject {
    @Published public private(set) var error: String?
    public var onExit: ((UUID) -> Void)?
    // The wrapper applies its theme after base config; keep the host palette authoritative.
    private lazy var controller = TerminalController(theme: .init()) {
        $0.withFontFamily("Menlo")
        $0.withFontSize(13)
        $0.withWindowPaddingX(14)
        $0.withWindowPaddingY(12)
        $0.withBackground("0D1725")
        $0.withForeground("E8EEF8")
        $0.withCursorColor("49E6CD")
        $0.withCursorText("0D1725")
        $0.withSelectionBackground("294159")
        $0.withSelectionForeground("F5F8FF")
        $0.withPalette(0, color: "#1A273A")
        $0.withPalette(1, color: "#E78080")
        $0.withPalette(2, color: "#58D7A4")
        $0.withPalette(3, color: "#EAC17C")
        $0.withPalette(4, color: "#7BAEF2")
        $0.withPalette(5, color: "#B79BF3")
        $0.withPalette(6, color: "#49D9D1")
        $0.withPalette(7, color: "#D9E2EF")
        $0.withPalette(8, color: "#788AA4")
        $0.withPalette(9, color: "#F29D98")
        $0.withPalette(10, color: "#80E5B5")
        $0.withPalette(11, color: "#F1D399")
        $0.withPalette(12, color: "#A3C7FF")
        $0.withPalette(13, color: "#D0B4FF")
        $0.withPalette(14, color: "#8DEDE3")
        $0.withPalette(15, color: "#F5F8FF")
        // User paste uses the native responder; protected requests are
        // handled by SurfaceEvents, while programs cannot read/write it.
        $0.withCustom("clipboard-write", "ask")
        $0.withCustom("shell-integration", "none")
    }
    private struct Entry {
        let view: TerminalView
        let events: SurfaceEvents
    }
    private var entries: [UUID: Entry] = [:]
    public init() {}

    /// Switching tabs reuses the view, PTY, and scrollback. Only explicit
    /// disconnect/reconnect may replace a surface with this identity.
    public func open(id: UUID, command: String) {
        guard entries[id] == nil else { return }
        let view = HostTerminalView(frame: .zero)
        let events = SurfaceEvents { [weak self] in
            self?.onExit?(id)
        }
        view.delegate = events
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            envVars: ["TERM": "xterm-256color"],
            command: command,
            waitAfterCommand: true
        )
        view.setAccessibilityLabel("터미널")
        error = controller.lastConfigurationIssue
        objectWillChange.send()
        entries[id] = Entry(view: view, events: events)
    }

    /// Releasing the local Ghostty PTY closes SSH. It sends no remote
    /// tmux kill command; the detached session continues on its host.
    public func disconnect(id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.view.delegate = nil
        entry.view.setSurfaceVisible(false)
        entry.view.removeFromSuperview()
        entry.view.controller = nil
        objectWillChange.send()
    }

    public func disconnectAll() {
        for id in Array(entries.keys) { disconnect(id: id) }
    }

    func view(for id: UUID) -> TerminalView? { entries[id]?.view }
}

/// Host-owned macOS shortcuts must not be consumed by standalone Ghostty
/// bindings. Use native responder actions for copy/paste and app termination.
@MainActor private final class HostTerminalView: TerminalView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self,
           let shortcut = HostShortcut(characters: event.charactersIgnoringModifiers,
                                       keyCode: event.keyCode, modifiers: event.modifierFlags) {
            switch shortcut {
            case .quit: NSApp.terminate(nil); return true
            case .copy: copy(nil); return true
            case .paste: paste(nil); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum HostShortcut: Equatable {
    case quit, copy, paste
    init?(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        switch characters?.lowercased() {
        case "q": self = .quit
        case "c": self = .copy
        case "v": self = .paste
        default:
            // Non-Latin input sources (for example Korean ㅍ on the V key)
            // still use physical Command shortcuts. Preserve Latin remapping.
            guard let characters, characters.unicodeScalars.contains(where: { !$0.isASCII }) else { return nil }
            switch keyCode {
            case 12: self = .quit
            case 8: self = .copy
            case 9: self = .paste
            default: return nil
            }
        }
    }
}

@MainActor private final class SurfaceEvents: TerminalSurfaceCloseDelegate, TerminalSurfaceClipboardConfirmationDelegate {
    private let exited: () -> Void
    init(exited: @escaping () -> Void) { self.exited = exited }
    func terminalDidClose(processAlive: Bool) { exited() }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        guard request.kind == .paste else {
            request.respond(allow: false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "터미널에 붙여넣을까요?"
        alert.informativeText = "줄바꿈이나 제어 문자가 포함되어 명령이 바로 실행될 수 있어요.\n\n" + String(request.contents.prefix(500))
        alert.alertStyle = .warning
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "붙여넣기")
        request.respond(allow: alert.runModal() == .alertSecondButtonReturn)
    }
}
