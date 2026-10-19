import SwiftUI
import InfraCore

extension Color {
    // Navy and mint from the approved owl concept.
    static let infraBackground = Color(red: 13.0 / 255, green: 23.0 / 255, blue: 37.0 / 255)
    static let infraPanel = Color(red: 20.0 / 255, green: 32.0 / 255, blue: 51.0 / 255)
    static let infraSidebar = Color(red: 26.0 / 255, green: 39.0 / 255, blue: 58.0 / 255)
    static let infraAccent = Color(red: 73.0 / 255, green: 230.0 / 255, blue: 205.0 / 255)
    static let infraText = Color(red: 232.0 / 255, green: 238.0 / 255, blue: 248.0 / 255)
    static let infraMuted = Color(red: 166.0 / 255, green: 180.0 / 255, blue: 200.0 / 255)
    static let infraTrack = Color(red: 42.0 / 255, green: 58.0 / 255, blue: 80.0 / 255)
}

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

struct TinyDonut: View {
    let metric: ResourceMetric
    let value: Double?
    let freshness: String
    let warning: String?
    var label: String { "\(metric.rawValue) \(percentage(value)) · \(freshness)" + (warning.map { " · \($0)" } ?? "") }
    var body: some View {
        ZStack {
            Circle().stroke(Color.infraTrack, lineWidth: 3)
            if let value, value.isFinite {
                let fraction = min(1, max(0, value))
                Circle().trim(from: 0, to: fraction)
                    .stroke(AngularGradient(stops: [
                        .init(color: .infraAccent, location: 0),
                        .init(color: .infraAccent, location: 0.50),
                        .init(color: Color(red: 0.87, green: 0.74, blue: 0.43), location: 0.70),
                        .init(color: Color(red: 0.90, green: 0.55, blue: 0.34), location: 0.85),
                        .init(color: Color(red: 0.84, green: 0.39, blue: 0.40), location: 1)
                    ], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(fraction * 100, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 8, weight: .regular, design: .rounded))
                    .monospacedDigit().foregroundStyle(Color.infraMuted)
            } else {
                Text("—").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.infraMuted)
            }
        }
        .frame(width: 22, height: 22).padding(2)
        .accessibilityElement(children: .ignore).accessibilityLabel(label).help(label)
    }
}

struct ResourceDisclosure: View {
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(ResourceMetric.allCases) { item in
                            Button { metric = item } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(item.rawValue).foregroundStyle(Color.infraMuted)
                                        Spacer(minLength: 2)
                                        Text(percentage(item.value(snapshot))).fontWeight(.semibold)
                                    }.font(.system(size: 11))
                                    GeometryReader { geometry in
                                        Capsule().fill(Color.infraTrack)
                                        if let value = item.value(snapshot) {
                                            Capsule().fill(item == .disk && value >= 0.85 ? Color.orange : Color.infraAccent)
                                                .frame(width: geometry.size.width * min(1, max(0, value)))
                                        }
                                    }.frame(height: 3)
                                    Text(item.caption(snapshot, local: server.kind == .local)).font(.system(size: 10)).foregroundStyle(Color.infraMuted).lineLimit(2)
                                }
                                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(metric == item ? Color.infraAccent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).accessibilityLabel("\(item.rawValue) \(percentage(item.value(snapshot))) 상세")
                        }
                    }
                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.rawValue).font(.caption).foregroundStyle(Color.infraMuted)
                            Text(percentage(metric.value(snapshot))).font(.title2.weight(.medium)).monospacedDigit()
                        }.frame(width: 108, alignment: .leading)
                        ResourceHistory(history: history, metric: metric, gap: interval * 3)
                            .frame(height: 55)
                    }
                    Text(demo ? "가상 데이터 · 실제 서버에 연결하지 않습니다." : "이 앱 실행 중 최근 15분 · 긴 공백은 연결하지 않음")
                        .font(.system(size: 10)).foregroundStyle(Color.infraMuted)
                    Divider()
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("GPU 장치", systemImage: "cpu").font(.caption.weight(.medium))
                            if snapshot?.gpus.isEmpty != false { Text(server.kind == .local ? "macOS 수집 미지원" : "미지원 또는 미수집").foregroundStyle(Color.infraMuted) }
                            ForEach(Array((snapshot?.gpus ?? []).enumerated()), id: \.offset) { _, gpu in
                                Text("\(gpu.name) · \(percentage(gpu.utilization))\nVRAM \(bytePair(gpu.memoryUsedBytes, gpu.memoryTotalBytes))")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 5) {
                            Label("네트워크", systemImage: "network").font(.caption.weight(.medium))
                            if snapshot?.network.isEmpty != false { Text(server.kind == .local ? "로컬 네트워크 수집 미지원" : "두 표본 수집 대기 또는 미수집").foregroundStyle(Color.infraMuted) }
                            ForEach(Array((snapshot?.network ?? []).enumerated()), id: \.offset) { _, interface in
                                Text("\(interface.name) · ↓ \(rateText(interface.receivedBytesPerSecond))  ↑ \(rateText(interface.sentBytesPerSecond))")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 11)).textSelection(.enabled)
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
                    ForEach(snapshot?.warnings ?? [], id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(Color.infraMuted)
                    }
                }.padding(.top, 10).padding(.bottom, 12)
            }.frame(maxHeight: 290)
        } label: {
            HStack {
                Text("\(server.name) 자원 상세")
                Spacer()
                if error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Text(freshness(snapshot, now: now, interval: interval, demo: demo)).foregroundStyle(Color.infraMuted)
            }.font(.system(size: 11)).padding(.vertical, 7)
        }
        .padding(.horizontal, 18).background(Color.infraPanel)
    }
}

private struct ResourceHistory: View {
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
                }.stroke(Color.infraMuted.opacity(0.15), lineWidth: 0.5)
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
                    }.stroke(Color.infraAccent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                } else {
                    Text("추이 표본 수집 대기").font(.caption2).foregroundStyle(Color.infraMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.accessibilityLabel("\(metric.rawValue) 앱 실행 중 추이, \(history.count)개 표본")
    }
}
