import Foundation

public struct GPUReading: Equatable, Sendable {
    public var name: String
    public var utilization: Double?
    public var memoryUsedBytes: Double?
    public var memoryTotalBytes: Double?
    public init(name: String, utilization: Double? = nil, memoryUsedBytes: Double? = nil, memoryTotalBytes: Double? = nil) {
        self.name = name; self.utilization = utilization; self.memoryUsedBytes = memoryUsedBytes; self.memoryTotalBytes = memoryTotalBytes
    }
}
public struct NetworkRate: Equatable, Sendable {
    public var name: String
    public var receivedBytesPerSecond: Double?
    public var sentBytesPerSecond: Double?
    public init(name: String, receivedBytesPerSecond: Double? = nil, sentBytesPerSecond: Double? = nil) {
        self.name = name; self.receivedBytesPerSecond = receivedBytesPerSecond; self.sentBytesPerSecond = sentBytesPerSecond
    }
}
public struct MetricsSnapshot: Equatable, Sendable {
    public var timestamp: Date
    public var cpu: Double?
    public var ram: Double?
    public var disk: Double?
    public var gpu: Double?
    public var vram: Double?
    public var memoryUsedBytes: Double?
    public var memoryTotalBytes: Double?
    public var diskUsedBytes: Double?
    public var diskTotalBytes: Double?
    public var gpus: [GPUReading]
    public var network: [NetworkRate]
    public var warnings: [String]
    public init(timestamp: Date, cpu: Double? = nil, ram: Double? = nil, disk: Double? = nil, gpu: Double? = nil, vram: Double? = nil,
                memoryUsedBytes: Double? = nil, memoryTotalBytes: Double? = nil, diskUsedBytes: Double? = nil, diskTotalBytes: Double? = nil,
                gpus: [GPUReading] = [], network: [NetworkRate] = [], warnings: [String] = []) {
        self.timestamp = timestamp; self.cpu = cpu; self.ram = ram; self.disk = disk; self.gpu = gpu; self.vram = vram
        self.memoryUsedBytes = memoryUsedBytes; self.memoryTotalBytes = memoryTotalBytes; self.diskUsedBytes = diskUsedBytes; self.diskTotalBytes = diskTotalBytes
        self.gpus = gpus; self.network = network; self.warnings = warnings
    }
    public func isStale(now: Date, interval: TimeInterval) -> Bool {
        !interval.isFinite || interval <= 0 || now.timeIntervalSince(timestamp) >= interval * 3
    }
}
public struct RawMetrics: Sendable {
    public var timestamp: Date
    public var bootID: String?
    public var uptime: Double?
    public var cpuCounters: [UInt64]?
    public var memoryTotalBytes: Double?
    public var memoryAvailableBytes: Double?
    public var diskUsedBytes: Double?
    public var diskTotalBytes: Double?
    public var gpus: [GPUReading]
    public var networkCounters: [String: (received: UInt64, sent: UInt64)]
    public var warnings: [String]
}
public enum MetricsParseError: Error, LocalizedError {
    case invalidEnvelope
    public var errorDescription: String? { "Incomplete or invalid Linux metrics response." }
}
public enum MetricsParser {
    public static func parse(_ output: String, timestamp: Date) throws -> RawMetrics {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "__INFRA_V1__", lines.last(where: { !$0.isEmpty }) == "__INFRA_END__" else { throw MetricsParseError.invalidEnvelope }
        var sections: [String: [String]] = [:]
        var section: String?
        for line in lines.dropFirst() {
            if line.hasPrefix("__INFRA_"), line.hasSuffix("__") {
                guard sections[line] == nil else { throw MetricsParseError.invalidEnvelope }
                section = line; sections[line] = []
            } else if !line.isEmpty, let section { sections[section, default: []].append(line) }
        }
        var raw = RawMetrics(timestamp: timestamp, bootID: nil, uptime: nil, cpuCounters: nil, memoryTotalBytes: nil,
                             memoryAvailableBytes: nil, diskUsedBytes: nil, diskTotalBytes: nil, gpus: [], networkCounters: [:], warnings: [])
        raw.bootID = sections["__INFRA_BOOT__"]?.first
        if let value = sections["__INFRA_UPTIME__"]?.first?.split(separator: " ").first.flatMap({ Double($0) }), value.isFinite, value >= 0 { raw.uptime = value }
        if let cpu = sections["__INFRA_CPU__"]?.first(where: { $0.hasPrefix("cpu ") }) {
            let fields = cpu.split(whereSeparator: \.isWhitespace).dropFirst()
            let counters = fields.prefix(8).compactMap { UInt64($0) }
            if counters.count >= 4, counters.count == min(8, fields.count) { raw.cpuCounters = counters }
        }
        if raw.cpuCounters == nil { raw.warnings.append("CPU counters unavailable.") }
        var memory: [String: Double] = [:]
        for line in sections["__INFRA_MEM__"] ?? [] {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 3, fields[2] == "kB", let value = positive(String(fields[1]), allowZero: true) { memory[String(fields[0])] = value * 1024 }
        }
        if let total = memory["MemTotal:"], let available = memory["MemAvailable:"], total > 0, available <= total {
            raw.memoryTotalBytes = total; raw.memoryAvailableBytes = available
        } else { raw.warnings.append("RAM unavailable: MemTotal/MemAvailable invalid.") }
        for line in sections["__INFRA_DISK__"] ?? [] {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 6, fields.last == "/", let total = positive(String(fields[1])),
               let used = positive(String(fields[2]), allowZero: true), used <= total {
                raw.diskTotalBytes = total * 1024; raw.diskUsedBytes = used * 1024
            }
        }
        if raw.diskTotalBytes == nil { raw.warnings.append("Root filesystem usage unavailable.") }
        for line in sections["__INFRA_NET__"] ?? [] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let fields = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace)
            if !name.isEmpty, fields.count >= 16, let received = UInt64(fields[0]), let sent = UInt64(fields[8]) {
                raw.networkCounters[name] = (received, sent)
            }
        }
        if raw.networkCounters.isEmpty { raw.warnings.append("Network counters unavailable.") }
        for line in sections["__INFRA_GPU__"] ?? [] {
            if line == "UNAVAILABLE" { raw.warnings.append("NVIDIA GPU collection unavailable."); continue }
            if line == "ERROR" { raw.warnings.append("NVIDIA GPU collection failed."); continue }
            let fields = csvFields(line)
            guard fields.count == 4, !fields[0].isEmpty else { raw.warnings.append("Malformed NVIDIA GPU response."); continue }
            let utilization = positive(fields[1], allowZero: true).flatMap { $0 <= 100 ? $0 / 100 : nil }
            let total = positive(fields[3]).map { $0 * 1024 * 1024 }
            let used = positive(fields[2], allowZero: true).map { $0 * 1024 * 1024 }.flatMap { value in total.flatMap { value <= $0 ? value : nil } }
            raw.gpus.append(GPUReading(name: fields[0], utilization: utilization, memoryUsedBytes: used, memoryTotalBytes: total))
            if utilization == nil || used == nil || total == nil { raw.warnings.append("GPU \(fields[0]) contains unavailable values.") }
        }
        if raw.gpus.isEmpty, raw.warnings.allSatisfy({ !$0.contains("GPU") }) { raw.warnings.append("NVIDIA GPU response missing.") }
        if raw.bootID == nil || raw.uptime == nil { raw.warnings.append("Boot identity/monotonic time unavailable; counter rates are unknown.") }
        return raw
    }
    private static func positive(_ string: String, allowZero: Bool = false) -> Double? {
        guard let value = Double(string), value.isFinite, allowZero ? value >= 0 : value > 0 else { return nil }
        return value
    }
    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []; var field = ""; var quoted = false
        for char in line {
            if char == "\"" { quoted.toggle() }
            else if char == "," && !quoted { fields.append(field.trimmingCharacters(in: .whitespaces)); field = "" }
            else { field.append(char) }
        }
        guard !quoted else { return [] }
        fields.append(field.trimmingCharacters(in: .whitespaces)); return fields
    }
}
public enum MetricsCalculator {
    public static func calculate(current: RawMetrics, previous: RawMetrics?) -> MetricsSnapshot {
        var snapshot = MetricsSnapshot(timestamp: current.timestamp, memoryTotalBytes: current.memoryTotalBytes,
                                       diskUsedBytes: current.diskUsedBytes, diskTotalBytes: current.diskTotalBytes, gpus: current.gpus, warnings: current.warnings)
        if let total = current.memoryTotalBytes, let available = current.memoryAvailableBytes {
            snapshot.memoryUsedBytes = total - available; snapshot.ram = ratio(total - available, total)
        }
        snapshot.disk = ratio(current.diskUsedBytes, current.diskTotalBytes)
        if !current.gpus.isEmpty {
            let values = current.gpus.compactMap(\.utilization)
            if values.count == current.gpus.count { snapshot.gpu = values.reduce(0, +) / Double(values.count) }
            let used = current.gpus.compactMap(\.memoryUsedBytes), total = current.gpus.compactMap(\.memoryTotalBytes)
            if used.count == current.gpus.count, total.count == current.gpus.count { snapshot.vram = ratio(used.reduce(0, +), total.reduce(0, +)) }
        }
        var elapsed: Double?
        if let previous, let boot = current.bootID, boot == previous.bootID,
           let now = current.uptime, let before = previous.uptime, now > before, now - before <= 30,
           current.timestamp.timeIntervalSince(previous.timestamp) > 0, current.timestamp.timeIntervalSince(previous.timestamp) <= 30 {
            elapsed = now - before
            if let a = current.cpuCounters, let b = previous.cpuCounters, a.count == b.count, zip(a, b).allSatisfy({ $0 >= $1 }) {
                let delta = zip(a, b).map { Double($0 - $1) }
                let total = delta.reduce(0, +), idle = delta[3] + (delta.count > 4 ? delta[4] : 0)
                snapshot.cpu = ratio(total - idle, total)
            }
        }
        snapshot.network = current.networkCounters.keys.sorted().map { name in
            var rate = NetworkRate(name: name)
            if let elapsed, let before = previous?.networkCounters[name], let now = current.networkCounters[name] {
                if now.received >= before.received { rate.receivedBytesPerSecond = Double(now.received - before.received) / elapsed }
                if now.sent >= before.sent { rate.sentBytesPerSecond = Double(now.sent - before.sent) / elapsed }
            }
            return rate
        }
        return snapshot
    }
    private static func ratio(_ used: Double?, _ total: Double?) -> Double? {
        guard let used, let total, total > 0, used >= 0, used <= total, total.isFinite, used.isFinite else { return nil }
        return used / total
    }
}

public enum LinuxCollector {
    public static let script = """
    export LC_ALL=C
    printf '__INFRA_V1__\\n__INFRA_BOOT__\\n'
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || awk '/^btime / {print $2}' /proc/stat
    printf '__INFRA_UPTIME__\\n'
    cat /proc/uptime
    printf '__INFRA_CPU__\\n'
    head -n 1 /proc/stat
    printf '__INFRA_MEM__\\n'
    cat /proc/meminfo
    printf '__INFRA_DISK__\\n'
    df -Pk /
    printf '__INFRA_NET__\\n'
    cat /proc/net/dev
    printf '__INFRA_GPU__\\n'
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null || printf 'ERROR\\n'
    else
      printf 'UNAVAILABLE\\n'
    fi
    printf '__INFRA_END__\\n'
    """
}
