import AppKit
import SwiftUI
import Testing
import InfraCore
@testable import InfraTerminalUI

@MainActor struct ProfileSSHKeySheetsTests {
    @Test func editorPresentationEqualityIncludesEveryInputAndSaveContext() {
        let model = makeModel()
        let context = ProfileEditorSaveContext(model: model, queue: .constant(SSHKeySetupQueue()), disconnect: { _ in })
        let otherContext = ProfileEditorSaveContext(model: model, queue: .constant(SSHKeySetupQueue()), disconnect: { _ in })
        let profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [SSHAccount(username: "fixture")])
        let tab = TerminalTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Existing")
        let base = ProfileEditorPresentation(profile: profile, tabs: [tab], demo: false, context: context)
        #expect(base == ProfileEditorPresentation(profile: profile, tabs: [tab], demo: false, context: context))
        var changed = profile
        changed.name = "Updated"
        #expect(base != ProfileEditorPresentation(profile: changed, tabs: [tab], demo: false, context: context))
        #expect(base != ProfileEditorPresentation(profile: nil, tabs: [tab], demo: false, context: context))
        #expect(base != ProfileEditorPresentation(profile: profile, tabs: [], demo: false, context: context))
        var changedTab = tab
        changedTab.title = "Renamed tab"
        #expect(base != ProfileEditorPresentation(profile: profile, tabs: [changedTab], demo: false, context: context))
        #expect(base != ProfileEditorPresentation(profile: profile, tabs: [tab], demo: true, context: context))
        #expect(base != ProfileEditorPresentation(profile: profile, tabs: [tab], demo: false, context: otherContext))
    }

    @Test func newServerQueuesEachSavedAccountInOrder() throws {
        let model = makeModel()
        let first = SSHAccount(username: "first", authMethod: .pendingKey)
        let second = SSHAccount(username: "second", authMethod: .pendingKey)
        let profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [first, second])
        var queue = SSHKeySetupQueue()

        try queue.saveProfile(profile, using: model)

        #expect(queue.pending.map(\.accountID) == [first.id, second.id])
        #expect(queue.pending.allSatisfy { $0.serverID == profile.id && !$0.unlock })
        #expect(try StateStore(url: model.storeURL).load() == model.workspace)
        #expect(queue.next()?.accountID == first.id)
        queue.markCompleted()
        #expect(queue.dismissed()?.accountID == second.id)
        queue.markCompleted()
        #expect(queue.dismissed() == nil)
    }

    @Test func addedAndRenamedAccountsUseCommittedIdentityWithoutReenrollingExistingAccounts() throws {
        let model = makeModel()
        let original = SSHAccount(username: "original")
        let retained = SSHAccount(username: "retained")
        var profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [original, retained])
        try model.saveProfile(profile)
        profile.accounts[0].username = "renamed"
        let added = SSHAccount(username: "added", authMethod: .pendingKey)
        profile.accounts.append(added)
        var queue = SSHKeySetupQueue()

        try queue.saveProfile(profile, using: model)

        let saved = try #require(model.workspace.servers.first { $0.id == profile.id })
        #expect(saved.accounts[0].id != original.id)
        #expect(queue.pending.map(\.accountID) == [saved.accounts[0].id, added.id])
        #expect(!queue.pending.contains { $0.accountID == original.id || $0.accountID == retained.id })
    }

    @Test func resavingPendingAccountKeepsSetupRequiredWithoutReopeningTheSheet() throws {
        let model = makeModel()
        let account = SSHAccount(username: "pending", authMethod: .pendingKey)
        var profile = ServerProfile(name: "Pending", host: "fixture.invalid", accounts: [account])
        var queue = SSHKeySetupQueue()
        try queue.saveProfile(profile, using: model)
        #expect(queue.next()?.accountID == account.id)
        #expect(queue.dismissed() == nil)
        profile.name = "Updated pending server"
        try queue.saveProfile(profile, using: model)
        #expect(queue.pending.isEmpty)
        #expect(model.workspace.servers.first { $0.id == profile.id }?.accounts[0].authMethod == .pendingKey)
    }

    @Test func ordinaryEditAndDemoSaveDoNotQueueSetup() throws {
        let model = makeModel()
        let account = SSHAccount(username: "existing")
        var profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        try model.saveProfile(profile)
        profile.name = "Renamed server"
        profile.monitoringEnabled = false
        var queue = SSHKeySetupQueue()
        try queue.saveProfile(profile, using: model)
        #expect(queue.next() == nil)
        #expect(queue.pending.isEmpty)

        let demo = makeModel(demo: true)
        try queue.saveProfile(profile, using: demo)
        #expect(queue.pending.isEmpty)
    }

    @Test func managedAccountsAreNotReenrolledAndLocalProfileCannotQueue() throws {
        let model = makeModel()
        let account = SSHAccount(username: "managed")
        var profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        profile.accounts[0].authMethod = .managedKey
        profile.accounts[0].managedKey = SSHManagedKeyReference(target: SSHConnectionTarget(server: profile, account: account, resolvedHost: profile.host))
        var queue = SSHKeySetupQueue()
        try queue.saveProfile(profile, using: model)
        #expect(queue.pending.isEmpty)
        let local = try #require(model.workspace.servers.first { $0.kind == .local })
        #expect(throws: (any Error).self) { try queue.saveProfile(local, using: model) }
        #expect(queue.pending.isEmpty)
    }

    @Test func saveFailureDoesNotQueueSetupOrChangePersistedWorkspace() throws {
        let model = makeModel()
        let account = SSHAccount(username: "existing")
        var profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        try model.saveProfile(profile)
        let before = model.workspace
        try Data("corrupt fixture".utf8).write(to: model.storeURL)
        profile.accounts.append(SSHAccount(username: "added", authMethod: .pendingKey))
        var queue = SSHKeySetupQueue()

        #expect(throws: (any Error).self) { try queue.saveProfile(profile, using: model) }
        #expect(queue.next() == nil)
        #expect(queue.pending.isEmpty)
        #expect(model.workspace == before)
        #expect(try String(contentsOf: model.storeURL, encoding: .utf8) == "corrupt fixture")
    }

    @Test func cancellationClearsRemainingSetupWithoutRemovingSavedAccounts() throws {
        let model = makeModel()
        let accounts = [SSHAccount(username: "first", authMethod: .pendingKey), SSHAccount(username: "second", authMethod: .pendingKey)]
        let profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: accounts)
        var queue = SSHKeySetupQueue()
        try queue.saveProfile(profile, using: model)
        #expect(queue.next()?.accountID == accounts[0].id)
        #expect(queue.dismissed() == nil)
        #expect(queue.pending.isEmpty)
        #expect(model.workspace.servers.first { $0.id == profile.id }?.accounts == accounts)
        #expect(queue.next() == nil)
    }

    @Test func savingEditorDismissesBeforePresentingTheNewAccountsPasswordSheet() async throws {
        let model = makeModel()
        let existing = SSHAccount(username: "existing")
        var draft = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [existing])
        try model.saveProfile(draft)
        let added = SSHAccount(username: "new-account", authMethod: .pendingKey)
        draft.accounts.append(added)
        let domain = "ProfileSSHKeySheetsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let appearance = AppearancePreferences(defaults: defaults)
        model.configureMonitoring(enabled: false, selectedInterval: 5)
        let presentation = SheetPresentation()
        let host = NSHostingView(rootView: SheetFixture(model: model, profile: draft, presentation: presentation)
            .environmentObject(appearance))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
        try await waitUntil { window.attachedSheet != nil }
        let editorSheet = try #require(window.attachedSheet)
        try await waitUntil { self.viewDescendants(of: editorSheet.contentView).contains { $0 is NSTextField } }
        for tick in 0..<40 {
            model.tick(at: Date(timeIntervalSince1970: Double(tick)))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(2))
        }
        let nameField = try #require(viewDescendants(of: editorSheet.contentView).compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.stringValue == "Fixture" })
        let lightTextColor = nameField.textColor
        appearance.selection = .dark
        try await waitUntil { nameField.textColor != lightTextColor }
        #expect(editorSheet.makeFirstResponder(nameField))
        let fieldEditor = try #require(nameField.currentEditor())
        fieldEditor.selectAll(nil)
        fieldEditor.insertText("Edited fixture")
        editorSheet.makeFirstResponder(nil)
        #expect(nameField.stringValue == "Edited fixture")
        let saveKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: editorSheet.windowNumber,
                                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                   isARepeat: false, keyCode: 36))
        #expect(editorSheet.performKeyEquivalent(with: saveKey), "The profile editor handles its default Save action")

        try await waitUntil {
            guard let sheet = window.attachedSheet, sheet !== editorSheet else { return false }
            return self.viewDescendants(of: sheet.contentView).contains { $0 is NSSecureTextField }
        }
        let setupSheet = try #require(window.attachedSheet)
        #expect(setupSheet !== editorSheet, "Dismiss the editor before presenting SSH setup")
        #expect(model.workspace.servers.first { $0.id == draft.id }?.accounts == [existing, added])
        #expect(model.workspace.servers.first { $0.id == draft.id }?.name == "Edited fixture")
        #expect(presentation.request?.serverID == draft.id)
        #expect(presentation.request?.accountID == added.id, "The password sheet targets the newly saved account")
        #expect(!viewDescendants(of: editorSheet.contentView).contains { $0 is NSSecureTextField })
    }

    private struct SheetFixture: View {
        @ObservedObject var model: AppModel
        let profile: ServerProfile
        @ObservedObject var presentation: SheetPresentation

        var body: some View {
            Text("Fixture \(model.now.timeIntervalSince1970)").frame(width: 800, height: 700)
                .modifier(ProfileSSHKeySheets(model: model, showProfile: $presentation.showProfile, editingProfile: profile,
                                              keySetupRequest: $presentation.request, disconnect: { _ in }))
        }
    }

    private class SheetPresentation: ObservableObject {
        @Published var showProfile = true
        @Published var request: SSHKeySetupRequest?
    }

    private func viewDescendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { viewDescendants(of: $0) }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "The native sheet transition did not finish within the bounded wait")
    }

    private func makeModel(demo: Bool = false) -> AppModel {
        AppModel(demo: demo, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("ProfileSSHKeySheetsTests-\(UUID())/state.json"), agentEnvironment: [:]) { _, _ in
            ProcessResult(exitCode: 255, stdout: "", stderr: "fixture")
        }
    }
}
