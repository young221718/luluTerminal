import Foundation
import Testing
import InfraCore
@testable import InfraTerminalUI

@MainActor struct MonitoringPreferencesTests {
    @Test func defaultsAndSelectionsSurviveReload() throws {
        let name = "MonitoringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preserved", forKey: "unrelated")
        let preferences = MonitoringPreferences(defaults: defaults)
        #expect(preferences.viewMode == .monitor)
        #expect(preferences.inspectorVisible)
        #expect(preferences.sidebarVisible)
        #expect(preferences.sidebarWidth == 190)
        #expect(preferences.inspectorWidth == 240)
        #expect(preferences.refreshInterval == 2)
        preferences.viewMode = .focus
        #expect(!preferences.inspectorVisible)
        #expect(!preferences.sidebarVisible)
        preferences.sidebarVisible = true
        preferences.sidebarWidth = 281
        preferences.inspectorWidth = 355
        preferences.inspectorVisible = true
        preferences.gpuStyle = .bars
        preferences.showNetwork = false
        preferences.enabled = false
        preferences.refreshInterval = 5
        let restored = MonitoringPreferences(defaults: defaults)
        #expect(restored.viewMode == .focus)
        #expect(restored.inspectorVisible)
        #expect(restored.sidebarVisible)
        #expect(restored.sidebarWidth == 281)
        #expect(restored.inspectorWidth == 355)
        #expect(restored.gpuStyle == .bars)
        #expect(!restored.showNetwork)
        #expect(!restored.enabled)
        #expect(restored.refreshInterval == 5)
        #expect(defaults.string(forKey: "unrelated") == "preserved")
    }

    @Test func invalidPersistedOptionsUseSafeDefaults() throws {
        let name = "MonitoringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("missing", forKey: "monitor.viewMode")
        defaults.set("missing", forKey: "monitor.gpuStyle")
        defaults.set(-20, forKey: "monitor.refreshInterval")
        let preferences = MonitoringPreferences(defaults: defaults)
        #expect(preferences.viewMode == .monitor)
        #expect(preferences.gpuStyle == .donuts)
        #expect(preferences.refreshInterval == 2)
        preferences.refreshInterval = .nan
        #expect(preferences.refreshInterval == 2)
        #expect(MonitoringPreferences(defaults: defaults).refreshInterval == 2)
    }

    @Test func legacyViewModesMigrateSidebarVisibilityWithoutOverridingSavedChoice() throws {
        for mode in WorkspaceViewMode.allCases {
            let name = "MonitoringTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(mode.rawValue, forKey: "monitor.viewMode")
            let preferences = MonitoringPreferences(defaults: defaults)
            #expect(preferences.sidebarVisible == (mode != .focus))
            #expect(defaults.object(forKey: "monitor.sidebarVisible") as? Bool == (mode != .focus))
            preferences.sidebarVisible.toggle()
            let restored = MonitoringPreferences(defaults: defaults)
            #expect(restored.sidebarVisible == (mode == .focus))
            #expect(restored.viewMode == mode)
        }
    }

    @Test func directPanelControlsPreserveModeAndResizedWidths() throws {
        let name = "MonitoringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MonitoringPreferences(defaults: defaults)
        preferences.sidebarWidth = 278
        preferences.inspectorWidth = 362
        preferences.sidebarVisible = false
        preferences.inspectorVisible = false
        #expect(preferences.viewMode == .monitor)
        preferences.sidebarVisible = true
        preferences.inspectorVisible = true
        #expect(preferences.sidebarWidth == 278)
        #expect(preferences.inspectorWidth == 362)
        preferences.viewMode = .focus
        #expect(!preferences.sidebarVisible)
        #expect(!preferences.inspectorVisible)
        preferences.viewMode = .compact
        #expect(preferences.sidebarVisible)
        #expect(!preferences.inspectorVisible)
        preferences.viewMode = .monitor
        #expect(preferences.sidebarVisible)
        #expect(preferences.inspectorVisible)
        let restored = MonitoringPreferences(defaults: defaults)
        #expect(restored.sidebarWidth == 278)
        #expect(restored.inspectorWidth == 362)
    }

    @Test func widthsClampToBoundsAndPersistCorrectedValues() throws {
        let name = "MonitoringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MonitoringPreferences.sidebarWidthRange == 160...320)
        #expect(MonitoringPreferences.inspectorWidthRange == 220...400)
        defaults.set(-25, forKey: "monitor.sidebarWidth")
        defaults.set(2_000, forKey: "monitor.inspectorWidth")
        let preferences = MonitoringPreferences(defaults: defaults)
        #expect(preferences.sidebarWidth == 160)
        #expect(preferences.inspectorWidth == 400)
        #expect(defaults.double(forKey: "monitor.sidebarWidth") == 160)
        #expect(defaults.double(forKey: "monitor.inspectorWidth") == 400)
        preferences.sidebarWidth = 999
        preferences.inspectorWidth = -1
        #expect(preferences.sidebarWidth == 320)
        #expect(preferences.inspectorWidth == 220)
        let restored = MonitoringPreferences(defaults: defaults)
        #expect(restored.sidebarWidth == 320)
        #expect(restored.inspectorWidth == 220)
    }

    @Test func nonFiniteWidthsUseDefaultsOnAssignmentAndReload() throws {
        let name = "MonitoringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MonitoringPreferences(defaults: defaults)
        for value in [Double.nan, .infinity, -.infinity] {
            preferences.sidebarWidth = value
            preferences.inspectorWidth = value
            #expect(preferences.sidebarWidth == 190)
            #expect(preferences.inspectorWidth == 240)
            defaults.set(value, forKey: "monitor.sidebarWidth")
            defaults.set(value, forKey: "monitor.inspectorWidth")
            let restored = MonitoringPreferences(defaults: defaults)
            #expect(restored.sidebarWidth == 190)
            #expect(restored.inspectorWidth == 240)
            #expect(defaults.double(forKey: "monitor.sidebarWidth") == 190)
            #expect(defaults.double(forKey: "monitor.inspectorWidth") == 240)
        }
    }

    @Test func monitoringControlsDoNotChangeTerminalConnections() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json")
        let model = AppModel(demo: false, storeURL: url) { _, _ in
            ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let account = SSHAccount(username: "tester")
        let server = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account], monitorAccountID: account.id)
        try model.saveProfile(server)
        let tab = try model.addTab(serverID: server.id, accountID: account.id, title: "Preserve")
        _ = await model.prepareConnection(tabID: tab.id, create: true)
        #expect(model.connections[tab.id] == .launched)
        model.configureMonitoring(enabled: false, selectedInterval: 5)
        #expect(model.dueServerIDs(now: Date()).isEmpty)
        let before = model.metrics
        model.tick(at: Date())
        #expect(model.metrics == before)
        #expect(model.connections[tab.id] == .launched)
        model.configureMonitoring(enabled: true, selectedInterval: 5)
        #expect(model.pollInterval(for: server.id) == 5)
        #expect(model.pollInterval(for: LocalMachine.serverID) == 10)
        #expect(model.dueServerIDs(now: Date()).contains(server.id))
        #expect(model.connections[tab.id] == .launched)
        model.configureMonitoring(enabled: true, selectedInterval: .infinity)
        #expect(model.pollInterval(for: server.id) == 2)
    }
}
