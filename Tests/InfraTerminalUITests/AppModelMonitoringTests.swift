import Testing
import Foundation
@testable import InfraTerminalUI
import InfraCore

extension AppModelTests {
    @Test func testDemoHasTenServersAndNeverSchedulesRemotePolling() throws {
        let model = AppModel(demo: true, storeURL: temporaryURL())
        #expect(model.workspace.servers.filter { $0.kind == .ssh }.count == 10)
        #expect(model.workspace.servers.first?.kind == .local)
        #expect(model.isDemo)
        #expect(model.dueServerIDs(now: Date()).isEmpty)
        #expect(model.metrics.values.contains { $0.gpu == 0 })
        #expect(model.metrics.values.contains { $0.gpu == nil })
    }

    @Test func testSchedulerUsesSelectedIntervalAndBoundedSlots() throws {
        let model = AppModel(demo: false, storeURL: temporaryURL())
        for index in 0..<5 {
            var profile = server()
            profile.name = "Server \(index)"
            try model.saveProfile(profile)
        }
        let now = Date()
        #expect(model.dueServerIDs(now: now).count == 3)
        #expect(model.dueServerIDs(now: now).first == model.selectedServer?.id)
        #expect(model.pollInterval(for: model.selectedServer!.id) == 2)
        #expect(model.pollInterval(for: model.workspace.servers.first!.id) == 10)
    }

    @Test func testRepeatedFailuresDoNotStarveUnattemptedServers() async throws {
        let model = AppModel(demo: false, storeURL: temporaryURL()) { _, _ in
            ProcessResult(exitCode: 255, stdout: "", stderr: "fixture failure")
        }
        for index in 0..<10 {
            var profile = server()
            profile.name = "Server \(index)"
            try model.saveProfile(profile)
        }
        let time = Date()
        let firstIDs = Set(model.dueServerIDs(now: time))
        model.tick(at: time)
        try await waitUntil { model.collectionErrors.count == 3 }
        let secondIDs = model.dueServerIDs(now: time.addingTimeInterval(16))
        #expect(secondIDs.first == model.selectedServer?.id)
        #expect(secondIDs.filter { !firstIDs.contains($0) }.count == 2)
    }

    @Test func testSuspendedCollectorsRemainBoundedWithoutOverlappingServers() async throws {
        let collector = SuspendedCollector()
        let model = AppModel(demo: false, storeURL: temporaryURL()) { command, _ in
            await collector.run(command)
        }
        for index in 0..<10 {
            var profile = server()
            profile.host = "server-\(index).invalid"
            try model.saveProfile(profile)
        }
        let time = Date()
        model.tick(at: time)
        for _ in 0..<500 {
            if await collector.commands.count == 3 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        model.tick(at: time.addingTimeInterval(20))
        let commands = await collector.commands
        #expect(commands.count == 3)
        #expect(Set(commands.map { $0.arguments.joined(separator: " ") }).count == 3)
        #expect(model.dueServerIDs(now: time.addingTimeInterval(20)).isEmpty)
        await collector.releaseAll()
        try await waitUntil { model.collectionErrors.count == 3 }
        model.stop()
    }

    @Test func testProfileEndpointChangeDiscardsPriorMetricsAndHistory() throws {
        let model = AppModel(demo: true, storeURL: temporaryURL())
        model.tick(at: Date())
        var profile = try #require(model.workspace.servers.first { $0.kind == .ssh })
        #expect(model.metrics[profile.id] != nil)
        #expect(model.histories[profile.id]?.isEmpty == false)
        profile.host = "different-target.invalid"
        try model.saveProfile(profile)
        #expect(model.metrics[profile.id] == nil)
        #expect(model.histories[profile.id] == nil)
        #expect(model.collectionErrors[profile.id] == nil)
    }

    @Test func testDisplayRenameRetainsSameTargetMeasurements() throws {
        let model = AppModel(demo: true, storeURL: temporaryURL())
        model.tick(at: Date())
        var profile = try #require(model.workspace.servers.first { $0.kind == .ssh })
        let originalMetrics = model.metrics[profile.id]
        let originalHistory = model.histories[profile.id]
        profile.name = "Renamed display"
        try model.saveProfile(profile)
        #expect(model.metrics[profile.id] == originalMetrics)
        #expect(model.histories[profile.id] == originalHistory)
    }

    @Test func testUnknownDetailValuesRemainDistinctFromZero() {
        #expect(percentage(nil) == "확인 불가")
        #expect(percentage(0) != percentage(nil))
        #expect(bytePair(nil, nil) == "— / —")
        #expect(rateText(nil) == "—")
        #expect(rateText(0) != rateText(nil))
    }
}
