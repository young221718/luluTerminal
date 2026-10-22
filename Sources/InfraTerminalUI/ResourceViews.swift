import SwiftUI
import InfraCore

enum ResourceMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU", ram = "RAM", disk = "디스크", gpu = "GPU", vram = "VRAM"
    var id: String { rawValue }
    func value(_ snapshot: MetricsSnapshot?) -> Double? {
        switch self {
        case .cpu: return snapshot?.cpu
        case .ram: return snapshot?.ram
        case .disk: return snapshot?.disk
        case .gpu: return snapshot?.gpu
        case .vram: return snapshot?.vram
        }
    }
    func caption(_ snapshot: MetricsSnapshot?, local: Bool = false) -> String {
        switch self {
        case .cpu: return "전체 코어 · 두 표본 차분"
        case .ram: return bytePair(snapshot?.memoryUsedBytes, snapshot?.memoryTotalBytes) + (local ? " · 캐시 포함" : "")
        case .disk: return (local ? "홈 볼륨 · " : "/ · ") + bytePair(snapshot?.diskUsedBytes, snapshot?.diskTotalBytes)
        case .gpu: return local ? "macOS GPU 수집 미지원" : snapshot?.gpus.isEmpty == false ? "장치 \(snapshot!.gpus.count)개 평균" : "장치 미지원 또는 미수집"
        case .vram: return local ? "macOS VRAM 수집 미지원" : "장치별 총량 가중 비율"
        }
    }
}

func percentage(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "확인 불가" }
    return value.formatted(.percent.precision(.fractionLength(0)))
}
func byteText(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
}
func bytePair(_ used: Double?, _ total: Double?) -> String { "\(byteText(used)) / \(byteText(total))" }
func rateText(_ value: Double?) -> String { value == nil ? "—" : byteText(value) + "/s" }
func freshness(_ snapshot: MetricsSnapshot?, now: Date, interval: TimeInterval, demo: Bool) -> String {
    guard let snapshot else { return "아직 수집하지 않음" }
    let age = max(0, Int(now.timeIntervalSince(snapshot.timestamp)))
    let prefix = snapshot.isStale(now: now, interval: interval) ? "갱신 중단 · " : ""
    return (demo ? "가상 · " : "") + prefix + (age < 60 ? "\(age)초 전" : "\(age / 60)분 전")
}

struct ResourceDisclosure: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    let server: ServerProfile
    let snapshot: MetricsSnapshot?
    let history: [MetricsSnapshot]
    let now: Date
    let interval: TimeInterval
    let error: String?
    let demo: Bool
    @ViewState private var expanded = false
    @ViewState private var metric: ResourceMetric = .cpu

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("추이 항목", selection: $metric) {
                    ForEach(ResourceMetric.allCases) { item in Text(item.rawValue).tag(item) }
                }.pickerStyle(.menu).controlSize(.small)
                HStack {
                    Text(metric.rawValue).foregroundStyle(appearance.colors.muted)
                    Spacer()
                    Text(percentage(metric.value(snapshot))).monospacedDigit()
                }.font(.system(size: 11))
                ResourceHistory(history: history, metric: metric, gap: interval * 3).frame(height: 65)
                Text(metric.caption(snapshot, local: server.kind == .local))
                Text(demo ? "가상 데이터 · 실제 서버에 연결하지 않습니다." : "앱 실행 중 최근 15분 · 긴 공백은 연결하지 않음")
                if snapshot?.gpus.isEmpty == false {
                    Divider()
                    Text("GPU 장치 상세").fontWeight(.medium)
                    ForEach(Array((snapshot?.gpus ?? []).enumerated()), id: \.offset) { index, gpu in
                        Text("GPU \(gpu.index ?? index) · \(gpu.name)\n사용률 \(percentage(gpu.utilization)) · VRAM \(bytePair(gpu.memoryUsedBytes, gpu.memoryTotalBytes))")
                    }
                }
                if snapshot?.network.isEmpty == false {
                    Divider()
                    Text("네트워크 인터페이스").fontWeight(.medium)
                    ForEach(Array((snapshot?.network ?? []).enumerated()), id: \.offset) { _, interface in
                        Text("\(interface.name)\n↓ \(rateText(interface.receivedBytesPerSecond))  ↑ \(rateText(interface.sentBytesPerSecond))")
                    }
                }
                ForEach(snapshot?.warnings ?? [], id: \.self) { warning in Text(warning) }
            }.font(.system(size: 10)).foregroundStyle(appearance.colors.muted)
                .textSelection(.enabled).padding(.top, 8).padding(.bottom, 6)
        } label: {
            Text("최근 기록 · 수집 상세").font(.system(size: 11))
        }
    }
}

private struct ResourceHistory: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    let history: [MetricsSnapshot]
    let metric: ResourceMetric
    let gap: TimeInterval
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    for level in [0.0, 0.5, 1.0] {
                        path.move(to: CGPoint(x: 0, y: geometry.size.height * level))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * level))
                    }
                }.stroke(appearance.colors.muted.opacity(0.15), lineWidth: 0.5)
                if history.count > 1, let first = history.first, let last = history.last {
                    Path { path in
                        let duration = max(1, last.timestamp.timeIntervalSince(first.timestamp))
                        var preceding: Date?
                        for sample in history {
                            guard let value = metric.value(sample), value.isFinite else { preceding = nil; continue }
                            let point = CGPoint(x: sample.timestamp.timeIntervalSince(first.timestamp) / duration * geometry.size.width, y: (1 - min(1, max(0, value))) * geometry.size.height)
                            if let preceding, sample.timestamp.timeIntervalSince(preceding) <= gap { path.addLine(to: point) }
                            else { path.move(to: point) }
                            preceding = sample.timestamp
                        }
                    }.stroke(appearance.colors.healthy, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                } else {
                    Text("추이 표본 수집 대기").font(.caption2).foregroundStyle(appearance.colors.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.accessibilityLabel("\(metric.rawValue) 앱 실행 중 추이, \(history.count)개 표본")
    }
}
