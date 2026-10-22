import Foundation

public struct DiskReading: Equatable, Sendable {
    public var id: String
    public var mountPoint: String
    public var totalBytes: Double?
    public var usedBytes: Double?
    public var availableBytes: Double?
    public init(id: String, mountPoint: String, totalBytes: Double? = nil, usedBytes: Double? = nil, availableBytes: Double? = nil) {
        self.id = id; self.mountPoint = mountPoint; self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.availableBytes = availableBytes
    }
    public var utilization: Double? {
        guard let totalBytes, let availableBytes, totalBytes.isFinite, availableBytes.isFinite,
              totalBytes > 0, availableBytes >= 0, availableBytes <= totalBytes else { return nil }
        // Reserved filesystem blocks are unavailable to the user and count toward capacity pressure.
        return (totalBytes - availableBytes) / totalBytes
    }
}

public struct GPUReading: Equatable, Sendable {
    public var id: String?
    public var index: Int?
    public var name: String
    public var utilization: Double?
    public var memoryUsedBytes: Double?
    public var memoryTotalBytes: Double?
    public init(name: String, utilization: Double? = nil, memoryUsedBytes: Double? = nil, memoryTotalBytes: Double? = nil, id: String? = nil, index: Int? = nil) {
        self.id = id; self.index = index
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
    public var disks: [DiskReading]
    public init(timestamp: Date, cpu: Double? = nil, ram: Double? = nil, disk: Double? = nil, gpu: Double? = nil, vram: Double? = nil,
                memoryUsedBytes: Double? = nil, memoryTotalBytes: Double? = nil, diskUsedBytes: Double? = nil, diskTotalBytes: Double? = nil,
                gpus: [GPUReading] = [], network: [NetworkRate] = [], warnings: [String] = [], disks: [DiskReading] = []) {
        self.timestamp = timestamp; self.cpu = cpu; self.ram = ram; self.disk = disk; self.gpu = gpu; self.vram = vram
        self.memoryUsedBytes = memoryUsedBytes; self.memoryTotalBytes = memoryTotalBytes; self.diskUsedBytes = diskUsedBytes; self.diskTotalBytes = diskTotalBytes
        self.gpus = gpus; self.network = network; self.warnings = warnings; self.disks = disks
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
    public var disks: [DiskReading] = []
}
public enum MetricsParseError: Error, LocalizedError {
    case invalidEnvelope
    public var errorDescription: String? { "Incomplete or invalid Linux metrics response." }
}
public enum MetricsParser {
    public static func parse(_ output: String, timestamp: Date) throws -> RawMetrics {
        let originalLines = output.components(separatedBy: .newlines)
        let lines = originalLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "__INFRA_V1__", lines.last(where: { !$0.isEmpty }) == "__INFRA_END__" else { throw MetricsParseError.invalidEnvelope }
        var sections: [String: [String]] = [:]
        var section: String?
        for (line, original) in zip(lines.dropFirst(), originalLines.dropFirst()) {
            if line.hasPrefix("__INFRA_"), line.hasSuffix("__") {
                guard sections[line] == nil else { throw MetricsParseError.invalidEnvelope }
                section = line; sections[line] = []
            } else if !line.isEmpty, let section { sections[section, default: []].append(section == "__INFRA_DISK__" ? original : line) }
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
            if line == "DISK_ERROR" { raw.warnings.append("Filesystem collection failed or timed out; disk readings may be incomplete."); continue }
            if line == "ALL_MOUNTS_UNAVAILABLE" { raw.warnings.append("All mounted filesystem collection unavailable: timeout command missing; root-only reading."); continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let typed = fields.count >= 7 && fields[5].hasSuffix("%")
            let offset = typed ? 1 : 0
            guard fields.count >= 6 + offset, fields[4 + offset].hasSuffix("%") else { continue }
            if typed, excludedFilesystems.contains(fields[1]) { continue }
            let mount = String(line.split(maxSplits: 5 + offset, whereSeparator: \.isWhitespace).last ?? "")
            guard mount.hasPrefix("/"), !raw.disks.contains(where: { $0.id == mount }) else { continue }
            let total = positive(fields[1 + offset]).flatMap(kibibytes)
            let used = positive(fields[2 + offset], allowZero: true).flatMap(kibibytes).flatMap { value in
                total.flatMap { value <= $0 ? value : nil }
            }
            let available = positive(fields[3 + offset], allowZero: true).flatMap(kibibytes).flatMap { value in
                total.flatMap { value <= $0 ? value : nil }
            }
            raw.disks.append(DiskReading(id: mount, mountPoint: mount, totalBytes: total, usedBytes: used, availableBytes: available))
            if mount == "/" { raw.diskTotalBytes = total; raw.diskUsedBytes = used }
            if total == nil || used == nil || available == nil { raw.warnings.append("Filesystem \(mount) contains unavailable values.") }
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
            guard fields.count == 4 || fields.count == 6 else { raw.warnings.append("Malformed NVIDIA GPU response."); continue }
            let offset = fields.count == 6 ? 2 : 0
            let name = fields[offset]
            guard !name.isEmpty else { raw.warnings.append("Malformed NVIDIA GPU response."); continue }
            let id = offset == 2 && !fields[0].isEmpty && fields[0] != "N/A" ? fields[0] : nil
            let index = offset == 2 ? Int(fields[1]).flatMap { $0 >= 0 ? $0 : nil } : nil
            let utilization = positive(fields[1 + offset], allowZero: true).flatMap { $0 <= 100 ? $0 / 100 : nil }
            let total = positive(fields[3 + offset]).flatMap { kibibytes($0 * 1024) }
            let used = positive(fields[2 + offset], allowZero: true).flatMap { kibibytes($0 * 1024) }.flatMap { value in total.flatMap { value <= $0 ? value : nil } }
            raw.gpus.append(GPUReading(name: name, utilization: utilization, memoryUsedBytes: used, memoryTotalBytes: total, id: id, index: index))
            if utilization == nil || used == nil || total == nil { raw.warnings.append("GPU \(name) contains unavailable values.") }
        }
        if raw.gpus.isEmpty, raw.warnings.allSatisfy({ !$0.contains("GPU") }) { raw.warnings.append("NVIDIA GPU response missing.") }
        if raw.bootID == nil || raw.uptime == nil { raw.warnings.append("Boot identity/monotonic time unavailable; counter rates are unknown.") }
        return raw
    }
    private static let excludedFilesystems: Set<String> = [
        "tmpfs", "devtmpfs", "overlay", "squashfs", "proc", "sysfs", "cgroup", "cgroup2", "devpts",
        "securityfs", "debugfs", "tracefs", "pstore", "configfs", "fusectl", "mqueue", "hugetlbfs", "autofs"
    ]
    private static func kibibytes(_ value: Double) -> Double? {
        let bytes = value * 1024
        return bytes.isFinite ? bytes : nil
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
                                       diskUsedBytes: current.diskUsedBytes, diskTotalBytes: current.diskTotalBytes, gpus: current.gpus, warnings: current.warnings, disks: current.disks)
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
    if command -v timeout >/dev/null 2>&1; then
      timeout -s KILL 2 df -PTk -x tmpfs -x devtmpfs -x overlay -x squashfs -x proc -x sysfs -x cgroup -x cgroup2 -x devpts -x securityfs -x debugfs -x tracefs -x pstore -x configfs -x fusectl -x mqueue -x hugetlbfs -x autofs 2>/dev/null || printf '\\nDISK_ERROR\\n'
    else
      printf 'ALL_MOUNTS_UNAVAILABLE\\n'
      df -Pk / 2>/dev/null || printf '\\nDISK_ERROR\\n'
    fi
    printf '__INFRA_NET__\\n'
    cat /proc/net/dev
    printf '__INFRA_GPU__\\n'
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=uuid,index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null || printf 'ERROR\\n'
    else
      printf 'UNAVAILABLE\\n'
    fi
    printf '__INFRA_END__\\n'
    """
}
