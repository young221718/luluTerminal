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
    @ViewState private var error: String?
    @ViewState private var preparing = true
    @ViewState private var verifying = false
    @ViewState private var applied = false
    @ViewState private var validation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.unlock ? "SSH 키 잠금 해제" : "SSH 키 설정").font(.title2.weight(.semibold))
            if let setup {
                Text("\(setup.server.name) · \(setup.account.username)@\(setup.reference.target.resolvedHost):\(setup.reference.target.port)")
                    .font(.callout).textSelection(.enabled)
            }
            Text(request.unlock
                 ? "아래 터미널의 ssh-add 요청에 키 암호를 입력하세요. 키를 다시 생성하거나 서버에 다시 등록하지 않습니다."
                 : "아래 터미널에서 키를 만들고 서버에 등록합니다. ssh-keygen의 키 암호는 직접 정합니다. 빈 암호도 허용되므로 보호하려면 암호를 입력하세요. 서버 비밀번호·키 암호는 이 터미널에서만 입력하며 앱과 키체인에 저장하지 않습니다.")
                .font(.caption).foregroundStyle(appearance.colors.muted)
            if let setup {
                TerminalPane(host: terminal, id: setup.id, style: appearance.terminalStyle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("SSH 키 설정 전용 터미널")
            } else {
                VStack(spacing: 12) {
                    if preparing { ProgressView(); Text("SSH 대상과 에이전트 확인 중…") }
                    else { Text("설정을 시작하지 못했습니다. 안내를 확인하고 창을 다시 여세요.") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = terminal.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if applied {
                Label("키 인증을 검증하고 적용했습니다. 자동 수집을 다시 시작합니다.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(appearance.colors.accent)
            } else {
                Text("터미널 작업이 끝나면 ‘검증하고 적용’을 누르세요. 별도 SSH 키 인증이 성공해야 연결 방식이 바뀝니다.")
                    .font(.caption).foregroundStyle(appearance.colors.muted)
            }
            HStack {
                Spacer()
                if verifying { ProgressView().controlSize(.small) }
                Button(applied ? "닫기" : "취소") { close() }.keyboardShortcut(.cancelAction)
                Button("검증하고 적용") { verify() }.disabled(setup == nil || verifying || applied)
            }
        }
        .padding(24).frame(width: 800, height: 620)
        .background(appearance.colors.panel).foregroundStyle(appearance.colors.text).tint(appearance.colors.accent)
        .task {
            do {
                let prepared = try await model.prepareSSHKeySetup(serverID: request.serverID, accountID: request.accountID, unlock: request.unlock)
                guard !Task.isCancelled else { model.cancelSSHKeySetup(prepared.id); return }
                setup = prepared
                terminal.open(id: prepared.id, command: prepared.command.shellString, environment: prepared.command.environment)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            preparing = false
        }
        .onDisappear { cancel() }
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
        if let setup { model.cancelSSHKeySetup(setup.id) }
        validation?.cancel()
        terminal.disconnectAll()
    }

    private func close() { cancel(); dismiss() }
}
