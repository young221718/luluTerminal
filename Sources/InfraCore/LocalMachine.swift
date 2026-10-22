import Foundation
import Darwin

public enum LocalMachine {
    public static let serverID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    public static let accountID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    public static let initialTabID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    public static var username: String { NSUserName() }
    public static var loginShell: String {
        guard let shell = getpwuid(getuid())?.pointee.pw_shell, shell.pointee != 0 else { return "/bin/zsh" }
        return String(cString: shell)
    }
    public static var homeDirectory: String {
        guard let home = getpwuid(getuid())?.pointee.pw_dir, home.pointee != 0 else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return String(cString: home)
    }
    public static var profile: ServerProfile {
        ServerProfile(id: serverID, name: "이 Mac", host: "localhost", accounts: [SSHAccount(id: accountID, username: username)],
                      monitorAccountID: accountID, kind: .local)
    }
    public static func terminal(shell: String = loginShell, home: String = homeDirectory) throws -> ShellCommand {
        guard shell.hasPrefix("/"), !shell.contains("\0"), FileManager.default.isExecutableFile(atPath: shell),
              home.hasPrefix("/"), !home.contains("\0") else {
            throw CoreError.invalidProfile("The current login shell and home must be valid absolute paths.")
        }
        // Home and executable remain positional arguments, including spaces or shell punctuation.
        return ShellCommand(executable: "/bin/sh", arguments: ["-c", "cd -- \"$1\" && HOME=\"$1\" exec \"$2\" -l", "infra-terminal-local", home, shell])
    }
}

extension WorkspaceState {
    public mutating func ensureLocalMachine() {
        let wasEmpty = servers.isEmpty && tabs.isEmpty && selectedServerID == nil
        if let index = servers.firstIndex(where: { $0.id == LocalMachine.serverID }) {
            servers.remove(at: index)
        }
        servers.insert(LocalMachine.profile, at: 0)
        if !tabs.contains(where: { $0.serverID == LocalMachine.serverID }) {
            let id = tabs.contains(where: { $0.id == LocalMachine.initialTabID }) ? UUID() : LocalMachine.initialTabID
            let tab = TerminalTab(id: id, serverID: LocalMachine.serverID, accountID: LocalMachine.accountID, title: "셸")
            tabs.append(tab)
            selectedTabByServer[LocalMachine.serverID] = tab.id
        }
        if wasEmpty { select(serverID: LocalMachine.serverID) }
    }
}

public struct LocalCPUReading: Equatable, Sendable {
    public var total: UInt64
    public var idle: UInt64
    public init(total: UInt64, idle: UInt64) { self.total = total; self.idle = idle }
}

public struct LocalMetricsCollector: Sendable {
    private var previousCPU: LocalCPUReading?
    public init() {}
    public static func cpuUsage(current: LocalCPUReading, previous: LocalCPUReading?) -> Double? {
        guard let previous, current.idle <= current.total, previous.idle <= previous.total,
              current.total > previous.total, current.idle >= previous.idle else { return nil }
        let total = current.total - previous.total, idle = current.idle - previous.idle
        guard idle <= total else { return nil }
        return Double(total - idle) / Double(total)
    }
    public mutating func collect(timestamp: Date = Date()) -> MetricsSnapshot {
        var snapshot = MetricsSnapshot(timestamp: timestamp, warnings: [
            "로컬 RAM은 active + inactive + wired + compressed 페이지 기준이며 회수 가능한 캐시를 포함합니다. Activity Monitor의 사용 메모리와 계산 기준이 다릅니다.",
            "macOS GPU·VRAM 및 네트워크 수집은 지원하지 않습니다."
        ])
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let values = cpu.cpu_ticks
            let reading = LocalCPUReading(total: UInt64(values.0) + UInt64(values.1) + UInt64(values.2) + UInt64(values.3), idle: UInt64(values.2))
            snapshot.cpu = Self.cpuUsage(current: reading, previous: previousCPU)
            previousCPU = reading
        } else { snapshot.warnings.append("로컬 CPU 수집 실패 (\(cpuResult)).") }

        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let memoryResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if memoryResult == KERN_SUCCESS {
            let usedPages = UInt64(vm.active_count) + UInt64(vm.inactive_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            let used = Double(usedPages) * Double(getpagesize())
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            if total > 0, used <= total {
                snapshot.memoryUsedBytes = used; snapshot.memoryTotalBytes = total; snapshot.ram = used / total
            } else { snapshot.warnings.append("로컬 RAM 페이지 합계를 확인할 수 없습니다.") }
        } else { snapshot.warnings.append("로컬 RAM 수집 실패 (\(memoryResult)).") }

        do {
            let volume = try URL(fileURLWithPath: LocalMachine.homeDirectory).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            if let total = volume.volumeTotalCapacity, let free = volume.volumeAvailableCapacity, total > 0, free >= 0, free <= total {
                snapshot.diskTotalBytes = Double(total); snapshot.diskUsedBytes = Double(total - free)
                snapshot.disk = Double(total - free) / Double(total)
            } else { snapshot.warnings.append("로컬 홈 볼륨의 용량을 확인할 수 없습니다.") }
        } catch { snapshot.warnings.append("로컬 디스크 수집 실패: \(error.localizedDescription)") }
        snapshot.disks = Self.mountedDisks()
        if snapshot.disks.isEmpty { snapshot.warnings.append("로컬 마운트 볼륨의 용량을 확인할 수 없습니다.") }
        return snapshot
    }
    private static func mountedDisks() -> [DiskReading] {
        // Cached mount statistics avoid waiting on removable or network filesystem I/O.
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var mounts: [statfs] = .init(repeating: .init(), count: Int(count))
        let read = mounts.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard read > 0 else { return [] }
        return mounts.prefix(min(Int(read), mounts.count)).compactMap { mount in
            guard mount.f_flags & UInt32(MNT_LOCAL) != 0, mount.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { return nil }
            var name = mount.f_mntonname
            let nameSize = MemoryLayout.size(ofValue: name)
            let path = withUnsafePointer(to: &name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: nameSize) { String(cString: $0) }
            }
            guard path.hasPrefix("/") else { return nil }
            let total = Double(mount.f_blocks) * Double(mount.f_bsize)
            let free = Double(mount.f_bfree) * Double(mount.f_bsize)
            let available = Double(mount.f_bavail) * Double(mount.f_bsize)
            guard total.isFinite, total > 0, free >= 0, free <= total, available >= 0, available <= total else {
                return DiskReading(id: path, mountPoint: path)
            }
            return DiskReading(id: path, mountPoint: path, totalBytes: total, usedBytes: total - free, availableBytes: available)
        }.sorted { $0.mountPoint < $1.mountPoint }
    }
}
