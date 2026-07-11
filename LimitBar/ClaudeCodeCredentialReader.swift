import Foundation
import Security

struct ClaudeCodeOAuthCredential {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

enum ClaudeCodeCredentialState {
    case found(ClaudeCodeOAuthCredential)
    case notFound
    case accessDenied
}

// Reuses the login Claude Code already maintains in the macOS Keychain,
// so LimitBar never runs its own OAuth flow or stores a copy of the token.
enum ClaudeCodeCredentialReader {
    private static let service = "Claude Code-credentials"

    static func read() -> ClaudeCodeCredentialState {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return .notFound
        default:
            return .accessDenied
        }

        guard let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else {
            return .notFound
        }

        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return .found(ClaudeCodeOAuthCredential(
            accessToken: accessToken,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String
        ))
    }
}
