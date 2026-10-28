import Foundation
import InfraCore
import Testing
@testable import InfraTerminalUI

struct ServerActivityStatusTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func freshMonitoringWakesOwlWithoutOpeningATerminal() {
        let status = status(snapshot: MetricsSnapshot(timestamp: now.addingTimeInterval(-1)))
        #expect(status.active)
        #expect(status.collecting)
        #expect(!status.terminalOpen)
        #expect(status.summary == "자원 수집 중")
        #expect(status.detail == "터미널 미연결 · 자원 수집 중")
    }

    @Test func cachedMetricsDoNotWakeOwlWhenMonitoringFailsOrStops() {
        let fresh = MetricsSnapshot(timestamp: now)
        #expect(!status(snapshot: fresh, error: "authentication failed").active)
        #expect(!status(snapshot: fresh, enabled: false).active)
        var disabled = server()
        disabled.monitoringEnabled = false
        #expect(!status(server: disabled, snapshot: fresh).active)
        var missingAccount = server()
        missingAccount.monitorAccountID = nil
        #expect(!status(server: missingAccount, snapshot: fresh).active)
        missingAccount.monitorAccountID = UUID()
        #expect(!status(server: missingAccount, snapshot: fresh).active)
        #expect(!status().active)
    }

    @Test(arguments: [2.0, 10.0]) func freshnessUsesTheExactThreeIntervalBoundary(interval: TimeInterval) {
        #expect(status(snapshot: MetricsSnapshot(timestamp: now.addingTimeInterval(-interval * 3 + 0.01)), interval: interval).active)
        #expect(!status(snapshot: MetricsSnapshot(timestamp: now.addingTimeInterval(-interval * 3)), interval: interval).active)
        #expect(!status(snapshot: MetricsSnapshot(timestamp: now.addingTimeInterval(-interval * 4)), interval: interval).active)
    }

    @Test func launchedTerminalKeepsOwlAwakeWhenMonitoringFails() {
        let profile = server()
        let tab = TerminalTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Fixture")
        let open = status(server: profile, tabs: [tab], connections: [tab.id: .launched], error: "collection failed")
        #expect(open.active)
        #expect(open.terminalOpen)
        #expect(!open.collecting)
        #expect(open.summary == "터미널 열림 · 연결 요청됨")
        #expect(open.detail.contains("자원 수집 중 아님"))
        let both = status(server: profile, tabs: [tab], connections: [tab.id: .launched], snapshot: MetricsSnapshot(timestamp: now))
        #expect(both.summary == "터미널 · 자원 수집 중")
        #expect(both.detail.contains("터미널 열림 · 연결 요청됨"))
    }

    @Test func closedAndOtherServerTerminalsDoNotWakeOwl() {
        let profile = server()
        let closed = TerminalTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Closed", isClosed: true)
        let other = TerminalTab(serverID: UUID(), accountID: profile.accounts[0].id, title: "Other")
        #expect(!status(server: profile, tabs: [closed, other], connections: [closed.id: .launched, other.id: .launched]).active)
        let checking = TerminalTab(serverID: profile.id, accountID: profile.accounts[0].id, title: "Checking")
        let waiting = status(server: profile, tabs: [checking], connections: [checking.id: .checking])
        #expect(!waiting.active)
        #expect(waiting.summary == "연결 확인 중")
        let monitored = status(server: profile, tabs: [checking], connections: [checking.id: .checking], snapshot: MetricsSnapshot(timestamp: now))
        #expect(monitored.active)
        #expect(monitored.detail == "연결 확인 중 · 자원 수집 중")
    }

    @Test func demoSamplesStayAsleepWhileRealLocalMonitoringCanWakeOwl() {
        let fresh = MetricsSnapshot(timestamp: now)
        #expect(!status(snapshot: fresh, demo: true).active)
        var local = LocalMachine.profile
        local.monitoringEnabled = false
        local.monitorAccountID = nil
        let localStatus = status(server: local, snapshot: fresh, demo: true)
        #expect(localStatus.active, "The local collector runs independently of SSH account settings, including in demo mode")
        #expect(localStatus.summary == "자원 수집 중")
        #expect(!status(server: local, snapshot: fresh, enabled: false, demo: true).active)
    }

    private func server() -> ServerProfile {
        let account = SSHAccount(username: "fixture")
        return ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account], monitorAccountID: account.id)
    }

    private func status(server: ServerProfile? = nil, tabs: [TerminalTab] = [], connections: [UUID: AppModel.ConnectionState] = [:],
                        snapshot: MetricsSnapshot? = nil, error: String? = nil, enabled: Bool = true,
                        interval: TimeInterval = 2, demo: Bool = false) -> ServerActivityStatus {
        ServerActivityStatus(server: server ?? self.server(), tabs: tabs, connections: connections,
                             monitoringEnabled: enabled, demo: demo, snapshot: snapshot, collectionError: error,
                             now: now, interval: interval)
    }
}
