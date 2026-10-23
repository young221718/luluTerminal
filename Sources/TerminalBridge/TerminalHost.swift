import AppKit
import Combine
import GhosttyTerminal

@MainActor public final class TerminalHost: ObservableObject {
    @Published public private(set) var error: String?
    @Published public private(set) var search: TerminalSearchState?
    @Published public private(set) var searchFocusRequest = UUID()
    public var onExit: ((UUID) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onSearchRequest: ((UUID) -> Void)?
    public var onQuickSwitch: (() -> Void)?
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
    private var searchGeneration: UUID?
    private var startingSearch: (id: UUID, generation: UUID, acknowledged: Bool)?
    private var engineSearchStart: (id: UUID, generation: UUID, needle: String?)?
    private let searchAction: (TerminalView, String) -> Bool

    public convenience init() { self.init(searchAction: { $0.performBindingAction($1) }) }

    init(searchAction: @escaping (TerminalView, String) -> Bool) {
        self.searchAction = searchAction
    }

    /// Switching tabs reuses the view, PTY, and scrollback. Disconnecting or
    /// a native terminal close releases the surface with this identity.
    public func open(id: UUID, command: String, environment: [String: String] = [:]) {
        guard entries[id] == nil else { return }
        let view = HostTerminalView(frame: .zero)
        let generation = UUID()
        view.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        view.onSearchRequest = { [weak self] in
            guard let self, self.entries[id]?.generation == generation,
                  self.entries[id]?.view.window?.attachedSheet == nil else { return }
            self.onSearchRequest?(id)
        }
        view.onQuickSwitch = { [weak self] in
            guard let self, self.entries[id]?.generation == generation,
                  self.entries[id]?.view.window?.attachedSheet == nil else { return }
            self.onQuickSwitch?()
        }
        let events = SurfaceEvents(exited: { [weak self] in
            // Free the surface only after Ghostty's native close callback returns.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.entries[id]?.generation == generation else { return }
                self.disconnect(id: id)
                self.onExit?(id)
            }
        }, searchEvent: { [weak self] event in
            self?.receiveSearch(event, id: id, generation: generation)
        })
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
        if search?.id == id { closeSearch(restoreFocus: false) }
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

    public func beginSearch(id: UUID) {
        guard let entry = entries[id], entry.view.window?.attachedSheet == nil else { return }
        searchFocusRequest = UUID()
        if search?.id == id, searchGeneration == entry.generation { return }
        closeSearch(restoreFocus: false)
        let start = engineSearchStart
        let isEngineStart = start?.id == id && start?.generation == entry.generation
        searchGeneration = entry.generation
        search = TerminalSearchState(id: id, query: isEngineStart ? start?.needle ?? "" : "", total: nil, selected: nil)
        if isEngineStart {
            if let needle = start?.needle, !needle.isEmpty, !needle.contains("\0") {
                _ = searchAction(entry.view, "search:" + needle)
            }
        } else {
            startingSearch = (id, entry.generation, false)
            let performed = searchAction(entry.view, "start_search")
            let acknowledged = startingSearch?.acknowledged == true
            startingSearch = nil
            // This pinned wrapper reports false even after delivering native search callbacks.
            if !performed && !acknowledged {
                search = nil
                searchGeneration = nil
            }
        }
    }

    public func updateSearchQuery(_ query: String) {
        guard var state = search, let entry = entries[state.id], searchGeneration == entry.generation,
              !query.contains("\0"), state.query != query else { return }
        state.query = query
        state.total = nil
        state.selected = nil
        search = state
        _ = searchAction(entry.view, "search:" + query)
    }

    public func navigateSearch(previous: Bool) {
        guard let state = search, let entry = entries[state.id], searchGeneration == entry.generation,
              !state.query.isEmpty else { return }
        _ = searchAction(entry.view, previous ? "navigate_search:previous" : "navigate_search:next")
    }

    public func closeSearch(restoreFocus: Bool = true) {
        guard let state = search else { return }
        let generation = searchGeneration
        search = nil
        searchGeneration = nil
        guard let entry = entries[state.id], entry.generation == generation else { return }
        _ = searchAction(entry.view, "end_search")
        if restoreFocus, entries[state.id]?.generation == generation { focus(id: state.id) }
    }

    public func focus(id: UUID) {
        guard let view = entries[id]?.view, let window = view.window,
              window.isKeyWindow, window.attachedSheet == nil else { return }
        window.makeFirstResponder(view)
    }

    private func receiveSearch(_ event: TerminalSearchEvent, id: UUID, generation: UUID) {
        guard let entry = entries[id], entry.generation == generation else { return }
        if case .started(let needle) = event {
            guard entry.view.window?.attachedSheet == nil else {
                _ = searchAction(entry.view, "end_search")
                return
            }
            if let pending = startingSearch, pending.id == id, pending.generation == generation {
                startingSearch = (id, generation, true)
            }
            if search?.id == id, searchGeneration == generation {
                if let needle, !needle.contains("\0") {
                    search = TerminalSearchState(id: id, query: needle, total: nil, selected: nil)
                    if !needle.isEmpty { _ = searchAction(entry.view, "search:" + needle) }
                }
            } else {
                // The app must accept native requests before a hidden tab can publish search UI.
                engineSearchStart = (id, generation, needle)
                onSearchRequest?(id)
                engineSearchStart = nil
                if search?.id != id || searchGeneration != generation { _ = searchAction(entry.view, "end_search") }
            }
            return
        }
        guard var state = search, state.id == id, searchGeneration == generation else { return }
        switch event {
        case .started: break
        case .ended:
            search = nil
            searchGeneration = nil
            focus(id: id)
            return
        case .total(let total):
            state.total = total.flatMap { $0 >= 0 ? $0 : nil }
            if let total = state.total, let selected = state.selected, selected >= total { state.selected = nil }
        case .selected(let selected):
            state.selected = selected.flatMap { $0 >= 0 ? $0 : nil }
            if let total = state.total, let selected = state.selected, selected >= total { state.selected = nil }
        }
        search = state
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
    var onSearchRequest: (() -> Void)?
    var onQuickSwitch: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self,
           let shortcut = HostShortcut(characters: event.charactersIgnoringModifiers,
                                       keyCode: event.keyCode, modifiers: event.modifierFlags) {
            switch shortcut {
            case .quit: NSApp.terminate(nil); return true
            case .copy: copy(nil); return true
            case .paste: paste(nil); return true
            case .settings: onOpenSettings?(); return true
            case .search: onSearchRequest?(); return true
            case .quickSwitch: onQuickSwitch?(); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum HostShortcut: Equatable {
    case quit, copy, paste, settings, search, quickSwitch
    init?(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        if relevant == [.command, .shift] {
            if characters?.lowercased() == "p" { self = .quickSwitch; return }
            if let characters, characters.unicodeScalars.contains(where: { !$0.isASCII }), keyCode == 35 { self = .quickSwitch; return }
            return nil
        }
        guard relevant == .command else { return nil }
        switch characters?.lowercased() {
        case "q": self = .quit
        case "c": self = .copy
        case "v": self = .paste
        case ",": self = .settings
        case "f": self = .search
        default:
            // Non-Latin input sources (for example Korean ㅍ on the V key)
            // still use physical Command shortcuts. Preserve Latin remapping.
            guard let characters, characters.unicodeScalars.contains(where: { !$0.isASCII }) else { return nil }
            switch keyCode {
            case 12: self = .quit
            case 8: self = .copy
            case 9: self = .paste
            case 43: self = .settings
            case 3: self = .search
            default: return nil
            }
        }
    }
}

@MainActor private final class SurfaceEvents: TerminalSurfaceCloseDelegate, TerminalSurfaceClipboardConfirmationDelegate, TerminalSurfaceSearchDelegate {
    private let exited: () -> Void
    private let searchEvent: (TerminalSearchEvent) -> Void
    init(exited: @escaping () -> Void, searchEvent: @escaping (TerminalSearchEvent) -> Void) {
        self.exited = exited
        self.searchEvent = searchEvent
    }
    func terminalDidClose(processAlive: Bool) { exited() }
    func terminalDidStartSearch(needle: String?) { searchEvent(.started(needle)) }
    func terminalDidEndSearch() { searchEvent(.ended) }
    func terminalDidUpdateSearchTotal(_ total: Int?) { searchEvent(.total(total)) }
    func terminalDidUpdateSearchSelected(_ selected: Int?) { searchEvent(.selected(selected)) }

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
