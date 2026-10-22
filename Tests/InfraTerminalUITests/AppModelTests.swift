import Testing
import Foundation
@testable import InfraTerminalUI
import InfraCore

@Suite @MainActor
struct AppModelTests {
    @Test func testDemoHasTenServersAndNeverSchedulesRemotePolling() throws {
        let model = AppModel(demo: true, storeURL: temporaryURL())
        #expect(model.workspace.servers.filter { $0.kind == .ssh }.count == 10)
        #expect(model.workspace.servers.first?.kind == .local)
        #expect(model.isDemo)
        #expect(model.dueServerIDs(now: Date()).isEmpty)
        #expect(model.metrics.values.contains { $0.gpu == 0 })
        #expect(model.metrics.values.contains { $0.gpu == nil })
    }

    @Test func testCorruptStateIsPreservedAndSavingRemainsBlocked() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not workspace JSON".utf8)
        try original.write(to: url)
        let model = AppModel(demo: false, storeURL: url)
        #expect(model.persistenceError != nil)
        #expect(model.persistenceBlocked)
        #expect(throws: (any Error).self) { try model.saveProfile(server()) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func testUsernameChangeCannotRetargetAnExistingTab() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        let profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Training")
        model.closeTab(tab.id)
        var changed = profile
        changed.accounts[0].username = "someone-else"
        #expect(throws: (any Error).self) { try model.saveProfile(changed) }
        #expect(model.workspace.servers.first { $0.id == profile.id }?.accounts.first?.username == "trainer")
        #expect(model.workspace.tabs.first { $0.id == tab.id }?.accountID == profile.accounts[0].id)
    }

    @Test func testSelectionAndClosedTabSurviveReload() throws {
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url)
        let profile = server()
        try model.saveProfile(profile)
        let first = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "First")
        let second = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Second")
        model.selectTab(first.id)
        model.closeTab(second.id)
        let loaded = AppModel(demo: false, storeURL: url)
        #expect(loaded.selectedTab?.id == first.id)
        #expect(loaded.workspace.tabs.first { $0.id == second.id }?.isClosed == true)
    }

    @Test func testSchedulerUsesSelectedIntervalAndBoundedSlots() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        for index in 0..<5 {
            var profile = server()
            profile.name = "Server \(index)"
            try model.saveProfile(profile)
        }
        let now = Date()
        #expect(model.dueServerIDs(now: now).count == 3)
        #expect(model.dueServerIDs(now: now).first == model.selectedServer?.id)
        #expect(model.pollInterval(for: model.selectedServer!.id) == 2)
        #expect(model.pollInterval(for: model.workspace.servers.first!.id) == 10)
    }

    @Test func testRepeatedFailuresDoNotStarveUnattemptedServers() async throws {
        let model = AppModel(demo: false, storeURL: temporaryURL()) { _, _ in
            ProcessResult(exitCode: 255, stdout: "", stderr: "fixture failure")
        }
        for index in 0..<10 {
            var profile = server()
            profile.name = "Server \(index)"
            try model.saveProfile(profile)
        }
        let time = Date()
        let firstIDs = Set(model.dueServerIDs(now: time))
        model.tick(at: time)
        try await waitUntil { model.collectionErrors.count == 3 }
        let secondIDs = model.dueServerIDs(now: time.addingTimeInterval(16))
        #expect(secondIDs.first == model.selectedServer?.id)
        #expect(secondIDs.filter { !firstIDs.contains($0) }.count == 2)
    }

    @Test func testSuspendedCollectorsRemainBoundedWithoutOverlappingServers() async throws {
        let collector = SuspendedCollector()
        let model = AppModel(demo: false, storeURL: temporaryURL()) { command, _ in
            await collector.run(command)
        }
        for index in 0..<10 {
            var profile = server()
            profile.host = "server-\(index).invalid"
            try model.saveProfile(profile)
        }
        let time = Date()
        model.tick(at: time)
        for _ in 0..<500 {
            if await collector.commands.count == 3 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        model.tick(at: time.addingTimeInterval(20))
        let commands = await collector.commands
        #expect(commands.count == 3)
        #expect(Set(commands.map { $0.arguments.joined(separator: " ") }).count == 3)
        #expect(model.dueServerIDs(now: time.addingTimeInterval(20)).isEmpty)
        await collector.releaseAll()
        try await waitUntil { model.collectionErrors.count == 3 }
        model.stop()
    }

    @Test func testMissingSessionRequiresExplicitCreation() async throws {
        let model = AppModel(demo: false, storeURL: temporaryURL()) { _, _ in
            ProcessResult(exitCode: 44, stdout: "", stderr: "")
        }
        let profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Retained")
        #expect(await model.prepareConnection(tabID: tab.id, create: false) == nil)
        #expect(model.connections[tab.id] == .missing)
        let explicitCreation = await model.prepareConnection(tabID: tab.id, create: true)
        #expect(explicitCreation != nil)
        #expect(model.connections[tab.id] == .launched)
    }

    @Test func testProbe255OffersExplicitInteractiveAuthentication() async throws {
        let recorder = FailedProbeRecorder()
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url) { command, _ in
            await recorder.run(command)
        }
        let profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Password account")
        let originalWorkspace = model.workspace
        let originalFile = try Data(contentsOf: url)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) == nil)
        #expect(model.connections[tab.id]?.label.contains("터미널에서 인증") == true)
        #expect(await recorder.commands.count == 1)

        let interactive = await model.prepareConnection(tabID: tab.id, create: false, probeExisting: false)
        let expected = try SSHCommandBuilder.terminal(server: profile, account: profile.accounts[0], tab: tab, create: false)
        #expect(interactive?.shellString == expected.shellString)
        #expect(model.connections[tab.id] == .launched)
        #expect(await recorder.commands.count == 1)
        #expect(model.workspace == originalWorkspace)
        #expect(try Data(contentsOf: url) == originalFile)
    }

    @Test func testDemoInteractiveReconnectDoesNotExecuteAuthentication() async throws {
        let recorder = FailedProbeRecorder()
        let model = AppModel(demo: true, storeURL: temporaryURL()) { command, _ in await recorder.run(command) }
        let tab = try #require(model.selectedTab)
        #expect(await model.prepareConnection(tabID: tab.id, create: false, probeExisting: false) == nil)
        #expect(await recorder.commands.isEmpty)
    }

    @Test func testStoppingInvalidatesPendingReconnect() async throws {
        let collector = SuspendedCollector()
        let model = AppModel(demo: false, storeURL: temporaryURL()) { command, _ in
            await collector.run(command)
        }
        let profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Pending")
        let connection = Task { await model.prepareConnection(tabID: tab.id, create: false) }
        for _ in 0..<500 {
            if await collector.commands.count == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        model.stop()
        await collector.releaseAll()
        #expect(await connection.value == nil)
        #expect(model.connections[tab.id] == .disconnected)
    }

    @Test func testProfileEndpointChangeDiscardsPriorMetricsAndHistory() throws {
        let model = AppModel(demo: true, storeURL: temporaryURL())
        model.tick(at: Date())
        var profile = try #require(model.workspace.servers.first { $0.kind == .ssh })
        #expect(model.metrics[profile.id] != nil)
        #expect(model.histories[profile.id]?.isEmpty == false)
        profile.host = "different-target.invalid"
        try model.saveProfile(profile)
        #expect(model.metrics[profile.id] == nil)
        #expect(model.histories[profile.id] == nil)
        #expect(model.collectionErrors[profile.id] == nil)
    }

    @Test func testDisplayRenameRetainsSameTargetMeasurements() throws {
        let model = AppModel(demo: true, storeURL: temporaryURL())
        model.tick(at: Date())
        var profile = try #require(model.workspace.servers.first { $0.kind == .ssh })
        let originalMetrics = model.metrics[profile.id]
        let originalHistory = model.histories[profile.id]
        profile.name = "Renamed display"
        try model.saveProfile(profile)
        #expect(model.metrics[profile.id] == originalMetrics)
        #expect(model.histories[profile.id] == originalHistory)
    }

    @Test func testUnknownDetailValuesRemainDistinctFromZero() {
        #expect(percentage(nil) == "확인 불가")
        #expect(percentage(0) != percentage(nil))
        #expect(bytePair(nil, nil) == "— / —")
        #expect(rateText(nil) == "—")
        #expect(rateText(0) != rateText(nil))
    }

    @Test func testTitleAndOrderChangesPreserveRemoteSessionIdentity() throws {
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url)
        let profile = server()
        try model.saveProfile(profile)
        let first = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "First")
        let second = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Second")
        model.renameTab(first.id, title: "Renamed")
        model.moveTab(second.id, by: -1)
        let loaded = AppModel(demo: false, storeURL: url)
        #expect(loaded.tabs(for: profile.id).map(\.id) == [second.id, first.id])
        #expect(loaded.workspace.tabs.first { $0.id == first.id }?.sessionName == first.sessionName)
        #expect(loaded.workspace.tabs.first { $0.id == first.id }?.title == "Renamed")
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

    private func server() -> ServerProfile {
        let account = SSHAccount(username: "trainer")
        return ServerProfile(name: "GPU", host: "example.invalid", accounts: [account], monitorAccountID: account.id)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("InfraTerminalUITests-\(UUID())/state.json")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(predicate(), "Collector tasks did not finish within the bounded wait")
    }
}

private actor SuspendedCollector {
    private let exitCode: Int32
    private let stdout: String
    init(exitCode: Int32 = 255, stdout: String = "") { self.exitCode = exitCode; self.stdout = stdout }
    private(set) var commands: [ShellCommand] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    func run(_ command: ShellCommand) async -> ProcessResult {
        commands.append(command)
        await withCheckedContinuation { pending.append($0) }
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: "fixture failure")
    }
    func releaseAll() {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private actor FailedProbeRecorder {
    private(set) var commands: [ShellCommand] = []
    func run(_ command: ShellCommand) -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitCode: 255, stdout: "", stderr: "fixture: interactive authentication required")
    }
}

private final class TestPasswordStore: PasswordCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: String] = [:]
    private var savedIDs: [UUID] = []
    private var deletedIDs: [UUID] = []
    var failSave = false
    var saved: [UUID] { lock.withLock { savedIDs } }
    var deleted: [UUID] { lock.withLock { deletedIDs } }
    func save(_ password: String, reference: SSHPasswordReference) throws {
        try lock.withLock {
            if failSave { throw CocoaError(.fileWriteNoPermission) }
            entries[reference.id] = password
            savedIDs.append(reference.id)
        }
    }
    func read(reference: SSHPasswordReference) throws -> String {
        try lock.withLock {
            guard let value = entries[reference.id] else { throw CocoaError(.fileNoSuchFile) }
            return value
        }
    }
    func delete(reference: SSHPasswordReference) throws {
        lock.withLock { entries[reference.id] = nil; deletedIDs.append(reference.id) }
    }
}

private let passwordFixture: SSHCommandExecutor = { command, timeout in
    ProcessResult(exitCode: 0, stdout: "hostname example.invalid\nuser trainer\nport 22\nproxyjump none\nproxycommand none\n", stderr: "")
}

private actor PasswordFailureRecorder {
    private(set) var commands: [ShellCommand] = []
    func run(_ command: ShellCommand) -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitCode: 255, stdout: "", stderr: "fixture SSH failure")
    }
}
