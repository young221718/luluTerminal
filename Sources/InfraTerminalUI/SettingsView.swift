import SwiftUI
import TerminalBridge

public struct InfraSettingsView: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    private let storeURL: URL
    private let demo: Bool

    public init(storeURL: URL? = nil, demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        self.storeURL = storeURL ?? AppModel.defaultStoreURL
        self.demo = demo
    }

    public var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("외관", systemImage: "circle.lefthalf.filled") }
            FontSettings()
                .tabItem { Label("글꼴", systemImage: "textformat") }
            MonitoringSettings()
                .tabItem { Label("보기 · 모니터링", systemImage: "sidebar.right") }
            GeneralSettings(storeURL: storeURL, demo: demo)
                .tabItem { Label("일반", systemImage: "gearshape") }
        }
        .frame(width: 760, height: 580)
        .background(appearance.colors.background)
        .foregroundStyle(appearance.colors.text)
    }
}

private struct AppearanceSettings: View {
    @EnvironmentObject private var appearance: AppearancePreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeading(title: "편안한 작업 공간", subtitle: "좋아하는 화면 모드와 색상으로 터미널을 꾸며 보세요.")
            HStack(spacing: 16) {
                ForEach(AppAppearance.allCases) { mode in
                    modeCard(mode)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(appearance.selection.title) 모드 색상").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { appearance.resetPalette(for: appearance.selection) } label: {
                        Label("기본 색상 복원", systemImage: "arrow.counterclockwise")
                    }.buttonStyle(.borderless).font(.system(size: 12))
                }
                HStack(spacing: 12) {
                    colorControl("배경", keyPath: \.background)
                    colorControl("텍스트", keyPath: \.foreground)
                    colorControl("강조", keyPath: \.accent)
                }
            }
            Label("색상은 화면 모드별로 저장되며, 앱과 열린 터미널에 바로 적용됩니다.", systemImage: "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(appearance.colors.muted)
            Spacer(minLength: 0)
        }.padding(30)
    }

    private func modeCard(_ mode: AppAppearance) -> some View {
        let palette = appearance.palette(for: mode)
        let selected = appearance.selection == mode
        return Button { appearance.selection = mode } label: {
            VStack(alignment: .leading, spacing: 12) {
                miniatureWindow(palette: palette)
                HStack(spacing: 8) {
                    Image(systemName: mode == .light ? "sun.max" : "moon")
                    Text(mode.title).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? appearance.colors.accent : appearance.colors.track)
                }
            }
            .padding(16)
            .background(appearance.colors.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).stroke(selected ? appearance.colors.accent : appearance.colors.track, lineWidth: selected ? 1.5 : 1) }
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title) 모드")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func miniatureWindow(palette: TerminalPalette) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Circle().fill(Color(rgb: palette.foreground).opacity(0.20)).frame(width: 5, height: 5) }
                Spacer()
                Text("luluTerminal").font(.system(size: 8)).foregroundStyle(Color(rgb: palette.foreground).opacity(0.5))
                Spacer()
            }.padding(.horizontal, 10).frame(height: 20)
                .background(Color(rgb: palette.foreground).opacity(0.04))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(rgb: palette.accent).opacity(0.14)).frame(height: 12)
                    RoundedRectangle(cornerRadius: 2).fill(Color(rgb: palette.foreground).opacity(0.08)).frame(width: 30, height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(Color(rgb: palette.foreground).opacity(0.08)).frame(width: 38, height: 4)
                    Spacer(minLength: 0)
                }.padding(9).frame(width: 66).background(Color(rgb: palette.foreground).opacity(0.035))
                VStack(alignment: .leading, spacing: 7) {
                    Text("~/workspace").foregroundStyle(Color(rgb: palette.foreground).opacity(0.65))
                    HStack(spacing: 4) {
                        Text("❯").foregroundStyle(Color(rgb: palette.accent))
                        Text("Hello, lulu.").foregroundStyle(Color(rgb: palette.foreground))
                    }
                    RoundedRectangle(cornerRadius: 1).fill(Color(rgb: palette.accent)).frame(width: 5, height: 10)
                    Spacer(minLength: 0)
                }.font(.system(size: 10, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 78)
        }
        .background(Color(rgb: palette.background))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color(rgb: palette.foreground).opacity(0.08), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    private func colorControl(_ title: String, keyPath: WritableKeyPath<TerminalPalette, UInt32>) -> some View {
        let mode = appearance.selection
        let rgb = appearance.palette(for: mode)[keyPath: keyPath]
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                ColorHexField(title: title, value: rgb) { value in
                    var palette = appearance.palette(for: mode)
                    palette[keyPath: keyPath] = value
                    appearance.setPalette(palette, for: mode)
                }
                .id(mode)
                .foregroundStyle(appearance.colors.muted)
            }
            Spacer(minLength: 2)
            ColorPicker(title, selection: Binding(get: {
                Color(rgb: appearance.palette(for: appearance.selection)[keyPath: keyPath])
            }, set: { color in
                guard let value = color.rgbValue else { return }
                var palette = appearance.palette(for: appearance.selection)
                palette[keyPath: keyPath] = value
                appearance.setPalette(palette, for: appearance.selection)
            }), supportsOpacity: false)
            .labelsHidden().accessibilityLabel("\(title) 색상").frame(width: 30)
        }.padding(14).frame(maxWidth: .infinity)
            .background(appearance.colors.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(appearance.colors.track.opacity(0.7), lineWidth: 0.5) }
    }
}

private struct FontSettings: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    private var family: Binding<String> {
        Binding(get: { appearance.fontFamily }, set: { appearance.setFont(family: $0, size: appearance.fontSize) })
    }
    private var size: Binding<Double> {
        Binding(get: { appearance.fontSize }, set: { appearance.setFont(family: appearance.fontFamily, size: $0) })
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeading(title: "읽기 좋은 글꼴", subtitle: "설치된 고정폭 글꼴 중에서 편안한 서체와 크기를 선택하세요.")
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("터미널 글꼴").font(.system(size: 12, weight: .medium))
                    Picker("터미널 글꼴", selection: family) {
                        ForEach(appearance.availableFontFamilies, id: \.self) { value in Text(value).tag(value) }
                    }.labelsHidden().frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("크기").font(.system(size: 12, weight: .medium))
                    Stepper(value: size, in: 10...28, step: 1) {
                        Text("\(Int(appearance.fontSize)) pt").monospacedDigit().frame(width: 48, alignment: .leading)
                    }.accessibilityLabel("터미널 글꼴 크기").frame(width: 120)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("미리 보기").font(.system(size: 12, weight: .medium))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Last login: today on ttys001").foregroundStyle(appearance.colors.muted)
                    HStack(spacing: 8) {
                        Text("❯").foregroundStyle(appearance.colors.accent)
                        Text("~/workspace").foregroundStyle(appearance.colors.text)
                        Text("git status").foregroundStyle(appearance.colors.text)
                    }
                    Text("On branch main").foregroundStyle(appearance.colors.text)
                    Text("작업 공간이 준비되었습니다.").foregroundStyle(appearance.colors.text)
                    HStack(spacing: 8) {
                        Text("❯").foregroundStyle(appearance.colors.accent)
                        Rectangle().fill(appearance.colors.accent).frame(width: appearance.fontSize * 0.56, height: appearance.fontSize + 2)
                    }
                }
                .font(.custom(appearance.fontFamily, size: appearance.fontSize))
                .padding(22).frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                .background(appearance.colors.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(appearance.colors.track, lineWidth: 1) }
            }
            HStack {
                Text("글꼴 변경은 열린 터미널과 새 터미널에 적용됩니다.")
                    .font(.system(size: 12)).foregroundStyle(appearance.colors.muted)
                Spacer()
                Button { appearance.resetFont() } label: {
                    Label("기본 글꼴 복원", systemImage: "arrow.counterclockwise")
                }.buttonStyle(.borderless).font(.system(size: 12))
            }
            Spacer(minLength: 0)
        }.padding(28)
        }
    }
}

private struct MonitoringSettings: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @EnvironmentObject private var monitoring: MonitoringPreferences

    var body: some View {
        Form {
            Section("작업 공간") {
                Picker("보기 모드", selection: $monitoring.viewMode) {
                    ForEach(WorkspaceViewMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("왼쪽 서버 목록 표시", isOn: $monitoring.sidebarVisible)
                Toggle("오른쪽 자원 패널 표시", isOn: $monitoring.inspectorVisible)
                Text("화면 양쪽 경계의 화살표로 패널을 접고 펼칩니다. 경계를 드래그하면 너비가 바뀌고, 끝까지 밀면 접힙니다.")
                    .font(.caption).foregroundStyle(appearance.colors.muted)
                Picker("GPU 표시", selection: $monitoring.gpuStyle) {
                    ForEach(GPUDisplayStyle.allCases) { Text($0.title).tag($0) }
                }
                Text("바깥 틸 링은 사용률, 안쪽 연두 링은 VRAM입니다. 가운데 숫자는 사용률만 표시합니다.")
                    .font(.caption).foregroundStyle(appearance.colors.muted)
            }
            Section("표시할 자원") {
                HStack(spacing: 18) {
                    Toggle("CPU", isOn: $monitoring.showCPU)
                    Toggle("메모리", isOn: $monitoring.showMemory)
                    Toggle("네트워크", isOn: $monitoring.showNetwork)
                }
                HStack(spacing: 18) {
                    Toggle("GPU", isOn: $monitoring.showGPU)
                    Toggle("저장 공간", isOn: $monitoring.showDisks)
                }
            }
            Section("수집") {
                Toggle("자원 모니터링", isOn: $monitoring.enabled)
                Picker("선택한 서버 갱신 간격", selection: $monitoring.refreshInterval) {
                    ForEach(MonitoringPreferences.refreshIntervals, id: \.self) { Text("\(Int($0))초").tag($0) }
                }.disabled(!monitoring.enabled)
                Text("다른 서버는 10초 간격으로 최대 3대씩 수집합니다. 서버별 수집 여부는 서버 편집에서 바꿀 수 있습니다. 패널을 숨겨도 수집은 계속되며, 수집을 꺼도 터미널 연결은 유지됩니다.")
                    .font(.caption).foregroundStyle(appearance.colors.muted)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).padding(16)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var connectionPreferences: ConnectionPreferences
    @EnvironmentObject private var appearance: AppearancePreferences
    @ViewState private var showsLicenses = false
    let storeURL: URL
    let demo: Bool
    var body: some View {
        Form {
            Section("터미널과 저장") {
                LabeledContent("터미널 엔진", value: "Ghostty")
                LabeledContent("인증", value: "앱 생성 SSH 키(키체인 미사용) · 기존 SSH 설정 · 저장 비밀번호")
                Text("탭 닫기와 연결 해제는 로컬 연결만 닫습니다. 원격 tmux 작업은 종료하지 않습니다.")
                    .font(.caption).foregroundStyle(appearance.colors.muted)
                Text(demo ? "데모 모드 · 실사용 저장 파일을 변경하지 않음" : storeURL.path)
                    .font(.caption).foregroundStyle(appearance.colors.muted).textSelection(.enabled)
            }
            Section("오픈소스") {
                Text("Ghostty와 함께 사용하는 오픈소스의 저작권 및 라이선스 고지입니다.")
                    .font(.caption).foregroundStyle(appearance.colors.muted)
                Button("오픈소스 라이선스 보기") { showsLicenses = true }
            }
            Section("연결 복구") {
                Toggle("절전·네트워크 복귀 후 기존 SSH 세션 다시 연결", isOn: $connectionPreferences.automaticallyReconnect)
                Text("SSH 키로 열었던 탭만 다시 연결합니다. 새 원격 세션은 만들지 않습니다. 저장 비밀번호·잠긴 키·경유 SSH는 직접 연결하세요.")
                    .font(.caption).foregroundStyle(appearance.colors.muted)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).padding(16)
        .sheet(isPresented: $showsLicenses) { OpenSourceLicensesView() }
    }
}

private struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private var notices: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt", subdirectory: "Licenses"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "앱에 포함된 오픈소스 라이선스 고지를 찾을 수 없습니다."
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("오픈소스 라이선스").font(.title2.bold())
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(verbatim: notices)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(24)
        .frame(width: 720, height: 520)
    }
}

private struct SettingsHeading: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 23, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(appearance.colors.muted)
        }
    }
}

enum HexColorInput {
    static func parse(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return UInt32(digits, radix: 16)
    }
    static func format(_ value: UInt32) -> String { String(format: "#%06X", value) }
}

private struct ColorHexField: View {
    let title: String
    let value: UInt32
    let onCommit: (UInt32) -> Void
    @ViewState private var draft: String
    @FocusState private var focused: Bool

    init(title: String, value: UInt32, onCommit: @escaping (UInt32) -> Void) {
        self.title = title
        self.value = value
        self.onCommit = onCommit
        _draft = State(initialValue: HexColorInput.format(value))
    }

    var body: some View {
        TextField("#RRGGBB", text: $draft)
            .font(.system(size: 11, design: .monospaced)).textFieldStyle(.plain)
            .frame(width: 78, alignment: .leading)
            .focused($focused)
            .accessibilityLabel("\(title) HEX 색상")
            .help("6자리 HEX 색상을 입력하고 Return을 누르세요. #은 생략할 수 있습니다.")
            .onSubmit { commit() }
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onChange(of: value) { _, next in draft = HexColorInput.format(next) }
            .onDisappear { commit() }
    }

    private func commit() {
        guard let next = HexColorInput.parse(draft) else {
            draft = HexColorInput.format(value)
            return
        }
        draft = HexColorInput.format(next)
        if next != value { onCommit(next) }
    }
}
