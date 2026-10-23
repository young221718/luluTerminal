import Testing
import Foundation
@testable import InfraTerminalUI
import InfraCore

extension AppModelTests {
    func server() -> ServerProfile {
        let account = SSHAccount(username: "trainer")
        return ServerProfile(name: "GPU", host: "example.invalid", accounts: [account], monitorAccountID: account.id)
    }

    func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("InfraTerminalUITests-\(UUID())/state.json")
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(predicate(), "Collector tasks did not finish within the bounded wait")
    }
}

actor SuspendedCollector {
    private let exitCode: Int32
    private let stdout: String
    init(exitCode: Int32 = 255, stdout: String = "") { self.exitCode = exitCode; self.stdout = stdout }
    private(set) var commands: [ShellCommand] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    func run(_ command: ShellCommand) async -> ProcessResult {
        commands.append(command)
        await withCheckedContinuation { pending.append($0) }
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: "fixture failure")
    }
    func releaseAll() {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

final class TestPasswordStore: PasswordCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: String] = [:]
    private var savedIDs: [UUID] = []
    private var deletedIDs: [UUID] = []
    private var reads: [UUID] = []
    var readIDs: [UUID] { lock.withLock { reads } }
    var failSave = false
    var saved: [UUID] { lock.withLock { savedIDs } }
    var deleted: [UUID] { lock.withLock { deletedIDs } }
    func save(_ password: String, reference: SSHPasswordReference) throws {
        try lock.withLock {
            if failSave { throw CocoaError(.fileWriteNoPermission) }
            entries[reference.id] = password
            savedIDs.append(reference.id)
        }
    }
    func read(reference: SSHPasswordReference) throws -> String {
        try lock.withLock {
            reads.append(reference.id)
            guard let value = entries[reference.id] else { throw CocoaError(.fileNoSuchFile) }
            return value
        }
    }
    func delete(reference: SSHPasswordReference) throws {
        lock.withLock { entries[reference.id] = nil; deletedIDs.append(reference.id) }
    }
}
