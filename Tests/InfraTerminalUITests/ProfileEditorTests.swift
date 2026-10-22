import AppKit
import SwiftUI
import InfraCore
import Testing
@testable import InfraTerminalUI

@MainActor struct ProfileEditorTests {
    @Test func passwordEntryHasAVisibleFullWidthClickTarget() async throws {
        let domain = "ProfileEditorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = SSHAccount(username: "fixture", authMethod: .password)
        let profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        let editor = ProfileEditor(profile: profile, lockedAccountIDs: []) { _, _ in }
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
        let field = try #require(descendants(of: host).compactMap { $0 as? NSSecureTextField }.first)
        let bounds = field.convert(field.bounds, to: host)
        #expect(field.isEnabled && field.isEditable)
        #expect(bounds.minX <= 80, "The password row's left side must be an editable target, not an inert label")
        #expect(bounds.width >= 400, "The input must span the account row")
        #expect(field.isBezeled || field.isBordered, "The editable region must have a visible boundary")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
