import Testing
import Foundation
@testable import InfraTerminalUI
import InfraCore

@Suite @MainActor
struct AppModelTests {
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
}

private actor FailedProbeRecorder {
    private(set) var commands: [ShellCommand] = []
    func run(_ command: ShellCommand) -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitCode: 255, stdout: "", stderr: "fixture: interactive authentication required")
    }
}
