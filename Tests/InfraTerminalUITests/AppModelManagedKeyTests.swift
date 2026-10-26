import Testing
import Foundation
@testable import InfraTerminalUI
import InfraCore

extension AppModelTests {
    @Test func testNaturalManagedTerminalExitKeepsMonitoringAvailable() async throws {
        let fixture = ManagedKeyFixture(sessionProbeExitCode: 0)
        let model = AppModel(demo: false, storeURL: temporaryURL(), agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in await fixture.run(command) }
        let profile = server()
        try model.saveProfile(profile)
        let setup = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        try await model.verifyAndApplySSHKeySetup(setup)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Detach")
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        model.terminalExited(tab.id)
        #expect(model.collectionErrors[profile.id] == nil)
        #expect(model.dueServerIDs(now: Date().addingTimeInterval(30)).contains(profile.id))
    }

    @Test func testExistingTerminalExitAfterManagedActivationKeepsMonitoringAvailable() async throws {
        let fixture = ManagedKeyFixture(sessionProbeExitCode: 0)
        let model = AppModel(demo: false, storeURL: temporaryURL(),
                             agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in await fixture.run(command) }
        let profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Keep running")
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        let setup = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        try await model.verifyAndApplySSHKeySetup(setup)
        #expect(model.connections[tab.id] == .launched)
        model.terminalExited(tab.id)
        #expect(model.collectionErrors[profile.id] == nil)
        #expect(model.dueServerIDs(now: Date().addingTimeInterval(30)).contains(profile.id))
    }

    @Test func testManagedKeyActivationPreservesTabsAndPersistsOnlyKeyReference() async throws {
        let fixture = ManagedKeyFixture()
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url,
                             agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in
            await fixture.run(command)
        }
        let profile = server()
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Keep session")
        let setup = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        #expect(model.workspace.servers.first { $0.id == profile.id }?.accounts[0].authMethod == .system)
        try await model.verifyAndApplySSHKeySetup(setup)
        let saved = try #require(model.workspace.servers.first { $0.id == profile.id })
        #expect(saved.accounts[0].authMethod == .managedKey)
        #expect(saved.accounts[0].managedKey == setup.reference)
        #expect(model.workspace.tabs.contains(tab))
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("credential"))
        let loaded = AppModel(demo: false, storeURL: url)
        #expect(loaded.workspace.servers.first { $0.id == profile.id }?.accounts == saved.accounts)
        let commands = await fixture.commands
        let verification = try #require(commands.last { $0.arguments.last == "true" })
        #expect(verification.arguments.last == "true")
        #expect(verification.environment["SSH_AUTH_SOCK"] == "/tmp/fixture-agent")
    }

    @Test func testFailedManagedKeyVerificationLeavesAuthenticationAndStateFileUntouched() async throws {
        let fixture = ManagedKeyFixture(verificationExitCode: 255)
        let url = temporaryURL()
        let model = AppModel(demo: false, storeURL: url, agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in await fixture.run(command) }
        let profile = server()
        try model.saveProfile(profile)
        let before = try Data(contentsOf: url)
        let setup = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        await #expect(throws: (any Error).self) { try await model.verifyAndApplySSHKeySetup(setup) }
        #expect(try Data(contentsOf: url) == before)
        #expect(model.workspace.servers.contains(profile))
    }

    @Test func testCancelledAndDuplicateSetupsCannotActivateOrReuseCandidateKeys() async throws {
        let fixture = ManagedKeyFixture()
        let model = AppModel(demo: false, storeURL: temporaryURL(), agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in await fixture.run(command) }
        let profile = server()
        try model.saveProfile(profile)
        let first = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        await #expect(throws: (any Error).self) { try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id) }
        model.cancelSSHKeySetup(first.id)
        await #expect(throws: (any Error).self) { try await model.verifyAndApplySSHKeySetup(first) }
        let second = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        #expect(first.reference.id != second.reference.id)
        model.cancelSSHKeySetup(second.id)
        #expect(model.workspace.servers.contains(profile))
    }

    @Test func testServerEditDuringManagedVerificationCannotActivateStaleReference() async throws {
        let fixture = ManagedKeyFixture(suspendVerification: true)
        let model = AppModel(demo: false, storeURL: temporaryURL(), agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in await fixture.run(command) }
        var profile = server()
        try model.saveProfile(profile)
        let setup = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        let validation = Task { try await model.verifyAndApplySSHKeySetup(setup) }
        for _ in 0..<500 {
            if await fixture.waiting { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await fixture.waiting)
        profile.host = "changed.invalid"
        try model.saveProfile(profile)
        await fixture.release()
        await #expect(throws: (any Error).self) { try await validation.value }
        #expect(model.workspace.servers.contains(profile))
    }

    @Test func testAgentFailureExitOneIsRejectedUnlessItMeansNoIdentities() async throws {
        let fixture = ManagedKeyFixture(agentError: "Error connecting to agent: Connection refused")
        let model = AppModel(demo: false, storeURL: temporaryURL(), agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in await fixture.run(command) }
        let profile = server()
        try model.saveProfile(profile)
        await #expect(throws: (any Error).self) { try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id) }
        #expect(model.workspace.servers.contains(profile))
    }

    @Test func testManagedAuthenticationFailurePausesCollectionAndUnlockResumesIt() async throws {
        let fixture = ManagedKeyFixture()
        let model = AppModel(demo: false, storeURL: temporaryURL(), agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in await fixture.run(command) }
        let profile = server()
        try model.saveProfile(profile)
        let setup = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        try await model.verifyAndApplySSHKeySetup(setup)
        let now = Date()
        model.tick(at: now)
        try await waitUntil { model.collectionErrors[profile.id] != nil }
        #expect(!model.dueServerIDs(now: now.addingTimeInterval(30)).contains(profile.id))
        let unlock = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id, unlock: true)
        #expect(unlock.reference == setup.reference)
        try await model.verifyAndApplySSHKeySetup(unlock)
        #expect(model.collectionErrors[profile.id] == nil)
        #expect(model.dueServerIDs(now: now.addingTimeInterval(31)).contains(profile.id))
    }
}

private actor ManagedKeyFixture {
    private(set) var commands: [ShellCommand] = []
    let verificationExitCode: Int32
    let agentError: String?
    let suspendVerification: Bool
    let sessionProbeExitCode: Int32
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    init(verificationExitCode: Int32 = 0, agentError: String? = nil, suspendVerification: Bool = false, sessionProbeExitCode: Int32 = 255) {
        self.verificationExitCode = verificationExitCode
        self.agentError = agentError
        self.suspendVerification = suspendVerification
        self.sessionProbeExitCode = sessionProbeExitCode
    }
    func run(_ command: ShellCommand) async -> ProcessResult {
        commands.append(command)
        if command.arguments.contains("-G") {
            return ProcessResult(exitCode: 0, stdout: "hostname example.invalid\nuser trainer\nport 22\nproxyjump none\nproxycommand none\n", stderr: "")
        }
        if command.executable == "/usr/bin/ssh-add" {
            return ProcessResult(exitCode: 1, stdout: agentError == nil ? "The agent has no identities.\n" : "", stderr: agentError ?? "")
        }
        if command.arguments.last == "true" {
            if suspendVerification { await withCheckedContinuation { continuation = $0 } }
            return ProcessResult(exitCode: verificationExitCode, stdout: "", stderr: verificationExitCode == 0 ? "" : "fixture key rejected")
        }
        if command.arguments.last?.contains("tmux has-session") == true {
            return ProcessResult(exitCode: sessionProbeExitCode, stdout: "", stderr: "")
        }
        return ProcessResult(exitCode: 255, stdout: "", stderr: "fixture key locked")
    }
    func release() { continuation?.resume(); continuation = nil }
}
