import Foundation
import Security
import Testing
@testable import InfraCore

struct KeychainAccessTests {
    @Test(arguments: [false, true])
    func readUsesTheRequestedInteractionPolicyWithoutChangingTheTarget(_ allowInteraction: Bool) throws {
        let account = SSHAccount(username: "fixture")
        let server = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        let reference = SSHPasswordReference(target: SSHPasswordTarget(server: server, account: account, resolvedHost: server.host))
        struct Payload: Encodable { let target: SSHPasswordTarget; let password: String }
        let data = try JSONEncoder().encode(Payload(target: reference.target, password: "fixture-only"))
        let store = KeychainCredentialStore { query, result in
            let attributes = query as! [String: Any]
            #expect(attributes[kSecUseAuthenticationUI as String] as? String == (allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail) as String)
            #expect(attributes[kSecAttrService as String] as? String == "com.luluterminal.ssh.password")
            #expect((attributes[kSecAttrAccount as String] as? String)?.hasPrefix(reference.id.uuidString + ":") == true)
            result?.pointee = data as CFData
            return errSecSuccess
        }
        #expect(try store.read(reference: reference, allowInteraction: allowInteraction) == "fixture-only")
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecInteractionRequired])
    func defaultReadFailsWithoutShowingAnAuthorizationWindow(_ status: OSStatus) throws {
        let account = SSHAccount(username: "fixture")
        let server = ServerProfile(name: "Fixture", host: "fixture.invalid", accounts: [account])
        let reference = SSHPasswordReference(target: SSHPasswordTarget(server: server, account: account, resolvedHost: server.host))
        let store = KeychainCredentialStore { query, _ in
            let attributes = query as! [String: Any]
            #expect(attributes[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
            return status
        }
        do {
            _ = try store.read(reference: reference)
            Issue.record("Authorization must fail without opening a window")
        } catch SSHPasswordError.keychainAccessRequired {}
    }
}
