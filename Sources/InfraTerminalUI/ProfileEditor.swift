import SwiftUI
import InfraCore

struct ProfileEditor: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @Environment(\.dismiss) private var dismiss
    @ViewState private var profile: ServerProfile
    @ViewState private var port: String
    @ViewState private var error: String?
    @ViewState private var passwords: [UUID: String] = [:]
    @ViewState private var saving = false
    let lockedAccountIDs: Set<UUID>
    let isNew: Bool
    let demo: Bool
    let save: (ServerProfile, [UUID: String]) async throws -> Void

    init(profile: ServerProfile?, lockedAccountIDs: Set<UUID>, demo: Bool = false, save: @escaping (ServerProfile, [UUID: String]) async throws -> Void) {
        let account = SSHAccount(username: "")
        let value = profile ?? ServerProfile(name: "", host: "", accounts: [account], monitorAccountID: account.id)
        _profile = State(initialValue: value)
        _port = State(initialValue: String(value.port))
        self.lockedAccountIDs = lockedAccountIDs
        self.isNew = profile == nil
        self.demo = demo
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "서버 추가" : "서버 편집").font(.title2.weight(.semibold))
            Text("계정마다 SSH 키 또는 저장한 비밀번호로 연결합니다.").font(.caption).foregroundStyle(appearance.colors.muted)
            Form {
                TextField("서버 이름", text: $profile.name)
                TextField("호스트 또는 SSH 별칭", text: $profile.host)
                TextField("SSH 포트", text: $port)
                Section("로그인 계정") {
                    ForEach($profile.accounts) { $account in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("계정 이름", text: $account.username)
                                    .disabled(lockedAccountIDs.contains(account.id))
                                if lockedAccountIDs.contains(account.id) {
                                    Image(systemName: "lock").help("열린 탭 또는 닫힌 탭이 사용하는 계정입니다. 다른 사용자는 새 계정으로 추가하세요.")
                                        .accessibilityLabel("탭이 사용 중인 계정, 변경 불가")
                                } else if profile.accounts.count > 1 {
                                    Button {
                                        let removed = account.id
                                        profile.accounts.removeAll { $0.id == removed }
                                        passwords[removed] = nil
                                        if profile.monitorAccountID == removed { profile.monitorAccountID = profile.accounts.first?.id }
                                    } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("\(account.username) 계정 제거")
                                }
                            }
                            Picker("인증 방식", selection: $account.authMethod) {
                                Text("SSH 키·기존 설정").tag(SSHAuthenticationMethod.system)
                                Text("저장한 비밀번호").tag(SSHAuthenticationMethod.password)
                            }.disabled(demo)
                            if account.authMethod == .password {
                                SecureField(hasSavedPassword(account) ? "새 비밀번호 · 비워두면 유지" : "비밀번호", text: passwordBinding(account.id))
                                    .textContentType(.password)
                                    .accessibilityLabel("\(account.username) SSH 비밀번호")
                                HStack(alignment: .top) {
                                    Label(hasSavedPassword(account) ? "이 연결 대상에 저장됨" : "저장할 비밀번호를 입력하세요", systemImage: hasSavedPassword(account) ? "checkmark.circle" : "key")
                                        .foregroundStyle(appearance.colors.muted)
                                    Spacer()
                                    if account.credential != nil {
                                        Button("저장한 비밀번호 삭제", role: .destructive) {
                                            account.authMethod = .system
                                            account.credential = nil
                                            passwords[account.id] = nil
                                        }.buttonStyle(.borderless)
                                    }
                                }.font(.caption)
                                Text("macOS 키체인에 보관하며 터미널과 모니터링에 함께 사용합니다.")
                                    .font(.caption).foregroundStyle(appearance.colors.muted)
                            }
                        }.padding(.vertical, 4)
                    }
                    Button("계정 추가", systemImage: "plus") { profile.accounts.append(SSHAccount(username: "")) }
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
    }
    private func hasSavedPassword(_ account: SSHAccount) -> Bool {
        guard let reference = account.credential, Int(port) == profile.port else { return false }
        return reference.target.matches(server: profile, account: account)
    }
    private func passwordBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { passwords[id] ?? "" }, set: { passwords[id] = $0 })
    }
    private func submit() {
        guard !saving else { return }
        guard let number = Int(port) else { error = "포트는 1~65535의 정수여야 합니다."; return }
        profile.port = number
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        error = nil
        Task { @MainActor in
            do { try await save(profile, passwords); passwords.removeAll(); dismiss() }
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
