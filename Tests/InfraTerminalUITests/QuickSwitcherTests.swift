import AppKit
import Foundation
import InfraCore
import SwiftUI
import Testing
@testable import InfraTerminalUI

struct QuickSwitcherTests {
    @Test func emptyQueryKeepsServerAndOpenTabOrder() {
        let workspace = fixture()
        let entries = QuickSwitchItem.entries(workspace: workspace, query: " \n\t ")
        #expect(entries.map(\.target) == [
            .server(workspace.servers[0].id), .tab(workspace.tabs[1].id),
            .server(workspace.servers[1].id), .tab(workspace.tabs[0].id)
        ])
        #expect(QuickSwitchItem.entries(workspace: WorkspaceState(), query: "").isEmpty)
    }

    @Test func tokensMatchAcrossAliasHostAccountAndKoreanTitle() {
        let workspace = fixture()
        #expect(QuickSwitchItem.entries(workspace: workspace, query: "GPU.EXAMPLE \t TRAINER\n학습").map(\.target)
                == [.tab(workspace.tabs[1].id)])
        #expect(QuickSwitchItem.entries(workspace: workspace, query: "분석 cafe").map(\.target)
                == [.server(workspace.servers[0].id), .tab(workspace.tabs[1].id)])
        #expect(QuickSwitchItem.entries(workspace: workspace, query: "분석 absent").isEmpty)
    }

    @Test func unusedAccountFindsServerWithoutOfferingANewSession() {
        let workspace = fixture()
        let entries = QuickSwitchItem.entries(workspace: workspace, query: "observer")
        #expect(entries.map(\.target) == [.server(workspace.servers[0].id)])
        #expect(entries.first?.subtitle.contains("observer") == true)
    }

    @Test func closedTabsAreExcludedEvenWhenTheirTitleMatches() {
        let workspace = fixture()
        #expect(QuickSwitchItem.entries(workspace: workspace, query: "archived").isEmpty)
        #expect(!QuickSwitchItem.entries(workspace: workspace, query: "").contains {
            $0.target == .tab(workspace.tabs[2].id)
        })
    }

    @Test func identitiesRemainStableAcrossFilteringAndRenaming() {
        var workspace = fixture()
        let original = QuickSwitchItem.entries(workspace: workspace, query: "")
        let filtered = QuickSwitchItem.entries(workspace: workspace, query: "학습")
        #expect(filtered.first?.id == original.first { $0.target == .tab(workspace.tabs[1].id) }?.id)
        workspace.servers[0].name = "Renamed server"
        workspace.tabs[1].title = "Renamed tab"
        let renamed = QuickSwitchItem.entries(workspace: workspace, query: "")
        #expect(renamed.map(\.id) == original.map(\.id))
        #expect(Set(renamed.map(\.id)).count == renamed.count)
    }

    @MainActor @Test func choosingExistingTargetsPreservesSessionsAndConnections() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSwitcherTests-\(UUID())/workspace.json")
        let recorder = QuickSwitchCommandRecorder()
        let model = AppModel(demo: false, storeURL: url) { command, _ in await recorder.run(command) }
        let workspace = fixture()
        for server in workspace.servers { try model.saveProfile(server) }
        let server = workspace.servers[0]
        let tab = try model.addTab(serverID: server.id, accountID: server.accounts[0].id, title: "학습")
        _ = await model.prepareConnection(tabID: tab.id, create: false)
        model.selectServer(workspace.servers[1].id)
        let servers = model.workspace.servers
        let tabs = model.workspace.tabs
        let connections = model.connections
        #expect(await recorder.commands.count == 1)

        for query in ["observer", "학습"] {
            let item = try #require(QuickSwitchItem.entries(workspace: model.workspace, query: query).first)
            switch item.target {
            case .server(let id): model.selectServer(id)
            case .tab(let id): model.selectTab(id)
            }
            #expect(model.workspace.selectedServerID == server.id)
            #expect(model.selectedTab?.id == tab.id)
            #expect(model.workspace.servers == servers)
            #expect(model.workspace.tabs == tabs)
            #expect(model.connections == connections)
        }
        #expect(await recorder.commands.count == 1)
    }

    @MainActor @Test func nativeFieldEditorRoutesArrowsReturnAndEscape() {
        var offsets: [Int] = []
        var submissions = 0
        var cancellations = 0
        let input = SearchInputField(text: .constant(""), placeholder: "Search", accessibilityLabel: "Search",
                                     focusRequest: UUID(), onSubmit: { submissions += 1 },
                                     onCancel: { cancellations += 1 }, onMove: { offsets.append($0) })
        let coordinator = input.makeCoordinator()
        let field = NSTextField()
        let editor = NSTextView()
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(offsets == [1, -1])
        #expect(submissions == 1)
        #expect(cancellations == 1)
    }

    @MainActor @Test func nativeFieldEditorPreservesMarkedTextAndModifiedArrows() {
        var offsets: [Int] = []
        let input = SearchInputField(text: .constant(""), placeholder: "Search", accessibilityLabel: "Search",
                                     focusRequest: UUID(), onSubmit: {}, onCancel: {}, onMove: { offsets.append($0) })
        let coordinator = input.makeCoordinator()
        let editor = NSTextView()
        let modifiedArrows: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
        for modifiers in modifiedArrows {
            #expect(!coordinator.routeCommand(#selector(NSResponder.moveDown(_:)), textView: editor, modifiers: modifiers))
        }
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        for command in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)),
                        #selector(NSResponder.cancelOperation(_:))] {
            #expect(!coordinator.routeCommand(command, textView: editor, modifiers: []))
        }
        #expect(offsets.isEmpty)
        editor.unmarkText()
        #expect(coordinator.routeCommand(#selector(NSResponder.moveDown(_:)), textView: editor, modifiers: [.function, .numericPad, .capsLock]))
        #expect(offsets == [1])
    }

    @MainActor @Test func nativeTextEditsPublishQueriesAndSearchOnlyInputKeepsArrows() {
        var query = ""
        let input = SearchInputField(text: Binding(get: { query }, set: { query = $0 }),
                                     placeholder: "Search", accessibilityLabel: "Search", focusRequest: UUID(),
                                     onSubmit: {}, onCancel: {})
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "gpu5")
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(query == "gpu5")
        #expect(!coordinator.routeCommand(#selector(NSResponder.moveDown(_:)), textView: NSTextView(), modifiers: []))
    }

    @MainActor @Test func nativeFieldFocusWaitsForAttachmentAndHonorsNewRequests() async throws {
        let field = SearchInputTextField()
        let token = UUID()
        field.requestFocus(token)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        container.addSubview(field)
        let other = NSTextField(frame: NSRect(x: 10, y: 50, width: 200, height: 24))
        container.addSubview(other)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        for _ in 0..<4 { await Task.yield() }
        let firstEditor = try #require(field.currentEditor())
        #expect(window.firstResponder === firstEditor)
        #expect(window.makeFirstResponder(other))
        field.requestFocus(token)
        for _ in 0..<4 { await Task.yield() }
        #expect(window.firstResponder === other.currentEditor())
        field.requestFocus(UUID())
        for _ in 0..<4 { await Task.yield() }
        #expect(field.currentEditor() != nil)
        #expect(window.firstResponder === field.currentEditor())
        #expect(window.makeFirstResponder(other))
        field.requestFocus(UUID())
        field.removeFromSuperview()
        for _ in 0..<4 { await Task.yield() }
        #expect(window.firstResponder === other.currentEditor())
    }

    private func fixture() -> WorkspaceState {
        let trainer = SSHAccount(username: "trainer")
        let first = ServerProfile(name: "분석 Café", host: "gpu.example", accounts: [trainer, SSHAccount(username: "observer")])
        let second = ServerProfile(name: "Storage", host: "nas.example", accounts: [SSHAccount(username: "admin")])
        var workspace = WorkspaceState()
        workspace.servers = [first, second]
        workspace.tabs = [
            TerminalTab(serverID: second.id, accountID: second.accounts[0].id, title: "Logs"),
            TerminalTab(id: first.id, serverID: first.id, accountID: trainer.id, title: "학습 상태"),
            TerminalTab(serverID: first.id, accountID: trainer.id, title: "Archived", isClosed: true)
        ]
        return workspace
    }
}

private actor QuickSwitchCommandRecorder {
    private(set) var commands: [ShellCommand] = []
    func run(_ command: ShellCommand) -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
