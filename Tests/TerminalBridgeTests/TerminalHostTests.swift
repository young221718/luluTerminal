import Foundation
import AppKit
import GhosttyTerminal
import Testing
@testable import TerminalBridge

@MainActor struct TerminalHostTests {
    @Test func brandPaletteSurvivesDefaultDarkAndLightAppearance() throws {
        let host = TerminalHost()
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        let controller = try #require(host.view(for: id)?.controller)
        let navy = TerminalColor(red: 13, green: 23, blue: 37)
        #expect(controller.backgroundColor == navy, "Initial configuration keeps the host palette")
        controller.setColorScheme(.dark)
        #expect(controller.backgroundColor == navy, "Dark appearance keeps the host palette")
        controller.setColorScheme(.light)
        #expect(controller.backgroundColor == navy, "Light appearance keeps the host palette")
    }

    @Test func oldContainerTeardownDoesNotRemoveReparentedTerminal() {
        let a = TerminalContainer(), b = TerminalContainer()
        let view = TerminalView(frame: .zero)
        a.show(view)
        b.show(view)
        a.show(nil)
        #expect(view.superview === b)
        #expect(b.subviews.contains { $0 === view })
    }

    @Test func showingSameTerminalReclaimsDetachedView() {
        let a = TerminalContainer(), b = TerminalContainer()
        let view = TerminalView(frame: .zero)
        a.show(view)
        b.show(view)
        a.show(view)
        #expect(view.superview === a)
        b.show(nil)
        #expect(view.superview === a)
    }

    @Test func nativeShortcutsWorkWithKoreanInputAndCapsLock() {
        #expect(HostShortcut(characters: "ㅍ", keyCode: 9, modifiers: .command) == .paste)
        #expect(HostShortcut(characters: "ㅊ", keyCode: 8, modifiers: [.command, .capsLock]) == .copy)
        #expect(HostShortcut(characters: "ㅂ", keyCode: 12, modifiers: .command) == .quit)
        #expect(HostShortcut(characters: "V", keyCode: 9, modifiers: [.command, .capsLock]) == .paste)
    }

    @Test func terminalControlAndModifiedBindingsRemainAvailable() {
        #expect(HostShortcut(characters: "c", keyCode: 8, modifiers: .control) == nil)
        #expect(HostShortcut(characters: "v", keyCode: 9, modifiers: [.command, .shift]) == nil)
        #expect(HostShortcut(characters: "x", keyCode: 9, modifiers: .command) == nil)
    }

    @Test func selectingAnExistingTabRetainsItsSurface() {
        let host = TerminalHost()
        let id = UUID()
        host.open(id: id, command: "/bin/echo first")
        let first = host.view(for: id)
        host.open(id: id, command: "/bin/echo second")
        #expect(first != nil)
        #expect(first === host.view(for: id))
        host.disconnectAll()
    }

    @Test func disconnectReleasesOnlyTheNamedSurface() {
        let host = TerminalHost()
        let a = UUID(), b = UUID()
        host.open(id: a, command: "/bin/echo a")
        host.open(id: b, command: "/bin/echo b")
        host.disconnect(id: a)
        #expect(host.view(for: a) == nil)
        #expect(host.view(for: b) != nil)
        host.disconnectAll()
        #expect(host.view(for: b) == nil)
    }
}
