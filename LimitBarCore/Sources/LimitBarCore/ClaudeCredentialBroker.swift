import Foundation
@preconcurrency import Security

public struct ClaudeCodeOAuthCredential: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    public func isExpired(now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

public enum ClaudeCredentialIntent: Equatable, Sendable {
    case passive
    case interactive
}

public enum ClaudeCredentialError: Error, Equatable, Sendable {
    case interactionRequired
    case userCancelled
    case authFailed
    case notAvailable
    case noAccess
    case malformedCredential
    case unexpected(OSStatus)
}

public enum ClaudeCredentialResult: Equatable, Sendable {
    case credential(ClaudeCodeOAuthCredential)
    case absent
    case failure(ClaudeCredentialError)

    public var credential: ClaudeCodeOAuthCredential? {
        guard case let .credential(credential) = self else { return nil }
        return credential
    }
}

public struct SecurityQueryResponse: Sendable {
    public let status: OSStatus
    public let data: Data?

    public init(status: OSStatus, data: Data?) {
        self.status = status
        self.data = data
    }
}

public struct SecurityClaudeCredentialReader: @unchecked Sendable {
    public typealias Query = (_ query: [CFString: Any]) -> SecurityQueryResponse

    private let query: Query

    public init(query: @escaping Query = SecurityClaudeCredentialReader.systemQuery) {
        self.query = query
    }

    public func read(intent: ClaudeCredentialIntent) -> ClaudeCredentialResult {
        // Raw values are the non-deprecated spelling of the required
        // kSecUseAuthenticationUIFail/Allow query values.
        let authenticationUI: CFString = intent == .passive ? "u_AuthUIFail" as CFString : "u_AuthUIAllow" as CFString
        let response = query([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecUseAuthenticationUI: authenticationUI
        ])

        switch response.status {
        case errSecSuccess:
            guard let data = response.data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any],
                  let accessToken = oauth["accessToken"] as? String,
                  !accessToken.isEmpty else {
                return .failure(.malformedCredential)
            }
            let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000) }
            return .credential(ClaudeCodeOAuthCredential(
                accessToken: accessToken,
                expiresAt: expiresAt,
                subscriptionType: oauth["subscriptionType"] as? String
            ))
        case errSecItemNotFound:
            return .absent
        case errSecInteractionNotAllowed, OSStatus(-25_315):
            return .failure(.interactionRequired)
        case errSecUserCanceled:
            return .failure(.userCancelled)
        case errSecAuthFailed:
            return .failure(.authFailed)
        case errSecNotAvailable:
            return .failure(.notAvailable)
        case errSecMissingEntitlement, errSecNotTrusted, OSStatus(-25_243):
            return .failure(.noAccess)
        default:
            return .failure(.unexpected(response.status))
        }
    }

    public static func systemQuery(_ query: [CFString: Any]) -> SecurityQueryResponse {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return SecurityQueryResponse(status: status, data: item as? Data)
    }
}

public actor ClaudeCredentialBroker {
    public static let shared = ClaudeCredentialBroker()

    private let reader: SecurityClaudeCredentialReader
    private let now: @Sendable () -> Date
    private var cachedCredential: ClaudeCodeOAuthCredential?

    public init(
        reader: SecurityClaudeCredentialReader = SecurityClaudeCredentialReader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.now = now
    }

    public func credential(intent: ClaudeCredentialIntent) -> ClaudeCredentialResult {
        if let cachedCredential, !cachedCredential.isExpired(now: now()) {
            return .credential(cachedCredential)
        }

        cachedCredential = nil
        let result = reader.read(intent: intent)
        if case let .credential(credential) = result,
           !credential.isExpired(now: now()) {
            cachedCredential = credential
        }
        return result
    }

    public func invalidate() {
        cachedCredential = nil
    }
}

public protocol ClaudeCredentialProviding: Sendable {
    func credential(intent: ClaudeCredentialIntent) async -> ClaudeCredentialResult
    func invalidate() async
}

extension ClaudeCredentialBroker: ClaudeCredentialProviding {}
