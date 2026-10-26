import Foundation
import Testing
@testable import InfraCore

@Suite struct SSHAutomaticKeyTests {
    private func fixture() -> (ServerProfile, SSHAccount, SSHManagedKeyReference) {
        let account = SSHAccount(username: "fixture")
        let server = ServerProfile(name: "Fixture", host: "example.invalid", accounts: [account], monitorAccountID: account.id)
        let reference = SSHManagedKeyReference(target: SSHConnectionTarget(server: server, account: account, resolvedHost: server.host), requiresAgent: false)
        return (server, account, reference)
    }

    @Test func legacyKeysKeepAgentRequirementAndNewKeysPersistDirectMode() throws {
        let (_, _, reference) = fixture()
        let encoded = try JSONEncoder().encode(reference)
        #expect(try JSONDecoder().decode(SSHManagedKeyReference.self, from: encoded).requiresAgent == false)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "requiresAgent")
        let loaded = try JSONDecoder().decode(SSHManagedKeyReference.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(loaded.requiresAgent)
        #expect(loaded.id == reference.id)
        #expect(loaded.target == reference.target)
    }

    @Test func automaticKeysConnectAndVerifyWithoutAgentOrPasswordFallback() throws {
        var (server, account, reference) = fixture()
        account.authMethod = .managedKey
        account.managedKey = reference
        server.accounts = [account]
        let tab = TerminalTab(serverID: server.id, accountID: account.id, title: "Existing")
        let commands = [
            try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: false, managedKeyAgentSocket: ""),
            try SSHCommandBuilder.probe(server: server, account: account, tab: tab, managedKeyAgentSocket: ""),
            try SSHCommandBuilder.monitor(server: server, account: account, managedKeyAgentSocket: ""),
            try SSHManagedKeys.verificationCommand(server: server, account: account, reference: reference)
        ]
        for command in commands {
            for option in ["IdentityAgent=none", "IdentityFile=none", "IdentitiesOnly=yes", "PreferredAuthentications=publickey", "PasswordAuthentication=no", "BatchMode=yes", "StrictHostKeyChecking=yes", "UseKeychain=no", "AddKeysToAgent=no"] {
                #expect(command.arguments.contains(option))
            }
            #expect(command.arguments.contains(SSHManagedKeys.keyURL(for: reference).path))
            #expect(command.environment["SSH_AUTH_SOCK"] == "")
            #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "never")
        }
    }

    @Test func generatesUnencryptedPrivateKeyWithPrivatePermissionsAndPreservesExistingAttempt() async throws {
        let (_, _, reference) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticSSHKey-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try SSHManagedKeys.automaticKeyGenerationCommand(reference: reference, rootURL: root)
        let result = try await ProcessRunner().run(command)
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("ssh-ed25519 "))
        #expect(result.stdout.split(separator: "\n").count == 1)
        let key = SSHManagedKeys.keyURL(for: reference, rootURL: root)
        for (url, permissions) in [(root, 0o700), (key.deletingLastPathComponent(), 0o700), (key, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == permissions)
        }
        let publicKey = try Data(contentsOf: key.appendingPathExtension("pub"))
        let derived = try await ProcessRunner().run(ShellCommand(executable: "/usr/bin/ssh-keygen", arguments: ["-y", "-P", "", "-f", key.path]))
        #expect(derived.exitCode == 0)
        #expect(result.stdout.split(separator: " ").prefix(2) == derived.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").prefix(2))
        let repeated = try await ProcessRunner().run(command)
        #expect(repeated.exitCode != 0)
        #expect(try Data(contentsOf: key.appendingPathExtension("pub")) == publicKey)
    }

    @Test func generationRefusesSymlinkRootAndExistingAttemptDirectory() async throws {
        let (_, _, reference) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticSSHGuard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("preserved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("keys")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let result = try await ProcessRunner().run(SSHManagedKeys.automaticKeyGenerationCommand(reference: reference, rootURL: link))
        #expect(result.exitCode != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let key = SSHManagedKeys.keyURL(for: reference, rootURL: destination)
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = key.deletingLastPathComponent().appendingPathComponent("preserved.txt")
        try Data("existing attempt".utf8).write(to: marker)
        let collision = try await ProcessRunner().run(SSHManagedKeys.automaticKeyGenerationCommand(reference: reference, rootURL: destination))
        #expect(collision.exitCode != 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "existing attempt")
        #expect(!FileManager.default.fileExists(atPath: key.path))
    }

    @Test func registrationUsesOnlyPublicInputAndOneStrictPasswordAttempt() throws {
        let (_, _, reference) = fixture()
        let publicKey = "ssh-ed25519 \(Data(repeating: 0, count: 51).base64EncodedString()) fixture"
        let command = try SSHManagedKeys.passwordRegistrationCommand(reference: reference, publicKey: publicKey + "\n")
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.standardInput == publicKey + "\n")
        #expect(command.arguments.last == SSHManagedKeys.registrationScript)
        for option in ["StrictHostKeyChecking=yes", "PreferredAuthentications=password", "PasswordAuthentication=yes", "PubkeyAuthentication=no", "KbdInteractiveAuthentication=no", "NumberOfPasswordPrompts=1", "IdentityAgent=none", "UseKeychain=no", "AddKeysToAgent=no", "ControlPath=none"] {
            #expect(command.arguments.contains(option))
        }
        #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "never")
        #expect(command.environment["LC_ALL"] == "C")
        #expect(!command.arguments.contains(publicKey))
        for invalid in ["ssh-rsa AAAA", "ssh-ed25519 !!!", publicKey + "\n" + publicKey, publicKey + "\0extra"] {
            #expect(throws: (any Error).self) { try SSHManagedKeys.passwordRegistrationCommand(reference: reference, publicKey: invalid) }
        }
    }
}
