import Testing
import Foundation
@testable import InfraCore

struct SSHConnectionFailureTests {
    @Test(arguments: [
        "ssh: connect to host example.invalid port 22: Operation timed out",
        "ssh: Could not resolve hostname example.invalid: nodename nor servname provided, or not known",
        "client_loop: send disconnect: Broken pipe",
        "ssh: connect to host example.invalid port 22: Connection refused"
    ]) func networkFailuresRemainRetryable(_ stderr: String) {
        let failure = SSHConnectionFailure.classify(exitCode: 255, stderr: stderr)
        #expect(failure == .network)
        #expect(!failure.blocksAutomaticRetry)
    }

    @Test func authenticationHostKeyAndKeychainAreDistinct() {
        #expect(SSHConnectionFailure.classify(exitCode: 255, stderr: "trainer@example.invalid: Permission denied (publickey,password).") == .authentication)
        #expect(SSHConnectionFailure.classify(exitCode: 255, stderr: "sign_and_send_pubkey: signing failed for ED25519: agent refused operation") == .authentication)
        #expect(SSHConnectionFailure.classify(exitCode: 255, stderr: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.") == .hostKey)
        #expect(SSHConnectionFailure.classify(exitCode: 255, stderr: SSHPasswordAuthentication.keychainAccessRequiredMarker) == .keychainAccess)
        #expect(SSHConnectionFailure.hostKey.blocksAutomaticRetry)
        #expect(SSHConnectionFailure.authentication.blocksAutomaticRetry)
    }

    @Test func unknownExit255DoesNotInventAuthenticationOrEchoCommands() {
        let failure = SSHConnectionFailure.classify(exitCode: 255, stderr: "unrecognized diagnostic; run $(touch /tmp/unsafe) now")
        #expect(failure == .unknown)
        #expect(failure.blocksAutomaticRetry)
        #expect(!failure.localizedDescription.contains("touch"))
        #expect(!failure.localizedDescription.contains("비밀번호"))
        #expect(SSHConnectionFailure.classify(exitCode: 7, stderr: "Permission denied (publickey).") == .unknown)
    }
}
