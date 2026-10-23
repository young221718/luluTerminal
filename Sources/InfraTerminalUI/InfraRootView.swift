import SwiftUI
import AppKit
import InfraCore
import TerminalBridge

// The CLT SDK 27 ships a conflicting State macro without its plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

public struct InfraRootView: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @EnvironmentObject private var monitoring: MonitoringPreferences
    @StateObject private var model = AppModel()
    @StateObject private var terminal = TerminalHost()
    @ViewState private var editingProfile: ServerProfile?
    @ViewState private var showProfile = false
    @ViewState private var showNewTab = false
    @Environment(\.openSettings) private var openSettings
    @ViewState private var renamingTab: TerminalTab?
    @ViewState private var renamedTitle = ""
    @ViewState private var actionError: String?
    @ViewState private var creatingSessionFor: TerminalTab?

    @ViewState private var sidebarDragWidth: Double?
    @ViewState private var inspectorDragWidth: Double?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let sizes = PanelLayout.fittedWidths(
                    available: Double(geometry.size.width),
                    sidebar: sidebarDragWidth ?? (monitoring.sidebarVisible ? monitoring.sidebarWidth : 0),
                    inspector: inspectorDragWidth ?? (monitoring.inspectorVisible ? monitoring.inspectorWidth : 0))
                HStack(spacing: 0) {
                    // Keep all five slots stable so panel gestures never recreate the terminal.
                    sidebar
                        .frame(width: max(sizes.sidebar, MonitoringPreferences.sidebarWidthRange.lowerBound))
                        .frame(width: sizes.sidebar).clipped()
                        .allowsHitTesting(sizes.sidebar > 0).accessibilityHidden(sizes.sidebar == 0)
                    PanelDivider(edge: .sidebar, isVisible: $monitoring.sidebarVisible,
                                 savedWidth: $monitoring.sidebarWidth, dragWidth: $sidebarDragWidth,
                                 displayedWidth: sizes.sidebar,
                                 maximumWidth: min(MonitoringPreferences.sidebarWidthRange.upperBound,
                                                   Double(geometry.size.width) - PanelLayout.reservedWidth - sizes.inspector),
                                 onDragBegan: { inspectorDragWidth = sizes.inspector },
                                 onDragEnded: {
                                     if let width = inspectorDragWidth, width > 0 { monitoring.inspectorWidth = width }
                                     inspectorDragWidth = nil
                                 })
                    workspace.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    PanelDivider(edge: .inspector, isVisible: $monitoring.inspectorVisible,
                                 savedWidth: $monitoring.inspectorWidth, dragWidth: $inspectorDragWidth,
                                 displayedWidth: sizes.inspector,
                                 maximumWidth: min(MonitoringPreferences.inspectorWidthRange.upperBound,
                                                   Double(geometry.size.width) - PanelLayout.reservedWidth - sizes.sidebar),
                                 onDragBegan: { sidebarDragWidth = sizes.sidebar },
                                 onDragEnded: {
                                     if let width = sidebarDragWidth, width > 0 { monitoring.sidebarWidth = width }
                                     sidebarDragWidth = nil
                                 })
                    Group {
                        if let server = model.selectedServer {
                            ResourceInspector(server: server, snapshot: model.metrics[server.id], history: model.histories[server.id] ?? [],
                                              now: model.now, interval: model.pollInterval(for: server.id), error: model.collectionErrors[server.id],
                                              demo: model.isDemo && server.kind == .ssh)
                                .id(server.id)
                        } else {
                            Text("서버를 선택하세요").font(.caption).foregroundStyle(appearance.colors.muted)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: max(sizes.inspector, MonitoringPreferences.inspectorWidthRange.lowerBound))
                    .frame(width: sizes.inspector).clipped()
                    .allowsHitTesting(sizes.inspector > 0).accessibilityHidden(sizes.inspector == 0)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .background(appearance.colors.background)
        .foregroundStyle(appearance.colors.text)
        .tint(appearance.colors.accent)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 22, height: 22).accessibilityHidden(true)
                    Text("luluTerminal").font(.system(size: 12, weight: .semibold))
                }.fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: { Label("설정", systemImage: "gearshape") }
                    .labelStyle(.titleAndIcon).help("외관 · 글꼴 · 모니터링 설정")
            }
        }
        .sheet(isPresented: $showProfile) {
            ProfileEditor(profile: editingProfile, lockedAccountIDs: Set(model.workspace.tabs.filter { $0.serverID == editingProfile?.id }.map(\.accountID)), demo: model.isDemo) { profile, passwords in
                try await model.saveProfile(profile, passwords: passwords)
                for tab in model.workspace.tabs where tab.serverID == profile.id { terminal.disconnect(id: tab.id) }
            }
            .id(editingProfile?.id)
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
        .sheet(item: $renamingTab) { tab in
            VStack(alignment: .leading, spacing: 16) {
                Text("작업 이름 변경").font(.title2)
                TextField("작업 이름", text: $renamedTitle)
                Text("이름을 바꿔도 원격 세션 ID는 유지됩니다.").font(.caption).foregroundStyle(appearance.colors.muted)
                HStack {
                    Spacer()
                    Button("취소") { renamingTab = nil }.keyboardShortcut(.cancelAction)
                    Button("저장") { model.renameTab(tab.id, title: renamedTitle); renamingTab = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 380).background(appearance.colors.panel)
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
            terminal.onOpenSettings = { openSettings() }
            terminal.onExit = { id in model.terminalExited(id) }
            model.configureMonitoring(enabled: monitoring.enabled, selectedInterval: monitoring.refreshInterval)
            model.start()
        }
        .task(id: model.selectedTab?.id) {
            if let tab = model.selectedTab, model.selectedServer?.kind == .local,
               model.connections[tab.id] != .launched, model.connections[tab.id] != .checking {
                connect(tab, create: false)
            }
        }
        .onChange(of: monitoring.enabled) { _, enabled in
            model.configureMonitoring(enabled: enabled, selectedInterval: monitoring.refreshInterval)
        }
        .onChange(of: monitoring.refreshInterval) { _, interval in
            model.configureMonitoring(enabled: monitoring.enabled, selectedInterval: interval)
        }
        .onDisappear { model.stop(); terminal.disconnectAll() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("내 서버").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(model.workspace.servers.count)대").font(.system(size: 10)).foregroundStyle(appearance.colors.muted)
                Button { editingProfile = nil; showProfile = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("서버 추가").accessibilityLabel("서버 추가")
            }.padding(.horizontal, 14).padding(.top, 15).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.workspace.servers) { server in serverRow(server) }
                }.padding(.horizontal, 7).padding(.bottom, 10)
            }
            if model.workspace.servers.isEmpty {
                Text("첫 서버를 추가하세요").font(.caption).foregroundStyle(appearance.colors.muted).padding(.bottom, 24)
            }
            Text("부엉이 클릭 · 자원 열기").font(.system(size: 10)).foregroundStyle(appearance.colors.muted).padding(12)
        }.background(appearance.colors.sidebar)
    }

    private func serverRow(_ server: ServerProfile) -> some View {
        let active = model.tabs(for: server.id).contains { model.connections[$0.id] == .launched }
        let checking = model.tabs(for: server.id).contains { model.connections[$0.id] == .checking }
        let state = active ? (server.kind == .local ? "로컬 셸 열림" : "터미널 열림 · 연결 요청됨") : checking ? "연결 확인 중" : "터미널 미연결"
        return HStack(spacing: 7) {
            Button { model.selectServer(server.id); monitoring.inspectorVisible = true } label: {
                OwlConnectionView(active: active).frame(width: 29, height: 29)
                    .foregroundStyle(active ? appearance.colors.text : appearance.colors.muted)
            }.buttonStyle(.plain).help("\(server.name) · \(state) · 자원 열기")
                .accessibilityLabel("\(server.name), \(active ? "눈 뜬" : "눈 감은") 부엉이, \(state), 자원 열기")
            Button { model.selectServer(server.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(state).font(.system(size: 9)).foregroundStyle(appearance.colors.muted).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.horizontal, 8).frame(height: 53)
            .background(model.workspace.selectedServerID == server.id ? appearance.colors.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .modifier(ServerReorderModifier(id: server.id) { draggedID, after in
                do { try model.moveServer(draggedID, relativeTo: server.id, after: after) }
                catch { actionError = error.localizedDescription }
            })
            .help("드래그하여 서버 순서 변경")
            .accessibilityElement(children: .contain)
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
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(appearance.colors.accent)
                    .padding(.horizontal, 20).padding(.vertical, 7).background(appearance.colors.accent.opacity(0.1))
            }
            if let error = model.persistenceError {
                banner(error, icon: "externaldrive.badge.exclamationmark", color: .orange)
            }
            if let server = model.selectedServer {
                serverHeader(server)
                tabsBar(server).id(server.id)
                terminalContent(server)
                Divider()
                HStack {
                    if let tab = model.selectedTab {
                        Text("\(model.account(for: tab)?.username ?? "계정 없음") / \(tab.title)").lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(server.kind == .local ? "로컬 탭을 다시 열면 새 셸 시작 · 작업 지속 보장 없음" : "탭·앱을 닫아도 원격 작업 유지")
                }.font(.system(size: 10)).foregroundStyle(appearance.colors.muted).padding(.horizontal, 14).padding(.vertical, 6).background(appearance.colors.panel)
            } else {
                Spacer()
                Image(systemName: "terminal").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.tertiary)
                Text("luluTerminal").font(.title2.weight(.medium)).padding(.top, 10)
                Text("서버 상태를 살피고, 계정별 작업을 이어가세요.").font(.callout).foregroundStyle(appearance.colors.muted).padding(.top, 3)
                Button("서버 추가") { editingProfile = nil; showProfile = true }.padding(.top, 18)
                Spacer()
            }
        }.background(appearance.colors.panel)
    }

    private func serverHeader(_ server: ServerProfile) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(server.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
                Text(server.kind == .local ? "로컬 macOS" : "\(server.host) · SSH \(server.port)")
                    .font(.system(size: 10)).foregroundStyle(appearance.colors.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
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
        }.controlSize(.small).padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func tabsBar(_ server: ServerProfile) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs(for: server.id)) { tab in
                        HStack(spacing: 6) {
                            Button { model.selectTab(tab.id) } label: {
                                HStack(spacing: 6) {
                                    Text(model.account(for: tab)?.username ?? "계정 없음").foregroundStyle(appearance.colors.accent)
                                    Text("·").foregroundStyle(.tertiary)
                                    Text(tab.title)
                                }.font(.system(size: 11)).padding(.vertical, 12).padding(.leading, 13)
                            }.buttonStyle(.plain)
                            Button { terminal.disconnect(id: tab.id); model.closeTab(tab.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(appearance.colors.muted)
                            }.buttonStyle(.plain).padding(.trailing, 12).help(server.kind == .local ? "탭 닫기 · 로컬 셸 종료" : "탭 닫기 · 원격 작업 유지").accessibilityLabel("\(tab.title) 탭 닫기, \(server.kind == .local ? "로컬 셸 종료" : "원격 작업 유지")")
                        }
                        .background(model.selectedTab?.id == tab.id ? appearance.colors.panel : Color.clear)
                        .overlay(alignment: .bottom) { if model.selectedTab?.id == tab.id { Rectangle().fill(appearance.colors.accent).frame(height: 2).padding(.horizontal, 10) } }
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
        }.background(appearance.colors.sidebar).overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
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
                    VStack(alignment: .leading, spacing: 10) {
                        Label(error, systemImage: "key").textSelection(.enabled)
                        HStack {
                            if model.account(for: tab)?.authMethod == .password {
                                Button("비밀번호 재시도") { connect(tab, create: false, retryAuthentication: true) }
                            }
                            Button("터미널에서 인증") { connect(tab, create: false, interactive: true) }
                        }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.orange.opacity(0.12))
                }
                if let error = terminal.error { banner(error, icon: "terminal", color: .orange) }
                if model.isDemo && server.kind == .ssh {
                    terminalPlaceholder("데모 터미널", detail: "\(model.account(for: tab)?.username ?? "") · \(tab.title)\n가상 서버와 자원 사용량을 둘러보세요. 실제 서버에는 연결되지 않습니다.")
                } else if state == .launched {
                    TerminalPane(host: terminal, id: tab.id, style: appearance.terminalStyle).id(tab.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("\(model.account(for: tab)?.username ?? "") 계정 \(tab.title) 터미널")
                } else {
                    terminalPlaceholder(state.label, detail: server.kind == .local ? "다시 연결하면 현재 로그인 계정의 홈에서 새 셸을 시작합니다.\n로컬 셸은 원격 tmux처럼 작업을 복원하지 않습니다." : "기존 세션 연결은 저장된 tmux ID만 확인합니다.\n원격 서버나 tmux가 종료되면 기존 작업을 복원할 수 없습니다.")
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.plus").font(.largeTitle).foregroundStyle(.tertiary)
                Text("\(server.name)의 작업을 시작하세요").foregroundStyle(appearance.colors.muted)
                Button("새 터미널 탭") { showNewTab = true }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func terminalPlaceholder(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "terminal").font(.system(size: 12, weight: .medium)).foregroundStyle(appearance.colors.muted)
            Text(detail).font(.system(size: 12)).foregroundStyle(appearance.colors.muted).lineSpacing(5)
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(appearance.colors.background)
    }
    private func banner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(color).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 10).background(color.opacity(0.08))
    }
    private func connect(_ tab: TerminalTab, create: Bool, interactive: Bool = false, retryAuthentication: Bool = false) {
        terminal.disconnect(id: tab.id)
        Task {
            if let command = await model.prepareConnection(tabID: tab.id, create: create, probeExisting: !interactive, retryAuthentication: retryAuthentication, manualAuthentication: interactive) {
                terminal.open(id: tab.id, command: command.shellString, environment: command.environment)
                if terminal.error != nil { model.disconnected(tab.id) }
            }
        }
    }
}
