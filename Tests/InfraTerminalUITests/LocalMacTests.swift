import Foundation
import Testing
import InfraCore
@testable import InfraTerminalUI

@Suite @MainActor
struct LocalMacTests {
    @Test func emptyFirstRunPinsAndSelectsOneLocalMac() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        #expect(model.workspace.servers.count == 1)
        let local = try #require(model.workspace.servers.first)
        #expect(local.host == "localhost")
        #expect(model.selectedServer?.id == local.id)
        #expect(model.selectedTab?.serverID == local.id)
    }

    @Test func loadingAnExistingWorkspacePreservesRemoteChoiceAndTabs() throws {
        let url = temporaryURL()
        let account = SSHAccount(username: "trainer")
        let remote = ServerProfile(name: "Existing", host: "example.invalid", accounts: [account], monitorAccountID: account.id)
        var original = WorkspaceState()
        original.servers = [remote]
        let tab = TerminalTab(serverID: remote.id, accountID: account.id, title: "Preserved")
        try original.add(tab: tab)
        try StateStore(url: url).save(original)
        let bytesBefore = try Data(contentsOf: url)
        let model = AppModel(demo: false, storeURL: url)
        #expect(model.workspace.servers.count == 2)
        #expect(model.workspace.servers.last == remote)
        #expect(model.selectedServer?.id == remote.id)
        #expect(model.selectedTab?.id == tab.id)
        #expect(model.workspace.tabs.contains(tab))
        #expect(try Data(contentsOf: url) == bytesBefore)
        model.selectTab(tab.id)
        let reloaded = AppModel(demo: false, storeURL: url)
        #expect(reloaded.workspace.servers.count == 2)
        #expect(reloaded.workspace.tabs.filter { $0.serverID == remote.id } == [tab])
        #expect(reloaded.selectedTab?.id == tab.id)
    }

    @Test func localConnectionAndCollectionNeverExecuteSSH() async throws {
        let recorder = LocalCommandRecorder()
        let model = AppModel(demo: false, storeURL: temporaryURL()) { command, _ in await recorder.run(command) }
        let tab = try #require(model.selectedTab)
        let command = try #require(await model.prepareConnection(tabID: tab.id, create: false))
        #expect(command.executable != "/usr/bin/ssh")
        #expect(!command.shellString.contains("tmux"))
        #expect(command.arguments.contains(LocalMachine.loginShell))
        #expect(command.arguments.contains(LocalMachine.homeDirectory))
        model.tick(at: Date())
        #expect(model.dueServerIDs(now: Date()).isEmpty)
        #expect(model.metrics[LocalMachine.serverID] != nil)
        #expect(model.collectionErrors[LocalMachine.serverID] == nil)
        #expect(await recorder.commands.isEmpty)
        #expect(ResourceMetric.ram.caption(model.metrics[LocalMachine.serverID], local: true).contains("캐시"))
        #expect(ResourceMetric.gpu.caption(nil, local: true).contains("미지원"))
    }

    @Test func localTabsCloseReopenAndReloadWithoutPretendingSessionPersistence() async throws {
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url)
        let initial = try #require(model.selectedTab)
        let second = try model.addTab(serverID: LocalMachine.serverID, accountID: LocalMachine.accountID, title: "Second local")
        model.closeTab(initial.id)
        model.reopenTab(initial.id)
        #expect(model.selectedTab?.id == initial.id)
        #expect(await model.prepareConnection(tabID: initial.id, create: false) != nil)
        model.selectTab(second.id)
        let loaded = AppModel(demo: false, storeURL: url)
        #expect(loaded.workspace.servers.filter { $0.kind == .local }.count == 1)
        #expect(loaded.tabs(for: LocalMachine.serverID).map(\.id) == [initial.id, second.id])
        #expect(loaded.selectedTab?.id == second.id)
        #expect(loaded.connections.isEmpty)
        let newShell = try #require(await loaded.prepareConnection(tabID: second.id, create: false))
        #expect(!newShell.shellString.contains("tmux"))
    }

    @Test func ordinaryProfileEditingCannotChangeLocalIdentity() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        var local = try #require(model.workspace.servers.first)
        local.name = "Changed"
        #expect(throws: (any Error).self) { try model.saveProfile(local) }
        #expect(model.workspace.servers.first == LocalMachine.profile)
    }

    @Test func demoKeepsRealLocalSeparateFromTenFakeServers() async throws {
        let recorder = LocalCommandRecorder()
        let model = AppModel(demo: true, storeURL: temporaryURL()) { command, _ in await recorder.run(command) }
        #expect(model.workspace.servers.first?.kind == .local)
        #expect(model.workspace.servers.filter { $0.kind == .ssh }.count == 10)
        model.selectServer(LocalMachine.serverID)
        let tab = try #require(model.selectedTab)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        model.tick(at: Date())
        #expect(model.metrics[LocalMachine.serverID]?.gpu == nil)
        #expect(await recorder.commands.isEmpty)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("InfraTerminalLocalTests-\(UUID())/state.json")
    }
}

private actor LocalCommandRecorder {
    private(set) var commands: [ShellCommand] = []
    func run(_ command: ShellCommand) -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitCode: 255, stdout: "", stderr: "Local path must not execute a remote command")
    }
}
