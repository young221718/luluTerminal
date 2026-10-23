import Foundation

public typealias SSHCommandExecutor = @Sendable (ShellCommand, TimeInterval) async throws -> ProcessResult

public struct SSHConnectionTarget: Codable, Equatable, Sendable {
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

public enum SSHConnectionError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

public enum SSHConnectionResolver {
    public static func resolveTarget(server: ServerProfile, account: SSHAccount, execute: SSHCommandExecutor) async throws -> SSHConnectionTarget {
        try server.validate()
        guard server.kind == .ssh, server.accounts.contains(account) else {
            throw SSHConnectionError.message("SSH 서버와 계정을 확인하세요.")
        }
        let command = ShellCommand(executable: "/usr/bin/ssh", arguments: ["-G", "-o", "UseKeychain=no", "-o", "AddKeysToAgent=no", "-p", String(server.port), "-l", account.username, "--", server.host], environment: ["SSH_ASKPASS_REQUIRE": "never", "SSH_ASKPASS": ""])
        let result = try await execute(command, 5)
        guard result.exitCode == 0 else { throw SSHConnectionError.message("SSH 설정을 확인할 수 없습니다. 기존 SSH 설정을 확인하세요.") }
        let options = result.stdout.split(separator: "\n").reduce(into: [String: String]()) { values, line in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 2 { values[String(parts[0]).lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
        }
        for key in ["proxyjump", "proxycommand", "hostkeyalias"] {
            if let value = options[key], !value.isEmpty, key == "hostkeyalias" || value != "none" {
                throw SSHConnectionError.message("앱에서 생성한 SSH 키는 경유 연결 또는 HostKeyAlias 설정을 지원하지 않습니다. SSH 키·기존 설정으로 연결하세요.")
            }
        }
        guard let hostname = options["hostname"], validHost(hostname), hostname.utf8.count <= 100,
              options["user"] == account.username, options["port"] == String(server.port), account.username.utf8.count <= 100 else {
            throw SSHConnectionError.message("SSH 연결 대상이 올바르지 않습니다. 서버 주소와 계정을 확인하세요.")
        }
        return SSHConnectionTarget(server: server, account: account, resolvedHost: hostname)
    }

    static func validHost(_ host: String) -> Bool {
        guard let range = host.range(of: "^[A-Za-z0-9][A-Za-z0-9._:%-]*$", options: .regularExpression) else { return false }
        return range == host.startIndex..<host.endIndex
    }
}
