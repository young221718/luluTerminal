import Foundation
import InfraCore
import Testing
@testable import InfraTerminalUI

extension AppModelTests {
    @Test func automaticKeySetupRegistersVerifiesAndPersistsWithoutAgentOrPassword() async throws {
        let fixture = AutomaticKeyFixture()
        let url = temporaryURL()
        let model = automaticModel(fixture, url: url)
        var profile = server()
        profile.accounts[0].managedKey = SSHManagedKeyReference(target: SSHConnectionTarget(server: profile, account: profile.accounts[0], resolvedHost: "example.invalid"))
        profile.accounts[0].authMethod = .managedKey
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Preserve")
        var progress: [SSHKeySetupProgress] = []
        try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id,
                                               password: "synthetic-secret-42") { progress.append($0) }
        let saved = try #require(model.workspace.servers.first { $0.id == profile.id })
        #expect(saved.accounts[0].authMethod == .managedKey)
        #expect(saved.accounts[0].managedKey?.requiresAgent == false)
        #expect(model.workspace.tabs.contains(tab))
        #expect(progress == [.generating, .registering, .verifying])
        let bytes = try Data(contentsOf: url)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("synthetic-secret-42"))
        #expect(try StateStore(url: url).load() == model.workspace)
        let commands = await fixture.commands
        #expect(!commands.contains { $0.executable == "/usr/bin/ssh-add" || $0.executable == "/bin/launchctl" })
        #expect(!commands.contains { $0.shellString.contains("synthetic-secret-42") || $0.environment.values.contains("synthetic-secret-42") })
        let registration = try #require(await fixture.registration)
        #expect(registration.standardInput == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA synthetic\n")
        #expect(await fixture.receivedExpectedPassword)
        let verification = try #require(commands.last { $0.arguments.last == "true" })
        #expect(verification.arguments.contains("IdentityAgent=none"))
        #expect(verification.environment["SSH_AUTH_SOCK"] != "/tmp/fixture-agent")
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil,
                "Agent-free keys must also work for normal terminal connection preparation")
    }

    @Test(arguments: ["generation", "registration", "verification"])
    func automaticKeyFailurePreservesPriorAuthenticationAndState(failingStage: String) async throws {
        let fixture = AutomaticKeyFixture(failingStage: failingStage)
        let url = temporaryURL()
        let model = automaticModel(fixture, url: url)
        var profile = server()
        profile.accounts[0].managedKey = SSHManagedKeyReference(target: SSHConnectionTarget(server: profile, account: profile.accounts[0], resolvedHost: "example.invalid"))
        profile.accounts[0].authMethod = .managedKey
        try model.saveProfile(profile)
        let before = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) {
            try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42")
        }
        #expect(model.workspace.servers.contains(profile))
        #expect(try Data(contentsOf: url) == before)
        let setup = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        model.cancelSSHKeySetup(setup.id)
    }

    @Test(arguments: ["resolution", "generation", "registration-target", "registration", "verification-target", "verification", "apply-target"], [false, true])
    func cancellingAutomaticSetupCannotApplyItsKey(suspendedStage: String, pending: Bool) async throws {
        let fixture = AutomaticKeyFixture(suspendedStage: suspendedStage)
        let url = temporaryURL()
        let model = automaticModel(fixture, url: url)
        var profile = server()
        if pending { profile.accounts[0].authMethod = .pendingKey }
        try model.saveProfile(profile)
        let before = try Data(contentsOf: url)
        let operation = Task { try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42") }
        try await waitForAutomaticFixture(fixture)
        operation.cancel()
        await fixture.release()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(model.workspace.servers.contains(profile))
        #expect(try Data(contentsOf: url) == before)
        if pending { #expect(!model.dueServerIDs(now: Date()).contains(profile.id)) }
        if ["resolution", "generation", "registration-target"].contains(suspendedStage) { #expect(await fixture.registration == nil) }
    }

    @Test(arguments: ["resolution", "generation", "registration-target", "registration", "verification-target", "verification", "apply-target"])
    func editingServerDuringAutomaticSetupCannotReviveOldProfile(suspendedStage: String) async throws {
        let fixture = AutomaticKeyFixture(suspendedStage: suspendedStage)
        let url = temporaryURL()
        let model = automaticModel(fixture, url: url)
        var profile = server()
        try model.saveProfile(profile)
        let operation = Task { try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42") }
        try await waitForAutomaticFixture(fixture)
        profile.host = "edited.invalid"
        try model.saveProfile(profile)
        let before = try Data(contentsOf: url)
        await fixture.release()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(model.workspace.servers.contains(profile))
        #expect(try Data(contentsOf: url) == before)
        if ["resolution", "generation", "registration-target"].contains(suspendedStage) { #expect(await fixture.registration == nil) }
    }

    @Test func aliasChangeBeforeRegistrationDoesNotSendPassword() async throws {
        let fixture = AutomaticKeyFixture(changesResolvedTarget: true)
        let model = automaticModel(fixture, url: temporaryURL())
        let profile = server()
        try model.saveProfile(profile)
        await #expect(throws: (any Error).self) {
            try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42")
        }
        #expect(await fixture.registration == nil)
        #expect(model.workspace.servers.contains(profile))
    }

    @Test func deletingServerDuringAutomaticSetupCannotRecreateIt() async throws {
        let fixture = AutomaticKeyFixture(suspendedStage: "registration")
        let url = temporaryURL()
        let model = automaticModel(fixture, url: url)
        let profile = server()
        try model.saveProfile(profile)
        let operation = Task { try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42") }
        try await waitForAutomaticFixture(fixture)
        try model.deleteServer(profile.id)
        let before = try Data(contentsOf: url)
        await fixture.release()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(!model.workspace.servers.contains { $0.id == profile.id })
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aliasChangesAfterVerificationCannotApplyTheOldTarget() async throws {
        let fixture = AutomaticKeyFixture(changesTargetAfterVerification: true)
        let url = temporaryURL()
        let model = automaticModel(fixture, url: url)
        let profile = server()
        try model.saveProfile(profile)
        let before = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) {
            try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42")
        }
        #expect(model.workspace.servers.contains(profile))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test(arguments: ["cancel", "edit", "delete", "stop"])
    func automaticRegistrationCancellationRetainsAuthenticationSlotUntilUnwound(action: String) async throws {
        let fixture = AutomaticKeyFixture(suspendedStage: "registration")
        let model = automaticModel(fixture, url: temporaryURL())
        var profile = server()
        try model.saveProfile(profile)
        let operation = Task { try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42") }
        try await waitForAutomaticFixture(fixture)
        switch action {
        case "cancel": operation.cancel()
        case "edit": profile.name = "Edited"; try model.saveProfile(profile)
        case "delete": try model.deleteServer(profile.id); try model.saveProfile(profile)
        default: model.stop()
        }
        for _ in 0..<500 {
            if await fixture.registrationCancelled { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await fixture.registrationCancelled, "Cancellation must reach the password transport")
        do {
            let unexpected = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
            model.cancelSSHKeySetup(unexpected.id)
            Issue.record("The authentication slot was released before the cancelled registrar unwound")
        } catch {}
        await fixture.release()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(model.workspace.servers.contains(profile))
        let retry = try await model.prepareSSHKeySetup(serverID: profile.id, accountID: profile.accounts[0].id)
        model.cancelSSHKeySetup(retry.id)
    }

    @Test func secondAutomaticSetupCannotRegisterWhileFirstIsRunning() async throws {
        let fixture = AutomaticKeyFixture(suspendedStage: "generation")
        let model = automaticModel(fixture, url: temporaryURL())
        let profile = server()
        try model.saveProfile(profile)
        let operation = Task { try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42") }
        try await waitForAutomaticFixture(fixture)
        await #expect(throws: (any Error).self) {
            try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "different-synthetic-password")
        }
        #expect(await fixture.registration == nil)
        operation.cancel()
        await fixture.release()
        await #expect(throws: (any Error).self) { try await operation.value }
    }

    @Test(arguments: [false, true]) func automaticSetupSaveFailurePreservesExistingAuthentication(pending: Bool) async throws {
        let fixture = AutomaticKeyFixture(suspendedStage: "verification")
        let url = temporaryURL()
        let model = automaticModel(fixture, url: url)
        var profile = server()
        if pending { profile.accounts[0].authMethod = .pendingKey }
        try model.saveProfile(profile)
        let operation = Task { try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42") }
        try await waitForAutomaticFixture(fixture)
        // Replace only this test's state file with a directory to force an atomic-save failure.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await fixture.release()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(model.workspace.servers.contains(profile))
        #expect(model.persistenceError != nil)
    }

    @Test(arguments: ["", "bad\npassword", "bad\rpassword", "bad\0password", String(repeating: "x", count: 1024), String(repeating: "é", count: 512)])
    func invalidAutomaticPasswordDoesNotStartAnyProcess(password: String) async throws {
        let fixture = AutomaticKeyFixture()
        let model = automaticModel(fixture, url: temporaryURL())
        let profile = server()
        try model.saveProfile(profile)
        await #expect(throws: (any Error).self) {
            try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: password)
        }
        #expect(await fixture.commands.isEmpty)
    }

    @Test(arguments: ["success", "generation", "registration", "verification"])
    func pendingKeyOnlyBecomesConnectableAfterSuccessfulEnrollment(stage: String) async throws {
        let fixture = AutomaticKeyFixture(failingStage: stage == "success" ? nil : stage)
        let url = temporaryURL()
        let model = automaticModel(fixture, url: url)
        var profile = server()
        profile.accounts[0].authMethod = .pendingKey
        try model.saveProfile(profile)
        if stage == "success" {
            try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42")
            let saved = try #require(model.workspace.servers.first { $0.id == profile.id })
            #expect(saved.accounts[0].authMethod == .managedKey)
            #expect(saved.accounts[0].managedKey?.requiresAgent == false)
            #expect(model.dueServerIDs(now: Date()).contains(profile.id))
        } else {
            await #expect(throws: (any Error).self) {
                try await model.automaticallySetUpSSHKey(serverID: profile.id, accountID: profile.accounts[0].id, password: "synthetic-secret-42")
            }
            #expect(model.workspace.servers.contains(profile))
            #expect(try StateStore(url: url).load()?.servers.contains(profile) == true)
            #expect(!model.dueServerIDs(now: Date()).contains(profile.id))
        }
    }

    private func automaticModel(_ fixture: AutomaticKeyFixture, url: URL) -> AppModel {
        AppModel(demo: false, storeURL: url, agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"], registerPassword: { command, password, _ in
            try await fixture.register(command, password: password)
        }) { command, _ in await fixture.run(command) }
    }

    private func waitForAutomaticFixture(_ fixture: AutomaticKeyFixture) async throws {
        for _ in 0..<500 {
            if await fixture.waiting { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await fixture.waiting, "Automatic setup did not reach the expected bounded suspension")
    }
}

private actor AutomaticKeyFixture {
    let failingStage: String?
    let suspendedStage: String?
    let changesResolvedTarget: Bool
    let changesTargetAfterVerification: Bool
    private var verified = false
    private var resolves = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ShellCommand] = []
    private(set) var registration: ShellCommand?
    private(set) var receivedExpectedPassword = false
    private(set) var registrationCancelled = false
    var waiting: Bool { continuation != nil }
    init(failingStage: String? = nil, suspendedStage: String? = nil, changesResolvedTarget: Bool = false,
         changesTargetAfterVerification: Bool = false) {
        self.failingStage = failingStage
        self.suspendedStage = suspendedStage
        self.changesResolvedTarget = changesResolvedTarget
        self.changesTargetAfterVerification = changesTargetAfterVerification
    }
    func run(_ command: ShellCommand) async -> ProcessResult {
        commands.append(command)
        if command.arguments.contains("-G") {
            resolves += 1
            let stage = resolves == 1 ? "resolution" : resolves == 2 ? "registration-target" : resolves == 3 ? "verification-target" : "apply-target"
            if suspendedStage == stage { await withCheckedContinuation { continuation = $0 } }
            let host = (changesResolvedTarget && resolves > 1) || (changesTargetAfterVerification && verified) ? "changed.invalid" : "example.invalid"
            return ProcessResult(exitCode: 0, stdout: "hostname \(host)\nuser trainer\nport 22\nproxyjump none\nproxycommand none\n", stderr: "")
        }
        if command.executable == "/usr/bin/ssh-add" { return ProcessResult(exitCode: 1, stdout: "The agent has no identities.\n", stderr: "") }
        let stage = command.arguments.last == "true" ? "verification" : "generation"
        if suspendedStage == stage { await withCheckedContinuation { continuation = $0 } }
        if stage == "verification" { verified = true }
        return ProcessResult(exitCode: failingStage == stage ? 255 : 0,
                             stdout: stage == "generation" ? "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA synthetic\n" : "", stderr: "untrusted output")
    }
    func register(_ command: ShellCommand, password: String) async throws {
        registration = command
        receivedExpectedPassword = password == "synthetic-secret-42"
        if suspendedStage == "registration" {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: { Task { await self.observeRegistrationCancellation() } }
        }
        if failingStage == "registration" { throw CancellationError() }
    }
    private func observeRegistrationCancellation() { registrationCancelled = true }
    func release() { continuation?.resume(); continuation = nil }
}
