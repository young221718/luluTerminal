import Foundation
import Testing
import Darwin
@testable import InfraCore

struct ProcessRunnerTests {
    @Test func testDrainsBothStreamsAndDeliversInputAndExitCode() async throws {
        let result = try await ProcessRunner().run(ShellCommand(executable: "/bin/sh", arguments: ["-c", "cat; i=0; while [ $i -lt 6000 ]; do printf 'out1234567890'; printf 'err1234567890' >&2; i=$((i+1)); done; exit 7"], standardInput: "input\n"))
        expectEqual(result.exitCode, 7)
        expectTrue(result.stdout.hasPrefix("input\n"))
        expectEqual(result.stderr.utf8.count, 78000)
        expectEqual(result.stdout.utf8.count, 78006)
    }
    @Test func testOutputLimitTerminatesUnboundedWriter() async throws {
        do {
            _ = try await ProcessRunner(maxOutputBytes: 4096).run(ShellCommand(executable: "/usr/bin/yes", arguments: []), timeout: 3)
            fail("Expected bounded output failure")
        } catch { expectEqual(error as? ProcessRunnerError, .outputLimitExceeded) }
    }
    @Test func testTimeoutReapsProcess() async throws {
        let start = Date()
        do {
            _ = try await ProcessRunner().run(ShellCommand(executable: "/bin/sleep", arguments: ["10"]), timeout: 0.15)
            fail("Expected timeout")
        } catch { expectEqual(error as? ProcessRunnerError, .timedOut) }
        expectLessThan(Date().timeIntervalSince(start), 2)
    }
    @Test func testCancellationReapsProcess() async throws {
        let fixture = try ProcessTreeFixture()
        let task = Task { try await ProcessRunner().run(fixture.command, timeout: 20) }
        defer { task.cancel(); fixture.cleanup() }
        let pids = try await fixture.waitUntilReady()
        let start = Date(); task.cancel()
        do { _ = try await task.value; fail("Expected cancellation") }
        catch { expectTrue(error is CancellationError) }
        expectLessThan(Date().timeIntervalSince(start), 2)
        try await expectProcessTreeStopped(parent: pids.parent, child: pids.child)
    }
    @Test func testLaunchFailureReturnsRatherThanHanging() async throws {
        do {
            _ = try await ProcessRunner().run(ShellCommand(executable: "/no/such/infra-executable", arguments: []))
            fail("Expected launch error")
        } catch { expectFalse(error is CancellationError) }
    }
    @Test func testTimeoutKillsDescendantsAndReapsDirectChild() async throws {
        let fixture = try ProcessTreeFixture()
        let start = Date()
        let task = Task { try await ProcessRunner().run(fixture.command, timeout: 3) }
        defer { task.cancel(); fixture.cleanup() }
        let pids = try await fixture.waitUntilReady()
        do {
            _ = try await task.value
            fail("Expected timeout")
        } catch { expectEqual(error as? ProcessRunnerError, .timedOut) }
        expectLessThan(Date().timeIntervalSince(start), 5)
        try await expectProcessTreeStopped(parent: pids.parent, child: pids.child)
    }
    @Test func testEarlyInputCloseDoesNotRaiseSIGPIPE() async throws {
        let result = try await ProcessRunner().run(ShellCommand(executable: "/usr/bin/true", arguments: [], standardInput: String(repeating: "x", count: 200_000)))
        expectEqual(result.exitCode, 0)
    }

    private struct ProcessTreeFixture {
        let directory: URL
        private var pidFile: URL { directory.appendingPathComponent("pids") }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var command: ShellCommand {
            ShellCommand(executable: "/bin/sh", arguments: ["-c", "set -eu; trap '' TERM; /bin/sleep 30 & child=$!; printf '%s %s\\n' \"$$\" \"$child\" > " + ShellCommand.quote(pidFile.path) + "; wait \"$child\""])
        }
        private func readPIDs() -> (parent: pid_t, child: pid_t)? {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
            let fields = text.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let parent = pid_t(fields[0]), let child = pid_t(fields[1]),
                  parent > 1, child > 1, parent != child else { return nil }
            return (parent, child)
        }
        func waitUntilReady() async throws -> (parent: pid_t, child: pid_t) {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(2)
            while clock.now < deadline {
                if let pids = readPIDs(), kill(pids.parent, 0) == 0, kill(pids.child, 0) == 0,
                   getpgid(pids.parent) == pids.parent, getpgid(pids.child) == pids.parent {
                    return pids
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "ProcessRunnerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disposable parent and child did not become ready in their private process group."])
        }
        func cleanup() {
            if let pids = readPIDs(), getpgid(pids.parent) == pids.parent || getpgid(pids.child) == pids.parent {
                kill(-pids.parent, SIGKILL)
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func expectProcessTreeStopped(parent: pid_t, child: pid_t) async throws {
        func isAbsent(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
        func childHasExited() -> Bool {
            if isAbsent(child) { return true }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // An orphan zombie has exited; macOS launchd, rather than ProcessRunner, owns its eventual reaping.
            if proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, size) == size {
                return info.pbi_status == UInt32(SZOMB)
            }
            return isAbsent(child)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if isAbsent(parent) && childHasExited() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(isAbsent(parent), "ProcessRunner must reap its direct child.")
        #expect(childHasExited(), "The actual descendant must terminate, even when macOS still retains its zombie.")
        var status: Int32 = 0
        let waited = waitpid(parent, &status, WNOHANG)
        let waitError = errno
        #expect(waited == -1 && waitError == ECHILD)
    }
}
