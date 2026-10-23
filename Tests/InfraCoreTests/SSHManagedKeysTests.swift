import Foundation
import Testing
@testable import InfraCore

struct SSHManagedKeysTests {
    private func fixture() -> (ServerProfile, SSHAccount, SSHManagedKeyReference) {
        var account = SSHAccount(username: "trainer", authMethod: .managedKey)
        var server = ServerProfile(name: "GPU", host: "gpu-alias", accounts: [account])
        let reference = SSHManagedKeyReference(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, target: SSHConnectionTarget(server: server, account: account, resolvedHost: "192.0.2.5"))
        account.managedKey = reference; server.accounts = [account]
        return (server, account, reference)
    }

    @Test func managedMetadataRoundTripsAndOldAccountsRemainCompatible() throws {
        let (server, _, reference) = fixture()
        #expect(try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(server)) == server)
        let old = try JSONDecoder().decode(SSHAccount.self, from: Data(#"{"id":"22222222-2222-2222-2222-222222222222","username":"trainer"}"#.utf8))
        #expect(old.authMethod == .system)
        #expect(old.managedKey == nil)
        #expect(SSHManagedKeys.keyURL(for: reference, rootURL: URL(fileURLWithPath: "/private/tmp/keys")).path == "/private/tmp/keys/44444444-4444-4444-4444-444444444444/id_ed25519")
    }

    @Test func managedCommandsUseOnlyTheBoundKeyAndAgent() async throws {
        let (server, account, reference) = fixture()
        let tab = TerminalTab(serverID: server.id, accountID: account.id, title: "shell")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + " fixture keys")
        let key = SSHManagedKeys.keyURL(for: reference, rootURL: root)
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture for SSH -G; no private key".utf8).write(to: key)
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = [
            try SSHManagedKeys.verificationCommand(server: server, account: account, reference: reference, agentSocket: "/private/tmp/fixture.sock", rootURL: root),
            try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: false, managedKeyAgentSocket: "/private/tmp/fixture.sock", managedKeyRootURL: root),
            try SSHCommandBuilder.probe(server: server, account: account, tab: tab, managedKeyAgentSocket: "/private/tmp/fixture.sock", managedKeyRootURL: root),
            try SSHCommandBuilder.monitor(server: server, account: account, managedKeyAgentSocket: "/private/tmp/fixture.sock", managedKeyRootURL: root)
        ]
        for command in commands {
            #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "never")
            #expect(command.environment["SSH_ASKPASS"] == "")
            #expect(command.environment["SSH_AUTH_SOCK"] == "/private/tmp/fixture.sock")
            #expect(command.arguments.contains("/dev/null"))
            #expect(command.arguments.contains(key.path))
            #expect(command.arguments.contains("UseKeychain=no"))
            #expect(command.arguments.contains("AddKeysToAgent=no"))
            let result = try await ProcessRunner().run(ShellCommand(executable: "/usr/bin/ssh", arguments: ["-G"] + command.arguments.dropLast()))
            #expect(result.exitCode == 0)
            let lines = result.stdout.split(separator: "\n").map(String.init)
            for expected in ["hostname 192.0.2.5", "user trainer", "port 22", "identitiesonly yes", "preferredauthentications publickey", "passwordauthentication no", "kbdinteractiveauthentication no", "batchmode yes", "stricthostkeychecking true", "controlmaster false", "controlpersist no"] {
                #expect(lines.contains(expected))
            }
            #expect(lines.filter { $0.hasPrefix("identityfile ") && $0 != "identityfile none" } == ["identityfile " + key.path])
            #expect(!lines.contains(where: { $0.hasPrefix("controlpath ") }))
        }
        #expect(commands.last?.standardInput == LinuxCollector.script)
        try FileManager.default.removeItem(at: key)
        let missing = try await ProcessRunner().run(ShellCommand(executable: "/usr/bin/ssh", arguments: ["-G"] + commands[0].arguments.dropLast()))
        #expect(missing.stdout.split(separator: "\n").filter { $0.hasPrefix("identityfile ") } == ["identityfile none"])
    }

    @Test func changedTargetsAndMissingReferencesAreRejected() throws {
        let (server, account, reference) = fixture()
        for field in ["host", "user", "port"] {
            var changedServer = server; var changedAccount = account
            if field == "host" { changedServer.host = "other" }
            if field == "port" { changedServer.port = 2222 }
            if field == "user" { changedAccount.username = "other"; changedServer.accounts = [changedAccount] }
            #expect(throws: (any Error).self) { try SSHManagedKeys.verificationCommand(server: changedServer, account: changedAccount, reference: reference, agentSocket: "/tmp/agent") }
        }
        var missing = account; missing.managedKey = nil
        var missingServer = server; missingServer.accounts = [missing]
        #expect(throws: (any Error).self) { try SSHCommandBuilder.monitor(server: missingServer, account: missing) }
        #expect(throws: (any Error).self) { try SSHManagedKeys.unlockCommand(reference: reference, agentSocket: "") }
    }

    @Test func registrationPreservesExistingBytesAndRejectsSymlinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let authorized = ssh.appendingPathComponent("authorized_keys")
        let previous = Data("# existing comment\nssh-ed25519 OLD existing-without-newline".utf8)
        try previous.write(to: authorized)
        let command = ShellCommand(executable: "/bin/sh", arguments: ["-c", SSHManagedKeys.registrationScript], standardInput: "ssh-ed25519 NEW fixture\n", environment: ["HOME": directory.path])
        #expect(try await ProcessRunner().run(command).exitCode == 0)
        let appended = Data("# existing comment\nssh-ed25519 OLD existing-without-newline\nssh-ed25519 NEW fixture\n".utf8)
        #expect(try Data(contentsOf: authorized) == appended)
        #expect(try await ProcessRunner().run(command).exitCode == 0)
        #expect(try Data(contentsOf: authorized) == appended)
        try FileManager.default.removeItem(at: authorized)
        let victim = directory.appendingPathComponent("preserve")
        try previous.write(to: victim)
        try FileManager.default.createSymbolicLink(at: authorized, withDestinationURL: victim)
        #expect(try await ProcessRunner().run(command).exitCode != 0)
        #expect(try Data(contentsOf: victim) == previous)
        try FileManager.default.removeItem(at: authorized)
        try FileManager.default.removeItem(at: ssh)
        try FileManager.default.createSymbolicLink(at: ssh, withDestinationURL: directory)
        #expect(try await ProcessRunner().run(command).exitCode != 0)
    }

    @Test func setupRefusesExistingAndSymlinkedKeyDirectoriesBeforePrompting() async throws {
        let (server, account, reference) = fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = SSHManagedKeys.keyURL(for: reference, rootURL: directory)
        let keyDirectory = key.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("preserve original".utf8)
        try original.write(to: key)
        let command = try SSHManagedKeys.setupCommand(server: server, account: account, reference: reference, agentSocket: "/tmp/fixture-agent", rootURL: directory)
        #expect(try await ProcessRunner().run(command).exitCode != 0)
        #expect(try Data(contentsOf: key) == original)
        try FileManager.default.removeItem(at: keyDirectory)
        let other = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: keyDirectory, withDestinationURL: other)
        #expect(try await ProcessRunner().run(command).exitCode != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    @Test func nativeSetupGeneratesEncryptedKeyAndRegistersOnlyPublicData() async throws {
        let (server, account, reference) = fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remoteHome = directory.appendingPathComponent("remote-home")
        try FileManager.default.createDirectory(at: remoteHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("agent.sock").path
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice; agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { if agent.isRunning { agent.terminate() }; agent.waitUntilExit() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: socket), "Disposable ssh-agent could not bind its test socket; this test requires a runtime that permits local Unix sockets.")

        let sshFixture = directory.appendingPathComponent("ssh-local-fixture")
        let fixtureScript = """
        #!/bin/sh
        HOME=\(ShellCommand.quote(remoteHome.path)); export HOME
        for argument do remote_command="$argument"; done
        exec /bin/sh -c "$remote_command"
        """
        try Data(fixtureScript.utf8).write(to: sshFixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshFixture.path)
        let root = directory.appendingPathComponent("keys with ' quote")
        let setup = try SSHManagedKeys.setupCommand(server: server, account: account, reference: reference, agentSocket: socket, rootURL: root)
        let localScript = setup.arguments[1].replacingOccurrences(of: "'/usr/bin/ssh'", with: ShellCommand.quote(sshFixture.path))
        let scriptURL = directory.appendingPathComponent("setup.sh")
        try Data(localScript.utf8).write(to: scriptURL)
        let ttyDriver = #"""
        import os, pty, select, signal, sys, time
        pid, fd = pty.fork()
        if pid == 0:
            os.execv('/bin/sh', ['/bin/sh', sys.argv[1]])
        prompts = [b'(empty for no passphrase):', b'Enter same passphrase again:', b'Enter passphrase for']
        if len(sys.argv) > 2: prompts = [b'Enter passphrase for']
        pending = b''
        output = b''
        step = 0
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                try: chunk = os.read(fd, 65536)
                except OSError: break
                if not chunk: break
                pending += chunk
                output += chunk
                if step < len(prompts) and prompts[step] in pending:
                    os.write(fd, b'fixture-only-passphrase\n')
                    step += 1
                    pending = b''
            waited, status = os.waitpid(pid, os.WNOHANG)
            if waited:
                if status: sys.stderr.buffer.write(output)
                sys.exit(os.waitstatus_to_exitcode(status))
        else:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            sys.stderr.buffer.write(output)
            sys.exit(98)
        _, status = os.waitpid(pid, 0)
        if status: sys.stderr.buffer.write(output)
        sys.exit(os.waitstatus_to_exitcode(status))
        """#
        let run = ShellCommand(executable: "/usr/bin/python3", arguments: ["-c", ttyDriver, scriptURL.path], environment: setup.environment)
        let result = try await ProcessRunner().run(run, timeout: 25)
        #expect(result.exitCode == 0, "Native setup failed: \(result.stderr)")
        let key = SSHManagedKeys.keyURL(for: reference, rootURL: root)
        let permissions = try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: key.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(directoryPermissions == 0o700)
        let publicKey = try Data(contentsOf: URL(fileURLWithPath: key.path + ".pub"))
        #expect(try Data(contentsOf: remoteHome.appendingPathComponent(".ssh/authorized_keys")) == publicKey)
        let unencryptedRead = try await ProcessRunner().run(ShellCommand(executable: "/usr/bin/ssh-keygen", arguments: ["-y", "-P", "", "-f", key.path]))
        #expect(unencryptedRead.exitCode != 0)
        let listed = try await ProcessRunner().run(ShellCommand(executable: "/usr/bin/ssh-add", arguments: ["-L"], environment: setup.environment))
        #expect(listed.exitCode == 0)
        #expect(Data(listed.stdout.utf8) == publicKey)
        let remove = ShellCommand(executable: "/usr/bin/ssh-add", arguments: ["-d", key.path + ".pub"], environment: setup.environment)
        #expect(try await ProcessRunner().run(remove).exitCode == 0)
        let unlock = try SSHManagedKeys.unlockCommand(reference: reference, agentSocket: socket, rootURL: root)
        try Data(unlock.arguments[1].utf8).write(to: scriptURL)
        let unlocked = try await ProcessRunner().run(ShellCommand(executable: "/usr/bin/python3", arguments: ["-c", ttyDriver, scriptURL.path, "unlock"], environment: unlock.environment), timeout: 25)
        #expect(unlocked.exitCode == 0, "Native unlock failed: \(unlocked.stderr)")
        let relisted = try await ProcessRunner().run(ShellCommand(executable: "/usr/bin/ssh-add", arguments: ["-L"], environment: unlock.environment))
        #expect(Data(relisted.stdout.utf8) == publicKey)
        #expect(try await ProcessRunner().run(setup).exitCode != 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: key.path + ".pub")) == publicKey)
    }
}
