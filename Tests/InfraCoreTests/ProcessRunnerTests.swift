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
        let task = Task { try await ProcessRunner().run(ShellCommand(executable: "/bin/sleep", arguments: ["10"]), timeout: 20) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date(); task.cancel()
        do { _ = try await task.value; fail("Expected cancellation") }
        catch { expectTrue(error is CancellationError) }
        expectLessThan(Date().timeIntervalSince(start), 2)
    }
    @Test func testLaunchFailureReturnsRatherThanHanging() async throws {
        do {
            _ = try await ProcessRunner().run(ShellCommand(executable: "/no/such/infra-executable", arguments: []))
            fail("Expected launch error")
        } catch { expectFalse(error is CancellationError) }
    }
    @Test func testTimeoutKillsDescendantsAndReapsDirectChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let start = Date()
        do {
            _ = try await ProcessRunner().run(ShellCommand(executable: "/bin/sh", arguments: ["-c", "echo $$ > '\(pidFile.path)'; trap '' TERM; sleep 20 & wait"]), timeout: 0.15)
            fail("Expected timeout")
        } catch { expectEqual(error as? ProcessRunnerError, .timedOut) }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
        expectLessThan(Date().timeIntervalSince(start), 2)
    }
    @Test func testEarlyInputCloseDoesNotRaiseSIGPIPE() async throws {
        let result = try await ProcessRunner().run(ShellCommand(executable: "/usr/bin/true", arguments: [], standardInput: String(repeating: "x", count: 200_000)))
        expectEqual(result.exitCode, 0)
    }

}
