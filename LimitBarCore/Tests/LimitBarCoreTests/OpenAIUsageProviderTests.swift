import Foundation
import Testing
@testable import LimitBarCore

@Suite("OpenAI usage provider")
struct OpenAIUsageProviderTests {
    @Test("OAuth feasibility validates organization usage access")
    func feasibilityRequest() async throws {
        let http = OpenAIRecordingHTTPClient(response: HTTPResponse(statusCode: 200, data: Data(#"{"data":[],"has_more":false}"#.utf8)))
        let client = OpenAIOrganizationClient(httpClient: http)

        let outcome = await client.validateOAuth(accessToken: "super-secret", interval: DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200)))
        let request = try #require(await http.requests.first)

        #expect(outcome == .supported)
        #expect(request.url.path == "/v1/organization/usage/completions")
        #expect(request.headers["Authorization"] == "Bearer super-secret")
        #expect(request.url.absoluteString.contains("start_time=100"))
        #expect(request.url.absoluteString.contains("end_time=200"))
        #expect(request.url.absoluteString.contains("bucket_width=1m"))
        #expect(request.url.absoluteString.contains("limit=1440"))
        #expect(request.url.absoluteString.contains("group_by%5B%5D=project_id"))
        #expect(request.url.absoluteString.contains("group_by%5B%5D=model"))
        #expect(!String(describing: outcome).contains("super-secret"))
    }

    @Test("OAuth feasibility maps access states", arguments: [
        (401, OpenAIFeasibilityOutcome.expired),
        (403, OpenAIFeasibilityOutcome.adminCredentialRequired),
        (404, OpenAIFeasibilityOutcome.unsupported),
        (500, OpenAIFeasibilityOutcome.failed(.refreshFailed))
    ])
    func feasibilityStatuses(status: Int, expected: OpenAIFeasibilityOutcome) async {
        let client = OpenAIOrganizationClient(httpClient: OpenAIRecordingHTTPClient(response: HTTPResponse(statusCode: status, data: Data("raw".utf8))))
        let outcome = await client.validateOAuth(accessToken: "secret", interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1))
        #expect(outcome == expected)
    }

    @Test("usage fixture maps explicit organization project and model identity")
    func usageMapping() throws {
        let data = Data(#"{"data":[{"start_time":1783687200,"end_time":1783690800,"results":[{"project_id":"proj_1","project_name":"Codex Enterprise","model":"gpt-5.1-codex","input_tokens":10,"cached_input_tokens":2,"output_tokens":4}]}]}"#.utf8)

        let metrics = try OpenAIUsageMapper.metrics(from: data, organization: "org_123", now: Date(timeIntervalSince1970: 1_783_716_000), calendar: try utcCalendar())
        let metric = try #require(metrics.first { $0.timeWindow == .today })

        #expect(metric.accountLabel == "org_123")
        #expect(metric.projectLabel == "Codex Enterprise")
        #expect(metric.modelLabel == "gpt-5.1-codex")
        #expect(metric.tokenUsage == TokenUsage(inputTokens: 10, outputTokens: 4))
        #expect(metric.limitStatus == .unsupportedByProviderAPI)
    }

    @Test("usage fixture rejects missing identity")
    func usageMappingRejectsMissingIdentity() throws {
        let data = Data(#"{"data":[{"start_time":1783687200,"end_time":1783690800,"results":[{"project_id":null,"model":"gpt","input_tokens":1,"output_tokens":1}]}]}"#.utf8)
        #expect(try OpenAIUsageMapper.metrics(from: data, organization: "org", now: Date(timeIntervalSince1970: 1_783_728_000), calendar: try utcCalendar()).isEmpty)
        #expect(try OpenAIUsageMapper.metrics(from: data, organization: "", now: Date(timeIntervalSince1970: 1_783_728_000), calendar: try utcCalendar()).isEmpty)
    }

    @Test("cost fixture maps provider-reported project spend")
    func costMapping() throws {
        let data = Data(#"{"data":[{"start_time":1783641600,"end_time":1783684800,"results":[{"project_id":"proj_1","line_item":"Completions","amount":{"value":1.25,"currency":"usd"}},{"project_id":"proj_1","line_item":"Ignored","amount":null}]},{"start_time":1783684800,"end_time":1783728000,"results":[{"project_id":"proj_1","line_item":"Completions","amount":{"value":0.75,"currency":"usd"}}]}]}"#.utf8)

        let metrics = try OpenAICostMapper.metrics(from: data, organization: "org_123", now: Date(timeIntervalSince1970: 1_783_716_000), calendar: try utcCalendar())
        let metric = try #require(metrics.first { $0.timeWindow == .today })

        #expect(metric.accountLabel == "org_123")
        #expect(metric.projectLabel == "proj_1")
        #expect(metric.modelLabel == "Completions")
        #expect(metric.cost == Cost(amount: Decimal(string: "2.00")!, currencyCode: "USD", source: .providerReported))
    }

    @Test("multi-currency cost rows persist independently")
    func multiCurrencyCostsPersistIndependently() throws {
        let data = Data(#"{"data":[{"start_time":1783641600,"end_time":1783728000,"results":[{"project_id":"proj_1","line_item":"Completions","amount":{"value":1.25,"currency":"usd"}},{"project_id":"proj_1","line_item":"Completions","amount":{"value":2.5,"currency":"eur"}}]}]}"#.utf8)
        let metrics = try OpenAICostMapper.metrics(from: data, organization: "org", now: Date(timeIntervalSince1970: 1_783_716_000), calendar: try utcCalendar()).filter { $0.timeWindow == .today }
        let store = try SQLiteUsageMetricStore.inMemory()

        _ = try OpenAIRefreshPersistence.apply(.success(metrics), to: store)

        #expect(try store.metrics(for: .today).count == 2)
        #expect(Set(try store.metrics(for: .today).compactMap(\.cost?.currencyCode)) == ["USD", "EUR"])
    }

    @Test("refresh persistence replaces only OpenAI and stales failures")
    func refreshPersistence() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let old = metric(provider: .openAI, model: "old")
        let anthropic = metric(provider: .anthropic, model: "claude")
        let fresh = metric(provider: .openAI, model: "new")
        try store.save([old, anthropic])

        let success = try OpenAIRefreshPersistence.apply(.success([fresh]), to: store)
        #expect(success.state == .connected)
        #expect(try store.allMetrics() == [anthropic, fresh])

        let failure = try OpenAIRefreshPersistence.apply(.failure(.insufficientPermissions), to: store)
        let retained = try #require(try store.allMetrics().first { $0.provider == .openAI })
        #expect(retained.modelLabel == "new")
        #expect(retained.freshness == .stale(missedRefreshes: 2))
        #expect(failure.failureReason == .insufficientPermissions)
    }

    private func metric(provider: ProviderKind, model: String) -> UsageMetric {
        UsageMetric(provider: provider, accountLabel: nil, projectLabel: nil, modelLabel: model, deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(timeIntervalSince1970: 100), freshness: .fresh)
    }

    private func utcCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        return calendar
    }
}

private actor OpenAIRecordingHTTPClient: HTTPClient {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(response: HTTPResponse) { responses = [response] }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}
