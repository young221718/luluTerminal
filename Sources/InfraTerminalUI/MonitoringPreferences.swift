import Foundation
import SwiftUI

public enum WorkspaceViewMode: String, CaseIterable, Identifiable {
    case monitor, compact, focus
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .monitor: return "모니터 우선"
        case .compact: return "컴팩트 서버"
        case .focus: return "터미널 집중"
        }
    }
}

public enum GPUDisplayStyle: String, CaseIterable, Identifiable {
    case donuts, bars
    public var id: String { rawValue }
    public var title: String { self == .donuts ? "동심원" : "작은 막대" }
}

@MainActor public final class MonitoringPreferences: ObservableObject {
    private let defaults: UserDefaults
    public static let refreshIntervals: [Double] = [2, 5, 10]
    public static let sidebarWidthRange: ClosedRange<Double> = 160...320
    public static let inspectorWidthRange: ClosedRange<Double> = 220...400
    @Published public var viewMode: WorkspaceViewMode {
        didSet {
            defaults.set(viewMode.rawValue, forKey: "monitor.viewMode")
            if oldValue != viewMode {
                sidebarVisible = viewMode != .focus
                inspectorVisible = viewMode == .monitor
            }
        }
    }
    @Published public var sidebarVisible: Bool { didSet { defaults.set(sidebarVisible, forKey: "monitor.sidebarVisible") } }
    @Published public var inspectorVisible: Bool { didSet { defaults.set(inspectorVisible, forKey: "monitor.inspectorVisible") } }
    @Published public var sidebarWidth: Double {
        didSet {
            let valid = Self.validWidth(sidebarWidth, range: Self.sidebarWidthRange, fallback: 190)
            if sidebarWidth != valid { sidebarWidth = valid }
            defaults.set(sidebarWidth, forKey: "monitor.sidebarWidth")
        }
    }
    @Published public var inspectorWidth: Double {
        didSet {
            let valid = Self.validWidth(inspectorWidth, range: Self.inspectorWidthRange, fallback: 240)
            if inspectorWidth != valid { inspectorWidth = valid }
            defaults.set(inspectorWidth, forKey: "monitor.inspectorWidth")
        }
    }
    @Published public var gpuStyle: GPUDisplayStyle { didSet { defaults.set(gpuStyle.rawValue, forKey: "monitor.gpuStyle") } }
    @Published public var showCPU: Bool { didSet { defaults.set(showCPU, forKey: "monitor.showCPU") } }
    @Published public var showMemory: Bool { didSet { defaults.set(showMemory, forKey: "monitor.showMemory") } }
    @Published public var showNetwork: Bool { didSet { defaults.set(showNetwork, forKey: "monitor.showNetwork") } }
    @Published public var showGPU: Bool { didSet { defaults.set(showGPU, forKey: "monitor.showGPU") } }
    @Published public var showDisks: Bool { didSet { defaults.set(showDisks, forKey: "monitor.showDisks") } }
    @Published public var enabled: Bool { didSet { defaults.set(enabled, forKey: "monitor.enabled") } }
    @Published public var refreshInterval: Double {
        didSet {
            if !Self.refreshIntervals.contains(refreshInterval) { refreshInterval = 2 }
            defaults.set(refreshInterval, forKey: "monitor.refreshInterval")
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initialMode = defaults.string(forKey: "monitor.viewMode").flatMap(WorkspaceViewMode.init(rawValue:)) ?? .monitor
        viewMode = initialMode
        sidebarVisible = defaults.object(forKey: "monitor.sidebarVisible") as? Bool ?? (initialMode != .focus)
        sidebarWidth = Self.validWidth(defaults.object(forKey: "monitor.sidebarWidth") as? Double ?? 190, range: Self.sidebarWidthRange, fallback: 190)
        inspectorWidth = Self.validWidth(defaults.object(forKey: "monitor.inspectorWidth") as? Double ?? 240, range: Self.inspectorWidthRange, fallback: 240)
        inspectorVisible = defaults.object(forKey: "monitor.inspectorVisible") as? Bool ?? (initialMode == .monitor)
        gpuStyle = defaults.string(forKey: "monitor.gpuStyle").flatMap(GPUDisplayStyle.init(rawValue:)) ?? .donuts
        showCPU = defaults.object(forKey: "monitor.showCPU") as? Bool ?? true
        showMemory = defaults.object(forKey: "monitor.showMemory") as? Bool ?? true
        showNetwork = defaults.object(forKey: "monitor.showNetwork") as? Bool ?? true
        showGPU = defaults.object(forKey: "monitor.showGPU") as? Bool ?? true
        showDisks = defaults.object(forKey: "monitor.showDisks") as? Bool ?? true
        enabled = defaults.object(forKey: "monitor.enabled") as? Bool ?? true
        refreshInterval = Self.validInterval(defaults.double(forKey: "monitor.refreshInterval"))
        defaults.set(sidebarVisible, forKey: "monitor.sidebarVisible")
        defaults.set(sidebarWidth, forKey: "monitor.sidebarWidth")
        defaults.set(inspectorWidth, forKey: "monitor.inspectorWidth")
    }

    private static func validWidth(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    static func validInterval(_ value: Double) -> Double { refreshIntervals.contains(value) ? value : 2 }
}
