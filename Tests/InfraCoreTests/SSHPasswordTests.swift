import Foundation
import Testing
@testable import InfraCore

struct SSHPasswordTests {
    private func fixture() -> (ServerProfile, SSHAccount, SSHPasswordReference) {
        var account = SSHAccount(username: "trainer", authMethod: .password)
        let server = ServerProfile(name: "GPU", host: "gpu-alias", accounts: [account])
        let reference = SSHPasswordReference(target: SSHPasswordTarget(server: server, account: account, resolvedHost: "192.0.2.5"))
        account.credential = reference
        var updated = server; updated.accounts = [account]
        return (updated, account, reference)
    }

    @Test func oldAccountsDecodeAsSystemAuthentication() throws {
        let data = Data(#"{"id":"22222222-2222-2222-2222-222222222222","username":"trainer"}"#.utf8)
        let account = try JSONDecoder().decode(SSHAccount.self, from: data)
        #expect(account.authMethod == .system)
        #expect(account.credential == nil)
    }

    @Test func metadataRoundTripNeverContainsPassword() throws {
        let (server, account, _) = fixture()
        let encoded = try JSONEncoder().encode(server)
        #expect(try JSONDecoder().decode(ServerProfile.self, from: encoded) == server)
        #expect(account.credential?.target.resolvedHost == "192.0.2.5")
        #expect(!String(decoding: encoded, as: UTF8.self).contains("fixture-secret"))
    }

    @Test func savedAuthenticationRequiresBoundContextAndPreservesCollectorStdin() async throws {
        let (server, account, reference) = fixture()
        #expect(throws: (any Error).self) { try SSHCommandBuilder.monitor(server: server, account: account) }
        let context = SSHAuthenticationContext(reference: reference, helperPath: "/tmp/askpass")
        let monitor = try SSHCommandBuilder.monitor(server: server, account: account, authentication: context)
        #expect(monitor.standardInput == LinuxCollector.script)
        #expect(monitor.environment["SSH_ASKPASS"] == "/tmp/askpass")
        #expect(monitor.environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(!monitor.shellString.contains("fixture-secret"))
        let evaluation = ShellCommand(executable: "/usr/bin/ssh", arguments: ["-F", "/dev/null", "-G"] + Array(monitor.arguments.dropLast(3)) + ["-o", "NoHostAuthenticationForLocalhost=yes", "--", server.host])
        let result = try await ProcessRunner().run(evaluation)
        #expect(result.exitCode == 0)
        for line in ["hostname 192.0.2.5", "batchmode no", "stricthostkeychecking true", "preferredauthentications password", "kbdinteractiveauthentication no", "pubkeyauthentication false", "numberofpasswordprompts 1", "controlmaster false", "nohostauthenticationforlocalhost no"] {
            #expect(result.stdout.split(separator: "\n").contains(Substring(line)))
        }
        #expect(!result.stdout.split(separator: "\n").contains(where: { $0.hasPrefix("controlpath ") }))
        var changed = server; changed.port = 2222
        #expect(throws: (any Error).self) { try SSHCommandBuilder.monitor(server: changed, account: account, authentication: context) }
        let tab = TerminalTab(serverID: server.id, accountID: account.id, title: "shell")
        let manual = try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: false, manualAuthentication: true)
        #expect(manual.environment["SSH_ASKPASS_REQUIRE"] == "never")
        #expect(manual.arguments.contains("StrictHostKeyChecking=ask"))
    }

    @Test func resolutionRejectsJumpHostsAndChangedAliases() async throws {
        let (server, account, _) = fixture()
        let target = try await SSHPasswordAuthentication.resolveTarget(server: server, account: account) { command, _ in
            #expect(command.executable == "/usr/bin/ssh")
            #expect(command.arguments.contains("-G"))
            return ProcessResult(exitCode: 0, stdout: "hostname 192.0.2.5\nuser trainer\nport 22\nproxycommand none\nproxyjump none\n", stderr: "")
        }
        #expect(target.resolvedHost == "192.0.2.5")
        for unsafeOption in ["proxyjump bastion", "proxycommand ssh bastion -W %h:%p", "hostkeyalias trusted-name", "hostkeyalias none"] {
            await #expect(throws: (any Error).self) {
                try await SSHPasswordAuthentication.resolveTarget(server: server, account: account) { _, _ in
                    ProcessResult(exitCode: 0, stdout: "hostname 192.0.2.5\nuser trainer\nport 22\n" + unsafeOption + "\n", stderr: "")
                }
            }
        }
        await #expect(throws: (any Error).self) {
            try await SSHPasswordAuthentication.context(server: server, account: account, helperPath: "/usr/bin/true") { _, _ in
                ProcessResult(exitCode: 0, stdout: "hostname 192.0.2.6\nuser trainer\nport 22\n", stderr: "")
            }
        }
    }

    @Test func askpassRejectsUnexpectedPromptsAndNonSSHParents() throws {
        let (_, _, reference) = fixture()
        #expect(SSHPasswordAuthentication.validateAskpass(prompt: "trainer@192.0.2.5's password: ", reference: reference, parentExecutable: "/usr/bin/ssh"))
        for prompt in ["trainer@bastion's password: ", "root@192.0.2.5's password: ", "Are you sure you want to continue connecting (yes/no)? ", "Enter passphrase for key '/tmp/key': ", "Verification code: ", "trainer@192.0.2.5's password: \n"] {
            #expect(!SSHPasswordAuthentication.validateAskpass(prompt: prompt, reference: reference, parentExecutable: "/usr/bin/ssh"))
        }
        #expect(!SSHPasswordAuthentication.validateAskpass(prompt: "trainer@192.0.2.5's password: ", reference: reference, parentExecutable: "/tmp/ssh"))
    }

    @Test func commandEnvironmentOverridesInheritedValuesWithoutEnteringShellString() async throws {
        let command = ShellCommand(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$LULUTERMINAL_ENV_TEST\""], environment: ["LULUTERMINAL_ENV_TEST": "override-value"])
        #expect(!command.shellString.contains("override-value"))
        #expect(try await ProcessRunner().run(command).stdout == "override-value")
    }
}
