import Foundation
import InfraCore
import SwiftUI
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

    @Test func nativeBeforeAndEndMapToSingleAtomicMoves() throws {
        guard #available(macOS 27, *) else { return }
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url)
        let first = profile("First"), second = profile("Second")
        try model.saveProfile(first)
        try model.saveProfile(second)
        let original = model.workspace
        let before = try #require(ServerReorderMove(sources: [second.id], destination: .before(first.id),
                                                   serverIDs: model.workspace.servers.map(\.id)))
        #expect(before.id == second.id && before.targetID == first.id && !before.after)
        #expect(try model.moveServer(before.id, relativeTo: before.targetID, after: before.after))
        #expect(model.workspace.servers.map(\.id) == [LocalMachine.serverID, second.id, first.id])
        let end = try #require(ServerReorderMove(sources: [second.id], destination: .end,
                                                serverIDs: model.workspace.servers.map(\.id)))
        #expect(end.id == second.id && end.targetID == first.id && end.after)
        #expect(try model.moveServer(end.id, relativeTo: end.targetID, after: end.after))
        #expect(model.workspace == original)
        #expect(AppModel(demo: false, storeURL: url).workspace == original)
    }

    @Test func nativeMovesAcrossBothEndsUseTheCurrentOrder() throws {
        guard #available(macOS 27, *) else { return }
        let first = UUID(), middle = UUID(), last = UUID()
        let order = [first, middle, last]
        let toFirst = try #require(ServerReorderMove(sources: [last], destination: .before(first), serverIDs: order))
        #expect(toFirst.id == last && toFirst.targetID == first && !toFirst.after)
        let toMiddle = try #require(ServerReorderMove(sources: [first], destination: .before(last), serverIDs: order))
        #expect(toMiddle.id == first && toMiddle.targetID == last && !toMiddle.after)
        let toEnd = try #require(ServerReorderMove(sources: [first], destination: .end, serverIDs: order))
        #expect(toEnd.id == first && toEnd.targetID == last && toEnd.after)
    }

    @Test func nativeInvalidSourcesAndStaleTargetsRejectTheWholeMove() {
        guard #available(macOS 27, *) else { return }
        let first = UUID(), second = UUID(), removed = UUID()
        let order = [first, second]
        #expect(ServerReorderMove(sources: [], destination: .end, serverIDs: order) == nil)
        #expect(ServerReorderMove(sources: [removed], destination: .end, serverIDs: order) == nil)
        #expect(ServerReorderMove(sources: [first, second], destination: .end, serverIDs: order) == nil)
        #expect(ServerReorderMove(sources: [first, first], destination: .end, serverIDs: order) == nil)
        #expect(ServerReorderMove(sources: [first], destination: .before(removed), serverIDs: order) == nil)
        #expect(ServerReorderMove(sources: [first], destination: .end, serverIDs: []) == nil)
        #expect(ServerReorderMove(sources: [first], destination: .end, serverIDs: [first, second, first]) == nil)
    }

    @Test func nativeUnchangedDestinationsDoNotProduceAMove() {
        guard #available(macOS 27, *) else { return }
        let first = UUID(), second = UUID()
        let order = [first, second]
        #expect(ServerReorderMove(sources: [first], destination: .before(first), serverIDs: order) == nil)
        #expect(ServerReorderMove(sources: [first], destination: .before(second), serverIDs: order) == nil)
        #expect(ServerReorderMove(sources: [second], destination: .end, serverIDs: order) == nil)
        #expect(ServerReorderMove(sources: [first], destination: .end, serverIDs: [first]) == nil)
    }

    private func profile(_ name: String) -> ServerProfile {
        ServerProfile(name: name, host: "fixture.invalid", accounts: [SSHAccount(username: "fixture")])
    }
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ServerOrderTests-\(UUID().uuidString)/workspace.json")
    }
}
