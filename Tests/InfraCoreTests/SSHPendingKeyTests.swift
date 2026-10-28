import Foundation
import Testing
@testable import InfraCore

struct SSHPendingKeyTests {
    @Test func pendingStatePersistsAndRefusesEverySSHConnectionPath() throws {
        let account = SSHAccount(username: "fixture", authMethod: .pendingKey)
        let server = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account], monitorAccountID: account.id)
        let tab = TerminalTab(serverID: server.id, accountID: account.id, title: "Fixture")
        let encoded = try JSONEncoder().encode(account)
        #expect(try JSONDecoder().decode(SSHAccount.self, from: encoded) == account)
        #expect(throws: (any Error).self) { try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: true) }
        #expect(throws: (any Error).self) { try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: false) }
        #expect(throws: (any Error).self) { try SSHCommandBuilder.probe(server: server, account: account, tab: tab) }
        #expect(throws: (any Error).self) { try SSHCommandBuilder.monitor(server: server, account: account) }
    }
}
