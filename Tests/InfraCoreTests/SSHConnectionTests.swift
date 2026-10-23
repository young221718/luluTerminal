import Foundation
import Testing
@testable import InfraCore

struct SSHConnectionTests {
    @Test func legacyPasswordWorkspaceMigratesWithoutChangingIdentity() throws {
        let account = SSHAccount(username: "trainer")
        let server = ServerProfile(name: "GPU", host: "gpu-alias", accounts: [account], monitorAccountID: account.id)
        let tab = TerminalTab(serverID: server.id, accountID: account.id, title: "keep session")
        var state = WorkspaceState(); state.servers = [server]
        try state.add(tab: tab)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var servers = try #require(payload["servers"] as? [[String: Any]])
        var accounts = try #require(servers[0]["accounts"] as? [[String: Any]])
        accounts[0]["authMethod"] = "password"
        // Retired metadata is ignored even if it is no longer structurally valid.
        accounts[0]["credential"] = ["obsolete": "fixture metadata"]
        servers[0]["accounts"] = accounts; payload["servers"] = servers
        let migrated = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: payload))
        try migrated.validate()
        #expect(migrated == state)
        #expect(migrated.tabs[0].sessionName == tab.sessionName)
        let encoded = try #require(String(data: JSONEncoder().encode(migrated), encoding: .utf8))
        #expect(!encoded.contains("credential"))
        #expect(!encoded.contains("password"))
    }

    @Test func everySystemSSHCommandDisablesKeychainAndAskpass() throws {
        let account = SSHAccount(username: "trainer")
        let server = ServerProfile(name: "GPU", host: "gpu-alias", accounts: [account])
        let tab = TerminalTab(serverID: server.id, accountID: account.id, title: "shell")
        let commands = [
            try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: true),
            try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: false),
            try SSHCommandBuilder.probe(server: server, account: account, tab: tab),
            try SSHCommandBuilder.monitor(server: server, account: account)
        ]
        for command in commands {
            #expect(command.arguments.contains("UseKeychain=no"))
            #expect(command.arguments.contains("AddKeysToAgent=no"))
            #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "never")
            #expect(command.environment["SSH_ASKPASS"] == "")
            #expect(!command.arguments.contains("ProxyJump=none"))
            #expect(!command.arguments.contains("ProxyCommand=none"))
        }
        #expect(commands[0].arguments.contains("BatchMode=no"))
        #expect(commands[0].arguments.contains("StrictHostKeyChecking=ask"))
        #expect(commands[2].arguments.contains("BatchMode=yes"))
        #expect(commands[2].arguments.contains("StrictHostKeyChecking=yes"))
        #expect(commands.last?.standardInput == LinuxCollector.script)
    }
    @Test func commandEnvironmentOverridesInheritedValuesWithoutEnteringShellString() async throws {
        let command = ShellCommand(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$LULUTERMINAL_ENV_TEST\""], environment: ["LULUTERMINAL_ENV_TEST": "override-value"])
        #expect(!command.shellString.contains("override-value"))
        #expect(try await ProcessRunner().run(command).stdout == "override-value")
    }
    @Test func managedTargetResolutionDisablesKeychainAndRejectsUnsafeRoutes() async throws {
        let account = SSHAccount(username: "trainer")
        let server = ServerProfile(name: "GPU", host: "gpu-alias", accounts: [account])
        let target = try await SSHConnectionResolver.resolveTarget(server: server, account: account) { command, timeout in
            #expect(command.executable == "/usr/bin/ssh")
            #expect(command.arguments.contains("-G"))
            #expect(command.arguments.contains("UseKeychain=no"))
            #expect(command.arguments.contains("AddKeysToAgent=no"))
            #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "never")
            #expect(command.environment["SSH_ASKPASS"] == "")
            #expect(timeout == 5)
            return ProcessResult(exitCode: 0, stdout: "hostname 192.0.2.5\nuser trainer\nport 22\nproxycommand none\nproxyjump none\n", stderr: "")
        }
        #expect(target.resolvedHost == "192.0.2.5")
        #expect(target.matches(server: server, account: account))
        for unsafeOption in ["proxyjump bastion", "proxycommand ssh bastion -W %h:%p", "hostkeyalias trusted-name", "hostkeyalias none"] {
            await #expect(throws: (any Error).self) {
                try await SSHConnectionResolver.resolveTarget(server: server, account: account) { _, _ in
                    ProcessResult(exitCode: 0, stdout: "hostname 192.0.2.5\nuser trainer\nport 22\n" + unsafeOption + "\n", stderr: "")
                }
            }
        }
        for invalid in ["hostname unsafe;host\nuser trainer\nport 22\n", "hostname 192.0.2.5\nuser other\nport 22\n", "hostname 192.0.2.5\nuser trainer\nport 2222\n"] {
            await #expect(throws: (any Error).self) {
                try await SSHConnectionResolver.resolveTarget(server: server, account: account) { _, _ in
                    ProcessResult(exitCode: 0, stdout: invalid, stderr: "")
                }
            }
        }
    }

    @Test func systemSSHOverridesKeychainConfigurationWithoutLosingProxyRoute() async throws {
        let account = SSHAccount(username: "trainer")
        let server = ServerProfile(name: "GPU", host: "gpu-alias", accounts: [account])
        let config = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ssh-config")
        try Data("Host *\n  UseKeychain yes\n  AddKeysToAgent yes\n  ProxyJump fixture-bastion\n  HostName 192.0.2.5\n".utf8).write(to: config)
        defer { try? FileManager.default.removeItem(at: config) }
        let command = try SSHCommandBuilder.monitor(server: server, account: account)
        let evaluated = try await ProcessRunner().run(ShellCommand(executable: command.executable,
            arguments: ["-F", config.path, "-G"] + command.arguments.dropLast(), environment: command.environment))
        #expect(evaluated.exitCode == 0)
        let options = evaluated.stdout.split(separator: "\n").map(String.init)
        // Apple ssh accepts UseKeychain but omits it from its -G dump.
        #expect(command.arguments.contains("UseKeychain=no"))
        #expect(options.contains("addkeystoagent false"))
        #expect(options.contains("proxyjump fixture-bastion"))
        #expect(options.contains("hostname 192.0.2.5"))
    }

    @Test func managedTargetDecodesExistingLayoutAndUnknownAuthenticationStillFails() throws {
        let data = Data(#"{"id":"44444444-4444-4444-4444-444444444444","target":{"serverID":"11111111-1111-1111-1111-111111111111","accountID":"22222222-2222-2222-2222-222222222222","host":"gpu-alias","port":22,"username":"trainer","resolvedHost":"192.0.2.5"}}"#.utf8)
        let reference = try JSONDecoder().decode(SSHManagedKeyReference.self, from: data)
        #expect(reference.target.serverID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(reference.target.accountID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(reference.target.host == "gpu-alias")
        #expect(reference.target.resolvedHost == "192.0.2.5")
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? NSDictionary == JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let unknown = Data(#"{"id":"22222222-2222-2222-2222-222222222222","username":"trainer","authMethod":"unknown-auth"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SSHAccount.self, from: unknown) }
    }

}
