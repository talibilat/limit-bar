import Foundation
import Testing
@testable import LimitBarCore

@MainActor
@Suite("Claude rate limits model")
struct ClaudeRateLimitsModelTests {
    @Test("appearance uses passive credentials and never calls API when authorization is required")
    func passiveAppearance() async {
        let credentials = CredentialProviderSpy(results: [.failure(.interactionRequired)])
        let client = ClaudeClientSpy(result: .failure(.requestRejected))
        let model = ClaudeRateLimitsModel(credentials: credentials, client: client)

        await model.appeared()

        #expect(await credentials.recordedIntents() == [.passive])
        #expect(client.tokens.isEmpty)
        #expect(model.state == .authorizationRequired)
        #expect(model.isPresent)
    }

    @Test("explicit connect permits interaction and then fetches")
    func connect() async {
        let credential = ClaudeCodeOAuthCredential(accessToken: "token", expiresAt: nil, subscriptionType: "max")
        let credentials = CredentialProviderSpy(results: [.credential(credential)])
        let snapshot = makeClaudeSnapshot()
        let client = ClaudeClientSpy(result: .success(snapshot))
        let model = ClaudeRateLimitsModel(credentials: credentials, client: client)

        await model.connect()

        #expect(await credentials.recordedIntents() == [.interactive])
        #expect(client.tokens == ["token"])
        #expect(model.state == .loaded(snapshot, subscription: "max"))
        #expect(!model.isRefreshing)
    }

    @Test("absent credentials keep the visible not-connected Check Again UI")
    func absentCredentialsRemainVisibleAndNotConnected() async {
        let model = ClaudeRateLimitsModel(
            credentials: CredentialProviderSpy(results: [.absent]),
            client: ClaudeClientSpy(result: .failure(.requestRejected))
        )

        await model.appeared()

        #expect(model.isPresent)
        #expect(model.state == .notConnected)
    }

    @Test("expired login invalidates cached credentials before the next explicit refresh")
    func expiredLoginInvalidatesCredentials() async {
        let credential = ClaudeCodeOAuthCredential(accessToken: "old", expiresAt: Date.distantFuture, subscriptionType: nil)
        let credentials = CredentialProviderSpy(results: [.credential(credential), .absent])
        let model = ClaudeRateLimitsModel(
            credentials: credentials,
            client: ClaudeClientSpy(result: .failure(.expiredLogin))
        )

        await model.appeared()
        await model.refresh()

        #expect(await credentials.invalidationCount == 1)
        #expect(await credentials.recordedIntents() == [.passive, .passive])
        #expect(model.state == .notConnected)
    }

    @Test("credential cancellation preserves prior state and clears refresh flag")
    func credentialCancellation() async {
        let prior = makeClaudeSnapshot()
        let model = ClaudeRateLimitsModel(
            credentials: CredentialProviderSpy(results: [.failure(.userCancelled)]),
            client: ClaudeClientSpy(result: .failure(.requestRejected)),
            state: .loaded(prior, subscription: "pro")
        )

        await model.connect()

        #expect(model.state == .loaded(prior, subscription: "pro"))
        #expect(!model.isRefreshing)
    }

    @Test("API cancellation preserves prior state and clears refresh flag")
    func apiCancellation() async {
        let prior = makeClaudeSnapshot()
        let credential = ClaudeCodeOAuthCredential(accessToken: "token", expiresAt: nil, subscriptionType: "pro")
        let model = ClaudeRateLimitsModel(
            credentials: CredentialProviderSpy(results: [.credential(credential)]),
            client: ClaudeClientSpy(result: .failure(.cancelled)),
            state: .loaded(prior, subscription: "pro")
        )

        await model.connect()

        #expect(model.state == .loaded(prior, subscription: "pro"))
        #expect(!model.isRefreshing)
    }
}

private actor CredentialProviderSpy: ClaudeCredentialProviding {
    private var results: [ClaudeCredentialResult]
    private(set) var intents: [ClaudeCredentialIntent] = []
    private(set) var invalidationCount = 0

    init(results: [ClaudeCredentialResult]) {
        self.results = results
    }

    func credential(intent: ClaudeCredentialIntent) -> ClaudeCredentialResult {
        intents.append(intent)
        return results.removeFirst()
    }

    func recordedIntents() -> [ClaudeCredentialIntent] { intents }
    func invalidate() { invalidationCount += 1 }
}

private final class ClaudeClientSpy: ClaudeRateLimitsFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<ClaudeRateLimitSnapshot, ClaudeRateLimitFailure>
    private(set) var tokens: [String] = []

    init(result: Result<ClaudeRateLimitSnapshot, ClaudeRateLimitFailure>) {
        self.result = result
    }

    func fetchRateLimits(accessToken: String) async -> Result<ClaudeRateLimitSnapshot, ClaudeRateLimitFailure> {
        lock.withLock { tokens.append(accessToken) }
        return result
    }
}

private func makeClaudeSnapshot() -> ClaudeRateLimitSnapshot {
    ClaudeRateLimitSnapshot(
        limits: [ClaudeRateLimit(kind: "session", group: .session, percentUsed: 10, severity: .normal, resetsAt: nil, scopeDisplayName: nil, isActive: false)],
        fetchedAt: Date(timeIntervalSince1970: 1)
    )
}
