import AppKit
import InfraCore
import SwiftUI

enum QuickSwitchTarget: Hashable {
    case server(UUID)
    case tab(UUID)
}

struct QuickSwitchItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let target: QuickSwitchTarget
    let searchableFields: [String]

    static func entries(workspace: WorkspaceState, query: String) -> [QuickSwitchItem] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return workspace.servers.flatMap { server in
            let fields = [server.name, server.host]
            var items = [QuickSwitchItem(
                id: "server:\(server.id.uuidString)", title: server.name,
                subtitle: (["서버", server.host] + server.accounts.map(\.username)).joined(separator: " · "),
                target: .server(server.id), searchableFields: fields + server.accounts.map(\.username)
            )]
            items += workspace.tabs.filter { $0.serverID == server.id && !$0.isClosed }.map { tab in
                let username = server.accounts.first { $0.id == tab.accountID }?.username ?? ""
                return QuickSwitchItem(
                    id: "tab:\(tab.id.uuidString)", title: tab.title,
                    subtitle: [server.name, "\(username)@\(server.host)"].joined(separator: " · "),
                    target: .tab(tab.id), searchableFields: fields + [username, tab.title]
                )
            }
            return items.filter { item in
                tokens.allSatisfy { token in
                    item.searchableFields.contains {
                        $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    }
                }
            }
        }
    }
}

struct QuickSwitcherSheet: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var selectedID: String?
    @ViewState private var searchFocusRequest = UUID()
    let workspace: WorkspaceState
    let onSelect: (QuickSwitchTarget) -> Void

    private var items: [QuickSwitchItem] { QuickSwitchItem.entries(workspace: workspace, query: query) }
    private var selectedItem: QuickSwitchItem? { items.first { $0.id == selectedID } ?? items.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("빠른 이동").font(.title2.weight(.semibold))
            SearchInputField(text: $query, placeholder: "서버·호스트·계정·열린 탭 검색",
                             accessibilityLabel: "서버·계정·열린 탭 검색", focusRequest: searchFocusRequest,
                             onSubmit: selectCurrent, onCancel: { dismiss() },
                             onMove: moveSelection, rounded: true)
                .frame(height: 24)
            ScrollViewReader { proxy in
                List(selection: $selectedID) {
                    ForEach(items) { item in
                        Button { onSelect(item.target) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: item.target)).frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.subtitle).font(.caption).foregroundStyle(appearance.colors.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.title), \(item.subtitle)")
                        .accessibilityHint("선택한 서버 또는 기존 열린 탭으로 이동")
                        .tag(item.id)
                        .id(item.id)
                    }
                }
                .scrollContentBackground(.hidden)
                .accessibilityLabel("빠른 이동 검색 결과")
                .overlay {
                    if items.isEmpty {
                        Text("검색 결과 없음").foregroundStyle(appearance.colors.muted).allowsHitTesting(false)
                    }
                }
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            HStack {
                Text("↑ ↓ 선택 · Return 이동").font(.caption).foregroundStyle(appearance.colors.muted)
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("이동", action: selectCurrent).keyboardShortcut(.defaultAction).disabled(items.isEmpty)
            }
        }
        .padding(22).frame(width: 580, height: 460)
        .background(appearance.colors.panel).foregroundStyle(appearance.colors.text).tint(appearance.colors.accent)
        .onAppear { selectedID = items.first?.id }
        .onChange(of: query) { _, _ in selectedID = items.first?.id }
        .onChange(of: items.map(\.id)) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            selectedID = ids.first
        }
    }

    private func icon(for target: QuickSwitchTarget) -> String {
        switch target {
        case .server: return "server.rack"
        case .tab: return "terminal"
        }
    }
    private func selectCurrent() {
        if let item = selectedItem { onSelect(item.target) }
    }
    private func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(items.count - 1, max(0, index + offset))].id
    }
}
