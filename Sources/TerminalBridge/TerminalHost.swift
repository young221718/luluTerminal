import AppKit
import Combine
import GhosttyTerminal

@MainActor public final class TerminalHost: ObservableObject {
    @Published public private(set) var error: String?
    public var onExit: ((UUID) -> Void)?
    public var onOpenSettings: (() -> Void)?
    private lazy var controller: TerminalController = {
        let controller = TerminalController(theme: style.theme) {
            $0.withWindowPaddingX(14)
            $0.withWindowPaddingY(12)
            // User paste uses the native responder; protected requests are
            // handled by SurfaceEvents, while programs cannot read/write it.
            $0.withCustom("clipboard-write", "ask")
            $0.withCustom("shell-integration", "none")
            // The app owns Settings; Ghostty's default open_config action cannot open it.
            $0.withCustom("keybind", "super+comma=unbind")
        }
        controller.setTerminalConfiguration(style.configuration)
        controller.setColorScheme(.light)
        return controller
    }()
    private struct Entry {
        let generation: UUID
        let view: TerminalView
        let events: SurfaceEvents
    }
    private var entries: [UUID: Entry] = [:]
    private var style = TerminalStyle.default
    public init() {}

    /// Switching tabs reuses the view, PTY, and scrollback. Disconnecting or
    /// a native terminal close releases the surface with this identity.
    public func open(id: UUID, command: String, environment: [String: String] = [:]) {
        guard entries[id] == nil else { return }
        let view = HostTerminalView(frame: .zero)
        view.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        let generation = UUID()
        let events = SurfaceEvents { [weak self] in
            // Free the surface only after Ghostty's native close callback returns.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.entries[id]?.generation == generation else { return }
                self.disconnect(id: id)
                self.onExit?(id)
            }
        }
        view.delegate = events
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            envVars: ["TERM": "xterm-256color"].merging(environment) { _, supplied in supplied },
            command: command,
            waitAfterCommand: true
        )
        view.setAccessibilityLabel("터미널")
        error = controller.lastConfigurationIssue
        objectWillChange.send()
        entries[id] = Entry(generation: generation, view: view, events: events)
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

    func setStyle(_ next: TerminalStyle) {
        if next.light != style.light || next.dark != style.dark {
            if controller.setTheme(next.theme) {
                style.light = next.light
                style.dark = next.dark
            }
        }
        if next.fontFamily != style.fontFamily || next.fontSize != style.fontSize {
            let sizeChanged = next.fontSize != style.fontSize
            if controller.setTerminalConfiguration(next.configuration) {
                style.fontFamily = next.fontFamily
                style.fontSize = next.fontSize
                // A surface zoom overrides app config; explicit settings size changes reset it.
                if sizeChanged {
                    for entry in entries.values { entry.view.performBindingAction("reset_font_size") }
                }
            }
        }
        if error != controller.lastConfigurationIssue { error = controller.lastConfigurationIssue }
    }

    func setColorScheme(_ scheme: TerminalColorScheme) {
        controller.setColorScheme(scheme)
        if error != controller.lastConfigurationIssue { error = controller.lastConfigurationIssue }
    }

    func view(for id: UUID) -> TerminalView? { entries[id]?.view }
}

/// Host-owned macOS shortcuts must not be consumed by standalone Ghostty
/// bindings. Use native responder actions for copy/paste and app termination.
@MainActor private final class HostTerminalView: TerminalView {
    var onOpenSettings: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self,
           let shortcut = HostShortcut(characters: event.charactersIgnoringModifiers,
                                       keyCode: event.keyCode, modifiers: event.modifierFlags) {
            switch shortcut {
            case .quit: NSApp.terminate(nil); return true
            case .copy: copy(nil); return true
            case .paste: paste(nil); return true
            case .settings: onOpenSettings?(); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum HostShortcut: Equatable {
    case quit, copy, paste, settings
    init?(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        switch characters?.lowercased() {
        case "q": self = .quit
        case "c": self = .copy
        case "v": self = .paste
        case ",": self = .settings
        default:
            // Non-Latin input sources (for example Korean ㅍ on the V key)
            // still use physical Command shortcuts. Preserve Latin remapping.
            guard let characters, characters.unicodeScalars.contains(where: { !$0.isASCII }) else { return nil }
            switch keyCode {
            case 12: self = .quit
            case 8: self = .copy
            case 9: self = .paste
            case 43: self = .settings
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
