import SwiftUI
import InfraTerminalUI
import TerminalBridge
import InfraCore

// CLT's SDK 27 lacks the new @State macro plugin; use the stable wrapper.
private typealias ViewState<Value> = SwiftUI.State<Value>

@main struct InfraTerminalApp: App {
    @StateObject private var appearance = AppearancePreferences(defaults: CommandLine.arguments.contains("--demo") ? UserDefaults(suiteName: "dev.chanyoung.infra-terminal.demo")! : .standard)
    @StateObject private var monitoring = MonitoringPreferences(defaults: CommandLine.arguments.contains("--demo") ? UserDefaults(suiteName: "dev.chanyoung.infra-terminal.demo")! : .standard)
    @StateObject private var connectionPreferences = ConnectionPreferences(defaults: CommandLine.arguments.contains("--demo") ? UserDefaults(suiteName: "dev.chanyoung.infra-terminal.demo")! : .standard)
    var body: some Scene {
        Window("luluTerminal", id: "main") {
            Group {
                if CommandLine.arguments.contains("--local-terminal") {
                    LocalTerminalView()
                } else {
                    InfraRootView()
                }
            }.frame(minWidth: 1000, minHeight: 680)
                .environmentObject(appearance)
                .environmentObject(monitoring)
                .environmentObject(connectionPreferences)
                .background(appearance.colors.background)
                .preferredColorScheme(appearance.selection.colorScheme)
                .tint(appearance.colors.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 800)
        .commands { TerminalWorkspaceCommands() }
        Settings {
            InfraSettingsView()
                .environmentObject(appearance)
                .environmentObject(monitoring)
                .environmentObject(connectionPreferences)
                .preferredColorScheme(appearance.selection.colorScheme)
                .tint(appearance.colors.accent)
        }
    }
}

private struct LocalTerminalView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var appearance: AppearancePreferences
    @StateObject private var terminal = TerminalHost()
    @ViewState private var id = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("로컬 터미널 검증 · Ghostty")
                Spacer()
                Text("원격 서버 접속 없음").foregroundStyle(.secondary)
            }.font(.caption).padding(12)
            Divider()
            TerminalPane(host: terminal, id: id, style: appearance.terminalStyle)
        }
        .task {
            terminal.onOpenSettings = { openSettings() }
            terminal.open(id: id, command: "/usr/bin/env TERM=xterm-256color /bin/zsh -f")
        }
        .onDisappear { terminal.disconnectAll() }
    }
}
