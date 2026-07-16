import Foundation
import Testing
@testable import LimitBarCore

@Suite("Claude rate limits")
struct ClaudeRateLimitsTests {
    private let sampleResponse = #"""
    {
      "five_hour": {"utilization": 45.0, "resets_at": "2026-07-11T18:09:59.640586+00:00"},
      "seven_day": {"utilization": 33.0, "resets_at": "2026-07-14T18:59:59.640614+00:00"},
      "limits": [
        {"kind": "session", "group": "session", "percent": 46, "severity": "normal", "resets_at": "2026-07-11T18:09:59.598777+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 33, "severity": "normal", "resets_at": "2026-07-14T18:59:59.598797+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 65, "severity": "normal", "resets_at": "2026-07-14T18:59:59.599087+00:00", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
      ]
    }
    """#

    @Test("maps limits with kind, group, percent, reset, and scope")
    func mapsLimits() throws {
        let snapshot = try ClaudeUsageResponseMapper.rateLimits(from: Data(sampleResponse.utf8), fetchedAt: Date(timeIntervalSince1970: 0))

        #expect(snapshot.limits.count == 3)

        let session = snapshot.limits[0]
        #expect(session.group == .session)
        #expect(session.percentUsed == 46)
        #expect(session.percentRemaining == 54)
        #expect(session.severity == .normal)
        #expect(session.displayLabel == "Session (5 hours)")
        #expect(session.resetsAt != nil)

        let weekly = snapshot.limits[1]
        #expect(weekly.displayLabel == "Weekly (all usage)")

        let scoped = snapshot.limits[2]
        #expect(scoped.scopeDisplayName == "Fable")
        #expect(scoped.displayLabel == "Weekly (Fable)")
        #expect(scoped.isActive)
    }

    @Test("individual plans see every limit including scoped ones")
    func individualPlansSeeEverything() throws {
        let snapshot = try ClaudeUsageResponseMapper.rateLimits(from: Data(sampleResponse.utf8), fetchedAt: Date(timeIntervalSince1970: 0))

        #expect(snapshot.displayLimits(forSubscriptionType: "pro").count == 3)
        #expect(snapshot.displayLimits(forSubscriptionType: "Max").count == 3)
    }

    @Test("team, enterprise, and unknown plans hide scoped limits")
    func businessPlansHideScopedLimits() throws {
        let snapshot = try ClaudeUsageResponseMapper.rateLimits(from: Data(sampleResponse.utf8), fetchedAt: Date(timeIntervalSince1970: 0))

        for subscriptionType in ["team", "enterprise", "unknown_future_plan", nil] {
            let displayed = snapshot.displayLimits(forSubscriptionType: subscriptionType)
            #expect(displayed.count == 2)
            #expect(displayed.allSatisfy { $0.scopeDisplayName == nil })
        }
    }

    @Test("falls back to window utilization when limits are absent")
    func fallsBackToWindows() throws {
        let json = #"{"five_hour": {"utilization": 12.0, "resets_at": "2026-07-11T18:09:59+00:00"}, "seven_day": {"utilization": 7.0, "resets_at": null}}"#

        let snapshot = try ClaudeUsageResponseMapper.rateLimits(from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 0))

        #expect(snapshot.limits.count == 2)
        #expect(snapshot.limits[0].group == .session)
        #expect(snapshot.limits[0].percentUsed == 12)
        #expect(snapshot.limits[1].group == .weekly)
    }

    @Test("unknown groups and severities map to typed fallbacks")
    func unknownGroupsAndSeverities() throws {
        let json = #"{"limits": [{"kind": "daily_special", "group": "daily", "percent": 5, "severity": "odd", "resets_at": null, "scope": null, "is_active": false}]}"#

        let snapshot = try ClaudeUsageResponseMapper.rateLimits(from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 0))

        let limit = try #require(snapshot.limits.first)
        #expect(limit.group == .other)
        #expect(limit.severity == .unknown)
        #expect(limit.displayLabel == "Daily Special")
    }

    @Test("empty and malformed responses throw")
    func malformedResponsesThrow() {
        #expect(throws: ClaudeRateLimitFailure.malformedResponse) {
            try ClaudeUsageResponseMapper.rateLimits(from: Data("not json".utf8), fetchedAt: Date())
        }
        #expect(throws: ClaudeRateLimitFailure.malformedResponse) {
            try ClaudeUsageResponseMapper.rateLimits(from: Data("{}".utf8), fetchedAt: Date())
        }
    }

    @Test("percentage fields outside finite zero through one hundred are skipped")
    func invalidPercentagesAreSkipped() throws {
        let mixed = #"{"limits":[{"kind":"negative","percent":-1},{"kind":"over","percent":101},{"kind":"valid","percent":100}]}"#

        let snapshot = try ClaudeUsageResponseMapper.rateLimits(from: Data(mixed.utf8), fetchedAt: Date())

        #expect(snapshot.limits.map(\.kind) == ["valid"])
        #expect(throws: ClaudeRateLimitFailure.malformedResponse) {
            try ClaudeUsageResponseMapper.rateLimits(from: Data(#"{"five_hour":{"utilization":101}}"#.utf8), fetchedAt: Date())
        }
        #expect(throws: ClaudeRateLimitFailure.malformedResponse) {
            try ClaudeUsageResponseMapper.rateLimits(from: Data(#"{"limits":[{"kind":"huge","percent":1e999}]}"#.utf8), fetchedAt: Date())
        }
    }

    @Test("client maps status codes to typed failures")
    func clientMapsStatusCodes() async {
        let unauthorized = ClaudeOAuthUsageClient(httpClient: StubHTTPClient(response: HTTPResponse(statusCode: 401, data: Data())))
        #expect(await unauthorized.fetchRateLimits(accessToken: "token") == .failure(.expiredLogin))

        let forbidden = ClaudeOAuthUsageClient(httpClient: StubHTTPClient(response: HTTPResponse(statusCode: 403, data: Data())))
        #expect(await forbidden.fetchRateLimits(accessToken: "token") == .failure(.requestRejected))

        let serverError = ClaudeOAuthUsageClient(httpClient: StubHTTPClient(response: HTTPResponse(statusCode: 500, data: Data())))
        #expect(await serverError.fetchRateLimits(accessToken: "token") == .failure(.requestRejected))

        let offline = ClaudeOAuthUsageClient(httpClient: StubHTTPClient(error: URLError(.notConnectedToInternet)))
        #expect(await offline.fetchRateLimits(accessToken: "token") == .failure(.networkUnavailable))

        let cancelled = ClaudeOAuthUsageClient(httpClient: StubHTTPClient(error: CancellationError()))
        #expect(await cancelled.fetchRateLimits(accessToken: "token") == .failure(.cancelled))
    }

    @Test("client sends bearer token and beta header to the usage endpoint")
    func clientSendsExpectedRequest() async throws {
        let stub = StubHTTPClient(response: HTTPResponse(statusCode: 200, data: Data(sampleResponse.utf8)))
        let client = ClaudeOAuthUsageClient(httpClient: stub)

        let result = await client.fetchRateLimits(accessToken: "secret-token", now: Date(timeIntervalSince1970: 100))

        let request = try #require(await stub.request)
        #expect(request.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.headers["Authorization"] == "Bearer secret-token")
        #expect(request.headers["anthropic-beta"] == "oauth-2025-04-20")
        let snapshot = try #require(try? result.get())
        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 100))
    }
}

private actor StubHTTPClient: HTTPClient {
    private let response: HTTPResponse?
    private let error: Error?
    private(set) var request: HTTPRequest?

    init(response: HTTPResponse? = nil, error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        self.request = request
        if let error {
            throw error
        }
        return response ?? HTTPResponse(statusCode: 500, data: Data())
    }
}
