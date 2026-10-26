import Testing
import Foundation
@testable import InfraTerminalUI
import InfraCore

extension AppModelTests {
    @Test func testRemovingAccountDiscardsOnlyItsOpenAndClosedTabsAndRepairsSelection() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        var profile = server()
        let retained = SSHAccount(username: "retained")
        profile.accounts.append(retained)
        try model.saveProfile(profile)
        let kept = try model.addTab(serverID: profile.id, accountID: retained.id, title: "Keep")
        let closed = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Closed")
        model.closeTab(closed.id)
        let removed = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Remove")
        profile.accounts.removeFirst()
        try model.saveProfile(profile)
        #expect(model.workspace.tabs.filter { $0.serverID == profile.id } == [kept])
        #expect(model.selectedTab?.id == kept.id)
        #expect(model.selectedServer?.monitorAccountID == retained.id)
        #expect(model.connections[closed.id] == nil)
        model.terminalExited(removed.id)
        #expect(model.connections[removed.id] == nil)
        #expect(try StateStore(url: model.storeURL).load() == model.workspace)
    }

    @Test func testRenamedManagedAccountDropsKeyBindingButPreservesOtherAccounts() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        var profile = server()
        let reference = SSHManagedKeyReference(target: SSHConnectionTarget(server: profile, account: profile.accounts[0], resolvedHost: profile.host))
        profile.accounts[0].authMethod = .managedKey
        profile.accounts[0].managedKey = reference
        let retained = SSHAccount(username: "retained")
        profile.accounts.append(retained)
        try model.saveProfile(profile)
        profile.accounts[0].username = "renamed"
        try model.saveProfile(profile)
        let saved = try #require(model.selectedServer)
        #expect(saved.accounts[0].id != profile.accounts[0].id)
        #expect(saved.accounts[0].authMethod == .system)
        #expect(saved.accounts[0].managedKey == nil)
        #expect(saved.accounts[1] == retained)
        #expect(saved.monitorAccountID == saved.accounts[0].id)
    }

    @Test func testRemovingLastAccountOrEditingLocalMachinePreservesState() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        var profile = server()
        try model.saveProfile(profile)
        let before = model.workspace
        profile.accounts.removeAll()
        #expect(throws: (any Error).self) { try model.saveProfile(profile) }
        var local = try #require(model.workspace.servers.first { $0.kind == .local })
        local.name = "Changed"
        #expect(throws: (any Error).self) { try model.saveProfile(local) }
        #expect(model.workspace == before)
    }

    @Test func testFailedAccountSavePreservesWorkspaceAndPendingConnection() async throws {
        let collector = SuspendedCollector(exitCode: 0)
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url) { command, _ in await collector.run(command) }
        var profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Pending")
        let connection = Task { await model.prepareConnection(tabID: tab.id, create: false) }
        try await waitForCommands(collector, count: 1)
        let before = model.workspace
        try Data("corrupt fixture".utf8).write(to: url)
        profile.accounts[0].username = "changed"
        #expect(throws: (any Error).self) { try model.saveProfile(profile) }
        #expect(model.workspace == before)
        #expect(model.connections[tab.id] == .checking)
        await collector.releaseAll()
        #expect(await connection.value != nil)
        #expect(model.connections[tab.id] == .launched)
        #expect(try String(contentsOf: url, encoding: .utf8) == "corrupt fixture")
    }

    @Test func testAccountRemovalInvalidatesPendingConnection() async throws {
        let collector = SuspendedCollector(exitCode: 0)
        let model = AppModel(demo: false, storeURL: temporaryURL()) { command, _ in await collector.run(command) }
        var profile = server()
        profile.accounts.append(SSHAccount(username: "retained"))
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Pending")
        let connection = Task { await model.prepareConnection(tabID: tab.id, create: false) }
        try await waitForCommands(collector, count: 1)
        profile.accounts.removeFirst()
        try model.saveProfile(profile)
        await collector.releaseAll()
        #expect(await connection.value == nil)
        model.terminalExited(tab.id)
        #expect(model.connections[tab.id] == nil)
        #expect(!model.workspace.tabs.contains { $0.id == tab.id })
    }

    @Test func testServerDeletionRemovesTabsAndCacheAndSelectsRemainingServer() async throws {
        let model = AppModel(demo: true, storeURL: temporaryURL())
        let removed = try #require(model.workspace.servers.first { $0.kind == .ssh })
        let tabIDs = model.workspace.tabs.filter { $0.serverID == removed.id }.map(\.id)
        model.closeTab(try #require(tabIDs.first))
        model.selectServer(removed.id)
        try model.deleteServer(removed.id)
        #expect(!model.workspace.servers.contains { $0.id == removed.id })
        #expect(!model.workspace.tabs.contains { $0.serverID == removed.id })
        #expect(model.workspace.selectedTabByServer[removed.id] == nil)
        #expect(model.selectedServer != nil)
        #expect(model.selectedServer?.id != removed.id)
        #expect(model.metrics[removed.id] == nil)
        #expect(model.histories[removed.id] == nil)
        #expect(model.collectionErrors[removed.id] == nil)
        for id in tabIDs {
            model.terminalExited(id)
            #expect(model.connections[id] == nil)
        }
        try model.workspace.validate()
    }

    @Test func testServerDeletionPersistsAndProtectsLocalMachine() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        let profile = server()
        try model.saveProfile(profile)
        try model.deleteServer(profile.id)
        #expect(model.selectedServer?.id == LocalMachine.serverID)
        #expect(try StateStore(url: model.storeURL).load() == model.workspace)
        let before = model.workspace
        #expect(throws: (any Error).self) { try model.deleteServer(LocalMachine.serverID) }
        #expect(model.workspace == before)
    }

    @Test func testFailedServerDeletionPreservesPendingConnectionAndFile() async throws {
        let collector = SuspendedCollector(exitCode: 0)
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url) { command, _ in await collector.run(command) }
        let profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Pending")
        let pending = Task { await model.prepareConnection(tabID: tab.id, create: false) }
        try await waitForCommands(collector, count: 1)
        let before = model.workspace
        try Data("preserve fixture".utf8).write(to: url)
        #expect(throws: (any Error).self) { try model.deleteServer(profile.id) }
        #expect(model.workspace == before)
        #expect(model.connections[tab.id] == .checking)
        await collector.releaseAll()
        #expect(await pending.value != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "preserve fixture")
    }

    @Test func testDeletedServerCannotReturnFromPendingConnectionOrMonitoring() async throws {
        let collector = SuspendedCollector(exitCode: 0)
        let model = AppModel(demo: false, storeURL: temporaryURL()) { command, _ in await collector.run(command) }
        let profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Pending")
        let pending = Task { await model.prepareConnection(tabID: tab.id, create: false) }
        model.tick(at: Date())
        try await waitForCommands(collector, count: 2)
        try model.deleteServer(profile.id)
        await collector.releaseAll()
        #expect(await pending.value == nil)
        await Task.yield()
        model.terminalExited(tab.id)
        #expect(model.connections[tab.id] == nil)
        #expect(model.metrics[profile.id] == nil)
        #expect(model.collectionErrors[profile.id] == nil)
        #expect(!model.workspace.servers.contains { $0.id == profile.id })
    }

    @Test func testDeletedServerInvalidatesKeySetupEvenAfterSameProfileIsRegisteredAgain() async throws {
        let model = AppModel(demo: false, storeURL: temporaryURL(), agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in
            if command.arguments.contains("-G") {
                return ProcessResult(exitCode: 0, stdout: "hostname example.invalid\nuser trainer\nport 22\nproxyjump none\nproxycommand none\n", stderr: "")
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let profile = server()
        try model.saveProfile(profile)
        let setup = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        try model.deleteServer(profile.id)
        try model.saveProfile(profile)
        await #expect(throws: (any Error).self) { try await model.verifyAndApplySSHKeySetup(setup) }
        let replacement = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        model.cancelSSHKeySetup(replacement.id)
        #expect(model.workspace.servers.contains(profile))
    }

    @Test func testRawStateStoreStillRejectsRetargetingExistingAccountIdentity() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        let profile = server()
        try model.saveProfile(profile)
        _ = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Retain identity")
        let before = try Data(contentsOf: model.storeURL)
        var raw = model.workspace
        let index = try #require(raw.servers.firstIndex { $0.id == profile.id })
        raw.servers[index].accounts[0].username = "retargeted"
        #expect(throws: CoreError.accountIdentityChanged) { try StateStore(url: model.storeURL).save(raw) }
        #expect(try Data(contentsOf: model.storeURL) == before)
    }

    @Test(arguments: ["edit", "delete", "delete-and-register-again"])
    func testCanceledCollectorsKeepTheirSlotsUntilExecutorReturns(action: String) async throws {
        let collector = SuspendedCollector()
        let model = AppModel(demo: false, storeURL: temporaryURL()) { command, _ in await collector.run(command) }
        var profiles: [ServerProfile] = []
        for index in 0..<4 {
            var profile = server()
            profile.host = "collector-\(index).invalid"
            profiles.append(profile)
            try model.saveProfile(profile)
        }
        let time = Date()
        model.tick(at: time)
        try await waitForCommands(collector, count: 3)
        var changed = try #require(profiles.last)
        switch action {
        case "edit":
            changed.accounts[0].username = "changed"
            try model.saveProfile(changed)
        case "delete":
            try model.deleteServer(changed.id)
        default:
            try model.deleteServer(changed.id)
            try model.saveProfile(changed)
        }
        // Cancellation does not mean an executor has returned: all three slots remain occupied.
        #expect(model.dueServerIDs(now: time.addingTimeInterval(30)).isEmpty)
        #expect(await collector.commands.count == 3)
        await collector.releaseAll()
        try await waitUntil { model.dueServerIDs(now: time.addingTimeInterval(30)).count == 3 }
        model.tick(at: time.addingTimeInterval(30))
        try await waitForCommands(collector, count: 6)
        let replacementCommands = Array(await collector.commands.suffix(3))
        #expect(Set(replacementCommands.map { $0.arguments }).count == 3)
        model.stop()
        await collector.releaseAll()
    }

    private func waitForCommands(_ collector: SuspendedCollector, count: Int) async throws {
        for _ in 0..<500 {
            if await collector.commands.count >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await collector.commands.count >= count)
    }
}
