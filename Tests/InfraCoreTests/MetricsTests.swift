import Foundation
import Testing
@testable import InfraCore

struct MetricsTests {
    func fixture(cpu: String = "cpu 100 0 100 800 0 0 0 0 0 0", uptime: Double = 100,
                 boot: String = "boot-one", gpu: String = "A, 20, 100, 1000\nB, 80, 900, 3000",
                 net: String = "eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0") -> String {
        """
        __INFRA_V1__
        __INFRA_BOOT__
        \(boot)
        __INFRA_UPTIME__
        \(uptime) 1
        __INFRA_CPU__
        \(cpu)
        __INFRA_MEM__
        MemTotal: 1000 kB
        MemAvailable: 250 kB
        __INFRA_DISK__
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/root 2000 500 1500 25% /
        __INFRA_NET__
        \(net)
        __INFRA_GPU__
        \(gpu)
        __INFRA_END__
        """
    }
    @Test func GPUUUIDFormatPreservesDuplicateDeviceNamesAndMissingValues() throws {
        let raw = try MetricsParser.parse(fixture(gpu: "GPU-first, 0, Same GPU, 0, 0, 1000\nGPU-second, 1, Same GPU, N/A, N/A, N/A"), timestamp: Date())
        #expect(raw.gpus.count == 2)
        #expect(raw.gpus.map(\.name) == ["Same GPU", "Same GPU"])
        #expect(raw.gpus.map(\.id) == ["GPU-first", "GPU-second"])
        #expect(raw.gpus.map(\.index) == [0, 1])
        #expect(raw.gpus.first?.utilization == 0)
        #expect(raw.gpus.last?.utilization == nil)
        #expect(raw.gpus.last?.memoryTotalBytes == nil)
    }

    @Test func multipleFilesystemsPreserveRawDFMountPathsAndAvailableCapacity() throws {
        let disks = #"""
        /dev/root ext4 2000 500 1400 27% /
        /dev/data xfs 4000 1000 3000 25% /data sets/with  spaces
        nas:/export nfs4 8000 2000 6000 25% /mnt/shared data
        /dev/backslash ext4 1000 100 900 10% /mnt/literal\040data
        /dev/space ext4 1000 100 900 10% /mnt/literal data
        /dev/root ext4 2000 500 1400 27% /
        tmpfs tmpfs 100 0 100 0% /run
        overlay overlay 2000 500 1400 27% /container
        """#
        let output = fixture().replacingOccurrences(of: "/dev/root 2000 500 1500 25% /", with: disks)
        let snapshot = MetricsCalculator.calculate(current: try MetricsParser.parse(output, timestamp: Date()), previous: nil)
        #expect(snapshot.disks.map(\.mountPoint) == ["/", "/data sets/with  spaces", "/mnt/shared data", #"/mnt/literal\040data"#, "/mnt/literal data"])
        #expect(Set(snapshot.disks.map(\.id)).count == 5)
        let root = try #require(snapshot.disks.first)
        #expect(root.totalBytes == 2_048_000)
        #expect(root.usedBytes == 512_000)
        #expect(root.availableBytes == 1_433_600)
        #expect(root.utilization == 0.3)
        #expect(snapshot.disk == 0.25)
        #expect(snapshot.diskTotalBytes == 2_048_000)
    }

    @Test func malformedDisksStayUnknownAndZeroUseRemainsValid() throws {
        let disks = """
        /dev/zero ext4 2000 0 2000 0% /empty
        /dev/bad ext4 0 0 0 0% /bad
        /dev/partial ext4 2000 500 N/A 25% /partial
        /dev/invalid ext4 2000 3000 4000 90% /invalid
        /dev/overflow ext4 1e308 1e307 1e307 90% /overflow
        """
        let output = fixture().replacingOccurrences(of: "/dev/root 2000 500 1500 25% /", with: disks)
        let snapshot = MetricsCalculator.calculate(current: try MetricsParser.parse(output, timestamp: Date()), previous: nil)
        #expect(snapshot.disks.count == 5)
        #expect(snapshot.disks[0].utilization == 0)
        #expect(snapshot.disks[0].usedBytes == 0)
        #expect(snapshot.disks[1].totalBytes == nil)
        #expect(snapshot.disks[1].usedBytes == nil)
        #expect(snapshot.disks[1].utilization == nil)
        #expect(snapshot.disks[2].usedBytes == 512_000)
        #expect(snapshot.disks[2].availableBytes == nil)
        #expect(snapshot.disks[2].utilization == nil)
        #expect(snapshot.disks[3].usedBytes == nil)
        #expect(snapshot.disks[3].availableBytes == nil)
        #expect(snapshot.disks[4].totalBytes == nil)
        #expect(snapshot.disk == nil)
        #expect(!snapshot.warnings.isEmpty)
        #expect(DiskReading(id: "x", mountPoint: "/x", totalBytes: .infinity, availableBytes: 0).utilization == nil)
    }

    @Test func testCalculatesIndependentResourceRatiosAndPerInterfaceRate() throws {
        let before = try MetricsParser.parse(fixture(), timestamp: Date(timeIntervalSince1970: 100))
        let after = try MetricsParser.parse(fixture(cpu: "cpu 150 0 150 900 0 0 0 0 50 0", uptime: 102,
                  net: "eth0: 3000 0 0 0 0 0 0 0 6000 0 0 0 0 0 0 0"), timestamp: Date(timeIntervalSince1970: 102))
        let snapshot = MetricsCalculator.calculate(current: after, previous: before)
        expectEqual(snapshot.cpu!, 0.5, accuracy: 0.0001) // guest time is already in user time
        expectEqual(snapshot.ram!, 0.75, accuracy: 0.0001)
        expectEqual(snapshot.disk!, 0.25, accuracy: 0.0001)
        expectEqual(snapshot.gpu!, 0.5, accuracy: 0.0001)
        expectEqual(snapshot.vram!, 0.25, accuracy: 0.0001) // 1000 / 4000, not mean of device percentages
        expectEqual(snapshot.memoryUsedBytes, 768000)
        expectEqual(snapshot.diskTotalBytes, 2048000)
        expectEqual(snapshot.gpus.count, 2)
        expectEqual(snapshot.network.first?.receivedBytesPerSecond, 1000)
        expectEqual(snapshot.network.first?.sentBytesPerSecond, 2000)
        expectFalse(snapshot.isStale(now: Date(timeIntervalSince1970: 107), interval: 2))
        expectTrue(snapshot.isStale(now: Date(timeIntervalSince1970: 108), interval: 2))
    }
    @Test func testInitialSampleResetRebootAndLongGapRemainUnknown() throws {
        let before = try MetricsParser.parse(fixture(), timestamp: Date(timeIntervalSince1970: 100))
        let initial = MetricsCalculator.calculate(current: before, previous: nil)
        expectNil(initial.cpu); expectNil(initial.network.first?.receivedBytesPerSecond)
        for output in [fixture(cpu: "cpu 1 0 1 8 0 0 0 0", uptime: 102),
                       fixture(uptime: 102, boot: "boot-two"), fixture(uptime: 99), fixture(uptime: 100)] {
            let current = try MetricsParser.parse(output, timestamp: Date(timeIntervalSince1970: 102))
            expectNil(MetricsCalculator.calculate(current: current, previous: before).cpu)
        }
        let later = try MetricsParser.parse(fixture(uptime: 200), timestamp: Date(timeIntervalSince1970: 200))
        expectNil(MetricsCalculator.calculate(current: later, previous: before).network.first?.receivedBytesPerSecond)
    }
    @Test func testNetworkCounterDecreaseDoesNotBecomeNegativeOrZero() throws {
        let before = try MetricsParser.parse(fixture(), timestamp: Date(timeIntervalSince1970: 100))
        let after = try MetricsParser.parse(fixture(uptime: 102, net: "eth0: 500 0 0 0 0 0 0 0 3000 0 0 0 0 0 0 0"), timestamp: Date(timeIntervalSince1970: 102))
        let snapshot = MetricsCalculator.calculate(current: after, previous: before)
        expectNil(snapshot.network[0].receivedBytesPerSecond)
        expectEqual(snapshot.network[0].sentBytesPerSecond, 500)
    }
    @Test func testUnavailableGPUAndPartialFailureDifferFromZero() throws {
        for gpu in ["UNAVAILABLE", "ERROR", "A, N/A, N/A, N/A", "A, 200, -1, 0", "malformed"] {
            let raw = try MetricsParser.parse(fixture(gpu: gpu), timestamp: Date())
            let snapshot = MetricsCalculator.calculate(current: raw, previous: nil)
            expectNil(snapshot.gpu); expectNil(snapshot.vram)
            expectFalse(snapshot.warnings.isEmpty)
        }
        let zero = try MetricsParser.parse(fixture(gpu: "A, 0, 0, 1000"), timestamp: Date())
        let snapshot = MetricsCalculator.calculate(current: zero, previous: nil)
        expectEqual(snapshot.gpu, 0); expectEqual(snapshot.vram, 0)
    }
    @Test func testMalformedRequiredEnvelopeThrowsAndBadResourceStaysUnknown() throws {
        expectThrowsError(try MetricsParser.parse("permission denied", timestamp: Date()))
        expectThrowsError(try MetricsParser.parse("__INFRA_V1__\n__INFRA_CPU__", timestamp: Date()))
        let text = fixture().replacingOccurrences(of: "MemTotal: 1000 kB", with: "MemTotal: 0 kB")
            .replacingOccurrences(of: "/dev/root 2000 500 1500 25% /", with: "df: denied")
        let snapshot = MetricsCalculator.calculate(current: try MetricsParser.parse(text, timestamp: Date()), previous: nil)
        expectNil(snapshot.ram); expectNil(snapshot.disk)
        expectFalse(snapshot.warnings.isEmpty)
    }
    @Test(arguments: ["normal", "timeout", "fallback"])
    func testCollectorScriptExecutesAgainstLinuxCommandFixtures(mode: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var scripts = [
            "cat": """
            case "$1" in
              /proc/sys/kernel/random/boot_id) printf 'fixture-boot\\n' ;;
              /proc/uptime) printf '100 1\\n' ;;
              /proc/meminfo) printf 'MemTotal: 1000 kB\\nMemAvailable: 250 kB\\n' ;;
              /proc/net/dev) printf 'eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\\n' ;;
              *) exit 90 ;;
            esac
            """,
            "head": "[ \"$*\" = '-n 1 /proc/stat' ] || exit 91; printf 'cpu 100 0 100 800 0 0 0 0\\n'",
            "df": "[ \"$1\" = '-PTk' ] || exit 92; shift; [ \"$*\" = '-x tmpfs -x devtmpfs -x overlay -x squashfs -x proc -x sysfs -x cgroup -x cgroup2 -x devpts -x securityfs -x debugfs -x tracefs -x pstore -x configfs -x fusectl -x mqueue -x hugetlbfs -x autofs' ] || exit 92; printf '/dev/root ext4 2000 500 1500 25%% /\\n/dev/data xfs 4000 1000 3000 25%% /data sets\\n'",
            "nvidia-smi": "[ \"$*\" = '--query-gpu=uuid,index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits' ] || exit 93; printf 'GPU-fixture, 0, GPU, 0, 0, 1000\\n'"
        ]
        if mode == "fallback" {
            scripts["df"] = "[ \"$*\" = '-Pk /' ] || exit 92; printf '/dev/root 2000 500 1500 25%% /\\n'"
        } else if mode == "timeout" {
            scripts["timeout"] = "[ \"$1\" = '-s' ] && [ \"$2\" = 'KILL' ] && [ \"$3\" = '2' ] && [ \"$4\" = 'df' ] || exit 94; printf '/dev/root ext4 2000 500 1500 25%% /\\n'; exit 124"
            scripts["df"] = "exit 95" // This mode must run through the disk-specific watchdog.
        } else {
            scripts["timeout"] = "[ \"$1\" = '-s' ] && [ \"$2\" = 'KILL' ] && [ \"$3\" = '2' ] || exit 94; shift 3; exec \"$@\""
        }
        for (name, body) in scripts {
            let url = directory.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let command = ShellCommand(executable: "/usr/bin/env", arguments: ["PATH=" + directory.path, "/bin/sh"], standardInput: LinuxCollector.script)
        let result = try await ProcessRunner().run(command)
        expectEqual(result.exitCode, 0)
        expectEqual(result.stderr, "")
        let snapshot = MetricsCalculator.calculate(current: try MetricsParser.parse(result.stdout, timestamp: Date()), previous: nil)
        expectEqual(snapshot.ram, 0.75)
        expectEqual(snapshot.disk, 0.25)
        expectEqual(snapshot.gpu, 0)
        expectEqual(snapshot.vram, 0)
        #expect(snapshot.disks.map(\.mountPoint) == (mode == "normal" ? ["/", "/data sets"] : ["/"]))
        #expect(snapshot.gpus.first?.id == "GPU-fixture")
        expectEqual(snapshot.network.first?.name, "eth0")
        if mode == "normal" { expectTrue(snapshot.warnings.isEmpty) }
        else if mode == "timeout" { #expect(snapshot.warnings.contains { $0.contains("timed out") }) }
        else { #expect(snapshot.warnings.contains { $0.contains("All mounted filesystem") }) }
    }

}
