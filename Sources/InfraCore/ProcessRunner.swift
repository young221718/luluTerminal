import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) { self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr }
}
public enum ProcessRunnerError: Error, LocalizedError, Equatable {
    case timedOut
    case outputLimitExceeded
    case invalidLimit
    case launchFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case .timedOut: return "Command timed out."
        case .outputLimitExceeded: return "Command exceeded the output limit."
        case .invalidLimit: return "Timeout and output limit must be positive and finite."
        case .launchFailed(let code): return "Could not launch command (\(code))."
        }
    }
}
public struct ProcessRunner: Sendable {
    public let maxOutputBytes: Int
    public init(maxOutputBytes: Int = 1_048_576) { self.maxOutputBytes = maxOutputBytes }
    public func run(_ command: ShellCommand, timeout: TimeInterval = 8) async throws -> ProcessResult {
        guard timeout.isFinite, timeout > 0, maxOutputBytes > 0 else { throw ProcessRunnerError.invalidLimit }
        let execution = Execution(command: command, timeout: timeout, limit: maxOutputBytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { execution.run(continuation) }
            }
        } onCancel: { execution.stop(CancellationError()) }
    }
}

private final class Execution: @unchecked Sendable {
    private let command: ShellCommand
    private let timeout: TimeInterval
    private let limit: Int
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var failure: Error?
    private var stdout = Data()
    private var stderr = Data()
    init(command: ShellCommand, timeout: TimeInterval, limit: Int) { self.command = command; self.timeout = timeout; self.limit = limit }

    func stop(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure = error }
        if pid > 0 { Darwin.kill(-pid, SIGKILL) }
    }
    func run(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        var descriptors: [Int32] = []
        for index in 0..<3 {
            var pair: [Int32] = [0, 0]
            guard Darwin.pipe(&pair) == 0 else {
                let code = errno; descriptors.forEach { Darwin.close($0) }
                continuation.resume(throwing: ProcessRunnerError.launchFailed(code)); return
            }
            for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            descriptors += pair
            switch index { case 0: input = pair; case 1: output = pair; default: errors = pair }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        for fd in descriptors { posix_spawn_file_actions_addclose(&actions, fd) }
        // A private process group lets timeout/cancellation also stop pipe-holding descendants.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ([command.executable] + command.arguments).map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        var argv = arguments + [nil]
        let environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, override in override }.map { strdup("\($0.key)=\($0.value)") }
        defer { environment.forEach { free($0) } }
        var envp = environment + [nil]
        lock.lock()
        if let failure {
            lock.unlock(); descriptors.forEach { Darwin.close($0) }; continuation.resume(throwing: failure); return
        }
        var child: pid_t = 0
        let code = posix_spawn(&child, command.executable, &actions, &attributes, &argv, &envp)
        if code == 0 { pid = child }
        lock.unlock()
        guard code == 0 else {
            descriptors.forEach { Darwin.close($0) }
            continuation.resume(throwing: ProcessRunnerError.launchFailed(code)); return
        }
        Darwin.close(input[0]); Darwin.close(output[1]); Darwin.close(errors[1])
        let timer = DispatchWorkItem { [weak self] in self?.stop(ProcessRunnerError.timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        let io = DispatchGroup()
        for (fd, isError) in [(output[0], false), (errors[0], true)] {
            io.enter()
            DispatchQueue.global(qos: .utility).async {
                self.drain(fd, isError: isError); Darwin.close(fd); io.leave()
            }
        }
        io.enter()
        let inputFD = input[1]
        DispatchQueue.global(qos: .utility).async {
            // Suppress SIGPIPE for this descriptor when the child exits before consuming stdin.
            _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
            let data = Data((self.command.standardInput ?? "").utf8)
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(inputFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written > 0 { offset += written }
                    else if errno != EINTR { break }
                }
            }
            Darwin.close(inputFD); io.leave()
        }
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(child, &status, 0) } while waited < 0 && errno == EINTR
        lock.lock()
        // Stop descendants before draining; they may otherwise keep inherited pipes open forever.
        Darwin.kill(-child, SIGKILL)
        pid = 0
        lock.unlock()
        io.wait()
        timer.cancel()
        lock.lock()
        let resultError = failure
        let result = ProcessResult(exitCode: (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f),
                                   stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
        lock.unlock()
        if let resultError { continuation.resume(throwing: resultError) }
        else if waited < 0 { continuation.resume(throwing: ProcessRunnerError.launchFailed(errno)) }
        else { continuation.resume(returning: result) }
    }
    private func drain(_ fd: Int32, isError: Bool) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return }
            if count == 0 { return }
            lock.lock()
            let remaining = limit - stdout.count - stderr.count
            let accepted = min(count, remaining)
            if accepted > 0 {
                if isError { stderr.append(contentsOf: buffer.prefix(accepted)) }
                else { stdout.append(contentsOf: buffer.prefix(accepted)) }
            }
            if count > remaining {
                if failure == nil { failure = ProcessRunnerError.outputLimitExceeded }
                if pid > 0 { Darwin.kill(-pid, SIGKILL) }
            }
            lock.unlock()
        }
    }
}
