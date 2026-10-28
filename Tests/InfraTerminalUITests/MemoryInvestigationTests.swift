import AppKit
import Darwin
import InfraCore
import SwiftUI
import Testing
@testable import InfraTerminalUI

// Opt-in native allocation regression; fresh process, synthetic state, no SSH.
// INFRA_MEMORY_STRESS=1 bash scripts/test.sh --filter MemoryInvestigationTests
@MainActor struct MemoryInvestigationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INFRA_MEMORY_STRESS"] == "1"))
    func profileEditorStaysBoundedDuringClockUpdates() async throws {
        let iterations = Int(ProcessInfo.processInfo.environment["INFRA_MEMORY_ITERATIONS"] ?? "2000") ?? 2000
        try #require(iterations > 0)
        let domain = "MemoryInvestigationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel(demo: false, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("MemoryInvestigationTests-\(UUID())/state.json"), agentEnvironment: [:]) { _, _ in
            ProcessResult(exitCode: 255, stdout: "", stderr: "synthetic diagnostic")
        }
        model.configureMonitoring(enabled: false, selectedInterval: 5)
        let presentation = MemoryPresentation()
        let counter = MemoryBodyCounter()
        let host = NSHostingView(rootView: MemoryProfileFixture(model: model, presentation: presentation, counter: counter)
            .environmentObject(AppearancePreferences(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        func commit(_ tick: Int) async throws {
            model.tick(at: Date(timeIntervalSince1970: Double(tick)))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(2))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            window.attachedSheet?.displayIfNeeded()
        }
        for tick in 1...100 { try await commit(tick) }
        let sheet = try #require(window.attachedSheet)
        func fieldCount(_ view: NSView) -> Int {
            (view is NSTextField ? 1 : 0) + view.subviews.reduce(0) { $0 + fieldCount($1) }
        }
        #expect(fieldCount(try #require(sheet.contentView)) == 4)
        let initialBodies = counter.bodies
        let initial = try memory()
        print("MEMORY_START iterations=\(iterations) bodies=\(initialBodies) footprint=\(initial.footprint) malloc=\(initial.malloc)")
        for tick in 1...iterations {
            try await commit(tick + 100)
            if tick % 500 == 0 || tick == iterations {
                let sample = try memory()
                print("MEMORY_SAMPLE tick=\(tick) bodies=\(counter.bodies - initialBodies) footprint=\(sample.footprint) malloc=\(sample.malloc) footprint_delta=\(Int64(sample.footprint) - Int64(initial.footprint)) malloc_delta=\(Int64(sample.malloc) - Int64(initial.malloc))")
            }
        }
        let final = try memory()
        #expect(counter.bodies - initialBodies >= iterations, "Every clock update must evaluate the root fixture")
        #expect(Int64(final.malloc) - Int64(initial.malloc) <= 1_048_576,
                "Presented editor must stay within 1 MiB after parent clock updates")
    }

    private func memory() throws -> (footprint: UInt64, malloc: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try #require(result == KERN_SUCCESS)
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return (info.phys_footprint, UInt64(statistics.size_in_use))
    }
}

@MainActor private final class MemoryBodyCounter {
    var bodies = 0
}

@MainActor private final class MemoryPresentation: ObservableObject {
    @Published var showProfile = true
    @Published var request: SSHKeySetupRequest?
}

private struct MemoryProfileFixture: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: MemoryPresentation
    let counter: MemoryBodyCounter

    var body: some View {
        let _ = counter.bodies += 1
        Text("Synthetic root \(model.now.timeIntervalSince1970)").frame(width: 800, height: 700)
            .modifier(ProfileSSHKeySheets(model: model, showProfile: $presentation.showProfile, editingProfile: nil,
                                          keySetupRequest: $presentation.request, disconnect: { _ in }))
    }
}
