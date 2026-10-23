import Foundation

public enum SSHConnectionFailure: Error, LocalizedError, Equatable, Sendable {
    case network, authentication, keychainAccess, hostKey, unknown

    public var blocksAutomaticRetry: Bool { self != .network }

    public static func classify(exitCode: Int32, stderr: String) -> Self {
        guard exitCode == 255 else { return .unknown }
        if stderr.contains(SSHPasswordAuthentication.keychainAccessRequiredMarker) { return .keychainAccess }
        let diagnostic = stderr.lowercased()
        if ["remote host identification has changed", "host key verification failed"].contains(where: diagnostic.contains) { return .hostKey }
        if ["permission denied (", "permission denied, please try again", "too many authentication failures",
            "authentication failed", "no more authentication methods to try", "sign_and_send_pubkey: signing failed"].contains(where: diagnostic.contains) {
            return .authentication
        }
        if ["connection timed out", "operation timed out", "could not resolve hostname", "no route to host",
            "network is unreachable", "connection refused", "connection reset by peer", "connection closed by",
            "closed by remote host", "broken pipe"].contains(where: diagnostic.contains) { return .network }
        return .unknown
    }

    public var errorDescription: String? {
        switch self {
        case .network: return "네트워크 연결을 확인할 수 없습니다. 주소·네트워크 상태를 확인하고 다시 연결하세요."
        case .authentication: return "SSH 연결 확인 필요. 인증에 실패했습니다. 터미널에서 인증하거나 SSH 키 잠금 해제를 확인하세요."
        case .keychainAccess: return SSHPasswordError.keychainAccessRequired.localizedDescription
        case .hostKey: return "SSH 호스트키 확인이 필요합니다. 자동 재시도를 멈췄습니다. 서버 신원을 확인한 뒤 수동으로 연결하세요."
        case .unknown: return "SSH 연결 확인 필요. 실패 원인을 확인하지 못했습니다. 수동 연결로 상태를 확인하세요."
        }
    }
}
