import AppKit
import GhosttyTerminal
import Testing
@testable import TerminalBridge

@MainActor struct TerminalSearchTests {
    @Test func searchAndQuickSwitchShortcutsUseNativeAndNonLatinKeyPaths() {
        #expect(HostShortcut(characters: "f", keyCode: 3, modifiers: .command) != nil)
        #expect(HostShortcut(characters: "ㄹ", keyCode: 3, modifiers: .command) != nil)
        #expect(HostShortcut(characters: "P", keyCode: 35, modifiers: [.command, .shift]) != nil)
        #expect(HostShortcut(characters: "ㅖ", keyCode: 35, modifiers: [.command, .shift]) != nil)
        #expect(HostShortcut(characters: "k", keyCode: 40, modifiers: .command) == nil)
    }

    @Test func bindingActionsStayOnTheCurrentSurfaceAndPreserveTheSession() throws {
        var actions: [String] = []
        var targets: [ObjectIdentifier] = []
        let host = TerminalHost(searchAction: { view, action in
            actions.append(action)
            targets.append(ObjectIdentifier(view))
            return true
        })
        let firstID = UUID(), secondID = UUID()
        host.open(id: firstID, command: "/usr/bin/true", environment: ["FIXTURE": "preserved"])
        host.open(id: secondID, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        let first = try #require(host.view(for: firstID))
        let second = try #require(host.view(for: secondID))
        let options = first.configuration
        host.beginSearch(id: firstID)
        host.updateSearchQuery("literal:한글 and space")
        host.navigateSearch(previous: false)
        host.navigateSearch(previous: true)
        host.closeSearch(restoreFocus: false)
        #expect(actions == ["start_search", "search:literal:한글 and space", "navigate_search:next", "navigate_search:previous", "end_search"])
        #expect(targets.allSatisfy { $0 == ObjectIdentifier(first) })
        #expect(host.search == nil)
        #expect(host.view(for: firstID) === first && host.view(for: secondID) === second)
        #expect(first.configuration.command == options.command)
        #expect(first.configuration.envVars == options.envVars)
    }

    @Test func nativeResultCountsAndSelectedIndexUpdateOnlyTheActiveSearch() throws {
        let host = TerminalHost(searchAction: { _, _ in true })
        let firstID = UUID(), secondID = UUID()
        host.open(id: firstID, command: "/usr/bin/true")
        host.open(id: secondID, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        let first = try #require(host.view(for: firstID)?.delegate as? any TerminalSurfaceSearchDelegate)
        let other = try #require(host.view(for: secondID)?.delegate as? any TerminalSurfaceSearchDelegate)
        host.beginSearch(id: firstID)
        first.terminalDidStartSearch(needle: "needle")
        first.terminalDidUpdateSearchTotal(4)
        first.terminalDidUpdateSearchSelected(0)
        #expect(host.search?.id == firstID && host.search?.query == "needle")
        #expect(host.search?.total == 4 && host.search?.selected == 0)
        other.terminalDidUpdateSearchTotal(99)
        other.terminalDidUpdateSearchSelected(7)
        other.terminalDidEndSearch()
        #expect(host.search?.total == 4 && host.search?.selected == 0)
        host.updateSearchQuery("new needle")
        #expect(host.search?.total == nil && host.search?.selected == nil)
        first.terminalDidUpdateSearchTotal(0)
        #expect(host.search?.total == 0 && host.search?.selected == nil)
        first.terminalDidEndSearch()
        #expect(host.search == nil)
    }

    @Test func oldGenerationAndClosedSearchCallbacksCannotReopenOrChangeSearch() throws {
        let host = TerminalHost(searchAction: { _, _ in true })
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        let old = try #require(host.view(for: id)?.delegate as? any TerminalSurfaceSearchDelegate)
        host.beginSearch(id: id)
        host.disconnect(id: id)
        #expect(host.search == nil)
        host.open(id: id, command: "/bin/echo replacement")
        defer { host.disconnectAll() }
        host.beginSearch(id: id)
        host.updateSearchQuery("replacement")
        old.terminalDidStartSearch(needle: "stale")
        old.terminalDidUpdateSearchTotal(99)
        old.terminalDidUpdateSearchSelected(9)
        old.terminalDidEndSearch()
        #expect(host.search?.query == "replacement" && host.search?.total == nil)
        let current = try #require(host.view(for: id)?.delegate as? any TerminalSurfaceSearchDelegate)
        host.closeSearch(restoreFocus: false)
        current.terminalDidUpdateSearchTotal(8)
        current.terminalDidUpdateSearchSelected(2)
        #expect(host.search == nil)
    }

    @Test func engineOriginatedSearchNeedsTheHostRequestGateBeforePublishing() throws {
        var actions: [String] = []
        let host = TerminalHost(searchAction: { _, action in actions.append(action); return true })
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        let callback = try #require(host.view(for: id)?.delegate as? any TerminalSurfaceSearchDelegate)
        var requests: [UUID] = []
        host.onSearchRequest = { requests.append($0) }
        callback.terminalDidStartSearch(needle: "rejected")
        #expect(requests == [id] && host.search == nil)
        #expect(actions == ["end_search"])
        host.onSearchRequest = { [weak host] id in host?.beginSearch(id: id) }
        callback.terminalDidStartSearch(needle: "selected text")
        #expect(host.search?.query == "selected text")
        #expect(actions == ["end_search", "search:selected text"], "Accepting an engine start must search the supplied selection without a second start action")
    }

    @Test func switchingSearchTargetsEndsOnlyTheOldSearchAndDisconnectCleansState() throws {
        var actions: [String] = []
        let host = TerminalHost(searchAction: { _, action in actions.append(action); return true })
        let firstID = UUID(), secondID = UUID()
        host.open(id: firstID, command: "/usr/bin/true")
        host.open(id: secondID, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        host.beginSearch(id: firstID)
        host.updateSearchQuery("old")
        host.beginSearch(id: secondID)
        #expect(host.search?.id == secondID && host.search?.query == "")
        #expect(actions == ["start_search", "search:old", "end_search", "start_search"])
        host.disconnect(id: firstID)
        #expect(host.search?.id == secondID)
        host.disconnect(id: secondID)
        #expect(host.search == nil)
        #expect(actions.last == "end_search")
    }

    @Test func rejectedNativeActionsDoNotLeaveAnActiveSearch() {
        let host = TerminalHost(searchAction: { _, _ in false })
        let id = UUID()
        host.beginSearch(id: id)
        #expect(host.search == nil)
        host.open(id: id, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        host.beginSearch(id: id)
        #expect(host.search == nil)
    }

    @Test func queuedPaneFocusDoesNotStealTheSearchFieldAndExplicitFocusRestoresTerminal() async throws {
        let host = TerminalHost(searchAction: { _, _ in true })
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        let view = try #require(host.view(for: id))
        let window = SearchTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentView!.bounds)
        let container = TerminalContainer(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        let field = NSTextField(frame: NSRect(x: 0, y: 260, width: 200, height: 24))
        root.addSubview(container); root.addSubview(field); window.contentView = root
        defer { host.disconnectAll(); window.close() }
        container.show(view)
        try #require(window.makeFirstResponder(field))
        let fieldResponder = window.firstResponder
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(window.firstResponder === fieldResponder)
        host.focus(id: id)
        #expect(window.firstResponder === view)
        _ = window.makeFirstResponder(field)
        let modalResponder = window.firstResponder
        window.testSheet = NSWindow()
        host.beginSearch(id: id)
        host.focus(id: id)
        #expect(host.search == nil && window.firstResponder === modalResponder)
        window.testSheet = nil
        window.testKey = false
        host.focus(id: id)
        #expect(window.firstResponder === modalResponder)
    }

    @Test func nativeStartCallbackAcknowledgementSurvivesFalseBindingReturn() {
        var actions: [String] = []
        let host = TerminalHost(searchAction: { view, action in
            actions.append(action)
            if action == "start_search" {
                (view.delegate as? any TerminalSurfaceSearchDelegate)?.terminalDidStartSearch(needle: nil)
            }
            return false
        })
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        host.beginSearch(id: id)
        #expect(host.search?.id == id)
        host.updateSearchQuery("needle")
        #expect(host.search?.query == "needle")
        #expect(actions == ["start_search", "search:needle"])
    }

    @Test func repeatedSearchRequestRefocusesWithoutResettingQueryOrResults() throws {
        var actions: [String] = []
        let host = TerminalHost(searchAction: { _, action in actions.append(action); return true })
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        host.beginSearch(id: id)
        host.updateSearchQuery("preserved")
        let callback = try #require(host.view(for: id)?.delegate as? any TerminalSurfaceSearchDelegate)
        callback.terminalDidUpdateSearchTotal(5)
        callback.terminalDidUpdateSearchSelected(2)
        let state = host.search
        let focusRequest = host.searchFocusRequest
        host.beginSearch(id: id)
        #expect(host.search == state)
        #expect(host.searchFocusRequest != focusRequest)
        #expect(actions == ["start_search", "search:preserved"])
    }

    @Test func nativeTerminalShortcutsRequestTheAppUIAndRespectSheets() throws {
        let host = TerminalHost(searchAction: { _, _ in true })
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        let view = try #require(host.view(for: id))
        let window = SearchTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { host.disconnectAll(); window.close() }
        try #require(window.makeFirstResponder(view))
        var searches: [UUID] = []
        var switches = 0
        host.onSearchRequest = { searches.append($0) }
        host.onQuickSwitch = { switches += 1 }
        let find = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        let quick = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "P", charactersIgnoringModifiers: "P", isARepeat: false, keyCode: 35))
        #expect(view.performKeyEquivalent(with: find))
        #expect(view.performKeyEquivalent(with: quick))
        #expect(searches == [id] && switches == 1)
        #expect(host.search == nil, "The app gate decides whether to show search")
        window.testSheet = NSWindow()
        #expect(view.performKeyEquivalent(with: find))
        #expect(view.performKeyEquivalent(with: quick))
        #expect(searches == [id] && switches == 1)
    }

    @Test func surfaceDelegateReceivesNativeSearchActions() throws {
        let host = TerminalHost()
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        _ = try #require(host.view(for: id)?.delegate as? any TerminalSurfaceSearchDelegate)
    }
}

@MainActor private final class SearchTestWindow: NSWindow {
    var testKey = true
    var testSheet: NSWindow?
    override var isKeyWindow: Bool { testKey }
    override var attachedSheet: NSWindow? { testSheet }
}
