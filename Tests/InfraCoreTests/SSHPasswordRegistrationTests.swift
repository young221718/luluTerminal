import Foundation
import Testing
import Darwin
@testable import InfraCore

@Suite(.serialized)
struct SSHPasswordRegistrationTests {
    @Test func passwordValidationPrecedesLaunch() async throws {
        for password in ["", "bad\nvalue", "bad\rvalue", "bad\0value", String(repeating: "é", count: 512)] {
            do {
                try await SSHPasswordRegistrationRunner().run(ShellCommand(executable: "/usr/bin/ssh", arguments: []), password: password)
                Issue.record("Invalid password was accepted")
            } catch { #expect(error as? SSHPasswordRegistrationError == .invalidPassword) }
        }
    }

    // A fake SSH process opens /dev/tty exactly as OpenSSH does; stdin remains key data.
    @Test func splitPromptUsesTTYWhilePublicKeyUsesStdin() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.runner.run(fixture.command("success"), password: "synthetic-only")
    }

    @Test func wholeIPv6PasswordPromptIsAccepted() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.runner.run(fixture.command("ipv6"), password: "synthetic-only")
    }

    @Test func splitIPv6ColonFragmentWaitsForRemainingPasswordPrompt() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.runner.run(fixture.command("ipv6-split"), password: "synthetic-only")
    }

    @Test func preservesAllowedControlUnicodeAndMaximumPasswordBytes() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.runner.run(fixture.command("controls"), password: "\u{03}\u{04}\u{7f}é\u{15}")
        try await fixture.runner.run(fixture.command("maximum"), password: String(repeating: "x", count: 1023))
    }

    @Test func ignoresPasswordBannersOnRemoteOutput() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.runner.run(fixture.command("spoof"), password: "synthetic-only")
        await expectFailure(.authenticationFailed, fixture: fixture, mode: "spoof-only")
    }

    @Test func refusesEchoRepeatedAndUnsupportedPrompts() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        await expectFailure(.terminalEchoEnabled, fixture: fixture, mode: "echo")
        await expectFailure(.unexpectedPrompt, fixture: fixture, mode: "repeat")
        await expectFailure(.unexpectedPrompt, fixture: fixture, mode: "repeat-exit")
        await expectFailure(.unexpectedPrompt, fixture: fixture, mode: "otp")
    }

    @Test func staticErrorsNeverReturnRemotePasswordOrBanner() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        await expectFailure(.authenticationFailed, fixture: fixture, mode: "wrong")
        await expectFailure(.hostKeyFailed, fixture: fixture, mode: "hostkey")
        do {
            try await SSHPasswordRegistrationRunner(executableForTesting: "/no/such/ssh-fixture")
                .run(fixture.command("success"), password: "synthetic-only")
            Issue.record("Missing executable accepted")
        } catch { #expect(error as? SSHPasswordRegistrationError == .launchFailed) }
    }

    @Test func enforcesOutputLimitAndDeadline() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        do {
            try await SSHPasswordRegistrationRunner(executableForTesting: fixture.executable.path, maxOutputBytes: 2048)
                .run(fixture.command("flood"), password: "synthetic-only")
            Issue.record("Output limit ignored")
        } catch { #expect(error as? SSHPasswordRegistrationError == .outputLimitExceeded) }
        await expectFailure(.timedOut, fixture: fixture, mode: "hang", timeout: 0.15)
    }

    @Test func cancellationAndTimeoutReapOwnedProcessTree() async throws {
        for cancelled in [false, true] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let task = Task { try await fixture.runner.run(fixture.command("tree"), password: "synthetic-only", timeout: cancelled ? 10 : 0.4) }
            let pids = try await fixture.waitForPIDs()
            if cancelled { task.cancel() }
            do { try await task.value; Issue.record("Process tree was not stopped") }
            catch {
                if cancelled { #expect(error is CancellationError) }
                else { #expect(error as? SSHPasswordRegistrationError == .timedOut) }
            }
            #expect(kill(pids.0, 0) == -1 && errno == ESRCH)
            var status: Int32 = 0
            #expect(waitpid(pids.0, &status, WNOHANG) == -1 && errno == ECHILD)
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let childState = proc_pidinfo(pids.1, PROC_PIDTBSDINFO, 0, &info, size)
            #expect(childState != size || info.pbi_status == UInt32(SZOMB))
        }
    }

    @Test func repeatedRunsCloseDescriptorsAndRejectNonSSHCommands() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let before = descriptorCount()
        for _ in 0..<12 { try await fixture.runner.run(fixture.command("success"), password: "synthetic-only") }
        #expect(descriptorCount() <= before + 2)
        do {
            try await SSHPasswordRegistrationRunner().run(ShellCommand(executable: "/bin/sh", arguments: []), password: "synthetic-only")
            Issue.record("Non SSH command accepted")
        } catch { #expect(error as? SSHPasswordRegistrationError == .invalidCommand) }
    }

    private func descriptorCount() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
    private func expectFailure(_ expected: SSHPasswordRegistrationError, fixture: Fixture, mode: String, timeout: TimeInterval = 2) async {
        do { try await fixture.runner.run(fixture.command(mode), password: "synthetic-only", timeout: timeout); Issue.record("Expected \(expected)") }
        catch {
            #expect(error as? SSHPasswordRegistrationError == expected)
            #expect(!String(describing: error).contains("synthetic-only"))
            #expect(!error.localizedDescription.contains("synthetic-only"))
        }
    }

    private struct Fixture {
        let directory: URL
        let executable: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("infra-password-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executable = directory.appendingPathComponent("fake-ssh")
            let source = directory.appendingPathComponent("fake-ssh.c")
            try Self.source.write(to: source, atomically: true, encoding: .utf8)
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            compiler.arguments = [source.path, "-o", executable.path]
            try compiler.run(); compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else { throw NSError(domain: "FixtureCompile", code: 1) }
        }
        var runner: SSHPasswordRegistrationRunner { SSHPasswordRegistrationRunner(executableForTesting: executable.path) }
        func command(_ mode: String) -> ShellCommand {
            ShellCommand(executable: "/usr/bin/ssh", arguments: [mode, directory.path], standardInput: "ssh-ed25519 AAAA fixture\n")
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
        func waitForPIDs() async throws -> (pid_t, pid_t) {
            for _ in 0..<100 {
                if let text = try? String(contentsOf: directory.appendingPathComponent("pids"), encoding: .utf8) {
                    let fields = text.split(separator: " ")
                    if fields.count == 2, let parent = pid_t(fields[0]), let child = pid_t(fields[1]) { return (parent, child) }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "FixtureReady", code: 1)
        }
        static let source = #"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #include <fcntl.h>
        #include <termios.h>
        #include <signal.h>
        #include <poll.h>
        int main(int argc, char **argv) {
            int tty = open("/dev/tty", O_RDWR);
            if (tty < 0 || isatty(0) || isatty(1) || isatty(2)) return 10;
            char key[256] = {0};
            int key_count = read(0, key, sizeof(key));
            if (key_count != 25 || strcmp(key, "ssh-ed25519 AAAA fixture\n")) return 11;
            const char *mode = argv[1];
            if (!strcmp(mode, "hostkey")) { fprintf(stderr, "Host key verification failed.\n"); return 255; }
            if (!strcmp(mode, "spoof") || !strcmp(mode, "spoof-only")) {
                fprintf(stdout, "fixture@host's password: "); fflush(stdout);
                fprintf(stderr, "fixture@host's password: "); fflush(stderr);
                int flags = fcntl(tty, F_GETFL);
                fcntl(tty, F_SETFL, flags | O_NONBLOCK);
                usleep(100000);
                char probe[1024];
                if (read(tty, probe, sizeof(probe)) > 0) return 20;
                fcntl(tty, F_SETFL, flags);
                if (!strcmp(mode, "spoof-only")) return 0;
            }
            if (!strcmp(mode, "hang")) { sleep(30); return 1; }
            if (!strcmp(mode, "tree")) {
                pid_t child = fork();
                if (!child) { sleep(30); return 1; }
                char path[4096]; snprintf(path, sizeof(path), "%s/pids", argv[2]);
                FILE *pids = fopen(path, "w"); fprintf(pids, "%d %d", getpid(), child); fclose(pids);
                sleep(30); return 1;
            }
            struct termios t;
            if (tcgetattr(tty, &t)) return 12;
            if (!strcmp(mode, "echo")) t.c_lflag |= ECHO;
            else t.c_lflag &= ~(ECHO | ECHONL);
            if (tcsetattr(tty, TCSANOW, &t)) return 13;
            if (!strcmp(mode, "otp")) { write(tty, "Verification code: ", 19); sleep(30); return 1; }
            if (!strcmp(mode, "ipv6")) {
                const char *prompt = "trainer@2001:db8::1's password: ";
                write(tty, prompt, strlen(prompt));
            } else if (!strcmp(mode, "ipv6-split")) {
                const char *prefix = "trainer@2001:";
                const char *suffix = "db8::1's password: ";
                write(tty, prefix, strlen(prefix)); usleep(100000);
                write(tty, suffix, strlen(suffix));
            } else {
                write(tty, "fixture@host's pass", 19); usleep(20000);
                write(tty, "word: ", 6);
            }
            char password[1025] = {0};
            int count = 0;
            while (count < sizeof(password)-1) {
                int got = read(tty, password+count, sizeof(password)-1-count);
                if (got <= 0) return 14;
                count += got;
                if (password[count-1] == '\n') break;
            }
            if (!strcmp(mode, "controls")) {
                if (count != 7 || memcmp(password, "\003\004\177é\025\n", 7)) return 14;
            } else if (!strcmp(mode, "maximum")) {
                if (count != 1024 || password[1023] != '\n') return 14;
                for (int i = 0; i < 1023; i++) if (password[i] != 'x') return 14;
            } else if (count != 15 || strcmp(password, "synthetic-only\n")) return 14;
            if (!strcmp(mode, "repeat-exit")) { write(tty, "Password: ", 10); return 0; }
            if (!strcmp(mode, "repeat")) { write(tty, "Password: ", 10); sleep(30); return 1; }
            if (!strcmp(mode, "wrong")) { fprintf(stderr, "%sPermission denied (password).", password); return 255; }
            if (!strcmp(mode, "flood")) { for (;;) write(1, "012345678901234567890123456789", 30); }
            // Verify the password never became an argument or an environment entry.
            for (int i = 0; i < argc; i++) if (strstr(argv[i], "synthetic-only")) return 21;
            extern char **environ;
            for (char **entry = environ; *entry; entry++) if (strstr(*entry, "synthetic-only")) return 22;
            close(tty); return 0;
        }
        """#
    }
}
