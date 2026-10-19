import Foundation

public struct ShellCommand: Sendable {
    public var executable: String
    public var arguments: [String]
    public var standardInput: String?
    public init(executable: String, arguments: [String], standardInput: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.standardInput = standardInput
    }
    public var shellString: String { ([executable] + arguments).map(Self.quote).joined(separator: " ") }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

public enum SSHCommandBuilder {
    private static func base(server: ServerProfile, account: SSHAccount, interactive: Bool) throws -> [String] {
        guard server.kind == .ssh else { throw CoreError.invalidProfile("Local connections must not enter SSH commands.") }
        try server.validate()
        guard server.accounts.contains(account) else { throw CoreError.invalidProfile("Account does not belong to this server.") }
        return [interactive ? "-tt" : "-T", "-o", interactive ? "StrictHostKeyChecking=ask" : "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
            + ["-o", interactive ? "BatchMode=no" : "BatchMode=yes"]
            + ["-p", String(server.port), "-l", account.username, "--", server.host]
    }
    private static func validate(tab: TerminalTab, server: ServerProfile, account: SSHAccount) throws {
        guard tab.serverID == server.id, tab.accountID == account.id else {
            throw CoreError.invalidWorkspace("Tab identity does not match the SSH server/account.")
        }
    }
    public static func terminal(server: ServerProfile, account: SSHAccount, tab: TerminalTab, create: Bool) throws -> ShellCommand {
        try validate(tab: tab, server: server, account: account)
        let target = ShellCommand.quote("=" + tab.sessionName)
        let script: String
        if create {
            script = "exec tmux new-session -s " + ShellCommand.quote(tab.sessionName)
        } else {
            script = "command -v tmux >/dev/null 2>&1 || { printf '%s\\n' 'tmux is unavailable on this server.' >&2; exit 127; }; "
                + "tmux has-session -t " + target + " 2>/dev/null || { printf '%s\\n' 'Remote tmux session is missing. Choose Create session to start a new session.' >&2; exit 44; }; "
                + "exec tmux attach-session -t " + target
        }
        return ShellCommand(executable: "/usr/bin/ssh", arguments: try base(server: server, account: account, interactive: true) + [script])
    }
    public static func probe(server: ServerProfile, account: SSHAccount, tab: TerminalTab) throws -> ShellCommand {
        try validate(tab: tab, server: server, account: account)
        let script = "command -v tmux >/dev/null 2>&1 || exit 127; tmux has-session -t " + ShellCommand.quote("=" + tab.sessionName) + " 2>/dev/null || exit 44"
        return ShellCommand(executable: "/usr/bin/ssh", arguments: try base(server: server, account: account, interactive: false) + [script])
    }
    public static func monitor(server: ServerProfile, account: SSHAccount) throws -> ShellCommand {
        ShellCommand(executable: "/usr/bin/ssh", arguments: try base(server: server, account: account, interactive: false) + ["sh -s"], standardInput: LinuxCollector.script)
    }
}
