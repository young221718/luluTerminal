import SwiftUI
import InfraCore
import TerminalBridge

// The CLT SDK 27 ships a conflicting State macro without its plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

public struct InfraRootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var terminal = TerminalHost()
    @ViewState private var editingProfile: ServerProfile?
    @ViewState private var showProfile = false
    @ViewState private var showNewTab = false
    @ViewState private var showSettings = false
    @ViewState private var renamingTab: TerminalTab?
    @ViewState private var renamedTitle = ""
    @ViewState private var actionError: String?
    @ViewState private var creatingSessionFor: TerminalTab?

    public init() {}

    public var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 344, idealWidth: 350, maxWidth: 430)
            workspace.frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 950, minHeight: 640)
        .background(Color.infraBackground)
        .foregroundStyle(Color.infraText)
        .tint(Color.infraAccent)
        .sheet(isPresented: $showProfile) {
            ProfileEditor(profile: editingProfile, lockedAccountIDs: Set(model.workspace.tabs.filter { $0.serverID == editingProfile?.id }.map(\.accountID))) { profile in
                try model.saveProfile(profile)
                for tab in model.workspace.tabs where tab.serverID == profile.id { terminal.disconnect(id: tab.id) }
            }
        }
        .sheet(isPresented: $showNewTab) {
            if let server = model.selectedServer {
                NewTabEditor(server: server, preferredAccount: model.selectedTab?.accountID, demo: model.isDemo && server.kind == .ssh) { account, title in
                    do {
                        let tab = try model.addTab(serverID: server.id, accountID: account, title: title)
                        connect(tab, create: true)
                    } catch { actionError = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $showSettings) { InfraSettings(storeURL: model.storeURL, demo: model.isDemo) }
        .sheet(item: $renamingTab) { tab in
            VStack(alignment: .leading, spacing: 16) {
                Text("작업 이름 변경").font(.title2)
                TextField("작업 이름", text: $renamedTitle)
                Text("이름을 바꿔도 원격 세션 ID는 유지됩니다.").font(.caption).foregroundStyle(Color.infraMuted)
                HStack {
                    Spacer()
                    Button("취소") { renamingTab = nil }.keyboardShortcut(.cancelAction)
                    Button("저장") { model.renameTab(tab.id, title: renamedTitle); renamingTab = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 380).background(Color.infraPanel)
        }
        .alert("작업을 완료할 수 없습니다", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("확인") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .confirmationDialog("원격 세션을 새로 만들까요?", isPresented: Binding(get: { creatingSessionFor != nil }, set: { if !$0 { creatingSessionFor = nil } }), titleVisibility: .visible, presenting: creatingSessionFor) { tab in
            Button("새 세션 만들기") { creatingSessionFor = nil; connect(tab, create: true) }
            Button("취소", role: .cancel) { creatingSessionFor = nil }
        } message: { _ in
            Text("이 탭의 원격 세션을 새로 만듭니다. 기존 세션이 있으면 생성을 중단하며, 원격 작업은 종료하지 않습니다.")
        }
        .task {
            terminal.onExit = { id in model.disconnected(id) }
            model.start()
        }
        .task(id: model.selectedTab?.id) {
            if let tab = model.selectedTab, model.selectedServer?.kind == .local,
               model.connections[tab.id] != .launched, model.connections[tab.id] != .checking {
                connect(tab, create: false)
            }
        }
        .onDisappear { model.stop(); terminal.disconnectAll() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("내 서버").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(model.workspace.servers.count)대").font(.system(size: 11)).foregroundStyle(Color.infraMuted)
                Button { editingProfile = nil; showProfile = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("서버 추가").accessibilityLabel("서버 추가")
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
            HStack(spacing: 6) {
                Text("서버").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(ResourceMetric.allCases) { item in Text(item.rawValue).lineLimit(1).minimumScaleFactor(0.8).frame(width: 26) }
            }.font(.system(size: 9)).foregroundStyle(Color.infraMuted).padding(.horizontal, 18).padding(.bottom, 7)
                .accessibilityHidden(true)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.workspace.servers) { server in serverRow(server) }
                }.padding(.horizontal, 8).padding(.bottom, 10)
            }
            if model.workspace.servers.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "server.rack").font(.title).foregroundStyle(.tertiary)
                    Text("첫 서버를 추가하세요").font(.caption).foregroundStyle(Color.infraMuted)
                }.padding(.bottom, 28)
            }
            Divider()
            Button { showSettings = true } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("설정")
                    Spacer()
                    Text("자동화 준비 중").font(.system(size: 10)).foregroundStyle(Color.infraMuted)
                }.font(.system(size: 12)).padding(16).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.background(Color.infraSidebar)
    }

    private func serverRow(_ server: ServerProfile) -> some View {
        let snapshot = model.metrics[server.id]
        let fresh = freshness(snapshot, now: model.now, interval: model.pollInterval(for: server.id), demo: model.isDemo && server.kind == .ssh)
        let stale = snapshot?.isStale(now: model.now, interval: model.pollInterval(for: server.id)) ?? true
        let failed = model.collectionErrors[server.id] != nil
        return Button { model.selectServer(server.id) } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if server.kind == .local { Image(systemName: "laptopcomputer").font(.system(size: 10)).foregroundStyle(Color.infraMuted) }
                        Circle().fill(failed ? Color.orange : stale ? Color.infraMuted : Color.infraAccent.opacity(0.8)).frame(width: 6, height: 6)
                        Text(server.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                    Text(server.kind == .local ? "\(server.accounts.first?.username ?? "") · 로컬" : failed ? "수집 오류" : stale && snapshot != nil ? "갱신 중단" : "\(model.isDemo ? "가상 · " : "")\(model.tabs(for: server.id).count)개 탭")
                        .font(.system(size: 10)).foregroundStyle(Color.infraMuted).padding(.leading, 12)
                }.frame(maxWidth: .infinity, alignment: .leading)
                ForEach(ResourceMetric.allCases) { item in
                    TinyDonut(metric: item, value: item.value(snapshot), freshness: fresh, warning: server.kind == .local && (item == .gpu || item == .vram) ? "macOS 수집 미지원" : model.collectionErrors[server.id] ?? snapshot?.warnings.first)
                }
            }.padding(.horizontal, 10).frame(height: 50)
                .background(model.workspace.selectedServerID == server.id ? Color.infraAccent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .accessibilityElement(children: .contain).accessibilityLabel("\(server.name) · \(fresh)")
            .accessibilityAddTraits(model.workspace.selectedServerID == server.id ? [.isSelected] : [])
            .contextMenu { if server.kind == .ssh { Button("서버 편집…") { editingProfile = server; showProfile = true } } }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if model.isDemo {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                    Text("데모 · 가상 서버 10대 + 실제 이 Mac · 가상 서버 SSH 미실행")
                    Spacer()
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(Color.infraAccent)
                    .padding(.horizontal, 20).padding(.vertical, 7).background(Color.infraAccent.opacity(0.1))
            }
            if let error = model.persistenceError {
                banner(error, icon: "externaldrive.badge.exclamationmark", color: .orange)
            }
            if let server = model.selectedServer {
                serverHeader(server)
                tabsBar(server).id(server.id)
                ResourceDisclosure(server: server, snapshot: model.metrics[server.id], history: model.histories[server.id] ?? [], now: model.now, interval: model.pollInterval(for: server.id), error: model.collectionErrors[server.id], demo: model.isDemo && server.kind == .ssh)
                    .id(server.id)
                Divider()
                terminalContent(server)
                Divider()
                HStack {
                    if let tab = model.selectedTab {
                        Text("\(model.account(for: tab)?.username ?? "계정 없음") / \(tab.title)").lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(server.kind == .local ? "로컬 탭을 다시 열면 새 셸 시작 · 작업 지속 보장 없음" : "탭·앱을 닫아도 원격 작업 유지")
                }.font(.system(size: 10)).foregroundStyle(Color.infraMuted).padding(.horizontal, 20).padding(.vertical, 10).background(Color.infraPanel)
            } else {
                Spacer()
                Image(systemName: "terminal").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.tertiary)
                Text("luluTerminal").font(.title2.weight(.medium)).padding(.top, 10)
                Text("서버 상태를 살피고, 계정별 작업을 이어가세요.").font(.callout).foregroundStyle(Color.infraMuted).padding(.top, 3)
                Button("서버 추가") { editingProfile = nil; showProfile = true }.padding(.top, 18)
                Spacer()
            }
        }.background(Color.infraPanel)
    }

    private func serverHeader(_ server: ServerProfile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.system(size: 17, weight: .semibold))
                Text(server.kind == .local ? "\(server.accounts.first?.username ?? "") · 로컬 macOS · \(LocalMachine.loginShell)" : "\(server.host) · SSH \(server.port)").font(.system(size: 11)).foregroundStyle(Color.infraMuted).textSelection(.enabled)
            }
            Spacer()
            if let tab = model.selectedTab {
                let state = model.connections[tab.id] ?? .disconnected
                if state == .launched {
                    Button("연결 해제") { terminal.disconnect(id: tab.id); model.disconnected(tab.id) }
                    Button { terminal.disconnect(id: tab.id); connect(tab, create: false) } label: { Image(systemName: "arrow.clockwise") }.help(server.kind == .local ? "새 로컬 셸 시작" : "기존 세션에 다시 연결")
                } else {
                    Button(state == .checking ? "확인 중…" : server.kind == .local ? "새 셸 시작" : "기존 세션 연결") { connect(tab, create: false) }
                        .disabled(state == .checking || (model.isDemo && server.kind == .ssh))
                }
            }
            Menu {
                if server.kind == .ssh { Button("서버 편집…") { editingProfile = server; showProfile = true } }
                Button(server.kind == .local ? "새 로컬 셸 탭" : "새 세션 만들기…") {
                    if server.kind == .local { showNewTab = true }
                    else if let tab = model.selectedTab { creatingSessionFor = tab }
                    else { showNewTab = true }
                }.disabled((model.isDemo && server.kind == .ssh) || model.selectedTab.map { model.connections[$0.id] == .checking } == true)
                Menu("닫은 탭 다시 열기") {
                    let closed = model.tabs(for: server.id, closed: true)
                    if closed.isEmpty { Text("닫은 탭 없음") }
                    ForEach(closed) { tab in
                        Button("\(model.account(for: tab)?.username ?? "계정 없음") · \(tab.title)") { model.reopenTab(tab.id) }
                    }
                }
                Button("Ansible · 준비 중") {}.disabled(true)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("서버 메뉴")
        }.controlSize(.small).padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func tabsBar(_ server: ServerProfile) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs(for: server.id)) { tab in
                        HStack(spacing: 6) {
                            Button { model.selectTab(tab.id) } label: {
                                HStack(spacing: 6) {
                                    Text(model.account(for: tab)?.username ?? "계정 없음").foregroundStyle(Color.infraAccent)
                                    Text("·").foregroundStyle(.tertiary)
                                    Text(tab.title)
                                }.font(.system(size: 11)).padding(.vertical, 12).padding(.leading, 13)
                            }.buttonStyle(.plain)
                            Button { terminal.disconnect(id: tab.id); model.closeTab(tab.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.infraMuted)
                            }.buttonStyle(.plain).padding(.trailing, 12).help(server.kind == .local ? "탭 닫기 · 로컬 셸 종료" : "탭 닫기 · 원격 작업 유지").accessibilityLabel("\(tab.title) 탭 닫기, \(server.kind == .local ? "로컬 셸 종료" : "원격 작업 유지")")
                        }
                        .background(model.selectedTab?.id == tab.id ? Color.infraPanel : Color.clear)
                        .overlay(alignment: .bottom) { if model.selectedTab?.id == tab.id { Rectangle().fill(Color.infraAccent).frame(height: 2).padding(.horizontal, 10) } }
                        .overlay(alignment: .trailing) { Divider() }
                        .contextMenu {
                            Button("작업 이름 변경…") { renamedTitle = tab.title; renamingTab = tab }
                            Button("왼쪽으로 이동") { model.moveTab(tab.id, by: -1) }
                            Button("오른쪽으로 이동") { model.moveTab(tab.id, by: 1) }
                        }
                    }
                }
            }
            Button { showNewTab = true } label: { Image(systemName: "plus").padding(12) }
                .buttonStyle(.plain).help("새 터미널 탭").accessibilityLabel("새 터미널 탭")
        }.background(Color.infraSidebar).overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private func terminalContent(_ server: ServerProfile) -> some View {
        if let tab = model.selectedTab {
            let state = model.connections[tab.id] ?? .disconnected
            VStack(spacing: 0) {
                if state == .missing {
                    HStack {
                        Label("기존 tmux 세션이 없습니다. 자동으로 다시 만들지 않습니다.", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("새 세션 만들기") { connect(tab, create: true) }
                    }.font(.caption).padding(12).background(Color.orange.opacity(0.12))
                } else if case .failed(let error) = state {
                    banner(error, icon: "exclamationmark.triangle", color: .orange)
                } else if case .authenticationRequired(let error) = state {
                    HStack(spacing: 12) {
                        Label(error, systemImage: "key").textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("터미널에서 인증하고 연결") { connect(tab, create: false, interactive: true) }.fixedSize()
                    }.font(.caption).padding(12).background(Color.orange.opacity(0.12))
                }
                if let error = terminal.error { banner(error, icon: "terminal", color: .orange) }
                if model.isDemo && server.kind == .ssh {
                    terminalPlaceholder("데모 터미널", detail: "\(model.account(for: tab)?.username ?? "") · \(tab.title)\n가상 서버와 자원 사용량을 둘러보세요. 실제 서버에는 연결되지 않습니다.")
                } else if state == .launched {
                    TerminalPane(host: terminal, id: tab.id).id(tab.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("\(model.account(for: tab)?.username ?? "") 계정 \(tab.title) 터미널")
                } else {
                    terminalPlaceholder(state.label, detail: server.kind == .local ? "다시 연결하면 현재 로그인 계정의 홈에서 새 셸을 시작합니다.\n로컬 셸은 원격 tmux처럼 작업을 복원하지 않습니다." : "기존 세션 연결은 저장된 tmux ID만 확인합니다.\n원격 서버나 tmux가 종료되면 기존 작업을 복원할 수 없습니다.")
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.plus").font(.largeTitle).foregroundStyle(.tertiary)
                Text("\(server.name)의 작업을 시작하세요").foregroundStyle(Color.infraMuted)
                Button("새 터미널 탭") { showNewTab = true }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func terminalPlaceholder(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "terminal").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.infraMuted)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.infraMuted).lineSpacing(5)
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.infraBackground)
    }
    private func banner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(color).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 10).background(color.opacity(0.08))
    }
    private func connect(_ tab: TerminalTab, create: Bool, interactive: Bool = false) {
        terminal.disconnect(id: tab.id)
        Task {
            if let command = await model.prepareConnection(tabID: tab.id, create: create, probeExisting: !interactive) {
                terminal.open(id: tab.id, command: command.shellString)
                if terminal.error != nil { model.disconnected(tab.id) }
            }
        }
    }
}
