import AppKit
import Testing
@testable import InfraTerminalUI

@MainActor struct ConnectionLifecycleTests {
    @Test func initialPathAndDuplicateEventsDoNotReconnect() async throws {
        let lifecycle = ConnectionLifecycle(center: NotificationCenter(), observeNetwork: false, delay: .milliseconds(5))
        var restored = 0
        var interrupted = 0
        lifecycle.onRestored = { restored += 1 }
        lifecycle.onInterrupted = { interrupted += 1 }
        lifecycle.start()
        lifecycle.receivePath(available: true, signature: "wifi")
        lifecycle.receivePath(available: true, signature: "wifi")
        lifecycle.receiveWake()
        try await Task.sleep(for: .milliseconds(30))
        #expect(restored == 0)
        #expect(interrupted == 0)
        lifecycle.stop()
    }

    @Test func sleepAndNetworkReturnCoalesceAndWaitForNetwork() async throws {
        let center = NotificationCenter()
        let lifecycle = ConnectionLifecycle(center: center, observeNetwork: false, delay: .milliseconds(5))
        var restored = 0
        lifecycle.onRestored = { restored += 1 }
        lifecycle.start()
        lifecycle.receivePath(available: true, signature: "wifi")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        lifecycle.receivePath(available: false, signature: "")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(restored == 0)
        lifecycle.receivePath(available: true, signature: "wifi")
        lifecycle.receivePath(available: true, signature: "ethernet")
        try await waitUntil { restored == 1 }
        #expect(restored == 1)
        lifecycle.stop()
    }

    @Test func routeChangeInterruptsButStoppedCallbacksCannotRecover() async throws {
        let center = NotificationCenter()
        let lifecycle = ConnectionLifecycle(center: center, observeNetwork: false, delay: .milliseconds(5))
        var interrupted = 0
        var restored = 0
        lifecycle.onInterrupted = { interrupted += 1 }
        lifecycle.onRestored = { restored += 1 }
        lifecycle.start()
        lifecycle.start()
        lifecycle.receivePath(available: true, signature: "wifi")
        lifecycle.receivePath(available: true, signature: "ethernet")
        #expect(interrupted == 1)
        lifecycle.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        lifecycle.receivePath(available: true, signature: "wifi")
        try await Task.sleep(for: .milliseconds(30))
        #expect(restored == 0)
        #expect(interrupted == 1)
        lifecycle.start()
        lifecycle.receivePath(available: true, signature: "wifi")
        lifecycle.receiveSleep()
        lifecycle.receiveWake()
        try await waitUntil { restored == 1 }
        #expect(restored == 1)
        lifecycle.stop()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func recoveryPreferenceDefaultsOffAndSurvivesReload() throws {
        let name = "ConnectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preserved", forKey: "unrelated")
        let preferences = ConnectionPreferences(defaults: defaults)
        #expect(!preferences.automaticallyReconnect)
        preferences.automaticallyReconnect = true
        #expect(ConnectionPreferences(defaults: defaults).automaticallyReconnect)
        #expect(defaults.string(forKey: "unrelated") == "preserved")
        preferences.automaticallyReconnect = false
        #expect(!ConnectionPreferences(defaults: defaults).automaticallyReconnect)
    }
}
