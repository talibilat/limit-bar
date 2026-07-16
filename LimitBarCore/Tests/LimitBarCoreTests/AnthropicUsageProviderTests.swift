import Foundation
import Testing
@testable import LimitBarCore

@Suite("Anthropic usage provider")
struct AnthropicUsageProviderTests {
    @Test("validation sends bounded Admin usage request and returns connected")
    func validationRequest() async throws {
        let http = UsageProviderRecordingHTTPClient(response: HTTPResponse(statusCode: 200, data: Data(#"{"data":[]}"#.utf8)))
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
        #expect(request.url.absoluteString.contains("group_by%5B%5D=model"))
        #expect(request.url.absoluteString.contains("bucket_width=1m"))
        #expect(!String(describing: outcome).contains("super-secret-value"))
    }

    @Test("validation maps HTTP and transport failures to safe reasons", arguments: [
        (401, ProviderFailureReason.authenticationRejected),
        (403, ProviderFailureReason.insufficientPermissions),
        (500, ProviderFailureReason.refreshFailed)
    ])
    func validationStatus(status: Int, reason: ProviderFailureReason) async {
        let http = UsageProviderRecordingHTTPClient(response: HTTPResponse(statusCode: status, data: Data("raw-secret-response".utf8)))
        let client = AnthropicAdminClient(httpClient: http)

        let outcome = await client.validate(apiKey: "secret", interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60))

        #expect(outcome == .failed(reason))
        #expect(!String(describing: outcome).contains("raw-secret-response"))
    }

    @Test("validation maps transport errors safely")
    func validationTransportError() async {
        let client = AnthropicAdminClient(httpClient: UsageProviderRecordingHTTPClient(error: TestHTTPError.failed))

        let outcome = await client.validate(apiKey: "secret", interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60))

        #expect(outcome == .failed(.networkUnavailable))
    }

    @Test("cancellation is not reported as an Anthropic provider failure")
    func cancellationIsTyped() async {
        let client = AnthropicAdminClient(httpClient: UsageProviderRecordingHTTPClient(error: CancellationError()))
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60)

        #expect(await client.validate(apiKey: "secret", interval: interval) == .cancelled)
        #expect(await client.fetchUsage(apiKey: "secret", interval: interval, now: Date(timeIntervalSince1970: 30), calendar: .current) == .cancelled)
    }

    @Test("fixture mapping preserves returned labels tokens costs and limits")
    func fixtureMapping() throws {
        let data = Data(#"""
        {
          "data": [{
            "starting_at": "2026-07-10T10:00:00Z",
            "ending_at": "2026-07-10T11:00:00Z",
            "results": [
              {"model":"Claude Sonnet","uncached_input_tokens":10,"cache_creation":{"ephemeral_1h_input_tokens":1,"ephemeral_5m_input_tokens":2},"cache_read_input_tokens":3,"output_tokens":5},
              {"dimension_label":"Cloud Design","input_tokens":7,"output_tokens":4,"limit_used":11,"limit_value":100}
            ]
          }]
        }
        """#.utf8)

        let metrics = try AnthropicUsageMapper.metrics(from: data, now: try date("2026-07-10T18:00:00Z"), calendar: utcCalendar())
        let today = metrics.filter { $0.timeWindow == .today }
        let sonnet = try #require(today.first { $0.modelLabel == "Claude Sonnet" })
        let cloudDesign = try #require(today.first { $0.modelLabel == "Cloud Design" })

        #expect(today.count == 2)
        #expect(sonnet.tokenUsage == TokenUsage(inputTokens: 16, outputTokens: 5))
        #expect(sonnet.cost == nil)
        #expect(sonnet.limitStatus == .unsupportedByProviderAPI)
        #expect(cloudDesign.tokenUsage == TokenUsage(inputTokens: 7, outputTokens: 4))
        #expect(cloudDesign.limitStatus == .confirmed(used: 11, limit: 100))
        #expect(metrics.filter { $0.timeWindow == .currentWeek }.count == 2)
        #expect(metrics.allSatisfy { $0.provenance.source == .providerAPI })
        #expect(metrics.allSatisfy { $0.provenance.exactWindow?.basis == .localCalendar })
    }

    @Test("cost report uses UTC billing week in a non-UTC calendar")
    func costReportUsesUTCBillingWeek() throws {
        let data = Data(#"{"data":[{"starting_at":"2026-07-06T00:00:00Z","ending_at":"2026-07-07T00:00:00Z","results":[{"description":"Claude API Usage","amount":"100","currency":"USD"}]}]}"#.utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try date("2026-07-06T01:00:00Z")
        let expected = try CurrentUsageWindows.resolve(at: now, calendar: calendar).utcBillingWeek

        let metrics = try AnthropicCostMapper.metrics(from: data, now: now, calendar: calendar)

        #expect(metrics.count == 1)
        #expect(metrics.first?.provenance == .bounded(source: .providerAPI, window: expected))
        #expect(metrics.first?.timeWindow == .currentWeek)
    }

    @Test("cost report maps returned descriptions and cents")
    func costReportMapping() throws {
        let data = Data(#"{"data":[{"starting_at":"2026-07-10T00:00:00Z","ending_at":"2026-07-10T12:00:00Z","results":[{"description":"Claude API Usage","amount":"125","currency":"USD"}]},{"starting_at":"2026-07-10T12:00:00Z","ending_at":"2026-07-11T00:00:00Z","results":[{"description":"Claude API Usage","amount":"75","currency":"USD"}]}]}"#.utf8)

        let metrics = try AnthropicCostMapper.metrics(from: data, now: try date("2026-07-10T18:00:00Z"), calendar: utcCalendar())
        let metric = try #require(metrics.first { $0.provenance.exactWindow?.basis == .utcBilling })
        let expectedAmount = try #require(Decimal(string: "2.00"))

        #expect(metric.modelLabel == "Claude API Usage")
        #expect(metric.tokenUsage == TokenUsage(inputTokens: 0, outputTokens: 0))
        #expect(metric.cost == Cost(amount: expectedAmount, currencyCode: "USD", source: .providerReported))
    }

    @Test("cost report skips negative and non-finite amounts")
    func costReportRejectsInvalidAmounts() throws {
        let windows = try CurrentUsageWindows.resolve(at: try date("2026-07-10T18:00:00Z"), calendar: utcCalendar())
        let rows = [
            AnthropicCostMapper.Row(description: "negative", amount: "-1", currency: "USD"),
            AnthropicCostMapper.Row(description: "nan", amount: "NaN", currency: "USD")
        ]
        let bucket = AnthropicCostMapper.Bucket(
            startingAt: "2026-07-10T00:00:00Z",
            endingAt: "2026-07-10T01:00:00Z",
            results: rows
        )

        #expect(try AnthropicCostMapper.metrics(from: [bucket], windows: windows).isEmpty)
    }

    @Test("usage fetch follows pagination")
    func usageFetchFollowsPagination() async {
        let first = HTTPResponse(statusCode: 200, data: Data(#"{"data":[],"has_more":true,"next_page":"page-2"}"#.utf8))
        let second = HTTPResponse(statusCode: 200, data: Data(#"{"data":[],"has_more":false,"next_page":null}"#.utf8))
        let http = UsageProviderRecordingHTTPClient(responses: [first, second])
        let client = AnthropicAdminClient(httpClient: http)

        let result = await client.fetchUsage(apiKey: "secret", interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60), now: Date(timeIntervalSince1970: 30), calendar: .current)
        let requests = await http.requests

        #expect(result == .success([]))
        #expect(requests.count == 2)
        #expect(requests[1].url.absoluteString.contains("page=page-2"))
    }

    @Test("pagination rejects a repeated token on every Anthropic endpoint", arguments: UsageProviderEndpoint.allCases)
    func paginationRejectsRepeatedToken(endpoint: UsageProviderEndpoint) async {
        let page = HTTPResponse(statusCode: 200, data: Data(#"{"data":[],"has_more":true,"next_page":"same"}"#.utf8))
        let http = UsageProviderRecordingHTTPClient(responses: [page, page])

        let result = await fetch(endpoint, client: AnthropicAdminClient(httpClient: http))

        #expect(result == .failure(.refreshFailed))
        #expect(await http.requests.count == 2)
    }

    @Test("pagination rejects a missing token on every Anthropic endpoint", arguments: UsageProviderEndpoint.allCases)
    func paginationRejectsMissingToken(endpoint: UsageProviderEndpoint) async {
        let page = HTTPResponse(statusCode: 200, data: Data(#"{"data":[],"has_more":true,"next_page":null}"#.utf8))
        let http = UsageProviderRecordingHTTPClient(response: page)

        let result = await fetch(endpoint, client: AnthropicAdminClient(httpClient: http))

        #expect(result == .failure(.refreshFailed))
        #expect(await http.requests.count == 1)
    }

    @Test("pagination permits at most 100 pages including the initial Anthropic request", arguments: UsageProviderEndpoint.allCases)
    func paginationIsBounded(endpoint: UsageProviderEndpoint) async {
        let responses = (1...100).map { index in
            HTTPResponse(statusCode: 200, data: Data("{\"data\":[],\"has_more\":true,\"next_page\":\"page-\(index)\"}".utf8))
        }
        let http = UsageProviderRecordingHTTPClient(responses: responses)

        let result = await fetch(endpoint, client: AnthropicAdminClient(httpClient: http))

        #expect(result == .failure(.refreshFailed))
        #expect(await http.requests.count == 100)
    }

    @Test("cost fetch groups descriptions and follows pagination")
    func costFetchFollowsPagination() async {
        let first = HTTPResponse(statusCode: 200, data: Data(#"{"data":[],"has_more":true,"next_page":"cost-2"}"#.utf8))
        let second = HTTPResponse(statusCode: 200, data: Data(#"{"data":[],"has_more":false,"next_page":null}"#.utf8))
        let http = UsageProviderRecordingHTTPClient(responses: [first, second])
        let client = AnthropicAdminClient(httpClient: http)

        let result = await client.fetchCost(apiKey: "secret", interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60), now: Date(timeIntervalSince1970: 30), calendar: .current)
        let requests = await http.requests

        #expect(result == .success([]))
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString.contains("group_by%5B%5D=description"))
        #expect(requests[1].url.absoluteString.contains("page=cost-2"))
    }

    @Test("cost fetch requests the immutable UTC billing week")
    func costFetchRequestsUTCBillingWeek() async throws {
        let http = UsageProviderRecordingHTTPClient(response: HTTPResponse(statusCode: 200, data: Data(#"{"data":[]}"#.utf8)))
        let client = AnthropicAdminClient(httpClient: http)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let windows = try CurrentUsageWindows.resolve(at: try date("2026-07-06T01:00:00Z"), calendar: calendar)

        let now = try date("2026-07-08T12:34:56Z")
        _ = await client.fetchCost(apiKey: "secret", windows: windows, now: now)
        let request = try #require(await http.lastRequest)
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(query.first { $0.name == "starting_at" }?.value == "2026-07-06T00:00:00Z")
        #expect(query.first { $0.name == "ending_at" }?.value == "2026-07-08T12:34:56Z")
    }

    @Test("usage fetch ends at now while retaining the full exact window")
    func usageFetchEndsAtNow() async throws {
        let response = Data(#"{"data":[{"starting_at":"2026-07-08T10:00:00Z","ending_at":"2026-07-08T11:00:00Z","results":[{"model":"claude","input_tokens":1,"output_tokens":1}]}]}"#.utf8)
        let http = UsageProviderRecordingHTTPClient(response: HTTPResponse(statusCode: 200, data: response))
        let client = AnthropicAdminClient(httpClient: http)
        let now = try date("2026-07-08T12:34:56Z")
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: utcCalendar())

        let result = await client.fetchUsage(apiKey: "secret", windows: windows, now: now)
        let request = try #require(await http.lastRequest)
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        guard case let .success(metrics) = result else { Issue.record("Expected success"); return }

        #expect(query.first { $0.name == "ending_at" }?.value == "2026-07-08T12:34:56Z")
        #expect(metrics.first?.provenance.exactWindow == windows.today || metrics.first?.provenance.exactWindow == windows.currentWeek)
    }

    @Test("fixture mapping does not invent missing labels")
    func fixtureMappingRejectsUnlabeledRows() throws {
        let data = Data(#"{"data":[{"starting_at":"2026-07-10T10:00:00Z","ending_at":"2026-07-10T11:00:00Z","results":[{"input_tokens":1,"output_tokens":2}]}]}"#.utf8)

        let metrics = try AnthropicUsageMapper.metrics(from: data, now: try date("2026-07-10T18:00:00Z"), calendar: utcCalendar())

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

    @Test("usage success with cost failure replaces usage and preserves prior cost")
    func usageSuccessCostFailurePersistsPartialOutcome() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let now = try date("2026-07-10T18:00:00Z")
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: utcCalendar())
        let oldUsage = boundedMetric(provider: .anthropic, model: "old usage", window: windows.today, cost: nil)
        let oldCost = boundedMetric(provider: .anthropic, model: "old cost", window: windows.utcBillingWeek, cost: Cost(amount: 3, currencyCode: "USD", source: .providerReported))
        let priorWindow = try ExactUsageWindow(timeWindow: .currentWeek, start: windows.utcBillingWeek.start.addingTimeInterval(-604_800), end: windows.utcBillingWeek.end.addingTimeInterval(-604_800), basis: .utcBilling)
        let priorCost = boundedMetric(provider: .anthropic, model: "prior cost", window: priorWindow, cost: Cost(amount: 2, currencyCode: "USD", source: .providerReported))
        let freshUsage = boundedMetric(provider: .anthropic, model: "fresh usage", window: windows.today, cost: nil)
        try store.save([oldUsage, oldCost, priorCost])

        let diagnostic = try AnthropicRefreshPersistence.apply(
            AnthropicRefreshBatch(usage: .success([freshUsage]), cost: .failure(.networkUnavailable)),
            to: store,
            windows: windows,
            now: now
        )
        let rows = try store.allMetrics()
        let retainedCost = try #require(rows.first { $0.modelLabel == "old cost" })
        let untouchedPriorCost = try #require(rows.first { $0.modelLabel == "prior cost" })

        #expect(rows.contains(freshUsage))
        #expect(retainedCost.freshness == .stale(missedRefreshes: 2))
        #expect(untouchedPriorCost.freshness == .fresh)
        #expect(!rows.contains(oldUsage))
        #expect(diagnostic.state == .connected)
        #expect(diagnostic.failureReason == .networkUnavailable)
    }

    @Test("cost success with usage failure updates cost and stales retained usage")
    func costSuccessUsageFailurePersistsPartialOutcome() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let now = try date("2026-07-10T18:00:00Z")
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: utcCalendar())
        let oldUsage = boundedMetric(provider: .anthropic, model: "old usage", window: windows.today, cost: nil)
        let oldCost = boundedMetric(provider: .anthropic, model: "old cost", window: windows.utcBillingWeek, cost: Cost(amount: 3, currencyCode: "USD", source: .providerReported))
        let freshCost = boundedMetric(provider: .anthropic, model: "fresh cost", window: windows.utcBillingWeek, cost: Cost(amount: 4, currencyCode: "USD", source: .providerReported))
        try store.save([oldUsage, oldCost])

        _ = try AnthropicRefreshPersistence.apply(
            AnthropicRefreshBatch(usage: .failure(.networkUnavailable), cost: .success([freshCost])),
            to: store,
            windows: windows,
            now: now
        )
        let rows = try store.allMetrics()
        let retainedUsage = try #require(rows.first { $0.modelLabel == "old usage" })

        #expect(retainedUsage.freshness == .stale(missedRefreshes: 2))
        #expect(rows.contains(freshCost))
        #expect(!rows.contains(oldCost))
    }

    @Test("cancelled Anthropic persistence preserves rows and returns cancelled")
    func cancelledPersistencePreservesRows() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let retained = metric(provider: .anthropic, model: "retained")
        try store.save([retained])

        let diagnostic = try AnthropicRefreshPersistence.apply(.cancelled, to: store)

        #expect(try store.allMetrics() == [retained])
        #expect(diagnostic.state == .cancelled)
        #expect(diagnostic.failureReason == nil)
    }

    @Test("fully cancelled Anthropic batch preserves rows and returns cancelled")
    func cancelledBatchPreservesRows() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let now = try date("2026-07-10T18:00:00Z")
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: utcCalendar())
        let retained = boundedMetric(provider: .anthropic, model: "retained", window: windows.today, cost: nil)
        try store.save([retained])
        let initializedBefore = try store.hasInitializedMetrics()

        let diagnostic = try AnthropicRefreshPersistence.apply(
            AnthropicRefreshBatch(usage: .cancelled, cost: .cancelled),
            to: store,
            windows: windows,
            now: now
        )

        #expect(try store.allMetrics() == [retained])
        #expect(try store.hasInitializedMetrics() == initializedBefore)
        #expect(diagnostic.state == .cancelled)
    }

    @Test("generic confirmed limits reject non-finite or negative ratios")
    func invalidConfirmedLimitsAreSkipped() throws {
        let data = Data(#"{"data":[{"starting_at":"2026-07-10T10:00:00Z","ending_at":"2026-07-10T11:00:00Z","results":[{"model":"bad","input_tokens":1,"output_tokens":1,"limit_used":-1,"limit_value":100},{"model":"valid-overage","input_tokens":1,"output_tokens":1,"limit_used":120,"limit_value":100}]}]}"#.utf8)

        let metrics = try AnthropicUsageMapper.metrics(from: data, now: try date("2026-07-10T18:00:00Z"), calendar: utcCalendar())

        #expect(metrics.filter { $0.modelLabel == "bad" }.allSatisfy { $0.limitStatus == .unsupportedByProviderAPI })
        #expect(metrics.filter { $0.modelLabel == "valid-overage" }.allSatisfy { $0.limitStatus == .confirmed(used: 120, limit: 100) })
        #expect(LimitStatus.confirmed(used: .nan, limit: 100).confirmedUsageRatio == nil)
        #expect(LimitStatus.confirmed(used: 1, limit: .infinity).confirmedUsageRatio == nil)
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

    private func boundedMetric(provider: ProviderKind, model: String, window: ExactUsageWindow, cost: Cost?) -> UsageMetric {
        UsageMetric(provider: provider, accountLabel: nil, projectLabel: nil, modelLabel: model, deploymentLabel: nil, provenance: .bounded(source: .providerAPI, window: window), tokenUsage: TokenUsage(inputTokens: cost == nil ? 1 : 0, outputTokens: 0), cost: cost, limitStatus: .unsupportedByProviderAPI, refreshedAt: window.start, freshness: .fresh)
    }

    private func fetch(_ endpoint: UsageProviderEndpoint, client: AnthropicAdminClient) async -> AnthropicRefreshResult {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60)
        switch endpoint {
        case .usage:
            return await client.fetchUsage(apiKey: "secret", interval: interval, now: Date(timeIntervalSince1970: 30), calendar: .current)
        case .cost:
            return await client.fetchCost(apiKey: "secret", interval: interval, now: Date(timeIntervalSince1970: 30), calendar: .current)
        }
    }

}

func date(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
}

func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    calendar.firstWeekday = 2
    return calendar
}

actor UsageProviderRecordingHTTPClient: HTTPClient {
    private var responses: [HTTPResponse]
    private let error: Error?
    private(set) var requests: [HTTPRequest] = []

    var lastRequest: HTTPRequest? { requests.last }

    init(response: HTTPResponse) {
        responses = [response]
        error = nil
    }

    init(responses: [HTTPResponse]) {
        self.responses = responses
        error = nil
    }

    init(error: Error) {
        responses = []
        self.error = error
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if let error { throw error }
        return responses.removeFirst()
    }
}

private enum TestHTTPError: Error {
    case failed
}
