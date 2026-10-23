import SwiftUI
import TerminalBridge

struct TerminalSearchBar: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @ObservedObject var host: TerminalHost

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(appearance.colors.muted)
            SearchInputField(
                text: Binding(get: { host.search?.query ?? "" }, set: { host.updateSearchQuery($0) }),
                placeholder: "터미널에서 찾기", accessibilityLabel: "터미널 검색어",
                focusRequest: host.searchFocusRequest,
                onSubmit: { host.navigateSearch(previous: false) },
                onCancel: { host.closeSearch() })
                .frame(height: 20)
            Text(resultLabel).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(appearance.colors.muted).monospacedDigit()
                .accessibilityLabel("검색 결과 \(resultLabel)")
            Button { host.navigateSearch(previous: true) } label: { Image(systemName: "chevron.up") }
                .help("이전 결과 · ⇧⌘G").accessibilityLabel("이전 검색 결과")
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button { host.navigateSearch(previous: false) } label: { Image(systemName: "chevron.down") }
                .help("다음 결과 · ⌘G").accessibilityLabel("다음 검색 결과")
                .keyboardShortcut("g", modifiers: .command)
            Button { host.closeSearch() } label: { Image(systemName: "xmark") }
                .help("검색 닫기 · Esc").accessibilityLabel("검색 닫기")
        }
        .buttonStyle(.plain).font(.system(size: 12))
        .padding(10).frame(width: 360)
        .background(appearance.colors.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(appearance.colors.track, lineWidth: 1) }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(10)
    }

    private var resultLabel: String {
        guard let search = host.search, !search.query.isEmpty else { return "" }
        guard let total = search.total else { return "…" }
        guard total > 0 else { return "0 / 0" }
        guard let selected = search.selected else { return "– / \(total)" }
        return "\(selected + 1) / \(total)"
    }
}
