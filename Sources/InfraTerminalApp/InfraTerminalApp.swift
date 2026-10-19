import SwiftUI
import InfraTerminalUI
import TerminalBridge

// CLT's SDK 27 lacks the new @State macro plugin; use the stable wrapper.
private typealias ViewState<Value> = SwiftUI.State<Value>

@main struct InfraTerminalApp: App {
    var body: some Scene {
        Window("luluTerminal", id: "main") {
            Group {
                if CommandLine.arguments.contains("--local-terminal") {
                    LocalTerminalView()
                } else {
                    InfraRootView()
                }
            }.frame(minWidth: 1000, minHeight: 680)
                .background(Color(red: 13.0 / 255, green: 23.0 / 255, blue: 37.0 / 255))
                .preferredColorScheme(.dark)
                .tint(Color(red: 73.0 / 255, green: 230.0 / 255, blue: 205.0 / 255))
        }
        .defaultSize(width: 1280, height: 800)
    }
}

private struct LocalTerminalView: View {
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
            TerminalPane(host: terminal, id: id)
        }
        .task { terminal.open(id: id, command: "/usr/bin/env TERM=xterm-256color /bin/zsh -f") }
        .onDisappear { terminal.disconnectAll() }
    }
}
