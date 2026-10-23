import Testing
import Foundation
@testable import InfraTerminalUI
import InfraCore

extension AppModelTests {
    @Test func testSelectingSystemAuthenticationPreservesDormantPasswordReference() async throws {
        let store = TestPasswordStore()
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url, credentialStore: store, execute: passwordFixture)
        var profile = server()
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"])
        var saved = try #require(model.workspace.servers.first { $0.id == profile.id })
        let reference = saved.accounts[0].credential
        saved.accounts[0].authMethod = .system
        try await model.saveProfile(saved, passwords: [:])
        let loaded = AppModel(demo: false, storeURL: url)
        #expect(loaded.workspace.servers.first { $0.id == profile.id }?.accounts[0].credential == reference)
        #expect(store.deleted.isEmpty)
    }

    @Test func testPasswordSaveKeepsSecretOutOfStateAndPreservesSessionIdentity() async throws {
        let store = TestPasswordStore()
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url, credentialStore: store, helperPath: "/usr/bin/true", execute: passwordFixture)
        var profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Retained")
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret-only"])
        let saved = try #require(model.workspace.servers.first { $0.id == profile.id })
        #expect(saved.accounts[0].credential != nil)
        #expect(store.saved.count == 1)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("fixture-secret-only"))
        #expect(model.workspace.tabs.first { $0.id == tab.id }?.sessionName == tab.sessionName)
        try await model.saveProfile(saved, passwords: [:])
        #expect(store.saved.count == 1)
    }

    @Test func testPasswordStoreFailurePreservesPriorProfileAndCredential() async throws {
        let store = TestPasswordStore()
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url, credentialStore: store, helperPath: "/usr/bin/true", execute: passwordFixture)
        var profile = server()
        try model.saveProfile(profile)
        profile.accounts[0].authMethod = .password
        store.failSave = true
        await #expect(throws: (any Error).self) { try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"]) }
        #expect(model.workspace.servers.first { $0.id == profile.id }?.accounts[0].authMethod == .system)
        #expect(store.saved.isEmpty)
        #expect(store.deleted.isEmpty)
    }

    @Test func testStateWriteFailureRollsBackOnlyNewCredential() async throws {
        let store = TestPasswordStore()
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url, credentialStore: store, helperPath: "/usr/bin/true", execute: passwordFixture)
        var profile = server()
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "first-fixture-secret"])
        let originalState = model.workspace
        let originalReference = try #require(originalState.servers.first { $0.id == profile.id }?.accounts[0].credential)
        let corrupt = Data("preserve corrupt state".utf8)
        try corrupt.write(to: url)
        await #expect(throws: (any Error).self) { try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "replacement-fixture-secret"]) }
        #expect(model.workspace == originalState)
        #expect(try Data(contentsOf: url) == corrupt)
        #expect(!store.deleted.contains(originalReference.id))
        #expect(store.deleted.count == 1)
    }

    @Test func testEndpointChangeRequiresNewPasswordAndDemoNeverWritesKeychain() async throws {
        let store = TestPasswordStore()
        let model = AppModel(demo: false, storeURL: temporaryURL(), credentialStore: store, helperPath: "/usr/bin/true", execute: passwordFixture)
        var profile = server()
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"])
        var saved = try #require(model.workspace.servers.first { $0.id == profile.id })
        saved.host = "new-target.invalid"
        await #expect(throws: (any Error).self) { try await model.saveProfile(saved, passwords: [:]) }
        #expect(store.saved.count == 1)
        let demo = AppModel(demo: true, storeURL: temporaryURL(), credentialStore: store, helperPath: "/usr/bin/true", execute: passwordFixture)
        var demoProfile = try #require(demo.workspace.servers.first { $0.kind == .ssh })
        demoProfile.accounts[0].authMethod = .password
        await #expect(throws: (any Error).self) { try await demo.saveProfile(demoProfile, passwords: [demoProfile.accounts[0].id: "do-not-save"]) }
        #expect(store.saved.count == 1)
    }

    @Test func testPasswordFailureStopsPollingUntilExplicitRetry() async throws {
        let store = TestPasswordStore()
        let recorder = PasswordFailureRecorder()
        let model = AppModel(demo: false, storeURL: temporaryURL(), credentialStore: store, helperPath: "/usr/bin/true") { command, timeout in
            if command.arguments.contains("-G") { return try await passwordFixture(command, timeout) }
            return await recorder.run(command)
        }
        var profile = server()
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"])
        model.tick(at: Date())
        try await waitUntil { model.collectionErrors[profile.id] != nil }
        #expect(model.dueServerIDs(now: Date().addingTimeInterval(120)).isEmpty)
        #expect(await recorder.commands.count == 1)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Retry")
        #expect(await model.prepareConnection(tabID: tab.id, create: true) == nil)
        #expect(await recorder.commands.count == 1)
        #expect(await model.prepareConnection(tabID: tab.id, create: true, retryAuthentication: true) == nil)
        #expect(await recorder.commands.count == 2)
        #expect(model.connections[tab.id]?.label.contains("SSH 연결 확인 필요") == true)
    }

    @Test func testKeychainDenialPausesCollectionWithoutRequestingANewPassword() async throws {
        let store = TestPasswordStore()
        let recorder = PasswordFailureRecorder(stderr: SSHPasswordAuthentication.keychainAccessRequiredMarker)
        let model = AppModel(demo: false, storeURL: temporaryURL(), credentialStore: store, helperPath: "/usr/bin/true") { command, timeout in
            if command.arguments.contains("-G") { return try await passwordFixture(command, timeout) }
            return await recorder.run(command)
        }
        var profile = server()
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"])
        model.tick(at: Date())
        try await waitUntil { model.collectionErrors[profile.id] != nil }
        #expect(model.collectionErrors[profile.id]?.contains("키체인 접근 허용") == true)
        #expect(model.dueServerIDs(now: Date().addingTimeInterval(120)).isEmpty)
        #expect(await recorder.commands.count == 1)
        #expect(store.saved.count == 1 && store.deleted.isEmpty)
    }

    @Test func testOnlyExplicitPasswordConnectionsMayAskForKeychainAccess() async throws {
        let store = TestPasswordStore()
        let recorder = PasswordSuccessRecorder()
        let model = AppModel(demo: false, storeURL: temporaryURL(), credentialStore: store, helperPath: "/usr/bin/true") { command, timeout in
            if command.arguments.contains("-G") { return try await passwordFixture(command, timeout) }
            return await recorder.run(command)
        }
        var profile = server()
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"])
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Retained")
        let terminal = try #require(await model.prepareConnection(tabID: tab.id, create: false))
        #expect(await recorder.commands.first?.environment["LULUTERMINAL_KEYCHAIN_UI"] == "allow")
        #expect(terminal.environment["LULUTERMINAL_KEYCHAIN_UI"] == "allow")
        model.tick(at: Date().addingTimeInterval(30))
        try await waitUntil { model.collectionErrors[profile.id] != nil }
        let commands = await recorder.commands
        #expect(commands.count == 2)
        #expect(commands.last?.standardInput == LinuxCollector.script)
        #expect(commands.last?.environment["LULUTERMINAL_KEYCHAIN_UI"] == "fail")
    }

    @Test func testPasswordProbeWaitsForCollectorAndManualFallbackDoesNotRetrySecret() async throws {
        let store = TestPasswordStore()
        let collector = SuspendedCollector()
        let model = AppModel(demo: false, storeURL: temporaryURL(), credentialStore: store, helperPath: "/usr/bin/true") { command, timeout in
            if command.arguments.contains("-G") { return try await passwordFixture(command, timeout) }
            return await collector.run(command)
        }
        var profile = server()
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"])
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Retained")
        model.tick(at: Date())
        for _ in 0..<500 {
            if await collector.commands.count == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let connection = Task { await model.prepareConnection(tabID: tab.id, create: true) }
        await Task.yield()
        #expect(await collector.commands.count == 1)
        await collector.releaseAll()
        #expect(await connection.value == nil)
        #expect(await collector.commands.count == 1)
        let manual = try #require(await model.prepareConnection(tabID: tab.id, create: false, probeExisting: false, manualAuthentication: true))
        #expect(manual.environment["SSH_ASKPASS_REQUIRE"] == "never")
        #expect(!manual.arguments.contains("PreferredAuthentications=password"))
        #expect(await collector.commands.count == 1)
    }

    @Test func testRemovingSavedPasswordDeletesOnlyAfterSuccessfulStateSave() async throws {
        let store = TestPasswordStore()
        let model = AppModel(demo: false, storeURL: temporaryURL(), credentialStore: store, helperPath: "/usr/bin/true", execute: passwordFixture)
        var profile = server()
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"])
        var saved = try #require(model.workspace.servers.first { $0.id == profile.id })
        let reference = try #require(saved.accounts[0].credential)
        saved.accounts[0].authMethod = .system
        saved.accounts[0].credential = nil
        #expect(store.deleted.isEmpty)
        try await model.saveProfile(saved, passwords: [:])
        #expect(store.deleted == [reference.id])
        #expect(model.workspace.servers.first { $0.id == profile.id }?.accounts[0].credential == nil)
    }

    @Test func testInvalidAndBlockedProfileNeverWritesCredential() async throws {
        let store = TestPasswordStore()
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserve original".utf8).write(to: url)
        let blocked = AppModel(demo: false, storeURL: url, credentialStore: store, helperPath: "/usr/bin/true", execute: passwordFixture)
        var profile = server()
        profile.accounts[0].authMethod = .password
        await #expect(throws: (any Error).self) { try await blocked.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"]) }
        let normal = AppModel(demo: false, storeURL: temporaryURL(), credentialStore: store, helperPath: "/usr/bin/true", execute: passwordFixture)
        profile.port = 0
        await #expect(throws: (any Error).self) { try await normal.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"]) }
        #expect(store.saved.isEmpty)
        #expect(store.deleted.isEmpty)
    }

    @Test func testSecondPasswordTabBusyDoesNotPauseSuccessfulAuthentication() async throws {
        let store = TestPasswordStore()
        let collector = SuspendedCollector(exitCode: 0)
        let model = AppModel(demo: false, storeURL: temporaryURL(), credentialStore: store, helperPath: "/usr/bin/true") { command, timeout in
            if command.arguments.contains("-G") { return try await passwordFixture(command, timeout) }
            return await collector.run(command)
        }
        var profile = server()
        profile.accounts[0].authMethod = .password
        try await model.saveProfile(profile, passwords: [profile.accounts[0].id: "fixture-secret"])
        let first = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "First")
        let second = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Second")
        let pending = Task { await model.prepareConnection(tabID: first.id, create: true) }
        for _ in 0..<500 {
            if await collector.commands.count == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await model.prepareConnection(tabID: second.id, create: true) == nil)
        #expect(model.connections[second.id]?.label.contains("잠시 후") == true)
        #expect(await collector.commands.count == 1)
        await collector.releaseAll()
        #expect(await pending.value != nil)
        #expect(model.dueServerIDs(now: Date().addingTimeInterval(120)).contains(profile.id))
        model.terminalExited(first.id)
        #expect(!model.dueServerIDs(now: Date().addingTimeInterval(120)).contains(profile.id))
    }

    @Test func testStopDuringPasswordTargetResolutionNeverStartsAuthentication() async throws {
        let configuration = SuspendedCollector(exitCode: 0, stdout: "hostname example.invalid\nuser trainer\nport 22\nproxyjump none\nproxycommand none\n")
        let authentication = PasswordFailureRecorder()
        let model = AppModel(demo: false, storeURL: temporaryURL(), credentialStore: TestPasswordStore(), helperPath: "/usr/bin/true") { command, _ in
            if command.arguments.contains("-G") { return await configuration.run(command) }
            return await authentication.run(command)
        }
        var profile = server()
        profile.accounts[0].authMethod = .password
        profile.accounts[0].credential = SSHPasswordReference(target: SSHPasswordTarget(server: profile, account: profile.accounts[0], resolvedHost: "example.invalid"))
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Cancelled")
        let connection = Task { await model.prepareConnection(tabID: tab.id, create: true) }
        for _ in 0..<500 {
            if await configuration.commands.count == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        model.stop()
        await configuration.releaseAll()
        #expect(await connection.value == nil)
        #expect(await authentication.commands.isEmpty)
        #expect(model.connections[tab.id] == .disconnected)
    }
}

private let passwordFixture: SSHCommandExecutor = { command, timeout in
    ProcessResult(exitCode: 0, stdout: "hostname example.invalid\nuser trainer\nport 22\nproxyjump none\nproxycommand none\n", stderr: "")
}

private actor PasswordFailureRecorder {
    private let stderr: String
    init(stderr: String = "fixture SSH failure") { self.stderr = stderr }
    private(set) var commands: [ShellCommand] = []
    func run(_ command: ShellCommand) -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitCode: 255, stdout: "", stderr: stderr)
    }
}

private actor PasswordSuccessRecorder {
    private(set) var commands: [ShellCommand] = []
    func run(_ command: ShellCommand) -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
