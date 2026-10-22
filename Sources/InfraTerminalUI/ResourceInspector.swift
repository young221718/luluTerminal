import SwiftUI
import InfraCore

struct ResourceInspector: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @EnvironmentObject private var monitoring: MonitoringPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let server: ServerProfile
    let snapshot: MetricsSnapshot?
    let history: [MetricsSnapshot]
    let now: Date
    let interval: TimeInterval
    let error: String?
    let demo: Bool

    private var utilizationColor: Color { Color(rgb: appearance.selection == .dark ? 0x79CCC1 : 0x176E69) }
    private var vramColor: Color { Color(rgb: appearance.selection == .dark ? 0xC8E896 : 0xAFD370) }
    private var disks: [DiskReading] {
        guard let snapshot else { return [] }
        if !snapshot.disks.isEmpty { return snapshot.disks }
        guard let total = snapshot.diskTotalBytes, let used = snapshot.diskUsedBytes else { return [] }
        return [DiskReading(id: "legacy-root", mountPoint: server.kind == .local ? "홈 볼륨" : "/", totalBytes: total,
                            usedBytes: used, availableBytes: max(0, total - used))]
    }

    private var collectionStatus: String {
        if !monitoring.enabled { return "전체 수집 꺼짐 · 마지막 측정값" }
        if demo { return "데모 · 예시 데이터" }
        if !server.monitoringEnabled { return "이 서버 수집 꺼짐 · 마지막 측정값" }
        return freshness(snapshot, now: now, interval: interval, demo: demo)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 5) {
                    Text(server.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                }
                Text(collectionStatus)
                    .font(.system(size: 10)).foregroundStyle(appearance.colors.muted)
                HStack(alignment: .top, spacing: 9) {
                    if monitoring.showCPU { computeMetric("CPU", value: snapshot?.cpu, detail: "사용률") }
                    if monitoring.showMemory { computeMetric("메모리", value: snapshot?.ram, detail: memoryDetail) }
                    if monitoring.showNetwork { networkMetric }
                }
                if monitoring.showGPU { gpuSection }
                if monitoring.showDisks { diskSection }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled)
                }
                if snapshot == nil {
                    Text(monitoring.enabled && server.monitoringEnabled ? "측정값 수집 대기" : "모니터링이 꺼져 있습니다.").font(.system(size: 10)).foregroundStyle(appearance.colors.muted)
                }
                Divider()
                ResourceDisclosure(server: server, snapshot: snapshot, history: history, now: now, interval: interval, error: error, demo: demo)
            }.padding(13)
        }.background(appearance.colors.panel)
    }

    private var memoryDetail: String {
        guard let used = snapshot?.memoryUsedBytes, let total = snapshot?.memoryTotalBytes else { return "측정 없음" }
        return String(format: "%.0f/%.0f GiB", used / 1_073_741_824, total / 1_073_741_824)
    }

    private func computeMetric(_ title: String, value: Double?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(appearance.colors.muted)
            animatedNumber(value == nil ? "—" : percentage(value), value: value).font(.system(size: 18, weight: .medium)).monospacedDigit()
            ResourceBar(value: value, color: utilizationColor).frame(height: 4)
            Text(value == nil ? "측정 없음" : detail).font(.system(size: 9)).foregroundStyle(appearance.colors.muted)
                .lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title) \(percentage(value)) · \(detail)")
    }

    private var networkMetric: some View {
        let interfaces = snapshot?.network.filter { $0.name != "lo" && $0.name != "lo0" } ?? []
        let received = totalRate(interfaces.map(\.receivedBytesPerSecond))
        let sent = totalRate(interfaces.map(\.sentBytesPerSecond))
        return VStack(alignment: .leading, spacing: 3) {
            Text("네트워크").font(.system(size: 10)).foregroundStyle(appearance.colors.muted)
            if received != nil || sent != nil {
                animatedNumber("↓ \(megabyteRate(received))", value: received).padding(.top, 2)
                animatedNumber("↑ \(megabyteRate(sent))", value: sent)
                Text("MB/s").font(.system(size: 9)).foregroundStyle(appearance.colors.muted)
            } else {
                Text("—").font(.system(size: 18, weight: .medium))
                Text(server.kind == .local ? "미지원" : "차분 대기").font(.system(size: 9)).foregroundStyle(appearance.colors.muted)
            }
        }.font(.system(size: 11)).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("네트워크 수신 \(megabyteRate(received)), 송신 \(megabyteRate(sent)) MB/s")
    }

    private var gpuSection: some View {
        let gpus = snapshot?.gpus ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 5) {
                Text("GPU").fontWeight(.medium)
                Text("\(gpus.count)개").foregroundStyle(appearance.colors.muted)
                Spacer()
                Menu {
                    Picker("GPU 표시", selection: $monitoring.gpuStyle) {
                        Text("동심원").tag(GPUDisplayStyle.donuts)
                        Text("작은 바").tag(GPUDisplayStyle.bars)
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("GPU 표시 방식")
            }.font(.system(size: 11))
            if gpus.isEmpty {
                Text(server.kind == .local ? "macOS GPU 수집 미지원" : "GPU 미지원 또는 미수집")
                    .font(.system(size: 10)).foregroundStyle(appearance.colors.muted)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: min(4, gpus.count)), spacing: 13) {
                    ForEach(Array(gpus.enumerated()), id: \.offset) { offset, gpu in
                        gpuCard(gpu, index: gpu.index ?? offset)
                    }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    legend(monitoring.gpuStyle == .donuts ? "바깥 사용률" : "위 사용률", color: utilizationColor)
                    legend(monitoring.gpuStyle == .donuts ? "안쪽 VRAM" : "아래 VRAM", color: vramColor)
                    Spacer(minLength: 0)
                }.font(.system(size: 9)).foregroundStyle(appearance.colors.muted)
            }
        }
    }

    private func gpuCard(_ gpu: GPUReading, index: Int) -> some View {
        let vram: Double? = {
            guard let used = gpu.memoryUsedBytes, let total = gpu.memoryTotalBytes,
                  used.isFinite, total.isFinite, total > 0, used >= 0, used <= total else { return nil }
            return used / total
        }()
        let label = "GPU \(index), \(gpu.name), 사용률 \(percentage(gpu.utilization)), VRAM \(percentage(vram))" + (gpu.id.map { ", \($0)" } ?? "")
        return VStack(spacing: 7) {
            if monitoring.gpuStyle == .donuts {
                ZStack {
                    resourceRing(gpu.utilization, color: utilizationColor, diameter: 41)
                    resourceRing(vram, color: vramColor, diameter: 35)
                    animatedNumber(gpu.utilization == nil ? "—" : percentage(gpu.utilization), value: gpu.utilization)
                        .font(.system(size: 10)).monospacedDigit()
                }.frame(width: 44, height: 44)
            } else {
                VStack(spacing: 5) {
                    animatedNumber(gpu.utilization == nil ? "—" : percentage(gpu.utilization), value: gpu.utilization).font(.system(size: 11)).monospacedDigit()
                    ResourceBar(value: gpu.utilization, color: utilizationColor).frame(height: 4)
                    ResourceBar(value: vram, color: vramColor).frame(height: 4)
                }.frame(maxWidth: .infinity).frame(height: 44)
            }
            VStack(spacing: 2) {
                Text("GPU \(index)").font(.system(size: 9)).lineLimit(1)
                if vram == nil {
                    Text("VRAM —").font(.system(size: 8)).foregroundStyle(appearance.colors.muted)
                }
            }.frame(height: 23, alignment: .top)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore).accessibilityLabel(label).help(label)
    }

    private func resourceRing(_ value: Double?, color: Color, diameter: CGFloat) -> some View {
        let amount = value.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        return ZStack {
            Circle().stroke(appearance.colors.track, lineWidth: 3)
            if let amount {
                Circle().trim(from: 0, to: amount)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .butt)).rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: amount)
            }
        }.frame(width: diameter, height: diameter)
    }

    private func animatedNumber(_ text: String, value: Double?) -> some View {
        let measured = value.flatMap { $0.isFinite ? $0 : nil }
        return Text(text)
            .contentTransition(reduceMotion || measured == nil ? .identity : .numericText(value: measured ?? 0))
            .animation(reduceMotion || measured == nil ? nil : .easeInOut(duration: 0.45), value: measured)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 5, height: 5); Text(title) }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("저장 공간").fontWeight(.medium)
                Text("\(disks.count)개").foregroundStyle(appearance.colors.muted)
                Spacer(minLength: 0)
                Text("남은 용량").foregroundStyle(appearance.colors.muted)
            }.font(.system(size: 10))
            if disks.isEmpty {
                Text("저장 공간 측정값 없음").font(.system(size: 10)).foregroundStyle(appearance.colors.muted)
            }
            ForEach(disks, id: \.id) { disk in
                let low = disk.availableBytes.flatMap { available in
                    disk.totalBytes.flatMap { total in total > 0 ? available / total <= 0.1 : nil }
                } ?? false
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        Image(systemName: "externaldrive").foregroundStyle(appearance.colors.muted)
                        Text(disk.mountPoint).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        Text(byteText(disk.availableBytes)).fixedSize().monospacedDigit()
                        if low { Image(systemName: "exclamationmark.triangle.fill") }
                    }.font(.system(size: 10)).foregroundStyle(low ? Color.orange : appearance.colors.text)
                    ResourceBar(value: disk.utilization, color: low ? .orange : utilizationColor).frame(height: 4)
                }.help("\(disk.mountPoint) · 남은 용량 \(byteText(disk.availableBytes)) · 사용률 \(percentage(disk.utilization))")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(disk.mountPoint), 남은 용량 \(byteText(disk.availableBytes)), 사용률 \(percentage(disk.utilization))\(low ? ", 남은 용량 주의" : "")")
            }
        }
    }

    private func totalRate(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }
    private func megabyteRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return (value / 1_000_000).formatted(.number.precision(.fractionLength(1)))
    }
}

private struct ResourceBar: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Double?
    let color: Color
    var body: some View {
        let amount = value.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(appearance.colors.track)
                if let amount {
                    Capsule().fill(color).frame(width: geometry.size.width * amount)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: amount)
                }
            }
        }.accessibilityHidden(true)
    }
}
