import AppKit
import SwiftUI
import InfraCore
import Testing
@testable import InfraTerminalUI

@MainActor struct ProfileEditorTests {
    @Test func profileEditorHasNoPasswordStorageField() async throws {
        let domain = "ProfileEditorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = SSHAccount(username: "fixture")
        let profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        let editor = ProfileEditor(profile: profile, lockedAccountIDs: []) { _ in }
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
        #expect(!fields.contains { $0 is NSSecureTextField }, "Password authentication is entered only in SSH's terminal prompt")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
