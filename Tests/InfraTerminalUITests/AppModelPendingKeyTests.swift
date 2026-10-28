import Foundation
import InfraCore
import Testing
@testable import InfraTerminalUI

extension AppModelTests {
    @Test func pendingAccountCannotConnectOrCollectAfterRestart() async throws {
        let url = temporaryURL()
        let account = SSHAccount(username: "fixture", authMethod: .pendingKey)
        let profile = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account], monitorAccountID: account.id)
        let initial = AppModel(demo: false, storeURL: url, agentEnvironment: [:]) { _, _ in
            Issue.record("Pending setup must not execute a command")
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        try initial.saveProfile(profile)
        let tab = try initial.addTab(serverID: profile.id, accountID: account.id, title: "Pending")
        let model = AppModel(demo: false, storeURL: url, agentEnvironment: [:]) { _, _ in
            Issue.record("Pending setup must not execute a command")
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        #expect(model.workspace.servers.contains(profile))
        #expect(model.dueServerIDs(now: Date()).isEmpty)
        #expect(await model.prepareConnection(tabID: tab.id, create: true) == nil)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) == nil)
        #expect(await model.prepareConnection(tabID: tab.id, create: false, retryAuthentication: true, manualAuthentication: true) == nil)
        #expect(model.connections[tab.id] == .authenticationRequired("새 SSH 키 자동 설정을 완료하세요."))
        model.configureConnectionRecovery(enabled: true)
        #expect(model.beginConnectionRecovery().isEmpty)
        #expect(await model.prepareConnection(tabID: tab.id, create: false, automaticRecovery: true) == nil)
        #expect(try StateStore(url: url).load()?.servers.contains(profile) == true)
    }
}
