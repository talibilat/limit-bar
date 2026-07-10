import Foundation
import Testing
@testable import LimitBarCore

@Suite("Anthropic usage provider")
struct AnthropicUsageProviderTests {
    @Test("validation sends bounded Admin usage request and returns connected")
    func validationRequest() async throws {
        let http = RecordingHTTPClient(response: HTTPResponse(statusCode: 200, data: Data(#"{"data":[]}"#.utf8)))
        let client = AnthropicAdminClient(httpClient: http)
        let interval = DateInterval(start: try date("2026-07-06T00:00:00Z"), end: try date("2026-07-13T00:00:00Z"))

        let outcome = await client.validate(apiKey: "super-secret-value", interval: interval)
        let request = try #require(await http.lastRequest)

        #expect(outcome == .connected)
        #expect(request.method == .get)
        #expect(request.url.host == "api.anthropic.com")
        #expect(request.url.path == "/v1/organizations/usage_report/messages")
        #expect(request.headers["x-api-key"] == "super-secret-value")
        #expect(request.headers["anthropic-version"] == "2023-06-01")
        #expect(request.url.absoluteString.contains("starting_at="))
        #expect(request.url.absoluteString.contains("ending_at="))
        #expect(!String(describing: outcome).contains("super-secret-value"))
    }

    @Test("validation maps HTTP and transport failures to safe reasons", arguments: [
        (401, ProviderFailureReason.authenticationRejected),
        (403, ProviderFailureReason.insufficientPermissions),
        (500, ProviderFailureReason.refreshFailed)
    ])
    func validationStatus(status: Int, reason: ProviderFailureReason) async {
        let http = RecordingHTTPClient(response: HTTPResponse(statusCode: status, data: Data("raw-secret-response".utf8)))
        let client = AnthropicAdminClient(httpClient: http)

        let outcome = await client.validate(apiKey: "secret", interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60))

        #expect(outcome == .failed(reason))
        #expect(!String(describing: outcome).contains("raw-secret-response"))
    }

    @Test("validation maps transport errors safely")
    func validationTransportError() async {
        let client = AnthropicAdminClient(httpClient: RecordingHTTPClient(error: TestHTTPError.failed))

        let outcome = await client.validate(apiKey: "secret", interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60))

        #expect(outcome == .failed(.networkUnavailable))
    }

    @Test("fixture mapping preserves returned labels tokens costs and limits")
    func fixtureMapping() throws {
        let data = Data(#"""
        {
          "data": [{
            "starting_at": "2026-07-10T10:00:00Z",
            "ending_at": "2026-07-10T11:00:00Z",
            "results": [
              {"model":"Claude Sonnet","uncached_input_tokens":10,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":5,"cost":"1.25","currency":"USD"},
              {"dimension_label":"Cloud Design","input_tokens":7,"output_tokens":4,"limit_used":11,"limit_value":100}
            ]
          }]
        }
        """#.utf8)

        let metrics = try AnthropicUsageMapper.metrics(from: data, now: try date("2026-07-10T18:00:00Z"), calendar: try utcCalendar())
        let today = metrics.filter { $0.timeWindow == .today }
        let sonnet = try #require(today.first { $0.modelLabel == "Claude Sonnet" })
        let cloudDesign = try #require(today.first { $0.modelLabel == "Cloud Design" })

        #expect(today.count == 2)
        #expect(sonnet.tokenUsage == TokenUsage(inputTokens: 15, outputTokens: 5))
        #expect(sonnet.cost == Cost(amount: Decimal(string: "1.25")!, currencyCode: "USD", source: .providerReported))
        #expect(sonnet.limitStatus == .unsupportedByProviderAPI)
        #expect(cloudDesign.tokenUsage == TokenUsage(inputTokens: 7, outputTokens: 4))
        #expect(cloudDesign.limitStatus == .confirmed(used: 11, limit: 100))
        #expect(metrics.filter { $0.timeWindow == .currentWeek }.count == 2)
    }

    @Test("fixture mapping does not invent missing labels")
    func fixtureMappingRejectsUnlabeledRows() throws {
        let data = Data(#"{"data":[{"starting_at":"2026-07-10T10:00:00Z","ending_at":"2026-07-10T11:00:00Z","results":[{"input_tokens":1,"output_tokens":2}]}]}"#.utf8)

        let metrics = try AnthropicUsageMapper.metrics(from: data, now: try date("2026-07-10T18:00:00Z"), calendar: try utcCalendar())

        #expect(metrics.isEmpty)
    }

    @Test("successful refresh replaces only Anthropic rows")
    func successfulRefreshPersistence() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let oldAnthropic = metric(provider: .anthropic, model: "old")
        let azure = metric(provider: .azureOpenAI, model: "azure")
        let openAI = metric(provider: .openAI, model: "openai")
        let refreshed = metric(provider: .anthropic, model: "new", input: 40, output: 10)
        try store.save([oldAnthropic, azure, openAI])

        let diagnostic = try AnthropicRefreshPersistence.apply(.success([refreshed]), to: store)

        #expect(diagnostic.state == .connected)
        #expect(try store.allMetrics() == [azure, openAI, refreshed])
    }

    @Test("failed refresh retains Anthropic values and marks only them stale")
    func failedRefreshPersistence() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let anthropic = metric(provider: .anthropic, model: "retained", input: 20, output: 5)
        let azure = metric(provider: .azureOpenAI, model: "azure")
        try store.save([anthropic, azure])

        let diagnostic = try AnthropicRefreshPersistence.apply(.failure(.networkUnavailable), to: store)

        let retained = try #require(try store.allMetrics().first { $0.provider == .anthropic })
        let untouchedAzure = try #require(try store.allMetrics().first { $0.provider == .azureOpenAI })
        #expect(retained.tokenUsage == anthropic.tokenUsage)
        #expect(retained.freshness == .stale(missedRefreshes: 2))
        #expect(untouchedAzure.freshness == .fresh)
        #expect(diagnostic.state == .failed)
        #expect(diagnostic.failureReason == .networkUnavailable)
    }

    private func metric(provider: ProviderKind, model: String, input: Int = 1, output: Int = 1) -> UsageMetric {
        UsageMetric(
            provider: provider,
            accountLabel: nil,
            projectLabel: nil,
            modelLabel: model,
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: input, outputTokens: output),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: Date(timeIntervalSince1970: 1_783_728_000),
            freshness: .fresh
        )
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func utcCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        return calendar
    }
}

private actor RecordingHTTPClient: HTTPClient {
    private let response: HTTPResponse?
    private let error: Error?
    private(set) var lastRequest: HTTPRequest?

    init(response: HTTPResponse) {
        self.response = response
        error = nil
    }

    init(error: Error) {
        response = nil
        self.error = error
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lastRequest = request
        if let error { throw error }
        return try #require(response)
    }
}

private enum TestHTTPError: Error {
    case failed
}
