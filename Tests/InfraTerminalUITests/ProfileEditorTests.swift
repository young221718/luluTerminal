import AppKit
import SwiftUI
import InfraCore
import Testing
@testable import InfraTerminalUI

@MainActor struct ProfileEditorTests {
    @Test func newAndRenamedAccountsRequireNewKeyWhileExistingAccountsRemainCompatible() {
        let existing = SSHAccount(username: "existing")
        let profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [existing])
        let editor = ProfileEditor(profile: profile, tabs: []) { _ in }
        #expect(!editor.needsAutomaticSSHKeySetup(for: existing))
        let added = SSHAccount(username: "added", authMethod: .pendingKey)
        #expect(editor.needsAutomaticSSHKeySetup(for: added))
        #expect(editor.automaticSSHKeySetupMessage(for: added).contains("저장 후 비밀번호"))
        var renamed = existing
        renamed.username = "renamed"
        #expect(editor.needsAutomaticSSHKeySetup(for: renamed))
        let newEditor = ProfileEditor(profile: nil, tabs: []) { _ in }
        #expect(newEditor.needsAutomaticSSHKeySetup(for: existing))
        var managed = existing
        managed.authMethod = .managedKey
        let managedProfile = ServerProfile(name: "Managed", host: "fixture.invalid", accounts: [managed])
        #expect(!ProfileEditor(profile: managedProfile, tabs: []) { _ in }.needsAutomaticSSHKeySetup(for: managed))
        #expect(existing.authMethod == .system)
        #expect(profile.accounts == [existing])
        var pending = existing
        pending.authMethod = .pendingKey
        let pendingProfile = ServerProfile(name: "Pending", host: "fixture.invalid", accounts: [pending])
        let pendingEditor = ProfileEditor(profile: pendingProfile, tabs: []) { _ in }
        #expect(pendingEditor.needsAutomaticSSHKeySetup(for: pending))
        #expect(pendingEditor.automaticSSHKeySetupMessage(for: pending).contains("서버 메뉴의 ‘SSH 키 설정’"))
    }

    @Test func accountChangesCountOnlyOriginalAccountsAndTheirServerTabs() {
        let renamed = SSHAccount(username: "old")
        let removed = SSHAccount(username: "removed")
        let kept = SSHAccount(username: "kept")
        let original = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [renamed, removed, kept])
        var draft = original
        draft.accounts[0].username = "new"
        draft.accounts.remove(at: 1)
        draft.accounts.append(SSHAccount(username: "added"))
        let tabs = [
            TerminalTab(serverID: original.id, accountID: renamed.id, title: "open"),
            TerminalTab(serverID: original.id, accountID: renamed.id, title: "closed", isClosed: true),
            TerminalTab(serverID: original.id, accountID: removed.id, title: "removed", isClosed: true),
            TerminalTab(serverID: original.id, accountID: kept.id, title: "kept"),
            TerminalTab(serverID: UUID(), accountID: renamed.id, title: "another server")
        ]

        let impact = ProfileEditImpact(original: original, draft: draft, tabs: tabs)

        #expect(impact.requiresConfirmation)
        #expect(impact.changes.map(\.originalUsername) == ["old", "removed"])
        #expect(impact.changes.map(\.updatedUsername) == ["new", nil])
        #expect(impact.openTabCount == 1)
        #expect(impact.closedTabCount == 2)
        #expect(original.accounts.map(\.username) == ["old", "removed", "kept"])
        #expect(tabs.count == 5, "Preparing confirmation must preserve original tab records")
    }

    @Test func addingAccountsAndEditingServerDetailsNeedNoAccountRemovalConfirmation() {
        let account = SSHAccount(username: "kept")
        let original = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        var draft = original
        draft.host = "new.invalid"
        draft.accounts.append(SSHAccount(username: "added"))
        let impact = ProfileEditImpact(original: original, draft: draft, tabs: [])
        #expect(!impact.requiresConfirmation)
        #expect(impact.openTabCount == 0)
        #expect(impact.closedTabCount == 0)
        #expect(!ProfileEditImpact(original: nil, draft: draft, tabs: []).requiresConfirmation)
    }

    @Test func serverDeletionCountsOpenAndClosedRecordsOnlyForThatServer() {
        let account = SSHAccount(username: "fixture")
        let server = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        let impact = ServerDeletionImpact(server: server, tabs: [
            TerminalTab(serverID: server.id, accountID: account.id, title: "open"),
            TerminalTab(serverID: server.id, accountID: account.id, title: "closed", isClosed: true),
            TerminalTab(serverID: UUID(), accountID: account.id, title: "other")
        ])
        #expect(impact.openTabCount == 1)
        #expect(impact.closedTabCount == 1)
    }

    @Test func profileEditorHasNoPasswordStorageField() async throws {
        let domain = "ProfileEditorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = SSHAccount(username: "fixture")
        let profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        let editor = ProfileEditor(profile: profile, tabs: [TerminalTab(serverID: profile.id, accountID: account.id, title: "existing")]) { _ in }
            .environmentObject(AppearancePreferences(defaults: defaults))
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let fields = descendants(of: host).compactMap { $0 as? NSTextField }
        #expect(fields.filter { $0.isEditable }.count >= 3, "Server and account identity fields remain editable")
        let username = try #require(fields.first { $0.stringValue == "fixture" })
        #expect(username.isEnabled && username.isEditable, "An existing account remains editable when tabs use it")
        #expect(!fields.contains { $0 is NSSecureTextField }, "Password authentication is entered only in SSH's terminal prompt")
    }

    @Test func newEditorSavesAnAccountThatRequiresItsOwnKey() async throws {
        let domain = "ProfileEditorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var saved: ServerProfile?
        let host = NSHostingView(rootView: ProfileEditor(profile: nil, tabs: []) { saved = $0 }
            .environmentObject(AppearancePreferences(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let fields = descendants(of: host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        try #require(fields.count == 4)
        for (field, value) in zip(fields, ["Fresh", "fixture.invalid", "22", "fresh-user"]) {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor())
            editor.selectAll(nil)
            editor.insertText(value)
            window.makeFirstResponder(nil)
        }
        let saveKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(window.performKeyEquivalent(with: saveKey))
        for _ in 0..<100 {
            if saved != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let profile = try #require(saved)
        #expect(profile.name == "Fresh")
        #expect(profile.accounts.map(\.username) == ["fresh-user"])
        #expect(profile.accounts.allSatisfy { $0.authMethod == .pendingKey && $0.managedKey == nil })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
