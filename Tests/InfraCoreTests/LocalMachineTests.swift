import Foundation
import Testing
@testable import InfraCore

struct LocalMachineCoreTests {
    @Test func legacyProfileWithoutKindStillDecodesAsSSH() throws {
        let account = SSHAccount(username: "trainer")
        let profile = ServerProfile(name: "Existing", host: "example.invalid", accounts: [account], monitorAccountID: account.id)
        let encoded = try JSONEncoder().encode(profile)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "kind")
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.kind == .ssh)
        #expect(decoded == profile)
    }

    @Test func ensuringLocalTwicePreservesClosedTabsAndSelection() throws {
        var state = WorkspaceState()
        state.ensureLocalMachine()
        let tab = try #require(state.tabs.first)
        state.close(tabID: tab.id)
        state.ensureLocalMachine()
        #expect(state.servers.count == 1)
        #expect(state.servers.first?.id == LocalMachine.serverID)
        #expect(state.tabs == [TerminalTab(id: tab.id, serverID: tab.serverID, accountID: tab.accountID, title: tab.title, isClosed: true)])
        #expect(state.selectedTabByServer[LocalMachine.serverID] == nil)
        try state.validate()
    }

    @Test func localInitialTabCollisionPreservesExistingRemoteTab() throws {
        let account = SSHAccount(username: "trainer")
        let remote = ServerProfile(name: "Existing", host: "example.invalid", accounts: [account])
        var state = WorkspaceState()
        state.servers = [remote]
        let original = TerminalTab(id: LocalMachine.initialTabID, serverID: remote.id, accountID: account.id, title: "Existing remote")
        try state.add(tab: original)
        state.ensureLocalMachine()
        #expect(state.tabs.contains(original))
        #expect(state.selectedTabByServer[remote.id] == original.id)
        #expect(Set(state.tabs.map(\.id)).count == state.tabs.count)
        try state.validate()
    }

    @Test func SSHBuildersRejectLocalProfilesAtEveryEntry() throws {
        let local = LocalMachine.profile
        let account = try #require(local.accounts.first)
        let tab = TerminalTab(serverID: local.id, accountID: account.id, title: "Local")
        #expect(throws: (any Error).self) { try SSHCommandBuilder.terminal(server: local, account: account, tab: tab, create: true) }
        #expect(throws: (any Error).self) { try SSHCommandBuilder.terminal(server: local, account: account, tab: tab, create: false) }
        #expect(throws: (any Error).self) { try SSHCommandBuilder.probe(server: local, account: account, tab: tab) }
        #expect(throws: (any Error).self) { try SSHCommandBuilder.monitor(server: local, account: account) }
    }

    @Test func localShellUsesLiteralHomeAndExecutableArguments() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("InfraLocalHome '\(UUID()) ; punctuation")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let shell = home.appendingPathComponent("fixture shell ' executable")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$HOME\" \"$1\"\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let command = try LocalMachine.terminal(shell: shell.path, home: home.path)
        #expect(command.executable == "/bin/sh")
        let result = try await ProcessRunner().run(command)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "\(home.path)\n\(home.path)\n-l\n")
    }

    @Test func localCPUUsesCounterDifferencesAndPreservesUnknownVsZero() {
        #expect(LocalMetricsCollector.cpuUsage(current: .init(total: 100, idle: 70), previous: nil) == nil)
        #expect(LocalMetricsCollector.cpuUsage(current: .init(total: 200, idle: 120), previous: .init(total: 100, idle: 70)) == 0.5)
        #expect(LocalMetricsCollector.cpuUsage(current: .init(total: 200, idle: 170), previous: .init(total: 100, idle: 70)) == 0)
        #expect(LocalMetricsCollector.cpuUsage(current: .init(total: 90, idle: 60), previous: .init(total: 100, idle: 70)) == nil)
        #expect(LocalMetricsCollector.cpuUsage(current: .init(total: 100, idle: 70), previous: .init(total: 100, idle: 70)) == nil)
        #expect(LocalMetricsCollector.cpuUsage(current: .init(total: 200, idle: 160), previous: .init(total: 100, idle: 140)) == nil)
    }

    @Test func nativeMetricsAreRealBoundedAndUnsupportedGPURemainsUnknown() throws {
        var collector = LocalMetricsCollector()
        let timestamp = Date()
        let snapshot = collector.collect(timestamp: timestamp)
        #expect(snapshot.timestamp == timestamp)
        #expect(snapshot.cpu == nil)
        #expect(snapshot.gpu == nil)
        #expect(snapshot.vram == nil)
        #expect(snapshot.network.isEmpty)
        let ram = try #require(snapshot.ram)
        let disk = try #require(snapshot.disk)
        #expect((0...1).contains(ram))
        #expect((0...1).contains(disk))
        #expect(snapshot.memoryTotalBytes == Double(ProcessInfo.processInfo.physicalMemory))
        #expect(snapshot.warnings.contains { $0.contains("캐시") })
    }
}
