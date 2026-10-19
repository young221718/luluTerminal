import SwiftUI
import InfraCore

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var profile: ServerProfile
    @ViewState private var port: String
    @ViewState private var error: String?
    let lockedAccountIDs: Set<UUID>
    let isNew: Bool
    let save: (ServerProfile) throws -> Void

    init(profile: ServerProfile?, lockedAccountIDs: Set<UUID>, save: @escaping (ServerProfile) throws -> Void) {
        let account = SSHAccount(username: "")
        let value = profile ?? ServerProfile(name: "", host: "", accounts: [account], monitorAccountID: account.id)
        _profile = State(initialValue: value)
        _port = State(initialValue: String(value.port))
        self.lockedAccountIDs = lockedAccountIDs
        self.isNew = profile == nil
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "서버 추가" : "서버 편집").font(.title2.weight(.semibold))
            Text("시스템 OpenSSH, SSH agent와 사용자 SSH 설정을 사용합니다.").font(.caption).foregroundStyle(Color.infraMuted)
            Form {
                TextField("서버 이름", text: $profile.name)
                TextField("호스트 또는 SSH 별칭", text: $profile.host)
                TextField("SSH 포트", text: $port)
                Section("로그인 계정") {
                    ForEach($profile.accounts) { $account in
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
                                    if profile.monitorAccountID == removed { profile.monitorAccountID = profile.accounts.first?.id }
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("\(account.username) 계정 제거")
                            }
                        }
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
                    Text("선택 서버 2초 · 나머지 10초 · 서버별 중복 수집 없음").font(.caption).foregroundStyle(Color.infraMuted)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "추가" : "저장") { submit() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
            .background(Color.infraPanel).foregroundStyle(Color.infraText).tint(Color.infraAccent)
    }
    private func submit() {
        guard let number = Int(port) else { error = "포트는 1~65535의 정수여야 합니다."; return }
        profile.port = number
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try save(profile); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct NewTabEditor: View {
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
            Text(server.name).foregroundStyle(Color.infraMuted)
            Form {
                Picker("로그인 계정", selection: $accountID) {
                    ForEach(server.accounts) { account in Text(account.username).tag(account.id) }
                }
                TextField("작업 이름", text: $title)
            }
            Text(server.kind == .local ? "현재 로그인 계정의 홈에서 새 셸을 시작합니다. 로컬 탭을 닫거나 앱을 종료한 뒤 작업 복원은 보장하지 않습니다." : demo ? "데모 탭만 추가합니다. SSH는 실행하지 않습니다." : "이 탭 전용 원격 tmux 세션을 만들고 연결합니다. 기존 원격 작업은 유지됩니다.")
                .font(.caption).foregroundStyle(Color.infraMuted)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(server.kind == .local ? "로컬 셸 시작" : demo ? "데모 탭 추가" : "만들고 연결") { create(accountID, title); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(server.accounts.isEmpty)
            }
        }.padding(24).frame(width: 420)
            .background(Color.infraPanel).foregroundStyle(Color.infraText).tint(Color.infraAccent)
    }
}

struct InfraSettings: View {
    @Environment(\.dismiss) private var dismiss
    let storeURL: URL
    let demo: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("설정").font(.title2.weight(.semibold))
            Form {
                Section("터미널과 저장") {
                    LabeledContent("터미널 엔진", value: "Ghostty")
                    LabeledContent("인증", value: "시스템 OpenSSH · SSH agent")
                    Text("탭 닫기와 연결 해제는 로컬 연결만 닫습니다. 원격 tmux 작업은 종료하지 않습니다.")
                        .font(.caption).foregroundStyle(Color.infraMuted)
                    Text(demo ? "데모 모드 · 실사용 저장 파일을 변경하지 않음" : storeURL.path)
                        .font(.caption).foregroundStyle(Color.infraMuted).textSelection(.enabled)
                }
                Section("모니터링") {
                    LabeledContent("선택한 서버", value: "2초")
                    LabeledContent("다른 서버", value: "10초")
                    LabeledContent("동시 수집 상한", value: "3대")
                }
                Section("Ansible · 준비 중") {
                    TextField("인벤토리", text: .constant("추후 지원"))
                    TextField("플레이북", text: .constant("추후 지원"))
                    Button("실행") {}.disabled(true)
                }.disabled(true)
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            HStack { Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 490)
            .background(Color.infraPanel).foregroundStyle(Color.infraText).tint(Color.infraAccent)
    }
}
