import SwiftUI
import InfraCore
import TerminalBridge

struct SSHKeySetupRequest: Identifiable {
    let id = UUID()
    let serverID: UUID
    let accountID: UUID
    var unlock = false
}

struct SSHKeySetupView: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let request: SSHKeySetupRequest
    @StateObject private var terminal = TerminalHost()
    @ViewState private var setup: SSHKeySetup?
    @ViewState private var password = ""
    @FocusState private var passwordFocused: Bool
    @ViewState private var progress: SSHKeySetupProgress?
    @ViewState private var error: String?
    @ViewState private var preparing = true
    @ViewState private var verifying = false
    @ViewState private var applied = false
    @ViewState private var validation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.unlock ? "SSH 키 잠금 해제" : "SSH 키 설정").font(.title2.weight(.semibold))
            if let server = model.workspace.servers.first(where: { $0.id == request.serverID }),
               let account = server.accounts.first(where: { $0.id == request.accountID }) {
                Text("\(server.name) · \(account.username)@\(server.host):\(server.port)")
                    .font(.callout).textSelection(.enabled)
            }
            if request.unlock {
                unlockContent
            } else {
                Text("비밀번호 한 번으로 키 생성·등록·검증을 자동으로 완료합니다. 비밀번호는 저장하지 않고 키체인도 사용하지 않습니다.")
                    .font(.callout)
                Text("개인 키는 암호 없이 이 Mac에 저장하며 현재 Mac 사용자 전용 파일 권한으로 보호합니다.")
                    .font(.caption).foregroundStyle(appearance.colors.muted)
                SecureField("서버 비밀번호", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                    .disabled(verifying)
                    .onSubmit { automaticallySetUp() }
                    .accessibilityIdentifier("sshSetupPassword")
                if let progress {
                    HStack { ProgressView().controlSize(.small); Text(progress.label) }
                        .font(.callout).accessibilityElement(children: .combine)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(applied ? "닫기" : "취소") { close() }.keyboardShortcut(.cancelAction)
                if request.unlock {
                    Button("검증하고 적용") { verify() }.disabled(setup == nil || verifying || applied)
                } else {
                    Button("자동 설정") { automaticallySetUp() }
                        .keyboardShortcut(.defaultAction).disabled(password.isEmpty || verifying)
                }
            }
        }
        .padding(24).frame(width: request.unlock ? 800 : 540, height: request.unlock ? 620 : nil)
        .background(appearance.colors.panel).foregroundStyle(appearance.colors.text).tint(appearance.colors.accent)
        .task {
            guard request.unlock else { passwordFocused = true; return }
            do {
                let prepared = try await model.prepareSSHKeySetup(serverID: request.serverID, accountID: request.accountID, unlock: true)
                guard !Task.isCancelled else { model.cancelSSHKeySetup(prepared.id); return }
                setup = prepared
                terminal.open(id: prepared.id, command: prepared.command.shellString, environment: prepared.command.environment)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            preparing = false
        }
        .onDisappear { cancel() }
    }

    @ViewBuilder private var unlockContent: some View {
        Text("아래 터미널의 ssh-add 요청에 키 암호를 입력하세요. 키를 다시 생성하거나 서버에 다시 등록하지 않습니다.")
            .font(.caption).foregroundStyle(appearance.colors.muted)
        if let setup {
            TerminalPane(host: terminal, id: setup.id, style: appearance.terminalStyle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("SSH 키 잠금 해제 전용 터미널")
        } else {
            VStack(spacing: 12) {
                if preparing { ProgressView(); Text("SSH 대상과 에이전트 확인 중…") }
                else { Text("잠금 해제를 시작하지 못했습니다. 안내를 확인하고 창을 다시 여세요.") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let error = terminal.error { Text(error).font(.caption).foregroundStyle(.orange) }
        if applied {
            Label("키 인증을 검증하고 적용했습니다. 자동 수집을 다시 시작합니다.", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(appearance.colors.accent)
        } else {
            Text("키 잠금 해제를 마치면 ‘검증하고 적용’을 누르세요.")
                .font(.caption).foregroundStyle(appearance.colors.muted)
        }
    }

    private func automaticallySetUp() {
        guard !request.unlock, !verifying, !password.isEmpty else { return }
        let submittedPassword = password
        password = ""
        passwordFocused = false
        verifying = true
        error = nil
        progress = .generating
        validation = Task { @MainActor in
            do {
                try await model.automaticallySetUpSSHKey(serverID: request.serverID, accountID: request.accountID,
                                                        password: submittedPassword) { progress = $0 }
                if !Task.isCancelled { dismiss() }
            } catch {
                if !Task.isCancelled {
                    self.error = (error as? SSHPasswordRegistrationError) == .hostKeyFailed
                        ? "서버 신원을 확인할 수 없습니다. 일반 터미널에서 SSH 대상과 호스트 키를 확인하고 신뢰한 뒤 다시 시도하세요."
                        : error.localizedDescription
                    passwordFocused = true
                }
            }
            progress = nil
            verifying = false
        }
    }

    private func verify() {
        guard let setup, !verifying else { return }
        verifying = true
        error = nil
        validation = Task { @MainActor in
            do {
                try await model.verifyAndApplySSHKeySetup(setup)
                if !Task.isCancelled { applied = true }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            verifying = false
        }
    }

    private func cancel() {
        password = ""
        if let setup { model.cancelSSHKeySetup(setup.id) }
        validation?.cancel()
        terminal.disconnectAll()
    }

    private func close() { cancel(); dismiss() }
}
