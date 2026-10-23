import Foundation
import Security
import CryptoKit

public protocol PasswordCredentialStore: Sendable {
    func save(_ password: String, reference: SSHPasswordReference) throws
    func read(reference: SSHPasswordReference) throws -> String
    func delete(reference: SSHPasswordReference) throws
}

public struct KeychainCredentialStore: PasswordCredentialStore {
    private let copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    public init() { copyMatching = { SecItemCopyMatching($0, $1) } }
    init(copyMatching: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus) {
        self.copyMatching = copyMatching
    }
    private struct Payload: Codable { var target: SSHPasswordTarget; var password: String }
    private func query(_ reference: SSHPasswordReference) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(reference.target)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.luluterminal.ssh.password",
                kSecAttrAccount as String: reference.id.uuidString + ":" + digest,
                kSecAttrSynchronizable as String: false]
    }
    public func save(_ password: String, reference: SSHPasswordReference) throws {
        guard !password.isEmpty, !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw SSHPasswordError.message("비밀번호는 비어 있거나 줄바꿈을 포함할 수 없습니다.")
        }
        var attributes = try query(reference)
        attributes[kSecValueData as String] = try JSONEncoder().encode(Payload(target: reference.target, password: password))
        attributes[kSecAttrLabel as String] = "luluTerminal SSH · \(reference.target.username)@\(reference.target.host)"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try check(SecItemAdd(attributes as CFDictionary, nil))
    }
    public func read(reference: SSHPasswordReference) throws -> String {
        try read(reference: reference, allowInteraction: false)
    }
    func read(reference: SSHPasswordReference, allowInteraction: Bool) throws -> String {
        var attributes = try query(reference)
        attributes[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(copyMatching(attributes as CFDictionary, &result))
        guard let data = result as? Data, let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.target == reference.target else {
            throw SSHPasswordError.message("저장된 비밀번호의 연결 대상이 일치하지 않습니다. 다시 저장하세요.")
        }
        return payload.password
    }
    public func delete(reference: SSHPasswordReference) throws {
        let status = SecItemDelete(try query(reference) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            switch status {
            case errSecItemNotFound: throw SSHPasswordError.message("키체인에 비밀번호가 없습니다. 서버 편집에서 다시 저장하세요.")
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired: throw SSHPasswordError.keychainAccessRequired
            case errSecDuplicateItem: throw SSHPasswordError.message("이미 저장된 비밀번호 항목입니다. 새 비밀번호로 다시 저장하세요.")
            default: throw SSHPasswordError.message("키체인 작업에 실패했습니다 (\(status)).")
            }
        }
    }
}
