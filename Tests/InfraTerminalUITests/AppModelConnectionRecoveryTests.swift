import Testing
import Foundation
@testable import InfraTerminalUI
import InfraCore

extension AppModelTests {
    @Test func testNetwork255DoesNotPauseManagedKeyPollingOrClaimAuthentication() async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, profile, tab) = try recoveryFixture(recorder: recorder, method: .managedKey)
        await recorder.respond(with: ProcessResult(exitCode: 255, stdout: "", stderr: "ssh: connect to host example.invalid port 22: Operation timed out"))
        #expect(await model.prepareConnection(tabID: tab.id, create: false) == nil)
        if case .failed? = model.connections[tab.id] {} else { Issue.record("Network failure must not request authentication") }
        model.tick(at: Date())
        try await waitUntil { model.collectionErrors[profile.id] != nil }
        #expect(model.dueServerIDs(now: Date().addingTimeInterval(120)).contains(profile.id))
        #expect(model.collectionErrors[profile.id]?.contains("네트워크") == true)
        model.stop()
    }

    @Test(arguments: ["Permission denied (publickey,password).", "Host key verification failed.", "unrecognized diagnostic"])
    func testProtectedFailuresBlockAutomaticRecoveryUntilExplicitAction(_ stderr: String) async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, profile, tab) = try recoveryFixture(recorder: recorder, method: .managedKey)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        await recorder.respond(with: ProcessResult(exitCode: 255, stdout: "", stderr: stderr))
        model.tick(at: Date())
        try await waitUntil { model.collectionErrors[profile.id] != nil }
        model.configureConnectionRecovery(enabled: true)
        model.connectionEnvironmentInterrupted()
        #expect(model.beginConnectionRecovery().isEmpty)
        #expect(!model.dueServerIDs(now: Date().addingTimeInterval(120)).contains(profile.id))
        model.stop()
    }

    @Test func testRecoveryIsOptInAndOnlyAttachesExistingSessionOncePerEvent() async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, _, tab) = try recoveryFixture(recorder: recorder)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        #expect(model.beginConnectionRecovery().isEmpty)
        model.configureConnectionRecovery(enabled: true)
        model.connectionEnvironmentInterrupted()
        model.terminalExited(tab.id)
        #expect(model.beginConnectionRecovery() == [tab.id])
        let command = try #require(await model.prepareConnection(tabID: tab.id, create: false, automaticRecovery: true))
        #expect(command.arguments.last?.contains("attach-session") == true)
        #expect(command.arguments.last?.contains("new-session") == false)
        #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "never")
        #expect(command.standardInput == nil)
        #expect(command.arguments.prefix(4) == ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"])
        for option in ["UseKeychain=no", "PasswordAuthentication=no", "KbdInteractiveAuthentication=no", "ControlPath=none"] {
            #expect(command.arguments.contains(option))
        }
        for option in ["ProxyJump=none", "ProxyCommand=none", "CanonicalizeHostname=no", "ClearAllForwardings=yes", "ForwardAgent=no"] {
            #expect(!command.arguments.contains(option), "Automatic system connections must preserve route and forwarding configuration")
        }
        let automaticProbe = try #require(await recorder.commands.last)
        #expect(automaticProbe.arguments.prefix(4) == ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"])
        #expect(automaticProbe.environment["SSH_ASKPASS_REQUIRE"] == "never")
        let count = await recorder.commands.count
        #expect(await model.prepareConnection(tabID: tab.id, create: false, automaticRecovery: true) == nil)
        #expect(await recorder.commands.count == count)
        model.terminalExited(tab.id)
        #expect(model.beginConnectionRecovery().isEmpty, "Normal logout after successful recovery must not reopen on a later event")
    }

    @Test(arguments: ["proxyjump bastion.invalid", "proxycommand ssh bastion.invalid -W %h:%p", "hostkeyalias alternate"])
    func testUnsupportedAutomaticRoutePreservesExistingConnectionWithoutNetworkProbe(_ configuration: String) async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, _, tab) = try recoveryFixture(recorder: recorder)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        model.configureConnectionRecovery(enabled: true)
        model.connectionEnvironmentInterrupted()
        #expect(model.beginConnectionRecovery() == [tab.id])
        await recorder.configureSSH(configuration)
        let previous = await recorder.commands.filter { !$0.arguments.contains("-G") }.count
        #expect(await model.prepareConnection(tabID: tab.id, create: false, automaticRecovery: true) == nil)
        #expect(model.connections[tab.id] == .launched)
        #expect(await recorder.commands.filter { !$0.arguments.contains("-G") }.count == previous)
        model.terminalExited(tab.id)
        #expect(model.beginConnectionRecovery().isEmpty)
    }

    @Test(arguments: ["Host key verification failed.", "unrecognized diagnostic", "Permission denied (publickey)."])
    func testExplicitManagedRetryCanClearPausedFailure(_ stderr: String) async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, _, tab) = try recoveryFixture(recorder: recorder, method: .managedKey)
        await recorder.respond(with: ProcessResult(exitCode: 255, stdout: "", stderr: stderr))
        #expect(await model.prepareConnection(tabID: tab.id, create: false) == nil)
        await recorder.respond(with: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let count = await recorder.commands.count
        #expect(await model.prepareConnection(tabID: tab.id, create: false) == nil)
        #expect(await recorder.commands.count == count)
        #expect(await model.prepareConnection(tabID: tab.id, create: false, retryAuthentication: true) != nil)
        #expect(model.connections[tab.id] == .launched)
    }

    @Test func testExplicitConnectionInvalidatesQueuedAutomaticPermit() async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, profile, first) = try recoveryFixture(recorder: recorder)
        let second = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Second")
        #expect(await model.prepareConnection(tabID: first.id, create: false) != nil)
        #expect(await model.prepareConnection(tabID: second.id, create: false) != nil)
        model.configureConnectionRecovery(enabled: true)
        model.connectionEnvironmentInterrupted()
        #expect(Set(model.beginConnectionRecovery()) == [first.id, second.id])
        #expect(await model.prepareConnection(tabID: second.id, create: false) != nil)
        let count = await recorder.commands.count
        #expect(await model.prepareConnection(tabID: second.id, create: false, automaticRecovery: true) == nil)
        #expect(await recorder.commands.count == count)
        #expect(model.connections[second.id] == .launched)
    }

    @Test func testRecoveryExcludesLocalClosedManualAndNeverOpenedTabs() async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, profile, opened) = try recoveryFixture(recorder: recorder)
        #expect(await model.prepareConnection(tabID: opened.id, create: false) != nil)
        let neverOpened = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Never opened")
        let closed = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Closed")
        #expect(await model.prepareConnection(tabID: closed.id, create: false) != nil)
        model.closeTab(closed.id)
        let local = try #require(model.workspace.tabs.first { $0.serverID == LocalMachine.serverID })
        #expect(await model.prepareConnection(tabID: local.id, create: false) != nil)
        model.configureConnectionRecovery(enabled: true)
        model.connectionEnvironmentInterrupted()
        model.disconnected(opened.id)
        #expect(model.beginConnectionRecovery().isEmpty)
        #expect(model.connections[local.id] == .launched, "Recovery selection must preserve the existing local shell")
        let count = await recorder.commands.count
        for tabID in [opened.id, neverOpened.id, closed.id, local.id] {
            #expect(await model.prepareConnection(tabID: tabID, create: true, automaticRecovery: true) == nil)
        }
        #expect(await recorder.commands.count == count)

        let demo = AppModel(demo: true, storeURL: temporaryURL()) { command, _ in await recorder.run(command) }
        demo.configureConnectionRecovery(enabled: true)
        demo.connectionEnvironmentInterrupted()
        #expect(demo.beginConnectionRecovery().isEmpty)
    }

    @Test(arguments: ["create", "manual", "skipProbe", "retry"])
    func testAutomaticRecoveryRejectsCreationAndInteractiveOverrides(_ action: String) async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, _, tab) = try recoveryFixture(recorder: recorder)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        model.configureConnectionRecovery(enabled: true)
        model.connectionEnvironmentInterrupted()
        #expect(model.beginConnectionRecovery() == [tab.id])
        let count = await recorder.commands.count
        let command = await model.prepareConnection(tabID: tab.id, create: action == "create", probeExisting: action != "skipProbe",
                                                    retryAuthentication: action == "retry", manualAuthentication: action == "manual", automaticRecovery: true)
        #expect(command == nil)
        #expect(await recorder.commands.count == count)
    }

    @Test func testNaturalExitDoesNotBecomeRecoveryIntent() async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, _, tab) = try recoveryFixture(recorder: recorder)
        model.configureConnectionRecovery(enabled: true)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        model.terminalExited(tab.id)
        model.connectionEnvironmentInterrupted()
        #expect(model.beginConnectionRecovery().isEmpty)
    }

    @Test func testNetworkRecoveryCanRetryOnLaterEventWithoutAnAutomaticLoop() async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, _, tab) = try recoveryFixture(recorder: recorder)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        model.configureConnectionRecovery(enabled: true)
        model.connectionEnvironmentInterrupted()
        model.terminalExited(tab.id)
        #expect(model.beginConnectionRecovery() == [tab.id])
        await recorder.respond(with: ProcessResult(exitCode: 255, stdout: "", stderr: "Connection refused"))
        #expect(await model.prepareConnection(tabID: tab.id, create: false, automaticRecovery: true) == nil)
        let count = await recorder.commands.count
        #expect(await model.prepareConnection(tabID: tab.id, create: false, automaticRecovery: true) == nil)
        #expect(await recorder.commands.count == count)
        await recorder.respond(with: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        #expect(model.beginConnectionRecovery() == [tab.id])
        #expect(await model.prepareConnection(tabID: tab.id, create: false, automaticRecovery: true) != nil)
    }

    @Test(arguments: ["manual", "close", "profile", "cancel", "disable", "stop"])
    func testPendingAutomaticRecoveryCannotLaunchAfterInvalidation(_ action: String) async throws {
        let recorder = RecoveryCommandRecorder()
        let (model, profile, tab) = try recoveryFixture(recorder: recorder)
        #expect(await model.prepareConnection(tabID: tab.id, create: false) != nil)
        model.configureConnectionRecovery(enabled: true)
        model.connectionEnvironmentInterrupted()
        #expect(model.beginConnectionRecovery() == [tab.id])
        await recorder.suspendNextProbe()
        let pending = Task { await model.prepareConnection(tabID: tab.id, create: false, automaticRecovery: true) }
        for _ in 0..<500 {
            if await recorder.isSuspended { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(await recorder.isSuspended)
        switch action {
        case "manual": model.disconnected(tab.id)
        case "close": model.closeTab(tab.id)
        case "profile": var changed = profile; changed.host = "changed.invalid"; try model.saveProfile(changed)
        case "cancel": pending.cancel()
        case "disable": model.configureConnectionRecovery(enabled: false)
        default: model.stop()
        }
        await recorder.release()
        #expect(await pending.value == nil)
        #expect(model.connections[tab.id] != .launched)
    }

    private func recoveryFixture(recorder: RecoveryCommandRecorder, method: SSHAuthenticationMethod = .system) throws -> (AppModel, ServerProfile, TerminalTab) {
        let model = AppModel(demo: false, storeURL: temporaryURL(), agentEnvironment: ["SSH_AUTH_SOCK": "/tmp/fixture-agent"]) { command, _ in await recorder.run(command) }
        var profile = server()
        profile.accounts[0].authMethod = method
        let target = SSHConnectionTarget(server: profile, account: profile.accounts[0], resolvedHost: "example.invalid")
        if method == .managedKey { profile.accounts[0].managedKey = SSHManagedKeyReference(target: target) }
        try model.saveProfile(profile)
        let tab = try model.addTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Recovery")
        return (model, profile, tab)
    }
}

private actor RecoveryCommandRecorder {
    private(set) var commands: [ShellCommand] = []
    private var result = ProcessResult(exitCode: 0, stdout: "", stderr: "")
    private var configuration = ""
    private var suspendProbe = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }
    func respond(with result: ProcessResult) { self.result = result }
    func configureSSH(_ configuration: String) { self.configuration = configuration }
    func suspendNextProbe() { suspendProbe = true }
    func release() { continuation?.resume(); continuation = nil }
    func run(_ command: ShellCommand) async -> ProcessResult {
        commands.append(command)
        if command.arguments.contains("-G") {
            return ProcessResult(exitCode: 0, stdout: "hostname example.invalid\nuser trainer\nport 22\nproxyjump none\nproxycommand none\n" + configuration + "\n", stderr: "")
        }
        if command.executable == "/usr/bin/ssh-add" { return ProcessResult(exitCode: 0, stdout: "fixture identity", stderr: "") }
        if suspendProbe {
            suspendProbe = false
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }
}
