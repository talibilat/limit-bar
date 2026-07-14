import Foundation
import Security
import Testing
@testable import LimitBarCore

@Suite("Claude credential broker")
struct ClaudeCredentialBrokerTests {
    @Test("passive reads prohibit authentication UI and parse credentials")
    func passiveQuery() async {
        let query = QuerySpy(status: errSecSuccess, data: credentialData(expiresAt: 2_000))
        let broker = ClaudeCredentialBroker(reader: SecurityClaudeCredentialReader(query: query.call), now: { Date(timeIntervalSince1970: 1) })

        let result = await broker.credential(intent: .passive)

        #expect(result == .credential(ClaudeCodeOAuthCredential(accessToken: "token", expiresAt: Date(timeIntervalSince1970: 2), subscriptionType: "pro")))
        #expect(query.queries.count == 1)
        #expect(query.queries[0][kSecClass] as? String == kSecClassGenericPassword as String)
        #expect(query.queries[0][kSecAttrService] as? String == "Claude Code-credentials")
        #expect(query.queries[0][kSecMatchLimit] as? String == kSecMatchLimitOne as String)
        #expect(query.queries[0][kSecReturnData] as? Bool == true)
        #expect(query.queries[0][kSecUseAuthenticationUI] as? String == "u_AuthUIFail")
    }

    @Test("interactive reads allow authentication UI")
    func interactiveQuery() async {
        let query = QuerySpy(status: errSecItemNotFound)
        let broker = ClaudeCredentialBroker(reader: SecurityClaudeCredentialReader(query: query.call))

        _ = await broker.credential(intent: .interactive)

        #expect(query.queries[0][kSecUseAuthenticationUI] as? String == "u_AuthUIAllow")
    }

    @Test(arguments: [
        (errSecItemNotFound, ClaudeCredentialResult.absent),
        (errSecInteractionNotAllowed, .failure(.interactionRequired)),
        (OSStatus(-25_315), .failure(.interactionRequired)),
        (errSecUserCanceled, .failure(.userCancelled)),
        (errSecAuthFailed, .failure(.authFailed)),
        (errSecNotAvailable, .failure(.notAvailable)),
        (errSecMissingEntitlement, .failure(.noAccess)),
        (errSecNotTrusted, .failure(.noAccess)),
        (OSStatus(-25_243), .failure(.noAccess)),
        (OSStatus(-777_777), .failure(.unexpected(-777_777)))
    ])
    func mapsSecurityStatus(status: OSStatus, expected: ClaudeCredentialResult) async {
        let broker = ClaudeCredentialBroker(reader: SecurityClaudeCredentialReader(query: QuerySpy(status: status).call))
        #expect(await broker.credential(intent: .passive) == expected)
    }

    @Test("malformed credentials are distinct from absent credentials")
    func malformedCredential() async {
        let query = QuerySpy(status: errSecSuccess, data: Data("{}".utf8))
        let broker = ClaudeCredentialBroker(reader: SecurityClaudeCredentialReader(query: query.call))
        #expect(await broker.credential(intent: .passive) == .failure(.malformedCredential))
    }

    @Test("future-expiry credentials are cached until invalidated")
    func cachesFutureExpiry() async {
        let query = QuerySpy(status: errSecSuccess, data: credentialData(expiresAt: 2_000))
        let broker = ClaudeCredentialBroker(reader: SecurityClaudeCredentialReader(query: query.call), now: { Date(timeIntervalSince1970: 1) })

        _ = await broker.credential(intent: .passive)
        _ = await broker.credential(intent: .passive)
        #expect(query.queries.count == 1)

        await broker.invalidate()
        _ = await broker.credential(intent: .passive)
        #expect(query.queries.count == 2)
    }

    @Test("expired and no-expiry credentials are never cached")
    func doesNotCacheUnboundedCredentials() async {
        let noExpiry = QuerySpy(status: errSecSuccess, data: credentialData(expiresAt: nil))
        let noExpiryBroker = ClaudeCredentialBroker(reader: SecurityClaudeCredentialReader(query: noExpiry.call))
        _ = await noExpiryBroker.credential(intent: .passive)
        _ = await noExpiryBroker.credential(intent: .passive)
        #expect(noExpiry.queries.count == 2)

        let expired = QuerySpy(status: errSecSuccess, data: credentialData(expiresAt: 1_000))
        let expiredBroker = ClaudeCredentialBroker(reader: SecurityClaudeCredentialReader(query: expired.call), now: { Date(timeIntervalSince1970: 2) })
        _ = await expiredBroker.credential(intent: .passive)
        _ = await expiredBroker.credential(intent: .passive)
        #expect(expired.queries.count == 2)
    }

    @Test("interactive authorization retries after passive interaction requirement")
    func interactiveRetries() async {
        let query = SequenceQuerySpy(responses: [
            SecurityQueryResponse(status: errSecInteractionNotAllowed, data: nil),
            SecurityQueryResponse(status: errSecSuccess, data: credentialData(expiresAt: 2_000))
        ])
        let broker = ClaudeCredentialBroker(reader: SecurityClaudeCredentialReader(query: query.call), now: { Date(timeIntervalSince1970: 1) })

        #expect(await broker.credential(intent: .passive) == .failure(.interactionRequired))
        #expect(await broker.credential(intent: .interactive).credential?.accessToken == "token")
        #expect(query.queries.count == 2)
    }
}

private final class QuerySpy: @unchecked Sendable {
    private let lock = NSLock()
    private let response: SecurityQueryResponse
    private(set) var queries: [[CFString: Any]] = []

    init(status: OSStatus, data: Data? = nil) {
        response = SecurityQueryResponse(status: status, data: data)
    }

    func call(_ query: [CFString: Any]) -> SecurityQueryResponse {
        lock.withLock { queries.append(query) }
        return response
    }
}

private final class SequenceQuerySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [SecurityQueryResponse]
    private(set) var queries: [[CFString: Any]] = []

    init(responses: [SecurityQueryResponse]) {
        self.responses = responses
    }

    func call(_ query: [CFString: Any]) -> SecurityQueryResponse {
        lock.withLock {
            queries.append(query)
            return responses.removeFirst()
        }
    }
}

private func credentialData(expiresAt: Double?) -> Data {
    var oauth: [String: Any] = ["accessToken": "token", "subscriptionType": "pro"]
    oauth["expiresAt"] = expiresAt
    return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
}
