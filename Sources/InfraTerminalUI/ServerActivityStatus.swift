import Foundation
import InfraCore

struct ServerActivityStatus {
    let terminalOpen: Bool
    let checking: Bool
    let collecting: Bool
    private let local: Bool

    init(server: ServerProfile, tabs: [TerminalTab], connections: [UUID: AppModel.ConnectionState],
         monitoringEnabled: Bool, demo: Bool, snapshot: MetricsSnapshot?, collectionError: String?,
         now: Date, interval: TimeInterval) {
        let serverTabs = tabs.filter { $0.serverID == server.id && !$0.isClosed }
        terminalOpen = serverTabs.contains { connections[$0.id] == .launched }
        checking = serverTabs.contains { connections[$0.id] == .checking }
        local = server.kind == .local
        // The local collector runs even in demo mode and has no SSH account gate.
        let canCollect = local || (!demo && server.monitoringEnabled && server.accounts.contains { $0.id == server.monitorAccountID })
        collecting = monitoringEnabled && canCollect && collectionError == nil &&
            snapshot.map { !$0.isStale(now: now, interval: interval) } == true
    }

    var active: Bool { terminalOpen || collecting }

    var summary: String {
        if collecting {
            if terminalOpen { return local ? "로컬 셸 · 자원 수집 중" : "터미널 · 자원 수집 중" }
            return checking ? "자원 수집 · 터미널 확인 중" : "자원 수집 중"
        }
        return terminalDescription
    }

    var detail: String {
        "\(terminalDescription) · \(collecting ? "자원 수집 중" : "자원 수집 중 아님")"
    }

    private var terminalDescription: String {
        if terminalOpen { return local ? "로컬 셸 열림" : "터미널 열림 · 연결 요청됨" }
        return checking ? "연결 확인 중" : "터미널 미연결"
    }
}
