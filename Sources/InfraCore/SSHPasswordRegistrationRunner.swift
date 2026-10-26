import Foundation
import Darwin
import InfraSSHPTY

public enum SSHPasswordRegistrationError: Error, LocalizedError, Equatable {
    case invalidPassword, invalidCommand, invalidLimit, launchFailed
    case authenticationFailed, hostKeyFailed, unexpectedPrompt, terminalEchoEnabled
    case timedOut, outputLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidPassword: return "비밀번호는 1~1023 UTF-8 바이트이며 줄바꿈과 NUL을 포함할 수 없습니다."
        case .invalidCommand: return "SSH 키 등록 명령이 올바르지 않습니다."
        case .invalidLimit: return "SSH 등록 시간 제한이 올바르지 않습니다."
        case .launchFailed: return "SSH 키 등록을 시작할 수 없습니다."
        case .authenticationFailed: return "SSH 비밀번호 인증 또는 공개 키 등록에 실패했습니다."
        case .hostKeyFailed: return "SSH 호스트 키를 확인할 수 없습니다. 먼저 서버 신원을 확인해 주세요."
        case .unexpectedPrompt: return "지원하지 않는 SSH 인증 요청입니다. 비밀번호 인증만 사용할 수 있습니다."
        case .terminalEchoEnabled: return "안전한 비밀번호 입력 채널을 확인할 수 없습니다."
        case .timedOut: return "SSH 키 등록 시간이 초과되었습니다."
        case .outputLimitExceeded: return "SSH 키 등록 출력이 허용 범위를 초과했습니다."
        }
    }
}

/// Uses a private controlling terminal for OpenSSH authentication, separate from remote data.
public struct SSHPasswordRegistrationRunner: Sendable {
    private let executable: String
    private let outputLimit: Int
    public init() { executable = "/usr/bin/ssh"; outputLimit = 1_048_576 }
    internal init(executableForTesting: String, maxOutputBytes: Int = 1_048_576) {
        executable = executableForTesting; outputLimit = maxOutputBytes
    }

    public func run(_ command: ShellCommand, password: String, timeout: TimeInterval = 30) async throws {
        let bytes = Array(password.utf8)
        guard !bytes.isEmpty, bytes.count <= 1023, !bytes.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
            throw SSHPasswordRegistrationError.invalidPassword
        }
        guard command.executable == "/usr/bin/ssh", !command.arguments.contains(where: { $0.utf8.contains(0) }),
              !executable.utf8.contains(0) else { throw SSHPasswordRegistrationError.invalidCommand }
        guard timeout.isFinite, timeout > 0, outputLimit > 0 else { throw SSHPasswordRegistrationError.invalidLimit }
        let execution = PasswordRegistrationExecution(command: command, executable: executable,
                                                      password: bytes, timeout: timeout, outputLimit: outputLimit)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do { try execution.run(); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { execution.cancel() }
    }
}

private final class PasswordRegistrationExecution: @unchecked Sendable {
    private let command: ShellCommand
    private let executable: String
    private var password: [UInt8]
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let lock = NSLock()
    private var cancelled = false

    init(command: ShellCommand, executable: String, password: [UInt8], timeout: TimeInterval, outputLimit: Int) {
        self.command = command; self.executable = executable; self.password = password
        self.timeout = timeout; self.outputLimit = outputLimit
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
    func run() throws {
        defer { _ = password.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }; password.removeAll() }
        try checkCancellation()
        let arguments = ([executable] + command.arguments).map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        guard arguments.allSatisfy({ $0 != nil }) else { throw SSHPasswordRegistrationError.launchFailed }
        var argv = arguments + [nil]
        // Do not inherit askpass/display/agent hooks or arbitrary command environment.
        var environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "TERM": "dumb", "SSH_ASKPASS_REQUIRE": "never", "SSH_ASKPASS": ""]
        for key in ["HOME", "USER", "LOGNAME"] { environment[key] = ProcessInfo.processInfo.environment[key] }
        let entries = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { entries.forEach { free($0) } }
        guard entries.allSatisfy({ $0 != nil }) else { throw SSHPasswordRegistrationError.launchFailed }
        var envp = entries + [nil]
        var process = infra_ssh_process()
        guard infra_ssh_spawn(executable, &argv, &envp, &process) == 0 else { throw SSHPasswordRegistrationError.launchFailed }
        var descriptors = [process.terminal, process.input, process.output, process.error, process.exec_error]
        var status: Int32 = 0
        var reaped = false
        defer {
            if !reaped { _ = infra_ssh_stop_and_reap(process.pid, &status) }
            for fd in descriptors where fd >= 0 { Darwin.close(fd) }
            Darwin.close(process.terminal_keeper)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let input = Array((command.standardInput ?? "").utf8)
        var inputOffset = 0, passwordOffset = 0, outputCount = 0
        var sentPassword = false
        var terminalText = "", diagnosticText = ""
        var buffer = [UInt8](repeating: 0, count: 8192)
        func closeDescriptor(_ index: Int) { if descriptors[index] >= 0 { Darwin.close(descriptors[index]); descriptors[index] = -1 } }
        func consume(_ index: Int, count: Int) throws {
            if index == 4 { throw SSHPasswordRegistrationError.launchFailed }
            outputCount += count
            if outputCount > outputLimit { throw SSHPasswordRegistrationError.outputLimitExceeded }
            let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            if index == 0 {
                terminalText += text
                if terminalText.utf8.count > 4096 { throw SSHPasswordRegistrationError.unexpectedPrompt }
                if Self.isPasswordPrompt(terminalText) {
                    guard !sentPassword else { throw SSHPasswordRegistrationError.unexpectedPrompt }
                    guard infra_ssh_terminal_has_no_echo(descriptors[0]) == 1 else { throw SSHPasswordRegistrationError.terminalEchoEnabled }
                    sentPassword = true; terminalText = ""
                } else if terminalText.hasSuffix(": ") {
                    throw SSHPasswordRegistrationError.unexpectedPrompt
                }
            } else if index == 3 {
                diagnosticText = String((diagnosticText + text).suffix(4096))
            }
        }
        while true {
            try checkCancellation()
            if ProcessInfo.processInfo.systemUptime >= deadline { throw SSHPasswordRegistrationError.timedOut }
            if inputOffset == input.count { closeDescriptor(1) }
            var polls = descriptors.enumerated().map { index, fd in
                pollfd(fd: fd, events: Int16(index == 1 ? POLLOUT : POLLIN), revents: 0)
            }
            if sentPassword && passwordOffset <= password.count { polls[0].events |= Int16(POLLOUT) }
            let ready = Darwin.poll(&polls, nfds_t(polls.count), 20)
            if ready < 0 && errno != EINTR { throw SSHPasswordRegistrationError.launchFailed }
            for index in polls.indices where polls[index].fd >= 0 {
                let events = polls[index].revents
                if index == 1 {
                    if events & Int16(POLLOUT) != 0 {
                        let written = input.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress!.advanced(by: inputOffset), input.count - inputOffset) }
                        if written > 0 { inputOffset += written }
                        else if errno != EINTR && errno != EAGAIN { closeDescriptor(1) }
                    } else if events & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { closeDescriptor(1) }
                    continue
                }
                if index == 0 && events & Int16(POLLOUT) != 0 && passwordOffset <= password.count {
                    guard infra_ssh_terminal_has_no_echo(descriptors[0]) == 1 else { throw SSHPasswordRegistrationError.terminalEchoEnabled }
                    var payload = password + [10]
                    let written = payload.withUnsafeBytes { Darwin.write(descriptors[0], $0.baseAddress!.advanced(by: passwordOffset), payload.count - passwordOffset) }
                    _ = payload.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                    if written > 0 { passwordOffset += written }
                    else if errno != EINTR && errno != EAGAIN { throw SSHPasswordRegistrationError.authenticationFailed }
                }
                if events & Int16(POLLIN | POLLHUP | POLLERR) == 0 { continue }
                let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                if count < 0 {
                    if errno != EINTR && errno != EAGAIN { closeDescriptor(index) }
                    continue
                }
                if count == 0 { closeDescriptor(index); continue }
                try consume(index, count: count)
            }
            let exited = infra_ssh_has_exited(process.pid)
            if exited < 0 { throw SSHPasswordRegistrationError.launchFailed }
            if exited == 1 {
                guard infra_ssh_stop_and_reap(process.pid, &status) == 0 else { throw SSHPasswordRegistrationError.launchFailed }
                reaped = true
                // Child and pipe-holding descendants have stopped; consume all queued output.
                for index in [0, 2, 3, 4] where descriptors[index] >= 0 {
                    while true {
                        let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                        if count < 0 && errno == EINTR { continue }
                        if count <= 0 { break }
                        try consume(index, count: count)
                    }
                }
                try checkCancellation()
                guard (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 0 else {
                    let diagnostic = (diagnosticText + terminalText).lowercased()
                    if diagnostic.contains("host key verification failed") || diagnostic.contains("remote host identification has changed") || diagnostic.contains("no matching host key") {
                        throw SSHPasswordRegistrationError.hostKeyFailed
                    }
                    throw SSHPasswordRegistrationError.authenticationFailed
                }
                guard sentPassword, passwordOffset == password.count + 1 else { throw SSHPasswordRegistrationError.authenticationFailed }
                return
            }
        }
    }

    private static func isPasswordPrompt(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .newlines)
        guard !line.contains("\r"), !line.contains("\n") else { return false }
        let prompt = line.hasSuffix(" ") ? String(line.dropLast()) : line
        if prompt == "Password:" || prompt == "password:" { return true }
        guard prompt.hasSuffix("'s password:") else { return false }
        let identity = prompt.dropLast("'s password:".count)
        return identity.contains("@") && !identity.contains(where: { $0.isWhitespace || $0.isASCII && $0.asciiValue! < 32 })
    }
}
