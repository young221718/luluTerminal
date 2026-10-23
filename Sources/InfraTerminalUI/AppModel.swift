import Foundation
import SwiftUI
import InfraCore

struct SSHKeySetup: Identifiable, Sendable {
    let id: UUID
    let server: ServerProfile
    let account: SSHAccount
    let reference: SSHManagedKeyReference
    let agentSocket: String
    let command: ShellCommand
    let isUnlock: Bool
}

@MainActor
public final class AppModel: ObservableObject {
    public static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("InfraTerminal/workspace-v1.json")
    }
    @Published public private(set) var workspace = WorkspaceState()
    @Published private(set) var metrics: [UUID: MetricsSnapshot] = [:]
    @Published private(set) var histories: [UUID: [MetricsSnapshot]] = [:]
    @Published private(set) var collectionErrors: [UUID: String] = [:]
    @Published private(set) var connections: [UUID: ConnectionState] = [:]
    @Published private(set) var persistenceError: String?
    @Published private(set) var now = Date()
    let isDemo: Bool
    let storeURL: URL
    private(set) var persistenceBlocked = false
    private let store: StateStore
    typealias CommandExecutor = @Sendable (ShellCommand, TimeInterval) async throws -> ProcessResult
    private let execute: CommandExecutor
    private let credentialStore: any PasswordCredentialStore
    private let helperPath: String?
    private let agentEnvironment: [String: String]
    private struct AccountKey: Hashable { let serverID: UUID; let accountID: UUID }
    private var pausedAuthentication: [AccountKey: SSHConnectionFailure] = [:]
    private var activeAuthentication: Set<AccountKey> = []
    private var passwordTerminalAccounts: [UUID: AccountKey] = [:]
    private var savingProfiles: Set<UUID> = []
    private var keySetupTokens: [AccountKey: UUID] = [:]
    private var verifyingKeySetups: Set<UUID> = []
    private var previous: [UUID: RawMetrics] = [:]
    private var lastAttempts: [UUID: Date] = [:]
    private var polls: [UUID: Task<Void, Never>] = [:]
    private var connectionTokens: [UUID: UUID] = [:]
    private var connectionChecks: [UUID: Task<ProcessResult, Error>] = [:]
    private var connectionRecoveryEnabled = false
    private var interruptedConnections: [UUID: ServerProfile] = [:]
    private var recoveryPermits: Set<UUID> = []
    private var automaticConnectionTokens: [UUID: UUID] = [:]
    private var scheduler: Task<Void, Never>?
    private var lastDemoRefresh = Date.distantPast
    private var monitoringEnabled = true
    private var selectedPollInterval: TimeInterval = 2
    private var localCollector = LocalMetricsCollector()

    enum ConnectionState: Equatable {
        case disconnected, checking, launched, missing, authenticationRequired(String), failed(String)
        var label: String {
            switch self {
            case .disconnected: return "연결 해제"
            case .checking: return "기존 세션 확인 중"
            case .launched: return "터미널 연결 요청됨"
            case .missing: return "기존 원격 세션 없음"
            case .authenticationRequired(let message), .failed(let message): return message
            }
        }
    }

    public convenience init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo"), storeURL: URL? = nil) {
        self.init(demo: demo, storeURL: storeURL) { command, timeout in
            try await ProcessRunner().run(command, timeout: timeout)
        }
    }

    init(demo: Bool, storeURL: URL?, credentialStore: any PasswordCredentialStore = KeychainCredentialStore(),
         helperPath: String? = SSHPasswordAuthentication.helperPath,
         agentEnvironment: [String: String] = ProcessInfo.processInfo.environment, execute: @escaping CommandExecutor) {
        self.isDemo = demo
        self.execute = execute
        self.credentialStore = credentialStore
        self.helperPath = helperPath
        self.agentEnvironment = agentEnvironment
        self.storeURL = storeURL ?? Self.defaultStoreURL
        self.store = StateStore(url: self.storeURL)
        if demo {
            makeDemo()
        } else {
            do { workspace = try store.load() ?? WorkspaceState() }
            catch {
                persistenceBlocked = true
                persistenceError = "저장 파일을 읽을 수 없습니다. 원본을 보존하고 저장을 중지했습니다. 복구 경로: \(self.storeURL.path)\n\(error.localizedDescription)"
            }
        }
        workspace.ensureLocalMachine()
    }

    var selectedServer: ServerProfile? { workspace.servers.first { $0.id == workspace.selectedServerID } }
    var selectedTab: TerminalTab? {
        guard let id = workspace.selectedServerID, let tabID = workspace.selectedTabByServer[id] else { return nil }
        return workspace.tabs.first { $0.id == tabID && !$0.isClosed && $0.serverID == id }
    }
    func tabs(for serverID: UUID, closed: Bool = false) -> [TerminalTab] {
        workspace.tabs.filter { $0.serverID == serverID && $0.isClosed == closed }
    }
    func account(for tab: TerminalTab) -> SSHAccount? {
        workspace.servers.first { $0.id == tab.serverID }?.accounts.first { $0.id == tab.accountID }
    }
    func selectServer(_ id: UUID) { workspace.select(serverID: id); persist() }
    @discardableResult
    func moveServer(_ id: UUID, relativeTo targetID: UUID, after: Bool) throws -> Bool {
        guard !persistenceBlocked else { throw UIError.message(persistenceError ?? "저장 파일 복구 전에는 순서를 변경할 수 없습니다.") }
        guard id != targetID, let source = workspace.servers.firstIndex(where: { $0.id == id }),
              workspace.servers.contains(where: { $0.id == targetID }) else { return false }
        var candidate = workspace
        let server = candidate.servers.remove(at: source)
        let target = candidate.servers.firstIndex(where: { $0.id == targetID })!
        candidate.servers.insert(server, at: target + (after ? 1 : 0))
        guard candidate != workspace else { return false }
        if !isDemo {
            do { try store.save(candidate); persistenceError = nil }
            catch { persistenceError = "저장 실패: \(error.localizedDescription)\n\(storeURL.path)"; throw error }
        }
        workspace = candidate
        return true
    }
    func selectTab(_ id: UUID) { workspace.select(tabID: id); persist() }
    func closeTab(_ id: UUID) { workspace.close(tabID: id); disconnected(id); persist() }
    func reopenTab(_ id: UUID) { workspace.reopen(tabID: id); persist() }
    func disconnected(_ id: UUID) {
        interruptedConnections[id] = nil
        recoveryPermits.remove(id)
        automaticConnectionTokens[id] = nil
        invalidateConnection(id)
    }

    private func invalidateConnection(_ id: UUID) {
        passwordTerminalAccounts[id] = nil
        connectionTokens[id] = nil
        connectionChecks.removeValue(forKey: id)?.cancel()
        connections[id] = .disconnected
    }

    func terminalExited(_ id: UUID) {
        if let key = passwordTerminalAccounts.removeValue(forKey: id),
           workspace.servers.first(where: { $0.id == key.serverID })?.accounts.first(where: { $0.id == key.accountID })?.authMethod == .password {
            pausedAuthentication[key] = .authentication
            collectionErrors[key.serverID] = "SSH 연결 확인 필요. 다시 연결하거나 서버 메뉴에서 인증 설정을 확인하세요."
        }
        // Only an observed sleep/network interruption carries reconnect intent through an exit.
        if interruptedConnections[id] != nil { invalidateConnection(id) }
        else { disconnected(id) }
    }

    func configureConnectionRecovery(enabled: Bool) {
        connectionRecoveryEnabled = enabled
        if !enabled {
            interruptedConnections.removeAll()
            recoveryPermits.removeAll()
            for id in Array(automaticConnectionTokens.keys) { disconnected(id) }
        }
    }

    func connectionEnvironmentInterrupted() {
        guard connectionRecoveryEnabled, !isDemo else { return }
        for tab in workspace.tabs where !tab.isClosed {
            guard let server = recoveryServer(for: tab) else { continue }
            if connections[tab.id] == .launched { interruptedConnections[tab.id] = server }
            if connections[tab.id] == .checking { invalidateConnection(tab.id) }
        }
        recoveryPermits.removeAll()
    }

    func beginConnectionRecovery() -> [UUID] {
        recoveryPermits.removeAll()
        guard connectionRecoveryEnabled, !isDemo, !persistenceBlocked else { return [] }
        var ids: [UUID] = []
        for tab in workspace.tabs where !tab.isClosed && connections[tab.id] != .checking {
            guard let server = recoveryServer(for: tab),
                  connections[tab.id] == .launched || interruptedConnections[tab.id] == server,
                  pausedAuthentication[AccountKey(serverID: server.id, accountID: tab.accountID)] == nil else { continue }
            interruptedConnections[tab.id] = server
            ids.append(tab.id)
        }
        recoveryPermits = Set(ids)
        return ids
    }

    private func recoveryServer(for tab: TerminalTab) -> ServerProfile? {
        guard let server = workspace.servers.first(where: { $0.id == tab.serverID && $0.kind == .ssh }),
              let account = server.accounts.first(where: { $0.id == tab.accountID }), account.authMethod != .password else { return nil }
        return server
    }

    func saveProfile(_ profile: ServerProfile) throws {
        try validateProfileEdit(profile)
        for account in profile.accounts where account.authMethod == .password {
            guard let reference = account.credential, reference.target.matches(server: profile, account: account) else {
                throw UIError.message("연결 대상이 바뀌었습니다. 이 계정의 비밀번호를 다시 입력하세요.")
            }
        }
        try commitProfile(profile)
    }

    func saveProfile(_ draft: ServerProfile, passwords: [UUID: String]) async throws {
        try validateProfileEdit(draft)
        guard !savingProfiles.contains(draft.id) else { throw UIError.message("이 서버의 설정을 저장하는 중입니다.") }
        if isDemo {
            guard passwords.values.allSatisfy({ $0.isEmpty }), draft.accounts.allSatisfy({ $0.authMethod == .system && $0.credential == nil }) else {
                throw UIError.message("데모에서는 비밀번호를 키체인에 저장하지 않습니다.")
            }
            try commitProfile(draft)
            return
        }
        savingProfiles.insert(draft.id)
        defer { savingProfiles.remove(draft.id) }
        let original = workspace.servers.first { $0.id == draft.id }
        var profile = draft
        var created: [SSHPasswordReference] = []
        do {
            for index in profile.accounts.indices {
                var account = profile.accounts[index]
                if account.authMethod == .managedKey {
                    guard let reference = account.managedKey else { throw UIError.message("서버를 저장한 뒤 SSH 키 설정을 완료하세요.") }
                    try SSHManagedKeys.validate(reference: reference, server: profile, account: account)
                } else if account.authMethod == .password, let password = passwords[account.id], !password.isEmpty {
                    let target = try await SSHPasswordAuthentication.resolveTarget(server: profile, account: account, execute: execute)
                    let reference = SSHPasswordReference(target: target)
                    // A new reference keeps the old secret intact until the state file commits.
                    try credentialStore.save(password, reference: reference)
                    created.append(reference)
                    account.credential = reference
                } else if account.authMethod == .password {
                    guard let reference = account.credential, reference.target.matches(server: profile, account: account) else {
                        throw UIError.message("이 연결 대상의 비밀번호를 입력하세요.")
                    }
                }
                profile.accounts[index] = account
            }
            guard workspace.servers.first(where: { $0.id == draft.id }) == original else {
                throw UIError.message("저장 중 서버 설정이 변경되었습니다. 다시 확인하세요.")
            }
            try validateProfileEdit(profile)
            try commitProfile(profile)
        } catch {
            for reference in created {
                do { try credentialStore.delete(reference: reference) }
                catch { persistenceError = "저장 실패 후 새 키체인 항목 정리에 실패했습니다. 키체인 접근에서 luluTerminal 항목을 확인하세요." }
            }
            throw error
        }
        let retained = Set(profile.accounts.compactMap { $0.credential?.id })
        for reference in original?.accounts.compactMap(\.credential) ?? [] where !retained.contains(reference.id) {
            do { try credentialStore.delete(reference: reference) }
            catch { persistenceError = "설정은 저장했지만 이전 비밀번호를 키체인에서 삭제하지 못했습니다. 키체인 접근에서 luluTerminal 항목을 확인하세요." }
        }
    }

    private func validateProfileEdit(_ profile: ServerProfile) throws {
        guard !persistenceBlocked else { throw UIError.message(persistenceError ?? "저장 파일 복구 전에는 설정을 저장할 수 없습니다.") }
        guard profile.kind == .ssh, profile.id != LocalMachine.serverID else {
            throw UIError.message("이 Mac은 기본 로컬 항목이므로 서버 편집으로 변경할 수 없습니다.")
        }
        try profile.validate()
        for account in profile.accounts where account.authMethod == .managedKey {
            guard let reference = account.managedKey else { throw UIError.message("서버를 저장한 뒤 SSH 키 설정을 완료하세요.") }
            try SSHManagedKeys.validate(reference: reference, server: profile, account: account)
        }
        if let old = workspace.servers.first(where: { $0.id == profile.id }) {
            for account in old.accounts where workspace.tabs.contains(where: { $0.serverID == old.id && $0.accountID == account.id }) {
                guard profile.accounts.first(where: { $0.id == account.id })?.username == account.username else {
                    throw UIError.message("열린 탭 또는 닫힌 탭이 사용하는 계정은 변경하거나 삭제할 수 없습니다. 새 계정을 추가하세요.")
                }
            }
        }
    }

    func prepareSSHKeySetup(serverID: UUID, accountID: UUID, unlock: Bool = false) async throws -> SSHKeySetup {
        guard !isDemo, !persistenceBlocked,
              let server = workspace.servers.first(where: { $0.id == serverID && $0.kind == .ssh }),
              let account = server.accounts.first(where: { $0.id == accountID }) else {
            throw UIError.message("저장된 SSH 서버와 계정을 선택하세요. 데모에서는 키를 설정하지 않습니다.")
        }
        let key = AccountKey(serverID: serverID, accountID: accountID)
        guard keySetupTokens[key] == nil, !savingProfiles.contains(serverID), !activeAuthentication.contains(key) else {
            throw UIError.message("이 계정의 인증 작업이 진행 중입니다. 완료 후 다시 시도하세요.")
        }
        let token = UUID()
        keySetupTokens[key] = token
        activeAuthentication.insert(key)
        do {
            let socket = try await availableSSHAgent()
            let target = try await SSHPasswordAuthentication.resolveTarget(server: server, account: account, execute: execute)
            try requireCurrentKeySetup(token, server: server, account: account)
            let reference: SSHManagedKeyReference
            let command: ShellCommand
            if unlock {
                guard let saved = account.managedKey, saved.target == target else {
                    throw UIError.message("이 대상에 설정한 SSH 키가 없습니다. SSH 키 설정을 새로 진행하세요.")
                }
                reference = saved
                command = try SSHManagedKeys.unlockCommand(reference: saved, agentSocket: socket)
            } else {
                reference = SSHManagedKeyReference(target: target)
                command = try SSHManagedKeys.setupCommand(server: server, account: account, reference: reference, agentSocket: socket)
            }
            return SSHKeySetup(id: token, server: server, account: account, reference: reference,
                               agentSocket: socket, command: command, isUnlock: unlock)
        } catch {
            cancelSSHKeySetup(token)
            throw error
        }
    }

    func cancelSSHKeySetup(_ id: UUID) {
        guard let key = keySetupTokens.first(where: { $0.value == id })?.key else { return }
        keySetupTokens[key] = nil
        activeAuthentication.remove(key)
    }

    func verifyAndApplySSHKeySetup(_ setup: SSHKeySetup) async throws {
        try requireCurrentKeySetup(setup.id, server: setup.server, account: setup.account)
        guard !verifyingKeySetups.contains(setup.id) else { throw UIError.message("SSH 키를 검증하고 있습니다.") }
        verifyingKeySetups.insert(setup.id)
        defer { verifyingKeySetups.remove(setup.id) }
        let target = try await SSHPasswordAuthentication.resolveTarget(server: setup.server, account: setup.account, execute: execute)
        try requireCurrentKeySetup(setup.id, server: setup.server, account: setup.account)
        guard target == setup.reference.target else { throw UIError.message("SSH 별칭의 연결 대상이 바뀌었습니다. 설정을 닫고 다시 시작하세요.") }
        _ = try await availableSSHAgent(socket: setup.agentSocket)
        try requireCurrentKeySetup(setup.id, server: setup.server, account: setup.account)
        let command = try SSHManagedKeys.verificationCommand(server: setup.server, account: setup.account,
                                                            reference: setup.reference, agentSocket: setup.agentSocket)
        let result = try await execute(command, 10)
        try requireCurrentKeySetup(setup.id, server: setup.server, account: setup.account)
        guard result.exitCode == 0 else {
            throw UIError.message("키 인증 검증 실패 (\(result.exitCode)). 터미널에서 키 생성·등록·잠금 해제를 완료한 뒤 다시 검증하세요.\n\(String(result.stderr.prefix(600)))")
        }
        var profile = setup.server
        guard let index = profile.accounts.firstIndex(where: { $0.id == setup.account.id }) else { return }
        profile.accounts[index].managedKey = setup.reference
        profile.accounts[index].authMethod = .managedKey
        // Keep the prior credential dormant and existing terminal surfaces connected.
        try commitProfile(profile, disconnectTabs: false)
        cancelSSHKeySetup(setup.id)
        pausedAuthentication[AccountKey(serverID: profile.id, accountID: setup.account.id)] = nil
        collectionErrors[profile.id] = nil
        lastAttempts[profile.id] = nil
    }

    private func requireCurrentKeySetup(_ id: UUID, server: ServerProfile, account: SSHAccount) throws {
        guard !Task.isCancelled, !isDemo, !persistenceBlocked,
              keySetupTokens[AccountKey(serverID: server.id, accountID: account.id)] == id,
              workspace.servers.contains(server) else {
            throw UIError.message("설정이 취소되었거나 서버·계정이 변경되었습니다. 설정을 닫고 다시 시작하세요.")
        }
    }

    private func availableSSHAgent(socket supplied: String? = nil) async throws -> String {
        var socket = supplied ?? agentEnvironment["SSH_AUTH_SOCK"]
        if socket == nil {
            let result = try await execute(ShellCommand(executable: "/bin/launchctl", arguments: ["getenv", "SSH_AUTH_SOCK"]), 3)
            if result.exitCode == 0 { socket = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let socket, socket.hasPrefix("/"), !socket.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw UIError.message("사용 가능한 SSH 에이전트가 없습니다. 로그인 세션의 ssh-agent를 시작하고 SSH_AUTH_SOCK를 설정한 뒤 앱을 다시 여세요.")
        }
        let result = try await execute(ShellCommand(executable: "/usr/bin/ssh-add", arguments: ["-l"],
                                                  environment: ["SSH_AUTH_SOCK": socket, "LC_ALL": "C", "SSH_ASKPASS_REQUIRE": "never"]), 3)
        let emptyAgent = result.exitCode == 1 && (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines) == "The agent has no identities."
        guard result.exitCode == 0 || emptyAgent else {
            throw UIError.message("SSH 에이전트에 연결할 수 없습니다. SSH_AUTH_SOCK와 로그인 세션의 ssh-agent를 확인한 뒤 다시 시도하세요.\n\(String(result.stderr.prefix(400)))")
        }
        return socket
    }

    private func managedKeySocket(server: ServerProfile, account: SSHAccount) async throws -> String {
        guard let reference = account.managedKey else { throw UIError.message("SSH 키 설정을 완료하세요.") }
        try SSHManagedKeys.validate(reference: reference, server: server, account: account)
        let target = try await SSHPasswordAuthentication.resolveTarget(server: server, account: account, execute: execute)
        guard target == reference.target else { throw UIError.message("SSH 별칭의 연결 대상이 바뀌었습니다. SSH 키 설정을 다시 진행하세요.") }
        return try await availableSSHAgent()
    }

    private func commitProfile(_ profile: ServerProfile, disconnectTabs: Bool = true) throws {
        let old = workspace.servers.first { $0.id == profile.id }
        var candidate = workspace
        if let index = candidate.servers.firstIndex(where: { $0.id == profile.id }) { candidate.servers[index] = profile }
        else { candidate.servers.append(profile); candidate.select(serverID: profile.id) }
        try candidate.validate()
        if !isDemo {
            do { try store.save(candidate); persistenceError = nil }
            catch { persistenceError = "저장 실패: \(error.localizedDescription)\n\(storeURL.path)"; throw error }
        }
        workspace = candidate
        if disconnectTabs {
            for tab in workspace.tabs where tab.serverID == profile.id { disconnected(tab.id) }
        }
        if let old {
            let oldMonitor = old.accounts.first { $0.id == old.monitorAccountID }
            let newMonitor = profile.accounts.first { $0.id == profile.monitorAccountID }
            if old.host != profile.host || old.port != profile.port || old.monitorAccountID != profile.monitorAccountID || oldMonitor != newMonitor {
                previous[profile.id] = nil
                metrics[profile.id] = nil
                histories[profile.id] = nil
                collectionErrors[profile.id] = nil
            }
        }
        lastAttempts[profile.id] = nil
        if old?.accounts != profile.accounts || old?.host != profile.host || old?.port != profile.port {
            pausedAuthentication = pausedAuthentication.filter { $0.key.serverID != profile.id }
        }
        polls[profile.id]?.cancel()
    }

    @discardableResult
    func addTab(serverID: UUID, accountID: UUID, title: String) throws -> TerminalTab {
        guard let server = workspace.servers.first(where: { $0.id == serverID }), server.accounts.contains(where: { $0.id == accountID }) else {
            throw UIError.message("서버와 계정을 선택하세요.")
        }
        let tab = TerminalTab(serverID: serverID, accountID: accountID, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "셸" : title)
        try workspace.add(tab: tab)
        persist()
        return tab
    }

    func renameTab(_ id: UUID, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
        workspace.tabs[index].title = value
        persist()
    }

    func moveTab(_ id: UUID, by offset: Int) {
        guard let index = workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = workspace.tabs[index]
        let siblings = workspace.tabs.indices.filter { workspace.tabs[$0].serverID == tab.serverID && !workspace.tabs[$0].isClosed }
        guard let position = siblings.firstIndex(of: index), siblings.indices.contains(position + offset) else { return }
        workspace.tabs.swapAt(index, siblings[position + offset])
        persist()
    }

    func prepareConnection(tabID: UUID, create: Bool, probeExisting: Bool = true,
                           retryAuthentication: Bool = false, manualAuthentication: Bool = false, automaticRecovery: Bool = false) async -> ShellCommand? {
        if automaticRecovery {
            guard recoveryPermits.remove(tabID) != nil, connectionRecoveryEnabled, !create, probeExisting,
                  !retryAuthentication, !manualAuthentication else { return nil }
        } else { recoveryPermits.remove(tabID) }
        guard let tab = workspace.tabs.first(where: { $0.id == tabID && !$0.isClosed }),
              let server = workspace.servers.first(where: { $0.id == tab.serverID }), let account = account(for: tab) else { return nil }
        guard server.kind == .local || !isDemo else { return nil }
        if automaticRecovery {
            guard !persistenceBlocked, recoveryServer(for: tab) == server, interruptedConnections[tabID] == server,
                  pausedAuthentication[AccountKey(serverID: server.id, accountID: account.id)] == nil else { return nil }
        } else { interruptedConnections[tabID] = nil }
        guard connections[tabID] != .checking else { return nil }
        let key = AccountKey(serverID: server.id, accountID: account.id)
        let savedPassword = server.kind == .ssh && account.authMethod == .password && !manualAuthentication
        let managedKey = server.kind == .ssh && account.authMethod == .managedKey
        let protectedAuthentication = savedPassword || managedKey
        let token = UUID()
        var ownsAuthentication = false
        let previousConnectionState = connections[tabID]
        connectionTokens[tabID] = token
        if automaticRecovery { automaticConnectionTokens[tabID] = token }
        connections[tabID] = .checking
        defer {
            if ownsAuthentication { activeAuthentication.remove(key) }
            if automaticConnectionTokens[tabID] == token { automaticConnectionTokens[tabID] = nil }
            if connectionTokens[tabID] == token {
                connectionChecks[tabID] = nil
                if connections[tabID] == .checking { connections[tabID] = .disconnected }
            }
        }
        do {
            if server.kind == .local {
                let command = try LocalMachine.terminal()
                connections[tabID] = .launched
                return command
            }
            if automaticRecovery && account.authMethod == .system {
                do {
                    // Detect unsupported routes without replacing them with a direct connection.
                    _ = try await SSHPasswordAuthentication.resolveTarget(server: server, account: account, execute: execute)
                } catch {
                    guard !Task.isCancelled, connectionTokens[tabID] == token, workspace.servers.contains(server) else { return nil }
                    interruptedConnections[tabID] = nil
                    connections[tabID] = previousConnectionState == .launched ? .launched : .failed("이 SSH 설정은 자동 복구를 지원하지 않습니다. 기존 설정으로 수동 연결하세요.")
                    return nil
                }
                guard !Task.isCancelled, connectionTokens[tabID] == token, workspace.servers.contains(server) else { return nil }
            }
            if account.authMethod == .password || managedKey {
                if let poll = polls[server.id] { await poll.value }
                guard !Task.isCancelled, connectionTokens[tabID] == token, workspace.servers.contains(server) else { return nil }
                if retryAuthentication { pausedAuthentication[key] = nil; collectionErrors[server.id] = nil }
                if protectedAuthentication {
                    guard !activeAuthentication.contains(key) else {
                        connections[tabID] = .failed("이 계정의 SSH 연결을 확인하고 있습니다. 잠시 후 다시 시도하세요.")
                        return nil
                    }
                    if let failure = pausedAuthentication[key] {
                        connections[tabID] = connectionState(for: failure)
                        return nil
                    }
                    activeAuthentication.insert(key)
                    ownsAuthentication = true
                }
            }
            let authentication: SSHAuthenticationContext?
            if savedPassword {
                guard let helperPath else { throw UIError.message("비밀번호 연결 도우미가 없습니다. 앱을 다시 설치하세요.") }
                authentication = try await SSHPasswordAuthentication.context(server: server, account: account, helperPath: helperPath, allowsKeychainInteraction: !automaticRecovery, execute: execute)
            } else { authentication = nil }
            guard !Task.isCancelled, connectionTokens[tabID] == token, workspace.servers.contains(server),
                  workspace.tabs.contains(where: { $0.id == tabID && !$0.isClosed }) else { return nil }
            let managedSocket = managedKey ? try await managedKeySocket(server: server, account: account) : nil
            guard !Task.isCancelled, connectionTokens[tabID] == token, workspace.servers.contains(server) else { return nil }
            // Explicit creation authenticates first; exit 44 means the requested session is absent.
            if (!create && probeExisting) || protectedAuthentication {
                var probe = try SSHCommandBuilder.probe(server: server, account: account, tab: tab, authentication: authentication, manualAuthentication: manualAuthentication, managedKeyAgentSocket: managedSocket)
                if automaticRecovery { probe = unattendedRecoveryCommand(probe) }
                let execute = self.execute
                let check = Task { try await execute(probe, 8) }
                connectionChecks[tabID] = check
                let result = try await check.value
                guard !Task.isCancelled, connectionTokens[tabID] == token, workspace.servers.contains(server) else { return nil }
                guard result.exitCode == 0 || (create && result.exitCode == 44) else {
                    switch result.exitCode {
                    case 44: connections[tabID] = .missing
                    case 127: connections[tabID] = .failed("원격 tmux가 설치되어 있지 않습니다.")
                    case 255:
                        let failure = SSHConnectionFailure.classify(exitCode: result.exitCode, stderr: result.stderr)
                        if failure.blocksAutomaticRetry { pausedAuthentication[key] = failure }
                        connections[tabID] = connectionState(for: failure)
                    default: connections[tabID] = .failed("SSH 세션 확인 실패 (\(result.exitCode)). \(String(result.stderr.prefix(600)))")
                    }
                    return nil
                }
            }
            guard !Task.isCancelled, connectionTokens[tabID] == token, workspace.servers.contains(server),
                  workspace.tabs.contains(where: { $0.id == tabID && !$0.isClosed }) else { return nil }
            // Probe and terminal use separate SSH processes. Allow Once for the probe
            // must not leave the explicit terminal request unable to ask for access.
            var command = try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: create,
                                                        authentication: authentication, manualAuthentication: manualAuthentication, managedKeyAgentSocket: managedSocket)
            if automaticRecovery { command = unattendedRecoveryCommand(command) }
            interruptedConnections[tabID] = nil
            pausedAuthentication[key] = nil
            if savedPassword {
                passwordTerminalAccounts[tab.id] = key
                lastAttempts[server.id] = Date().addingTimeInterval(10)
            } else { passwordTerminalAccounts[tab.id] = nil }
            connections[tabID] = .launched
            return command
        } catch {
            if !Task.isCancelled, connectionTokens[tabID] == token, workspace.servers.contains(server) {
                let failure = connectionFailure(for: error)
                if failure.blocksAutomaticRetry && (protectedAuthentication || automaticRecovery) { pausedAuthentication[key] = failure }
                connections[tabID] = connectionState(for: failure)
            }
            return nil
        }
    }

    private func connectionState(for failure: SSHConnectionFailure) -> ConnectionState {
        switch failure {
        case .authentication, .keychainAccess: return .authenticationRequired(failure.localizedDescription)
        default: return .failed(failure.localizedDescription)
        }
    }

    private func connectionFailure(for error: Error) -> SSHConnectionFailure {
        if let failure = error as? SSHConnectionFailure { return failure }
        if let passwordError = error as? SSHPasswordError {
            if case .keychainAccessRequired = passwordError { return .keychainAccess }
            return .authentication
        }
        if let processError = error as? ProcessRunnerError, processError == .timedOut { return .network }
        return .unknown
    }

    private func unattendedRecoveryCommand(_ command: ShellCommand) -> ShellCommand {
        var command = command
        // OpenSSH uses the first value; these precede interactive defaults and existing SSH configuration.
        command.arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                             "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
                             "-o", "UseKeychain=no", "-o", "AddKeysToAgent=no", "-o", "PermitLocalCommand=no",
                             "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no"] + command.arguments
        command.environment.merge(["SSH_ASKPASS_REQUIRE": "never", "SSH_ASKPASS": "", "LULUTERMINAL_SSH_REFERENCE": "", "LULUTERMINAL_KEYCHAIN_UI": "fail", "LC_ALL": "C"]) { _, value in value }
        return command
    }

    func start() {
        guard scheduler == nil else { return }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick(at: Date())
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
    func stop() {
        scheduler?.cancel(); scheduler = nil
        for task in polls.values { task.cancel() }
        for id in Array(connectionTokens.keys) { disconnected(id) }
        interruptedConnections.removeAll()
        recoveryPermits.removeAll()
        for id in Array(keySetupTokens.values) { cancelSSHKeySetup(id) }
    }
    func configureMonitoring(enabled: Bool, selectedInterval: TimeInterval) {
        let wasEnabled = monitoringEnabled
        monitoringEnabled = enabled
        selectedPollInterval = MonitoringPreferences.validInterval(selectedInterval)
        if !enabled {
            for task in polls.values { task.cancel() }
        } else if !wasEnabled {
            lastAttempts.removeAll()
            previous.removeAll()
            localCollector = LocalMetricsCollector()
        }
    }
    func pollInterval(for id: UUID) -> TimeInterval { workspace.selectedServerID == id ? selectedPollInterval : max(10, selectedPollInterval) }
    func tick(at time: Date) {
        now = time
        guard monitoringEnabled else { return }
        if isDemo, time.timeIntervalSince(lastDemoRefresh) >= selectedPollInterval { refreshDemo(at: time) }
        if time.timeIntervalSince(lastAttempts[LocalMachine.serverID] ?? .distantPast) >= pollInterval(for: LocalMachine.serverID) {
            lastAttempts[LocalMachine.serverID] = time
            record(localCollector.collect(timestamp: time), for: LocalMachine.serverID)
        }
        for id in dueServerIDs(now: time) { poll(id, at: time) }
    }
    func dueServerIDs(now: Date) -> [UUID] {
        guard monitoringEnabled, !isDemo else { return [] }
        let slots = max(0, 3 - polls.count)
        return workspace.servers
            .filter { $0.kind == .ssh && $0.monitoringEnabled && $0.monitorAccountID != nil && polls[$0.id] == nil && !self.isAuthenticationUnavailable(server: $0) && now.timeIntervalSince(lastAttempts[$0.id] ?? .distantPast) >= pollInterval(for: $0.id) }
            .sorted { lhs, rhs in
                let leftSelected = lhs.id == workspace.selectedServerID
                let rightSelected = rhs.id == workspace.selectedServerID
                if leftSelected != rightSelected { return leftSelected }
                return (lastAttempts[lhs.id] ?? .distantPast) < (lastAttempts[rhs.id] ?? .distantPast)
            }
            .prefix(slots).map(\.id)
    }
    private func isAuthenticationUnavailable(server: ServerProfile) -> Bool {
        guard let account = server.accounts.first(where: { $0.id == server.monitorAccountID }) else { return false }
        let key = AccountKey(serverID: server.id, accountID: account.id)
        return pausedAuthentication[key] != nil || activeAuthentication.contains(key) || savingProfiles.contains(server.id)
    }

    private func poll(_ id: UUID, at time: Date) {
        guard let server = workspace.servers.first(where: { $0.id == id }), let account = server.accounts.first(where: { $0.id == server.monitorAccountID }) else { return }
        let key = AccountKey(serverID: server.id, accountID: account.id)
        let savedPassword = account.authMethod == .password
        let managedKey = account.authMethod == .managedKey
        let protectedAuthentication = savedPassword || managedKey
        guard !protectedAuthentication || !isAuthenticationUnavailable(server: server) else { return }
        if protectedAuthentication { activeAuthentication.insert(key) }
        lastAttempts[id] = time
        polls[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.polls[id] = nil
                if protectedAuthentication { self.activeAuthentication.remove(key) }
            }
            var receivedResult = false
            do {
                let authentication: SSHAuthenticationContext?
                if savedPassword {
                    guard let helperPath = self.helperPath else { throw UIError.message("비밀번호 연결 도우미가 없습니다. 앱을 다시 설치하세요.") }
                    authentication = try await SSHPasswordAuthentication.context(server: server, account: account, helperPath: helperPath, execute: self.execute)
                } else { authentication = nil }
                let managedSocket = managedKey ? try await self.managedKeySocket(server: server, account: account) : nil
                guard !Task.isCancelled, self.workspace.servers.contains(server) else { return }
                let result = try await self.execute(SSHCommandBuilder.monitor(server: server, account: account, authentication: authentication, managedKeyAgentSocket: managedSocket), 8)
                receivedResult = true
                guard !Task.isCancelled, self.workspace.servers.contains(server) else { return }
                guard result.exitCode == 0 else {
                    if result.exitCode == 255 {
                        let failure = SSHConnectionFailure.classify(exitCode: result.exitCode, stderr: result.stderr)
                        if failure.blocksAutomaticRetry && (protectedAuthentication || failure != .unknown) { self.pausedAuthentication[key] = failure }
                        throw failure
                    }
                    throw UIError.message("수집 실패 (\(result.exitCode)): \(String(result.stderr.prefix(400)))")
                }
                let raw = try MetricsParser.parse(result.stdout, timestamp: Date())
                let snapshot = MetricsCalculator.calculate(current: raw, previous: self.previous[id])
                self.previous[id] = raw
                self.record(snapshot, for: id)
                self.collectionErrors[id] = nil
            } catch {
                if !Task.isCancelled, self.workspace.servers.contains(server) {
                    if protectedAuthentication && !receivedResult {
                        let failure = self.connectionFailure(for: error)
                        if failure.blocksAutomaticRetry { self.pausedAuthentication[key] = failure }
                    }
                    self.collectionErrors[id] = error.localizedDescription
                }
            }
        }
    }

    private func persist() {
        guard !isDemo, !persistenceBlocked else { return }
        do { try store.save(workspace); persistenceError = nil }
        catch { persistenceError = "저장 실패: \(error.localizedDescription)\n\(storeURL.path)" }
    }

    private func record(_ snapshot: MetricsSnapshot, for id: UUID) {
        metrics[id] = snapshot
        var history = histories[id] ?? []
        history.append(snapshot)
        history.removeAll { snapshot.timestamp.timeIntervalSince($0.timestamp) > 900 }
        histories[id] = Array(history.suffix(450))
    }

    private func refreshDemo(at time: Date) {
        lastDemoRefresh = time
        for server in workspace.servers where server.kind == .ssh && server.name != "Backup" {
            guard var snapshot = metrics[server.id] else { continue }
            snapshot.timestamp = time
            metrics[server.id] = snapshot
            var history = histories[server.id] ?? []
            history.append(snapshot)
            history.removeAll { time.timeIntervalSince($0.timestamp) > 900 }
            histories[server.id] = Array(history.suffix(450))
        }
    }

    private func makeDemo() {
        let names = ["GPU Lab 01", "GPU Lab 02", "GPU Lab 03", "GPU Lab 04", "Inference", "Web Server", "Web Staging", "Build Server", "Storage", "Backup"]
        let values: [[Double?]] = [[0.42,0.68,0.73,0.96,0.80],[0.76,0.82,0.61,0.99,0.91],[0.31,0.47,0.54,0.64,0.58],[0.08,0.22,0.39,0,0.04],[0.24,0.56,0.42,0.38,0.65],[0.18,0.36,0.46,nil,nil],[0.12,0.28,0.31,nil,nil],[0.62,0.71,0.67,nil,nil],[0.26,0.52,0.88,nil,nil],[nil,nil,nil,nil,nil]]
        for (index, name) in names.enumerated() {
            let admin = SSHAccount(username: "admin"), trainer = SSHAccount(username: "trainer")
            let server = ServerProfile(name: name, host: "demo-\(index + 1).invalid", accounts: [admin, trainer], monitorAccountID: admin.id, monitoringEnabled: false)
            workspace.servers.append(server)
            let first = TerminalTab(serverID: server.id, accountID: index < 5 ? trainer.id : admin.id, title: index < 5 ? "학습" : "셸")
            let second = TerminalTab(serverID: server.id, accountID: admin.id, title: "셸")
            try? workspace.add(tab: first); try? workspace.add(tab: second)
            workspace.select(tabID: first.id)
            let v = values[index], gib = 1_073_741_824.0
            let timestamp = Date().addingTimeInterval(index == 9 ? -720 : 0)
            let demoGPUUsage = [v[3], v[3].map { max(0, $0 - 0.12) }, v[3].map { min(1, $0 + 0.02) }, v[3].map { $0 * 0.1 }]
            let demoGPUs = index < 5 ? (0..<4).map { gpuIndex in
                GPUReading(name: "NVIDIA RTX 4090 · 가상", utilization: demoGPUUsage[gpuIndex],
                           memoryUsedBytes: v[4].map { $0 * Double(4 - gpuIndex) / 4 * 24 * gib }, memoryTotalBytes: 24 * gib,
                           id: "demo-\(index)-gpu-\(gpuIndex)", index: gpuIndex)
            } : []
            let demoDisks = index == 9 ? [] : [
                DiskReading(id: "demo-root", mountPoint: "/", totalBytes: 1024 * gib, usedBytes: 444 * gib, availableBytes: 580 * gib),
                DiskReading(id: "demo-data", mountPoint: "/data", totalBytes: 4000 * gib, usedBytes: 3760 * gib, availableBytes: 240 * gib),
                DiskReading(id: "demo-nas", mountPoint: "/mnt/nas", totalBytes: 20000 * gib, usedBytes: 8600 * gib, availableBytes: 11400 * gib)
            ]
            metrics[server.id] = MetricsSnapshot(timestamp: timestamp, cpu: v[0], ram: v[1], disk: v[2], gpu: v[3], vram: v[4], memoryUsedBytes: v[1].map { $0 * 64 * gib }, memoryTotalBytes: index == 9 ? nil : 64 * gib, diskUsedBytes: v[2].map { $0 * 2048 * gib }, diskTotalBytes: index == 9 ? nil : 2048 * gib, gpus: demoGPUs, network: index == 9 ? [] : [NetworkRate(name: "eth0 · 가상", receivedBytesPerSecond: 24_800_000, sentBytesPerSecond: 3_200_000)], warnings: index == 9 ? ["데모: 수집 중단 예시"] : index >= 5 ? ["데모: GPU 미지원 예시"] : [], disks: demoDisks)
        }
        if let first = workspace.servers.first { workspace.select(serverID: first.id) }
    }
}

enum UIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
