import Foundation

public struct SSHManagedKeyReference: Codable, Equatable, Sendable {
    public var id: UUID
    public var target: SSHConnectionTarget
    public var requiresAgent: Bool
    public init(id: UUID = UUID(), target: SSHConnectionTarget, requiresAgent: Bool = true) {
        self.id = id; self.target = target; self.requiresAgent = requiresAgent
    }
    private enum CodingKeys: String, CodingKey { case id, target, requiresAgent }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        target = try values.decode(SSHConnectionTarget.self, forKey: .target)
        // Existing encrypted keys still need the user's login-session agent.
        requiresAgent = try values.decodeIfPresent(Bool.self, forKey: .requiresAgent) ?? true
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(target, forKey: .target)
        if !requiresAgent { try values.encode(false, forKey: .requiresAgent) }
    }
}

public enum SSHManagedKeys {
    public static func keyURL(for reference: SSHManagedKeyReference, rootURL: URL? = nil) -> URL {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InfraTerminal/SSHKeys", isDirectory: true)
        return root.appendingPathComponent(reference.id.uuidString.lowercased(), isDirectory: true).appendingPathComponent("id_ed25519")
    }

    public static func validate(reference: SSHManagedKeyReference, server: ServerProfile, account: SSHAccount) throws {
        try server.validate()
        guard server.accounts.contains(account), reference.target.matches(server: server, account: account) else {
            throw CoreError.invalidProfile("SSH 키의 연결 대상이 바뀌었습니다. 이 서버와 계정에 키를 다시 설정하세요.")
        }
        try validate(reference: reference)
    }

    private static func validate(reference: SSHManagedKeyReference) throws {
        let target = reference.target
        guard SSHConnectionResolver.validHost(target.host), SSHConnectionResolver.validHost(target.resolvedHost),
              (1...65535).contains(target.port),
              let range = target.username.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*[$]?$", options: .regularExpression),
              range == target.username.startIndex..<target.username.endIndex else {
            throw CoreError.invalidProfile("SSH 키의 연결 대상이 올바르지 않습니다.")
        }
    }

    static func environment(agentSocket: String) throws -> [String: String] {
        guard agentSocket.hasPrefix("/"), !agentSocket.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw CoreError.invalidProfile("SSH 에이전트가 없습니다. macOS 로그인 세션에서 다시 시도하세요.")
        }
        return ["SSH_AUTH_SOCK": agentSocket, "SSH_ASKPASS_REQUIRE": "never", "APPLE_SSH_ADD_BEHAVIOR": "openssh", "SSH_ASKPASS": ""]
    }

    static func environment(reference: SSHManagedKeyReference, agentSocket: String?) throws -> [String: String] {
        if reference.requiresAgent {
            return try environment(agentSocket: agentSocket ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? "")
        }
        return ["SSH_AUTH_SOCK": "", "SSH_ASKPASS_REQUIRE": "never", "SSH_ASKPASS": ""]
    }

    static func connectionArguments(reference: SSHManagedKeyReference, interactive: Bool, rootURL: URL? = nil) -> [String] {
        // A missing -i path is discarded by ssh; the sentinel also disables its default identity fallback.
        return (reference.requiresAgent ? [] : ["-o", "IdentityAgent=none"]) +
        [interactive ? "-tt" : "-T", "-F", "/dev/null", "-o", "IdentityFile=none", "-i", keyURL(for: reference, rootURL: rootURL).path,
         "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey", "-o", "PubkeyAuthentication=yes",
         "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "BatchMode=yes",
         "-o", "StrictHostKeyChecking=yes", "-o", "UseKeychain=no", "-o", "AddKeysToAgent=no",
         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
         "-o", "NoHostAuthenticationForLocalhost=no", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
         "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
         "-p", String(reference.target.port), "-l", reference.target.username, "--", reference.target.resolvedHost]
    }

    public static func verificationCommand(server: ServerProfile, account: SSHAccount, reference: SSHManagedKeyReference,
                                           agentSocket: String? = nil, rootURL: URL? = nil) throws -> ShellCommand {
        try validate(reference: reference, server: server, account: account)
        return ShellCommand(executable: "/usr/bin/ssh", arguments: connectionArguments(reference: reference, interactive: false, rootURL: rootURL) + ["true"], environment: try environment(reference: reference, agentSocket: agentSocket))
    }

    public static func automaticKeyGenerationCommand(reference: SSHManagedKeyReference, rootURL: URL? = nil) throws -> ShellCommand {
        try validate(reference: reference)
        guard !reference.requiresAgent else { throw CoreError.invalidProfile("자동 설정에는 암호 없는 새 키가 필요합니다.") }
        let key = keyURL(for: reference, rootURL: rootURL)
        let directory = key.deletingLastPathComponent()
        let script = """
        set -eu
        umask 077
        root=\(ShellCommand.quote(directory.deletingLastPathComponent().path))
        directory=\(ShellCommand.quote(directory.path))
        key=\(ShellCommand.quote(key.path))
        [ ! -L "$root" ] && { [ ! -e "$root" ] || [ -d "$root" ]; } || exit 1
        mkdir -p "$root"
        chmod 700 "$root"
        mkdir -m 700 "$directory" || exit 1
        /usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$key" -C \(ShellCommand.quote("luluTerminal-" + reference.id.uuidString.lowercased())) </dev/null
        [ ! -L "$key" ] && [ -f "$key" ] && [ ! -L "$key.pub" ] && [ -f "$key.pub" ] || exit 1
        chmod 600 "$key"
        cat "$key.pub"
        """
        return ShellCommand(executable: "/bin/sh", arguments: ["-c", script], environment: ["SSH_ASKPASS_REQUIRE": "never", "SSH_ASKPASS": ""])
    }

    public static func passwordRegistrationCommand(reference: SSHManagedKeyReference, publicKey: String) throws -> ShellCommand {
        try validate(reference: reference)
        let line = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.split(separator: " ", maxSplits: 2)
        guard line.utf8.count <= 16_384, !line.contains(where: { $0 == "\0" || $0 == "\r" || $0 == "\n" }),
              fields.count >= 2, fields[0] == "ssh-ed25519", Data(base64Encoded: String(fields[1])) != nil else {
            throw CoreError.invalidProfile("생성된 SSH 공개 키를 확인할 수 없습니다.")
        }
        return ShellCommand(executable: "/usr/bin/ssh", arguments: [
            "-T", "-F", "/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=no",
            "-o", "PreferredAuthentications=password", "-o", "PasswordAuthentication=yes", "-o", "PubkeyAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no", "-o", "NumberOfPasswordPrompts=1", "-o", "IdentityAgent=none",
            "-o", "UseKeychain=no", "-o", "AddKeysToAgent=no", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ControlPersist=no", "-o", "NoHostAuthenticationForLocalhost=no", "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "-p", String(reference.target.port), "-l", reference.target.username, "--", reference.target.resolvedHost, registrationScript
        ], standardInput: line + "\n", environment: ["LC_ALL": "C", "SSH_AUTH_SOCK": "", "SSH_ASKPASS_REQUIRE": "never", "SSH_ASKPASS": ""])
    }

    public static func unlockCommand(reference: SSHManagedKeyReference, agentSocket: String, rootURL: URL? = nil) throws -> ShellCommand {
        try validate(reference: reference)
        let key = keyURL(for: reference, rootURL: rootURL)
        let script = """
        set -eu
        key=\(ShellCommand.quote(key.path))
        directory=\(ShellCommand.quote(key.deletingLastPathComponent().path))
        [ ! -L "$directory" ] && [ -d "$directory" ] && [ ! -L "$key" ] && [ -f "$key" ] || { printf '%s\\n' 'SSH key is missing or unsafe. Existing files were preserved.' >&2; exit 1; }
        exec /usr/bin/ssh-add "$key" </dev/tty
        """
        return ShellCommand(executable: "/bin/sh", arguments: ["-c", script], environment: try environment(agentSocket: agentSocket))
    }

    public static func setupCommand(server: ServerProfile, account: SSHAccount, reference: SSHManagedKeyReference,
                                    agentSocket: String, rootURL: URL? = nil) throws -> ShellCommand {
        try validate(reference: reference, server: server, account: account)
        let key = keyURL(for: reference, rootURL: rootURL)
        let directory = key.deletingLastPathComponent()
        let registration = ShellCommand(executable: "/usr/bin/ssh", arguments: [
            "-T", "-F", "/dev/null", "-o", "StrictHostKeyChecking=ask", "-o", "BatchMode=no",
            "-o", "UseKeychain=no", "-o", "AddKeysToAgent=no", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ControlPersist=no", "-o", "NoHostAuthenticationForLocalhost=no", "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=15", "-p", String(reference.target.port),
            "-l", reference.target.username, "--", reference.target.resolvedHost, registrationScript
        ])
        let script = """
        set -eu
        umask 077
        root=\(ShellCommand.quote(directory.deletingLastPathComponent().path))
        directory=\(ShellCommand.quote(directory.path))
        key=\(ShellCommand.quote(key.path))
        [ ! -L "$root" ] && { [ ! -e "$root" ] || [ -d "$root" ]; } || { printf '%s\\n' 'SSH key directory is unsafe. Existing files were preserved.' >&2; exit 1; }
        mkdir -p "$root"
        mkdir -m 700 "$directory" || { printf '%s\\n' 'SSH key attempt already exists. Existing files were preserved. Start a new setup attempt.' >&2; exit 1; }
        /usr/bin/ssh-keygen -t ed25519 -f "$key" -C \(ShellCommand.quote("luluTerminal-" + reference.id.uuidString.lowercased())) </dev/tty
        [ ! -L "$key" ] && [ -f "$key" ] && [ ! -L "$key.pub" ] && [ -f "$key.pub" ] || exit 1
        chmod 600 "$key"
        /usr/bin/ssh-add "$key" </dev/tty
        cat "$key.pub" | \(registration.shellString)
        printf '%s\\n' 'Public key registered. Return to luluTerminal to verify this exact key.'
        """
        return ShellCommand(executable: "/bin/sh", arguments: ["-c", script], environment: try environment(agentSocket: agentSocket))
    }

    // Only the generated public key enters stdin; authentication prompts stay on the local TTY.
    static let registrationScript = """
    set -eu
    umask 077
    directory="$HOME/.ssh"
    file="$directory/authorized_keys"
    [ ! -L "$directory" ] && { [ ! -e "$directory" ] || [ -d "$directory" ]; } || { printf '%s\\n' 'Unsafe .ssh directory; no keys changed.' >&2; exit 1; }
    if [ ! -d "$directory" ]; then mkdir -m 700 "$directory"; fi
    [ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || { printf '%s\\n' 'Unsafe authorized_keys; no keys changed.' >&2; exit 1; }
    IFS= read -r key
    case "$key" in "ssh-ed25519 "*) ;; *) printf '%s\\n' 'Expected an Ed25519 public key.' >&2; exit 1 ;; esac
    if [ ! -e "$file" ]; then (set -C; : > "$file"); fi
    [ ! -L "$file" ] && [ -f "$file" ] || exit 1
    if ! grep -Fqx -- "$key" "$file"; then
        if [ -s "$file" ] && [ "$(tail -c 1 "$file" | wc -l)" -eq 0 ]; then printf '\\n' >> "$file"; fi
        printf '%s\\n' "$key" >> "$file"
    fi
    chmod 700 "$directory"
    chmod 600 "$file"
    """
}
