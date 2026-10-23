import Foundation
import InfraCore
import Testing
@testable import InfraTerminalUI

@MainActor struct ServerOrderTests {
    @Test func orderSurvivesReloadWithoutChangingTabsSelectionOrConnections() async throws {
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url) { _, _ in
            ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let first = profile("First"), second = profile("Second")
        try model.saveProfile(first)
        try model.saveProfile(second)
        let tab = try model.addTab(serverID: first.id, accountID: first.accounts[0].id, title: "Retained")
        _ = await model.prepareConnection(tabID: tab.id, create: false)
        let original = model.workspace
        let connections = model.connections
        #expect(try model.moveServer(first.id, relativeTo: second.id, after: true))
        #expect(model.workspace.servers.map(\.id) == [LocalMachine.serverID, second.id, first.id])
        #expect(try model.moveServer(second.id, relativeTo: LocalMachine.serverID, after: false))
        #expect(model.workspace.servers.map(\.id) == [second.id, LocalMachine.serverID, first.id])
        #expect(model.workspace.tabs == original.tabs)
        #expect(model.workspace.selectedServerID == original.selectedServerID)
        #expect(model.workspace.selectedTabByServer == original.selectedTabByServer)
        #expect(model.connections == connections)
        let loaded = AppModel(demo: false, storeURL: url)
        #expect(loaded.workspace == model.workspace)
    }

    @Test func invalidOrUnchangedDropsDoNotWriteState() throws {
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url)
        let server = profile("Remote")
        try model.saveProfile(server)
        let original = try Data(contentsOf: url)
        #expect(try !model.moveServer(UUID(), relativeTo: server.id, after: false))
        #expect(try !model.moveServer(server.id, relativeTo: UUID(), after: true))
        #expect(try !model.moveServer(server.id, relativeTo: server.id, after: false))
        #expect(try !model.moveServer(server.id, relativeTo: LocalMachine.serverID, after: true))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func failedSavePreservesTheDisplayedOrderAndExistingFile() throws {
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url)
        let server = profile("Remote")
        try model.saveProfile(server)
        let original = model.workspace
        let corrupt = Data("preserve this unreadable state".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) {
            try model.moveServer(server.id, relativeTo: LocalMachine.serverID, after: false)
        }
        #expect(model.workspace == original)
        #expect(model.persistenceError != nil)
        #expect(try Data(contentsOf: url) == corrupt)
    }

    private func profile(_ name: String) -> ServerProfile {
        ServerProfile(name: name, host: "fixture.invalid", accounts: [SSHAccount(username: "fixture")])
    }
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ServerOrderTests-\(UUID().uuidString)/workspace.json")
    }
}
