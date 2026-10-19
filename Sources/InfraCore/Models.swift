import Foundation

public enum CoreError: Error, LocalizedError, Equatable {
    case invalidProfile(String)
    case invalidWorkspace(String)
    case unsupportedSchema(Int)
    case accountIdentityChanged

    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let reason), .invalidWorkspace(let reason): return reason
        case .unsupportedSchema(let version): return "Unsupported workspace schema: \(version). Preserve the file and use a compatible app."
        case .accountIdentityChanged: return "An account used by an existing tab changed. Create a new account identity instead."
        }
    }
}

public struct SSHAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var username: String
    public init(id: UUID = UUID(), username: String) { self.id = id; self.username = username }
}

public enum ServerConnectionKind: String, Codable, Sendable { case ssh, local }

public struct ServerProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var accounts: [SSHAccount]
    public var monitorAccountID: UUID?
    public var monitoringEnabled: Bool
    public var kind: ServerConnectionKind

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22,
                accounts: [SSHAccount], monitorAccountID: UUID? = nil, monitoringEnabled: Bool = true, kind: ServerConnectionKind = .ssh) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.accounts = accounts; self.monitorAccountID = monitorAccountID; self.monitoringEnabled = monitoringEnabled
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, accounts, monitorAccountID, monitoringEnabled, kind
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        accounts = try values.decode([SSHAccount].self, forKey: .accounts)
        monitorAccountID = try values.decodeIfPresent(UUID.self, forKey: .monitorAccountID)
        monitoringEnabled = try values.decode(Bool.self, forKey: .monitoringEnabled)
        kind = try values.decodeIfPresent(ServerConnectionKind.self, forKey: .kind) ?? .ssh
    }

    public func validate() throws {
        if kind == .local {
            guard id == LocalMachine.serverID, host == "localhost", accounts.count == 1,
                  accounts.first?.id == LocalMachine.accountID, accounts.first?.username.isEmpty == false,
                  monitorAccountID == LocalMachine.accountID else {
                throw CoreError.invalidProfile("Only the built-in local Mac may use a local connection.")
            }
            return
        }
        guard id != LocalMachine.serverID else { throw CoreError.invalidProfile("The local Mac identity is reserved.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError.invalidProfile("Server name is required.")
        }
        guard Self.matches(host, "^[A-Za-z0-9][A-Za-z0-9._:%-]*$") else {
            throw CoreError.invalidProfile("Host must be an SSH alias, hostname, or IP address without spaces or shell characters.")
        }
        guard (1...65535).contains(port) else { throw CoreError.invalidProfile("Port must be 1...65535.") }
        guard !accounts.isEmpty, Set(accounts.map(\.id)).count == accounts.count,
              Set(accounts.map(\.username)).count == accounts.count else {
            throw CoreError.invalidProfile("At least one unique account is required.")
        }
        for account in accounts {
            guard Self.matches(account.username, "^[A-Za-z0-9_][A-Za-z0-9_.-]*[$]?$") else {
                throw CoreError.invalidProfile("Invalid SSH username.")
            }
        }
        if let monitorAccountID, !accounts.contains(where: { $0.id == monitorAccountID }) {
            throw CoreError.invalidProfile("Monitoring account must belong to this server.")
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        // Full-range check also rejects a trailing newline, which $ alone accepts.
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }
}

public struct TerminalTab: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var serverID: UUID
    public var accountID: UUID
    public var title: String
    public var isClosed: Bool
    public init(id: UUID = UUID(), serverID: UUID, accountID: UUID, title: String, isClosed: Bool = false) {
        self.id = id; self.serverID = serverID; self.accountID = accountID; self.title = title; self.isClosed = isClosed
    }
    public var sessionName: String {
        "infra_" + [serverID, accountID, id].map { $0.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }.joined(separator: "_")
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var servers: [ServerProfile] = []
    public var tabs: [TerminalTab] = []
    public var selectedServerID: UUID?
    public var selectedTabByServer: [UUID: UUID] = [:]
    public init() {}

    public mutating func select(serverID: UUID) {
        guard servers.contains(where: { $0.id == serverID }) else { return }
        selectedServerID = serverID
        if !tabs.contains(where: { $0.id == selectedTabByServer[serverID] && $0.serverID == serverID && !$0.isClosed }) {
            selectedTabByServer[serverID] = tabs.last(where: { $0.serverID == serverID && !$0.isClosed })?.id
        }
    }
    public mutating func select(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID && !$0.isClosed }) else { return }
        selectedServerID = tab.serverID; selectedTabByServer[tab.serverID] = tabID
    }
    public mutating func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isClosed = true
        let serverID = tabs[index].serverID
        if selectedTabByServer[serverID] == tabID {
            selectedTabByServer[serverID] = tabs.last(where: { $0.serverID == serverID && !$0.isClosed })?.id
        }
    }
    public mutating func reopen(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isClosed = false; select(tabID: tabID)
    }
    public mutating func add(tab: TerminalTab) throws {
        guard !tabs.contains(where: { $0.id == tab.id }),
              let server = servers.first(where: { $0.id == tab.serverID }),
              server.accounts.contains(where: { $0.id == tab.accountID }) else {
            throw CoreError.invalidWorkspace("Tab must have a unique ID and belong to an existing server/account.")
        }
        tabs.append(tab)
        if !tab.isClosed { select(tabID: tab.id) }
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw CoreError.unsupportedSchema(schemaVersion) }
        guard Set(servers.map(\.id)).count == servers.count, Set(tabs.map(\.id)).count == tabs.count else {
            throw CoreError.invalidWorkspace("Duplicate server or tab identity.")
        }
        for server in servers { try server.validate() }
        for tab in tabs {
            guard servers.contains(where: { $0.id == tab.serverID && $0.accounts.contains(where: { $0.id == tab.accountID }) }) else {
                throw CoreError.invalidWorkspace("A retained tab references a missing server or account.")
            }
        }
        if let selectedServerID, !servers.contains(where: { $0.id == selectedServerID }) {
            throw CoreError.invalidWorkspace("Selected server is missing.")
        }
        for (serverID, tabID) in selectedTabByServer {
            guard tabs.contains(where: { $0.serverID == serverID && $0.id == tabID && !$0.isClosed }) else {
                throw CoreError.invalidWorkspace("Selected tab is missing or closed.")
            }
        }
    }
}

public struct StateStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> WorkspaceState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: url))
        try state.validate()
        return state
    }
    public func save(_ state: WorkspaceState) throws {
        try state.validate()
        // Read before writing: corrupt/unsupported files remain available for explicit recovery.
        if let previous = try load() {
            for tab in previous.tabs {
                guard let oldServer = previous.servers.first(where: { $0.id == tab.serverID }), oldServer.kind == .ssh,
                      let oldAccount = oldServer.accounts.first(where: { $0.id == tab.accountID }) else { continue }
                if let newServer = state.servers.first(where: { $0.id == tab.serverID }),
                   let newAccount = newServer.accounts.first(where: { $0.id == tab.accountID }),
                   newAccount.username != oldAccount.username {
                    throw CoreError.accountIdentityChanged
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
