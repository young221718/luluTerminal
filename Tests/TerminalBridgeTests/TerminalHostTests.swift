import Foundation
import AppKit
import GhosttyTerminal
import Testing
@testable import TerminalBridge

@MainActor struct TerminalHostTests {
    @Test func terminalDefaultsToLightAndAdaptsToBothAppearances() throws {
        let host = TerminalHost()
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        let controller = try #require(host.view(for: id)?.controller)
        let originalView = host.view(for: id)
        let charcoal = TerminalColor(red: 24, green: 27, blue: 32)
        let light = TerminalColor(red: 255, green: 255, blue: 255)
        #expect(controller.backgroundColor == light, "New terminals default to light")
        #expect(controller.renderedConfig.split(separator: "\n").contains("minimum-contrast = 4.5"),
                "Light terminals keep ANSI foregrounds readable without rewriting palette backgrounds")
        #expect(controller.lastConfigurationIssue == nil)
        #expect(controller.renderedConfig.split(separator: "\n").contains("keybind = super+comma=unbind"),
                "The embedded terminal must release Command-comma to the native Settings menu")
        host.setColorScheme(.dark)
        #expect(controller.backgroundColor == charcoal, "Dark appearance keeps the host palette")
        host.setColorScheme(.light)
        #expect(controller.backgroundColor == light, "Light appearance updates the palette")
        #expect(host.view(for: id) === originalView, "Changing appearance retains the terminal view")
        #expect(host.view(for: id)?.controller === controller)
        let secondID = UUID()
        host.setColorScheme(.dark)
        host.open(id: secondID, command: "/usr/bin/true")
        #expect(host.view(for: secondID)?.controller?.backgroundColor == charcoal)
        #expect(host.view(for: id) === originalView)
    }

    @Test func customColorsAndFontUpdateEveryCachedViewWithoutReplacingItsOptions() throws {
        let host = TerminalHost()
        let firstID = UUID(), secondID = UUID()
        host.open(id: firstID, command: "/usr/bin/true")
        host.open(id: secondID, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        let first = try #require(host.view(for: firstID))
        let second = try #require(host.view(for: secondID))
        let controller = try #require(first.controller)
        let firstOptions = first.configuration
        let secondOptions = second.configuration
        let custom = TerminalStyle(light: .init(background: 0xF4EEE3, foreground: 0x302A25, accent: 0x8C4D35),
                                   dark: .init(background: 0x24201D, foreground: 0xEFE8DE, accent: 0xCD9777),
                                   fontFamily: "Monaco", fontSize: 19)
        host.setStyle(custom)
        #expect(controller.backgroundColor == TerminalColor(red: 244, green: 238, blue: 227))
        var lines = controller.renderedConfig.split(separator: "\n")
        #expect(lines.contains("foreground = 302A25"))
        #expect(lines.contains("cursor-color = 8C4D35"))
        #expect(lines.filter { $0.hasPrefix("font-family = ") } == ["font-family = Monaco"],
                "Font family must replace the old family instead of adding a fallback after Menlo")
        #expect(lines.contains("font-size = 19"))
        #expect(controller.lastConfigurationIssue == nil)
        #expect(controller.renderedConfig.split(separator: "\n").contains("keybind = super+comma=unbind"),
                "The embedded terminal must release Command-comma to the native Settings menu")
        host.setColorScheme(.dark)
        #expect(controller.backgroundColor == TerminalColor(red: 36, green: 32, blue: 29))
        lines = controller.renderedConfig.split(separator: "\n")
        #expect(lines.contains("foreground = EFE8DE"))
        #expect(lines.contains("cursor-color = CD9777"))
        #expect(lines.contains("minimum-contrast = 4.5"))
        #expect(host.view(for: firstID) === first)
        #expect(host.view(for: secondID) === second)
        #expect(first.controller === controller && second.controller === controller)
        for (view, options) in [(first, firstOptions), (second, secondOptions)] {
            #expect(view.configuration.fontSize == options.fontSize,
                    "Surface font size is part of PTY identity and must remain unchanged")
            #expect(view.configuration.command == options.command)
            #expect(view.configuration.envVars == options.envVars)
            #expect(view.configuration.waitAfterCommand == options.waitAfterCommand)
        }
        let rendered = controller.renderedConfig
        host.setStyle(custom)
        #expect(controller.renderedConfig == rendered)
        let thirdID = UUID()
        host.open(id: thirdID, command: "/usr/bin/true")
        #expect(host.view(for: thirdID)?.controller === controller)
        #expect(controller.renderedConfig.contains("font-family = Monaco"))
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
        #expect(HostShortcut(characters: ",", keyCode: 43, modifiers: .command) == .settings)
        #expect(HostShortcut(characters: "ㅂ", keyCode: 43, modifiers: .command) == .settings)
    }

    @Test func terminalControlAndModifiedBindingsRemainAvailable() {
        #expect(HostShortcut(characters: "c", keyCode: 8, modifiers: .control) == nil)
        #expect(HostShortcut(characters: "v", keyCode: 9, modifiers: [.command, .shift]) == nil)
        #expect(HostShortcut(characters: "x", keyCode: 9, modifiers: .command) == nil)
        #expect(HostShortcut(characters: ",", keyCode: 43, modifiers: [.command, .shift]) == nil)
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

    @Test func commandEnvironmentReachesSurfaceWithoutReplacingExistingTab() throws {
        let host = TerminalHost()
        let id = UUID()
        let environment = ["SSH_ASKPASS": "/Applications/luluTerminal.app/Contents/Helpers/luluTerminalAskPass", "SSH_ASKPASS_REQUIRE": "force"]
        host.open(id: id, command: "/usr/bin/true", environment: environment)
        defer { host.disconnectAll() }
        let view = try #require(host.view(for: id))
        #expect(view.configuration.envVars["TERM"] == "xterm-256color")
        #expect(view.configuration.envVars["SSH_ASKPASS"] == environment["SSH_ASKPASS"])
        #expect(view.configuration.envVars["SSH_ASKPASS_REQUIRE"] == "force")
        host.open(id: id, command: "/usr/bin/false", environment: [:])
        #expect(host.view(for: id) === view)
        #expect(view.configuration.envVars["SSH_ASKPASS_REQUIRE"] == "force")
    }

    @Test func terminalExitReleasesItsViewAfterTheNativeCallbackReturns() async throws {
        let host = TerminalHost()
        let exitedID = UUID(), liveID = UUID()
        host.open(id: exitedID, command: "/usr/bin/true")
        host.open(id: liveID, command: "/usr/bin/true")
        defer { host.disconnectAll() }
        weak var released = host.view(for: exitedID)
        var notifications: [UUID] = []
        host.onExit = { notifications.append($0) }
        let callback = try #require(host.view(for: exitedID)?.delegate as? any TerminalSurfaceCloseDelegate)
        callback.terminalDidClose(processAlive: false)
        #expect(host.view(for: exitedID) != nil, "Native callback must finish before freeing its surface")
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(host.view(for: exitedID) == nil)
        #expect(released == nil)
        #expect(host.view(for: liveID) != nil)
        #expect(notifications == [exitedID])
    }

    @Test func delayedExitCannotDisconnectAReplacementWithTheSameTabID() async throws {
        let host = TerminalHost()
        let id = UUID()
        host.open(id: id, command: "/usr/bin/true")
        let callback = try #require(host.view(for: id)?.delegate as? any TerminalSurfaceCloseDelegate)
        var notifications: [UUID] = []
        host.onExit = { notifications.append($0) }
        callback.terminalDidClose(processAlive: false)
        host.disconnect(id: id)
        host.open(id: id, command: "/bin/echo replacement")
        let replacement = host.view(for: id)
        defer { host.disconnectAll() }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(host.view(for: id) === replacement)
        #expect(notifications.isEmpty)
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
