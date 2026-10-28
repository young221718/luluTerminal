import SwiftUI
import InfraCore

struct ProfileEditImpact {
    struct AccountChange {
        let id: UUID
        let originalUsername: String
        let updatedUsername: String?
    }
    let changes: [AccountChange]
    let openTabCount: Int
    let closedTabCount: Int
    var requiresConfirmation: Bool { !changes.isEmpty }
    init(original: ServerProfile?, draft: ServerProfile, tabs: [TerminalTab]) {
        changes = original?.accounts.compactMap { account in
            let updated = draft.accounts.first { $0.id == account.id }
            guard updated?.username != account.username else { return nil }
            return AccountChange(id: account.id, originalUsername: account.username, updatedUsername: updated?.username)
        } ?? []
        let accountIDs = Set(changes.map(\.id))
        let affected = tabs.filter { $0.serverID == original?.id && accountIDs.contains($0.accountID) }
        openTabCount = affected.filter { !$0.isClosed }.count
        closedTabCount = affected.filter(\.isClosed).count
    }

    var confirmationMessage: String {
        let accounts = changes.map { change in
            if let username = change.updatedUsername { return "이름 변경: \(change.originalUsername) → \(username)" }
            return "계정 삭제: \(change.originalUsername)"
        }.joined(separator: "\n")
        return "\(accounts)\n\n위 계정의 열린 탭 \(openTabCount)개와 닫힌 탭 기록 \(closedTabCount)개를 앱에서 제거합니다. 이 서버의 앱 연결은 모두 해제됩니다.\n\n원격 로그인 계정·파일·tmux 세션과 로컬 SSH 키 파일은 유지됩니다. 이름이 바뀐 계정은 새 계정으로 저장되며 관리 키 연결이 해제됩니다. 저장하면 새 계정의 SSH 키 자동 설정 화면이 열립니다."
    }
}

struct ServerDeletionImpact {
    let serverName: String
    let openTabCount: Int
    let closedTabCount: Int
    init(server: ServerProfile, tabs: [TerminalTab]) {
        serverName = server.name
        let affected = tabs.filter { $0.serverID == server.id }
        openTabCount = affected.filter { !$0.isClosed }.count
        closedTabCount = affected.filter(\.isClosed).count
    }

    var confirmationMessage: String {
        "‘\(serverName)’ 서버 등록과 열린 탭 \(openTabCount)개, 닫힌 탭 기록 \(closedTabCount)개를 앱에서 제거하고 이 서버의 앱 연결을 해제합니다.\n\n원격 로그인 계정·파일·tmux 세션과 로컬 SSH 키 파일은 유지됩니다."
    }
}

struct ProfileEditor: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @Environment(\.dismiss) private var dismiss
    @ViewState private var profile: ServerProfile
    @ViewState private var port: String
    @ViewState private var error: String?
    @ViewState private var saving = false
    @ViewState private var confirmingChanges = false
    let originalProfile: ServerProfile?
    let tabs: [TerminalTab]
    let isNew: Bool
    let demo: Bool
    let save: (ServerProfile) async throws -> Void

    init(profile: ServerProfile?, tabs: [TerminalTab], demo: Bool = false, save: @escaping (ServerProfile) async throws -> Void) {
        let account = SSHAccount(username: "", authMethod: .pendingKey)
        let value = profile ?? ServerProfile(name: "", host: "", accounts: [account], monitorAccountID: account.id)
        _profile = State(initialValue: value)
        _port = State(initialValue: String(value.port))
        self.originalProfile = profile
        self.tabs = tabs
        self.isNew = profile == nil
        self.demo = demo
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "서버 추가" : "서버 편집").font(.title2.weight(.semibold))
            Text("새 계정은 앱 전용 SSH 키를 새로 만듭니다. 저장 후 서버 비밀번호를 한 번 입력하면 키 생성·등록·검증을 완료합니다. 기존 키 파일과 서버에 등록된 공개 키는 유지하며, 비밀번호는 저장하지 않습니다.").font(.caption).foregroundStyle(appearance.colors.muted)
            if !isNew {
                Text("저장하면 이 서버의 앱 연결은 모두 해제됩니다. 원격 작업은 유지됩니다.")
                    .font(.caption).foregroundStyle(appearance.colors.muted)
            }
            Form {
                TextField("서버 별칭", text: $profile.name)
                TextField("SSH IP(SSH 저장명)", text: $profile.host)
                TextField("SSH 포트", text: $port)
                Section("로그인 계정") {
                    ForEach($profile.accounts) { $account in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("계정 이름", text: $account.username)
                                Button(role: .destructive) {
                                    let removed = account.id
                                    profile.accounts.removeAll { $0.id == removed }
                                    if profile.monitorAccountID == removed { profile.monitorAccountID = profile.accounts.first?.id }
                                } label: { Label("계정 삭제", systemImage: "trash") }
                                .buttonStyle(.borderless).disabled(profile.accounts.count <= 1)
                                .accessibilityLabel("\(account.username) 계정 삭제")
                            }
                            if needsAutomaticSSHKeySetup(for: account) {
                                LabeledContent("인증 방식", value: "새 SSH 키 자동 설정")
                                Text(automaticSSHKeySetupMessage(for: account))
                                    .font(.caption).foregroundStyle(appearance.colors.muted)
                            } else {
                                Picker("인증 방식", selection: $account.authMethod) {
                                    Text("SSH 키·기존 설정").tag(SSHAuthenticationMethod.system)
                                    if account.managedKey != nil {
                                        Text("앱에서 설정한 SSH 키").tag(SSHAuthenticationMethod.managedKey)
                                    }
                                }.disabled(demo)
                            }
                            if accountWasRenamed(account) {
                                Text("계정 이름을 변경하면 새 계정으로 저장되고 관리 키 연결이 해제됩니다. 저장 후 SSH 키 자동 설정 화면이 열립니다. 기존 SSH 키 파일은 유지됩니다.")
                                    .font(.caption).foregroundStyle(appearance.colors.muted)
                            } else if account.authMethod == .managedKey {
                                Text(account.managedKey?.requiresAgent == true
                                     ? "설정한 키를 사용합니다. 키 암호가 필요하면 서버 메뉴의 ‘SSH 키 잠금 해제’를 선택하세요. 연결 대상을 바꾸려면 먼저 ‘SSH 키·기존 설정’으로 저장한 뒤 새 키를 설정하세요."
                                     : "이 Mac에 저장한 키로 자동 인증합니다. 연결 대상을 바꾸려면 먼저 ‘SSH 키·기존 설정’으로 저장한 뒤 새 키를 설정하세요.")
                                    .font(.caption).foregroundStyle(appearance.colors.muted)
                            }
                        }.padding(.vertical, 4)
                    }
                    if profile.accounts.count == 1 {
                        Text("마지막 계정은 삭제할 수 없습니다. 서버 전체를 지우려면 서버 메뉴의 ‘서버 삭제…’를 사용하세요.")
                            .font(.caption).foregroundStyle(appearance.colors.muted)
                    }
                    Button("계정 추가", systemImage: "plus") { profile.accounts.append(SSHAccount(username: "", authMethod: .pendingKey)) }
                }
                Section("모니터링") {
                    Toggle("앱 실행 중 자원 수집", isOn: $profile.monitoringEnabled)
                    Picker("모니터링 계정", selection: $profile.monitorAccountID) {
                        Text("선택 안 함").tag(Optional<UUID>.none)
                        ForEach(profile.accounts) { account in
                            Text(account.username.isEmpty ? "계정 이름 입력 필요" : account.username).tag(Optional(account.id))
                        }
                    }
                    Text("선택 서버 2초 · 나머지 10초 · 서버별 중복 수집 없음").font(.caption).foregroundStyle(appearance.colors.muted)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(height: 400).disabled(saving)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(isNew ? "추가" : "저장") { submit() }.keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(24).frame(width: 540).interactiveDismissDisabled(saving)
            .background(appearance.colors.panel).foregroundStyle(appearance.colors.text).tint(appearance.colors.accent)
            .alert("계정 변경을 저장할까요?", isPresented: $confirmingChanges) {
                Button("취소", role: .cancel) {}
                Button("변경 후 저장", role: .destructive) { persistProfile() }
            } message: {
                Text(ProfileEditImpact(original: originalProfile, draft: profile, tabs: tabs).confirmationMessage)
            }
    }

    func needsAutomaticSSHKeySetup(for account: SSHAccount) -> Bool {
        if account.authMethod == .pendingKey { return true }
        guard let original = originalProfile?.accounts.first(where: { $0.id == account.id }) else { return true }
        return original.username != account.username
    }

    func automaticSSHKeySetupMessage(for account: SSHAccount) -> String {
        if demo { return "데모에서는 실제 SSH 키를 생성하지 않습니다." }
        if originalProfile?.accounts.contains(where: { $0.id == account.id && $0.username == account.username }) == true {
            return "SSH 키 설정을 완료해야 연결할 수 있습니다. 서버 메뉴의 ‘SSH 키 설정’에서 다시 시도하세요."
        }
        return "저장 후 비밀번호를 한 번 입력하면 별도의 키를 생성·등록·검증합니다. 설정을 완료해야 연결할 수 있습니다."
    }

    private func accountWasRenamed(_ account: SSHAccount) -> Bool {
        originalProfile?.accounts.first { $0.id == account.id }.map { $0.username != account.username } ?? false
    }

    private func submit() {
        guard !saving else { return }
        guard let number = Int(port) else { error = "포트는 1~65535의 정수여야 합니다."; return }
        profile.port = number
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try profile.validate() }
        catch { self.error = error.localizedDescription; return }
        error = nil
        if ProfileEditImpact(original: originalProfile, draft: profile, tabs: tabs).requiresConfirmation {
            confirmingChanges = true
        } else { persistProfile() }
    }

    private func persistProfile() {
        guard !saving else { return }
        saving = true
        error = nil
        let submittedProfile = profile
        Task { @MainActor in
            do { try await save(submittedProfile); dismiss() }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }

}

struct NewTabEditor: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @Environment(\.dismiss) private var dismiss
    let server: ServerProfile
    let demo: Bool
    let create: (UUID, String) -> Void
    @ViewState private var accountID: UUID
    @ViewState private var title = "셸"
    init(server: ServerProfile, preferredAccount: UUID?, demo: Bool, create: @escaping (UUID, String) -> Void) {
        self.server = server
        self.demo = demo
        self.create = create
        _accountID = State(initialValue: preferredAccount ?? server.accounts.first?.id ?? UUID())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(server.kind == .local ? "새 로컬 셸 탭" : "새 터미널 탭").font(.title2.weight(.semibold))
            Text(server.name).foregroundStyle(appearance.colors.muted)
            Form {
                Picker("로그인 계정", selection: $accountID) {
                    ForEach(server.accounts) { account in Text(account.username).tag(account.id) }
                }
                TextField("작업 이름", text: $title)
            }
            Text(server.kind == .local ? "현재 로그인 계정의 홈에서 새 셸을 시작합니다. 로컬 탭을 닫거나 앱을 종료한 뒤 작업 복원은 보장하지 않습니다." : demo ? "데모 탭만 추가합니다. SSH는 실행하지 않습니다." : "이 탭 전용 원격 tmux 세션을 만들고 연결합니다. 기존 원격 작업은 유지됩니다.")
                .font(.caption).foregroundStyle(appearance.colors.muted)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(server.kind == .local ? "로컬 셸 시작" : demo ? "데모 탭 추가" : "만들고 연결") { create(accountID, title); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(server.accounts.isEmpty)
            }
        }.padding(24).frame(width: 420)
            .background(appearance.colors.panel).foregroundStyle(appearance.colors.text).tint(appearance.colors.accent)
    }
}
