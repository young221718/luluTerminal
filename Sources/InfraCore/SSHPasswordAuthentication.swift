import Foundation
import Darwin

public typealias SSHCommandExecutor = @Sendable (ShellCommand, TimeInterval) async throws -> ProcessResult

public struct SSHPasswordTarget: Codable, Equatable, Sendable {
    public var serverID: UUID
    public var accountID: UUID
    public var host: String
    public var port: Int
    public var username: String
    public var resolvedHost: String
    public init(server: ServerProfile, account: SSHAccount, resolvedHost: String) {
        serverID = server.id; accountID = account.id; host = server.host; port = server.port
        username = account.username; self.resolvedHost = resolvedHost
    }
    public func matches(server: ServerProfile, account: SSHAccount) -> Bool {
        server.kind == .ssh && serverID == server.id && accountID == account.id && host == server.host
            && port == server.port && username == account.username
    }
}

public struct SSHPasswordReference: Codable, Equatable, Sendable {
    public var id: UUID
    public var target: SSHPasswordTarget
    public init(id: UUID = UUID(), target: SSHPasswordTarget) { self.id = id; self.target = target }
}

public enum SSHPasswordError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public struct SSHAuthenticationContext: Sendable {
    public let reference: SSHPasswordReference
    public let helperPath: String
    public init(reference: SSHPasswordReference, helperPath: String) { self.reference = reference; self.helperPath = helperPath }
    public var environment: [String: String] {
        // The reference contains destination metadata only; the password stays in Keychain.
        let data = try! JSONEncoder().encode(reference)
        return ["SSH_ASKPASS": helperPath, "SSH_ASKPASS_REQUIRE": "force", "LC_ALL": "C",
                "LULUTERMINAL_SSH_REFERENCE": data.base64EncodedString()]
    }
}

public enum SSHPasswordAuthentication {
    public static var helperPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/luluTerminalAskPass").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public static func resolveTarget(server: ServerProfile, account: SSHAccount, execute: SSHCommandExecutor) async throws -> SSHPasswordTarget {
        try server.validate()
        guard server.kind == .ssh, server.accounts.contains(account) else {
            throw SSHPasswordError.message("SSH 서버와 계정을 확인하세요.")
        }
        let command = ShellCommand(executable: "/usr/bin/ssh", arguments: ["-G", "-p", String(server.port), "-l", account.username, "--", server.host])
        let result = try await execute(command, 5)
        guard result.exitCode == 0 else { throw SSHPasswordError.message("SSH 설정을 확인할 수 없습니다. 기존 SSH 설정을 확인하세요.") }
        let options = result.stdout.split(separator: "\n").reduce(into: [String: String]()) { values, line in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 2 { values[String(parts[0]).lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
        }
        for key in ["proxyjump", "proxycommand", "hostkeyalias"] {
            if let value = options[key], !value.isEmpty, key == "hostkeyalias" || value != "none" {
                throw SSHPasswordError.message("경유 연결 또는 HostKeyAlias 설정은 저장 비밀번호 자동 인증을 지원하지 않습니다. SSH 키·기존 설정으로 연결하세요.")
            }
        }
        guard let hostname = options["hostname"], validHost(hostname), hostname.utf8.count <= 100,
              options["user"] == account.username, options["port"] == String(server.port), account.username.utf8.count <= 100 else {
            throw SSHPasswordError.message("SSH 연결 대상이 올바르지 않습니다. 서버 주소와 계정을 확인하세요.")
        }
        return SSHPasswordTarget(server: server, account: account, resolvedHost: hostname)
    }

    public static func context(server: ServerProfile, account: SSHAccount, helperPath: String, execute: SSHCommandExecutor) async throws -> SSHAuthenticationContext {
        guard account.authMethod == .password, let reference = account.credential,
              reference.target.matches(server: server, account: account) else {
            throw SSHPasswordError.message("이 연결 대상의 비밀번호를 다시 저장하세요.")
        }
        let target = try await resolveTarget(server: server, account: account, execute: execute)
        guard reference.target == target else { throw SSHPasswordError.message("SSH 별칭의 연결 대상이 바뀌었습니다. 비밀번호를 다시 저장하세요.") }
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { throw SSHPasswordError.message("비밀번호 연결 도우미가 없습니다. 앱을 다시 설치하세요.") }
        return SSHAuthenticationContext(reference: reference, helperPath: helperPath)
    }

    public static func validateAskpass(prompt: String, reference: SSHPasswordReference, parentExecutable: String) -> Bool {
        let target = reference.target
        return parentExecutable == "/usr/bin/ssh" && validHost(target.resolvedHost)
            && target.resolvedHost.utf8.count <= 100 && target.username.utf8.count <= 100
            && prompt == "\(target.username)@\(target.resolvedHost)'s password: "
    }

    public static func respondToAskpass(arguments: [String], environment: [String: String]) -> Int32 {
        guard arguments.count == 3, arguments[1] == "--ssh-askpass", environment["SSH_ASKPASS_REQUIRE"] == "force",
              let encoded = environment["LULUTERMINAL_SSH_REFERENCE"], encoded.utf8.count <= 8192,
              let data = Data(base64Encoded: encoded), let reference = try? JSONDecoder().decode(SSHPasswordReference.self, from: data) else { return 1 }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getppid(), &path, UInt32(path.count)) > 0,
              validateAskpass(prompt: arguments[2], reference: reference, parentExecutable: String(cString: path)) else { return 1 }
        do {
            let password = try KeychainCredentialStore().read(reference: reference)
            guard !password.isEmpty, !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return 1 }
            try FileHandle.standardOutput.write(contentsOf: Data((password + "\n").utf8))
            return 0
        } catch { return 1 }
    }

    static func validHost(_ host: String) -> Bool {
        guard let range = host.range(of: "^[A-Za-z0-9][A-Za-z0-9._:%-]*$", options: .regularExpression) else { return false }
        return range == host.startIndex..<host.endIndex
    }
}
