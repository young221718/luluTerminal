import Foundation
import Testing
@testable import InfraCore

struct ModelsAndCommandsTests {
    private let account = SSHAccount(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, username: "trainer")
    private var server: ServerProfile {
        ServerProfile(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "GPU", host: "gpu-alias", accounts: [account], monitorAccountID: account.id)
    }
    private var tab: TerminalTab {
        TerminalTab(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, serverID: server.id, accountID: account.id, title: "train")
    }

    @Test func testRejectsHostAndAccountOptionAndShellInjection() throws {
        for value in ["-oProxyCommand=evil", "host name", "host\nnext", "host;id", "host/evil", "user@host", ""] {
            var profile = server
            profile.host = value
            expectThrowsError(try profile.validate(), value)
        }
        for value in ["-root", "user name", "root;id", "root\n", "root@host", ""] {
            var profile = server
            profile.accounts = [SSHAccount(id: account.id, username: value)]
            expectThrowsError(try profile.validate(), value)
        }
        for port in [0, -1, 65536] {
            var profile = server; profile.port = port
            expectThrowsError(try profile.validate())
        }
        var profile = server; profile.host = "2001:db8::1"
        expectNoThrow(try profile.validate())
        profile.monitorAccountID = UUID()
        expectThrowsError(try profile.validate())
    }

    @Test func testAccountMembershipAndTabIdentityCheckedAtCommandBoundary() throws {
        expectThrowsError(try SSHCommandBuilder.terminal(server: server, account: SSHAccount(username: "root"), tab: tab, create: false))
        var wrong = tab; wrong.accountID = UUID()
        expectThrowsError(try SSHCommandBuilder.terminal(server: server, account: account, tab: wrong, create: false))
        wrong = tab; wrong.serverID = UUID()
        expectThrowsError(try SSHCommandBuilder.terminal(server: server, account: account, tab: wrong, create: false))
    }

    @Test func testSessionIdentitySurvivesTitleChangeAndSeparatesAccounts() throws {
        expectEqual(tab.sessionName, "infra_11111111111111111111111111111111_22222222222222222222222222222222_33333333333333333333333333333333")
        var renamed = tab; renamed.title = "a'; $(bad)"
        expectEqual(renamed.sessionName, tab.sessionName)
        renamed.accountID = UUID()
        expectNotEqual(renamed.sessionName, tab.sessionName)
        let attach = try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: false)
        expectEqual(attach.executable, "/usr/bin/ssh")
        expectTrue(attach.arguments.contains("StrictHostKeyChecking=ask"))
        expectTrue(attach.arguments.contains("trainer"))
        expectTrue(attach.arguments.contains("22"))
        expectTrue(attach.arguments.last!.contains("attach-session"))
        expectFalse(attach.arguments.last!.contains("new-session"))
        expectFalse(attach.arguments.last!.contains("-d"))
        let create = try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: true)
        expectTrue(create.arguments.last!.contains("new-session"))
        expectFalse(create.arguments.last!.contains(" -A"))
        let monitor = try SSHCommandBuilder.monitor(server: server, account: account)
        expectTrue(monitor.arguments.contains("BatchMode=yes"))
        expectEqual(monitor.standardInput, LinuxCollector.script)
    }

    @Test func testShellStringPreservesLiteralArguments() async throws {
        let command = ShellCommand(executable: "/usr/bin/printf", arguments: ["%s", "a b';$(echo BAD)\nnext"])
        let result = try await ProcessRunner().run(ShellCommand(executable: "/bin/sh", arguments: ["-c", command.shellString]))
        expectEqual(result.stdout, "a b';$(echo BAD)\nnext")
    }

    @Test func testCloseReopenRetainsIdentityAndServerSelection() throws {
        var state = WorkspaceState(); state.servers = [server]
        let first = tab
        let second = TerminalTab(serverID: server.id, accountID: account.id, title: "second")
        try state.add(tab: first); try state.add(tab: second)
        state.select(tabID: first.id)
        state.close(tabID: first.id)
        expectEqual(state.tabs.count, 2)
        expectTrue(state.tabs[0].isClosed)
        expectEqual(state.selectedTabByServer[server.id], second.id)
        state.reopen(tabID: first.id)
        expectFalse(state.tabs[0].isClosed)
        expectEqual(state.tabs[0].sessionName, first.sessionName)
        expectEqual(state.selectedTabByServer[server.id], first.id)
        var bad = tab; bad.accountID = UUID()
        expectThrowsError(try state.add(tab: bad))
        expectThrowsError(try state.add(tab: first))
    }

    @Test func testStoreRoundTripAndPreservesCorruptionAndUnsupportedSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let store = StateStore(url: url)
        expectNil(try store.load())
        var state = WorkspaceState(); state.servers = [server]; try state.add(tab: tab)
        state.close(tabID: tab.id)
        try store.save(state)
        expectEqual(try store.load(), state)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        expectThrowsError(try store.load())
        expectThrowsError(try store.save(state))
        expectEqual(try Data(contentsOf: url), corrupt)
        try FileManager.default.removeItem(at: url)
        state.schemaVersion = 99
        expectThrowsError(try store.save(state))
    }

    @Test func testStoreRejectsAccountDeletionOrRenameUsedByExistingTabs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(url: directory.appendingPathComponent("state.json"))
        var state = WorkspaceState(); state.servers = [server]; try state.add(tab: tab)
        try store.save(state)
        state.servers[0].accounts[0].username = "root"
        expectThrowsError(try store.save(state))
        state.servers[0].accounts = []
        expectThrowsError(try store.save(state))
    }
    @Test func testRemoteLifecycleCommandsExecuteOnlyRequestedOperation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("session")
        let stub = directory.appendingPathComponent("tmux")
        let script = """
        #!/bin/sh
        case "$1" in
          has-session) [ "$3" = '=\(tab.sessionName)' ] && [ -e '\(marker.path)' ] ;;
          new-session) [ "$3" = '\(tab.sessionName)' ] && [ ! -e '\(marker.path)' ] && : > '\(marker.path)' ;;
          attach-session) [ "$3" = '=\(tab.sessionName)' ] && [ -e '\(marker.path)' ] ;;
          *) exit 88 ;;
        esac
        """
        try Data(script.utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        func local(_ command: ShellCommand, path: String? = nil) -> ShellCommand {
            ShellCommand(executable: "/usr/bin/env", arguments: ["PATH=" + (path ?? directory.path), "/bin/sh", "-c", command.arguments.last!])
        }
        let probe = try SSHCommandBuilder.probe(server: server, account: account, tab: tab)
        let attach = try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: false)
        let create = try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: true)
        expectEqual(try await ProcessRunner().run(local(probe)).exitCode, 44)
        let missing = try await ProcessRunner().run(local(attach))
        expectEqual(missing.exitCode, 44)
        expectTrue(missing.stderr.contains("Remote tmux session is missing"))
        expectTrue(missing.stderr.contains("Create session"))
        expectFalse(FileManager.default.fileExists(atPath: marker.path))
        expectEqual(try await ProcessRunner().run(local(probe, path: directory.appendingPathComponent("absent").path)).exitCode, 127)
        expectEqual(try await ProcessRunner().run(local(create)).exitCode, 0)
        expectEqual(try await ProcessRunner().run(local(probe)).exitCode, 0)
        expectEqual(try await ProcessRunner().run(local(attach)).exitCode, 0)
        expectNotEqual(try await ProcessRunner().run(local(create)).exitCode, 0)
        expectTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func testSSHOptionsAllowInteractiveTrustAndAuthOnlyForTerminal() async throws {
        let terminal = try SSHCommandBuilder.terminal(server: server, account: account, tab: tab, create: false)
        let probe = try SSHCommandBuilder.probe(server: server, account: account, tab: tab)
        let monitor = try SSHCommandBuilder.monitor(server: server, account: account)
        for (command, trust, batch) in [(terminal, "ask", "no"), (probe, "true", "yes"), (monitor, "true", "yes")] {
            // -G evaluates emitted options without connecting; -F avoids reading user SSH configuration.
            let evaluation = ShellCommand(executable: command.executable, arguments: ["-F", "/dev/null", "-G"] + command.arguments.dropLast())
            let result = try await ProcessRunner().run(evaluation)
            expectEqual(result.exitCode, 0)
            let options = result.stdout.split(separator: "\n").reduce(into: [String: String]()) { values, line in
                let fields = line.split(separator: " ", maxSplits: 1)
                if fields.count == 2 { values[String(fields[0])] = String(fields[1]) }
            }
            expectEqual(options["stricthostkeychecking"], trust)
            expectEqual(options["batchmode"], batch)
            expectEqual(options["user"], "trainer")
            expectEqual(options["port"], "22")
        }
    }

}
