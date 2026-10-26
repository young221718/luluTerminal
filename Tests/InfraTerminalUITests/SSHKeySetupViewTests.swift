import AppKit
import SwiftUI
import InfraCore
import Testing
@testable import InfraTerminalUI

@MainActor struct SSHKeySetupViewTests {
    @Test func automaticSetupPasswordFieldAcceptsNativeFocusAndUserInput() async throws {
        let domain = "SSHKeySetupViewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel(demo: false, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/state.json")) { _, _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let account = SSHAccount(username: "fixture")
        let server = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        try model.saveProfile(server)
        let view = SSHKeySetupView(model: model, request: SSHKeySetupRequest(serverID: server.id, accountID: account.id))
            .environmentObject(AppearancePreferences(defaults: defaults))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let field = try #require(descendants(of: host).compactMap { $0 as? NSSecureTextField }.first,
                                 "New SSH setup must present a native secure password field")
        #expect(field.isEditable && field.isEnabled)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor())
        editor.insertText("synthetic-input-42")
        #expect(editor.string == "synthetic-input-42", "The focused native password editor accepts user input")
        window.makeFirstResponder(nil)
        #expect(field.stringValue == "synthetic-input-42")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
