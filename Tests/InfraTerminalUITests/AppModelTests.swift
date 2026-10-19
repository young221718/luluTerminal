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
        try model.saveProfile(server())
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
    private(set) var commands: [ShellCommand] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    func run(_ command: ShellCommand) async -> ProcessResult {
        commands.append(command)
        await withCheckedContinuation { pending.append($0) }
        return ProcessResult(exitCode: 255, stdout: "", stderr: "fixture failure")
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
