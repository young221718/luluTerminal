import Testing
import Foundation
@testable import InfraTerminalUI
import InfraCore

extension AppModelTests {
    @Test func testLegacySavedPasswordMigratesWithoutCommandsOrSessionIdentityLoss() async throws {
        let url = temporaryURL()
        let original = AppModel(demo: false, storeURL: url)
        let profile = server()
        try original.saveProfile(profile)
        let open = try original.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Keep session")
        let closed = try original.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Keep closed")
        original.closeTab(closed.id)
        original.selectTab(open.id)
        let expected = original.workspace
        let legacy = try legacyPasswordState(try Data(contentsOf: url), serverID: profile.id)
        try legacy.write(to: url)
        let recorder = AuthenticationCommandRecorder()
        let migrated = AppModel(demo: false, storeURL: url) { command, _ in await recorder.run(command) }
        #expect(!migrated.persistenceBlocked)
        #expect(migrated.workspace == expected)
        #expect(try Data(contentsOf: url) == legacy, "Loading must not overwrite the original file")
        #expect(await recorder.commands.isEmpty, "Migration must never request credentials or start SSH")
        try migrated.saveProfile(try #require(migrated.workspace.servers.first { $0.id == profile.id }))
        let saved = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!saved.contains("credential"))
        #expect(!saved.contains("legacy-reference"))
        let reloaded = AppModel(demo: false, storeURL: url)
        #expect(reloaded.workspace == expected)
    }

    @Test func testLegacyDormantPasswordMetadataDoesNotOverrideManagedKey() throws {
        let url = temporaryURL()
        let original = AppModel(demo: false, storeURL: url)
        var profile = server()
        profile.accounts[0].authMethod = .managedKey
        profile.accounts[0].managedKey = SSHManagedKeyReference(target: SSHConnectionTarget(server: profile, account: profile.accounts[0], resolvedHost: "example.invalid"))
        try original.saveProfile(profile)
        let legacy = try legacyPasswordState(try Data(contentsOf: url), serverID: profile.id, authMethod: "managedKey")
        try legacy.write(to: url)
        let migrated = AppModel(demo: false, storeURL: url)
        #expect(!migrated.persistenceBlocked)
        #expect(migrated.workspace.servers.contains(profile))
        try migrated.saveProfile(profile)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("credential"))
    }

    @Test func testMigratedAccountCanAuthenticateInteractivelyAfterFailedProbe() async throws {
        let url = temporaryURL()
        let original = AppModel(demo: false, storeURL: url)
        let profile = server()
        try original.saveProfile(profile)
        let tab = try original.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Interactive")
        try legacyPasswordState(try Data(contentsOf: url), serverID: profile.id).write(to: url)
        let recorder = AuthenticationCommandRecorder()
        let migrated = AppModel(demo: false, storeURL: url) { command, _ in await recorder.run(command) }
        #expect(await migrated.prepareConnection(tabID: tab.id, create: false) == nil)
        #expect(migrated.connections[tab.id]?.label.contains("SSH 연결 확인 필요") == true)
        let terminal = try #require(await migrated.prepareConnection(tabID: tab.id, create: false, manualAuthentication: true))
        #expect(terminal.arguments.contains("UseKeychain=no"))
        #expect(terminal.environment["SSH_ASKPASS_REQUIRE"] == "never")
        #expect(!terminal.arguments.contains("BatchMode=yes"))
        #expect(await recorder.commands.count == 1, "Manual terminal authentication must skip the noninteractive probe")
        #expect(terminal.arguments.last?.contains(tab.sessionName) == true)
    }

    @Test func testProfileWriteFailurePreservesPriorStateAndOriginalBytes() throws {
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url)
        var profile = server()
        try model.saveProfile(profile)
        let original = model.workspace
        let corrupt = Data("preserve corrupt state".utf8)
        try corrupt.write(to: url)
        profile.name = "Changed alias"
        #expect(throws: (any Error).self) { try model.saveProfile(profile) }
        #expect(model.workspace == original)
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func testManagedProbeWaitsForCollectorAndPausesAfterAuthenticationFailure() async throws {
        let collector = SuspendedCollector()
        let model = managedFixture(collector: collector)
        let profile = try managedProfile(model: model)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Retained")
        model.tick(at: Date())
        for _ in 0..<500 {
            if await collector.commands.count == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(await collector.commands.count == 1)
        let connection = Task { await model.prepareConnection(tabID: tab.id, create: true) }
        await Task.yield()
        #expect(await collector.commands.count == 1)
        await collector.releaseAll()
        #expect(await connection.value == nil)
        #expect(await collector.commands.count == 1)
        #expect(!model.dueServerIDs(now: Date().addingTimeInterval(120)).contains(profile.id))
        model.stop()
    }

    @Test func testSecondManagedTabBusyDoesNotPauseSuccessfulAuthentication() async throws {
        let collector = SuspendedCollector(exitCode: 0)
        let model = managedFixture(collector: collector)
        let profile = try managedProfile(model: model)
        let first = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "First")
        let second = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Second")
        let pending = Task { await model.prepareConnection(tabID: first.id, create: true) }
        for _ in 0..<500 {
            if await collector.commands.count == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(await collector.commands.count == 1)
        #expect(await model.prepareConnection(tabID: second.id, create: true) == nil)
        #expect(model.connections[second.id]?.label.contains("잠시 후") == true)
        await collector.releaseAll()
        #expect(await pending.value != nil)
        #expect(model.dueServerIDs(now: Date().addingTimeInterval(120)).contains(profile.id))
        model.terminalExited(first.id)
        #expect(model.dueServerIDs(now: Date().addingTimeInterval(120)).contains(profile.id))
        model.stop()
    }

    @Test func testStopDuringManagedTargetResolutionNeverStartsAuthentication() async throws {
        let configuration = SuspendedCollector(exitCode: 0, stdout: "hostname example.invalid\nuser trainer\nport 22\nproxyjump none\nproxycommand none\n")
        let authentication = AuthenticationCommandRecorder()
        let model = AppModel(demo: false, storeURL: temporaryURL(), agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in
            if command.arguments.contains("-G") { return await configuration.run(command) }
            return await authentication.run(command)
        }
        let profile = try managedProfile(model: model)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Cancelled")
        let connection = Task { await model.prepareConnection(tabID: tab.id, create: true) }
        for _ in 0..<500 {
            if await configuration.commands.count == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(await configuration.commands.count == 1)
        model.stop()
        await configuration.releaseAll()
        #expect(await connection.value == nil)
        #expect(await authentication.commands.isEmpty)
        #expect(model.connections[tab.id] == .disconnected)
    }

    private func managedFixture(collector: SuspendedCollector) -> AppModel {
        AppModel(demo: false, storeURL: temporaryURL(), agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in
            if command.arguments.contains("-G") { return ProcessResult(exitCode: 0, stdout: "hostname example.invalid\nuser trainer\nport 22\nproxyjump none\nproxycommand none\n", stderr: "") }
            if command.executable == "/usr/bin/ssh-add" { return ProcessResult(exitCode: 0, stdout: "fixture identity", stderr: "") }
            return await collector.run(command)
        }
    }

    private func managedProfile(model: AppModel) throws -> ServerProfile {
        var profile = server()
        profile.accounts[0].authMethod = .managedKey
        profile.accounts[0].managedKey = SSHManagedKeyReference(target: SSHConnectionTarget(server: profile, account: profile.accounts[0], resolvedHost: "example.invalid"))
        try model.saveProfile(profile)
        return profile
    }

    private func legacyPasswordState(_ data: Data, serverID: UUID, authMethod: String = "password") throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var servers = try #require(object["servers"] as? [[String: Any]])
        let index = try #require(servers.firstIndex { ($0["id"] as? String)?.lowercased() == serverID.uuidString.lowercased() })
        var accounts = try #require(servers[index]["accounts"] as? [[String: Any]])
        accounts[0]["authMethod"] = authMethod
        accounts[0]["credential"] = ["id": "legacy-reference", "target": ["host": "example.invalid"]]
        servers[index]["accounts"] = accounts
        object["servers"] = servers
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private actor AuthenticationCommandRecorder {
    private(set) var commands: [ShellCommand] = []
    func run(_ command: ShellCommand) -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitCode: 255, stdout: "", stderr: "trainer@example.invalid: Permission denied (publickey,password).")
    }
}
