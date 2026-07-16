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

    @Test("cancellation is not reported as an OpenAI provider failure")
    func cancellationIsTyped() async {
        let client = OpenAIOrganizationClient(httpClient: OpenAIRecordingHTTPClient(error: CancellationError()))
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60)

        #expect(await client.validateOAuth(accessToken: "secret", interval: interval) == .cancelled)
        #expect(await client.fetchUsage(credential: "secret", organization: "org", interval: interval, now: Date(timeIntervalSince1970: 30), calendar: .current) == .cancelled)
    }

    @Test("usage fixture maps explicit organization project and model identity")
    func usageMapping() throws {
        let data = Data(#"{"data":[{"start_time":1783687200,"end_time":1783690800,"results":[{"project_id":"proj_1","project_name":"Codex Enterprise","model":"gpt-5.1-codex","input_tokens":10,"cached_input_tokens":2,"output_tokens":4}]}]}"#.utf8)

        let metrics = try OpenAIUsageMapper.metrics(from: data, organization: "org_123", now: Date(timeIntervalSince1970: 1_783_716_000), calendar: gregorianGMTCalendar())
        let metric = try #require(metrics.first { $0.timeWindow == .today })

        #expect(metric.accountLabel == "org_123")
        #expect(metric.projectLabel == "Codex Enterprise")
        #expect(metric.modelLabel == "gpt-5.1-codex")
        #expect(metric.tokenUsage == TokenUsage(inputTokens: 10, outputTokens: 4))
        #expect(metric.limitStatus == .unsupportedByProviderAPI)
        #expect(metric.provenance.source == .providerAPI)
        #expect(metric.provenance.exactWindow?.basis == .localCalendar)
    }

    @Test("cost mapping uses UTC billing week instead of local Today")
    func costMappingUsesUTCBillingWeek() throws {
        let data = Data(#"{"data":[{"start_time":1783296000,"end_time":1783382400,"results":[{"project_id":"proj_1","line_item":"Completions","amount":{"value":1.25,"currency":"usd"}}]}]}"#.utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = Date(timeIntervalSince1970: 1_783_303_200)
        let expected = try CurrentUsageWindows.resolve(at: now, calendar: calendar).utcBillingWeek

        let metrics = try OpenAICostMapper.metrics(from: data, organization: "org", now: now, calendar: calendar)

        #expect(metrics.count == 1)
        #expect(metrics.first?.provenance == .bounded(source: .providerAPI, window: expected))
        #expect(metrics.first?.timeWindow == .currentWeek)
    }

    @Test("usage fixture rejects missing identity")
    func usageMappingRejectsMissingIdentity() throws {
        let data = Data(#"{"data":[{"start_time":1783687200,"end_time":1783690800,"results":[{"project_id":null,"model":"gpt","input_tokens":1,"output_tokens":1}]}]}"#.utf8)
        #expect(try OpenAIUsageMapper.metrics(from: data, organization: "org", now: Date(timeIntervalSince1970: 1_783_728_000), calendar: gregorianGMTCalendar()).isEmpty)
        #expect(try OpenAIUsageMapper.metrics(from: data, organization: "", now: Date(timeIntervalSince1970: 1_783_728_000), calendar: gregorianGMTCalendar()).isEmpty)
    }

    @Test("cost fixture maps provider-reported project spend")
    func costMapping() throws {
        let data = Data(#"{"data":[{"start_time":1783641600,"end_time":1783684800,"results":[{"project_id":"proj_1","line_item":"Completions","amount":{"value":1.25,"currency":"usd"}},{"project_id":"proj_1","line_item":"Ignored","amount":null}]},{"start_time":1783684800,"end_time":1783728000,"results":[{"project_id":"proj_1","line_item":"Completions","amount":{"value":0.75,"currency":"usd"}}]}]}"#.utf8)

        let metrics = try OpenAICostMapper.metrics(from: data, organization: "org_123", now: Date(timeIntervalSince1970: 1_783_716_000), calendar: gregorianGMTCalendar())
        let metric = try #require(metrics.first { $0.provenance.exactWindow?.basis == .utcBilling })
        let expectedAmount = try #require(Decimal(string: "2.00"))

        #expect(metric.accountLabel == "org_123")
        #expect(metric.projectLabel == "proj_1")
        #expect(metric.modelLabel == "Completions")
        #expect(metric.cost == Cost(amount: expectedAmount, currencyCode: "USD", source: .providerReported))
    }

    @Test("multi-currency cost rows persist independently")
    func multiCurrencyCostsPersistIndependently() throws {
        let data = Data(#"{"data":[{"start_time":1783641600,"end_time":1783728000,"results":[{"project_id":"proj_1","line_item":"Completions","amount":{"value":1.25,"currency":"usd"}},{"project_id":"proj_1","line_item":"Completions","amount":{"value":2.5,"currency":"eur"}}]}]}"#.utf8)
        let metrics = try OpenAICostMapper.metrics(from: data, organization: "org", now: Date(timeIntervalSince1970: 1_783_716_000), calendar: gregorianGMTCalendar())
        let store = try SQLiteUsageMetricStore.inMemory()

        _ = try OpenAIRefreshPersistence.apply(.success(metrics), to: store)

        #expect(try store.metrics(for: .currentWeek).count == 2)
        #expect(Set(try store.metrics(for: .currentWeek).compactMap(\.cost?.currencyCode)) == ["USD", "EUR"])
    }

    @Test("cost aggregation overflow is rejected")
    func costAggregationOverflowIsRejected() throws {
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: gregorianGMTCalendar())
        let amount = OpenAICostMapper.Amount(value: Decimal.greatestFiniteMagnitude, currency: "USD")
        let row = OpenAICostMapper.Row(projectID: "project", lineItem: "usage", amount: amount)
        let bucket = OpenAICostMapper.Bucket(
            startTime: Int(windows.utcBillingWeek.start.timeIntervalSince1970),
            endTime: Int(windows.utcBillingWeek.start.addingTimeInterval(60).timeIntervalSince1970),
            results: [row, row]
        )

        #expect(throws: OpenAIMappingError.costOverflow) {
            try OpenAICostMapper.metrics(from: [bucket], organization: "org", windows: windows)
        }
    }

    @Test("cost mapping skips negative and non-finite amounts")
    func costMappingRejectsInvalidAmounts() throws {
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: gregorianGMTCalendar())
        let rows = [
            OpenAICostMapper.Row(projectID: "project", lineItem: "negative", amount: .init(value: -1, currency: "USD")),
            OpenAICostMapper.Row(projectID: "project", lineItem: "nan", amount: .init(value: .nan, currency: "USD"))
        ]
        let bucket = OpenAICostMapper.Bucket(
            startTime: Int(windows.utcBillingWeek.start.timeIntervalSince1970),
            endTime: Int(windows.utcBillingWeek.start.addingTimeInterval(60).timeIntervalSince1970),
            results: rows
        )

        #expect(try OpenAICostMapper.metrics(from: [bucket], organization: "org", windows: windows).isEmpty)
    }

    @Test("cost fetch requests the immutable UTC billing week")
    func costFetchRequestsUTCBillingWeek() async throws {
        let http = OpenAIRecordingHTTPClient(response: HTTPResponse(statusCode: 200, data: Data(#"{"data":[]}"#.utf8)))
        let client = OpenAIOrganizationClient(httpClient: http)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let windows = try CurrentUsageWindows.resolve(at: Date(timeIntervalSince1970: 1_783_303_200), calendar: calendar)

        let now = Date(timeIntervalSince1970: 1_783_389_296)
        _ = await client.fetchCosts(credential: "secret", organization: "org", windows: windows, now: now)
        let request = try #require(await http.requests.first)
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(query.first { $0.name == "start_time" }?.value == String(Int(windows.utcBillingWeek.start.timeIntervalSince1970)))
        #expect(query.first { $0.name == "end_time" }?.value == String(Int(now.timeIntervalSince1970)))
    }

    @Test("usage fetch ends at now while retaining the full exact window")
    func usageFetchEndsAtNow() async throws {
        let response = Data(#"{"data":[{"start_time":1783526400,"end_time":1783530000,"results":[{"project_id":"proj","model":"gpt","input_tokens":1,"output_tokens":1}]}]}"#.utf8)
        let http = OpenAIRecordingHTTPClient(response: HTTPResponse(statusCode: 200, data: response))
        let client = OpenAIOrganizationClient(httpClient: http)
        let now = Date(timeIntervalSince1970: 1_783_389_296)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: gregorianGMTCalendar())

        let result = await client.fetchUsage(credential: "secret", organization: "org", windows: windows, now: now)
        let request = try #require(await http.requests.first)
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        guard case let .success(metrics) = result else { Issue.record("Expected success"); return }

        #expect(query.first { $0.name == "end_time" }?.value == String(Int(now.timeIntervalSince1970)))
        #expect(metrics.allSatisfy { $0.provenance.exactWindow == windows.today || $0.provenance.exactWindow == windows.currentWeek })
    }

    @Test("pagination rejects repeated tokens on every OpenAI endpoint", arguments: UsageProviderEndpoint.allCases)
    func paginationRejectsRepeatedTokens(endpoint: UsageProviderEndpoint) async {
        let page = HTTPResponse(statusCode: 200, data: Data(#"{"data":[],"has_more":true,"next_page":"same"}"#.utf8))
        let http = OpenAIRecordingHTTPClient(responses: [page, page])

        let result = await fetch(endpoint, client: OpenAIOrganizationClient(httpClient: http))

        #expect(result == .failure(.refreshFailed))
        #expect(await http.requests.count == 2)
    }

    @Test("pagination rejects missing tokens on every OpenAI endpoint", arguments: UsageProviderEndpoint.allCases)
    func paginationRejectsMissingTokens(endpoint: UsageProviderEndpoint) async {
        let page = HTTPResponse(statusCode: 200, data: Data(#"{"data":[],"has_more":true,"next_page":null}"#.utf8))
        let http = OpenAIRecordingHTTPClient(response: page)

        let result = await fetch(endpoint, client: OpenAIOrganizationClient(httpClient: http))

        #expect(result == .failure(.refreshFailed))
        #expect(await http.requests.count == 1)
    }

    @Test("pagination permits at most 100 pages including the initial OpenAI request", arguments: UsageProviderEndpoint.allCases)
    func paginationIsBounded(endpoint: UsageProviderEndpoint) async {
        let responses = (1...100).map { index in
            HTTPResponse(statusCode: 200, data: Data("{\"data\":[],\"has_more\":true,\"next_page\":\"page-\(index)\"}".utf8))
        }
        let http = OpenAIRecordingHTTPClient(responses: responses)

        let result = await fetch(endpoint, client: OpenAIOrganizationClient(httpClient: http))

        #expect(result == .failure(.refreshFailed))
        #expect(await http.requests.count == 100)
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

    @Test("usage success with cost failure replaces OpenAI usage and preserves prior cost")
    func usageSuccessCostFailurePersistsPartialOutcome() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: gregorianGMTCalendar())
        let oldUsage = boundedMetric(model: "old usage", window: windows.today, cost: nil)
        let oldCost = boundedMetric(model: "old cost", window: windows.utcBillingWeek, cost: Cost(amount: 3, currencyCode: "USD", source: .providerReported))
        let priorWindow = try ExactUsageWindow(timeWindow: .currentWeek, start: windows.utcBillingWeek.start.addingTimeInterval(-604_800), end: windows.utcBillingWeek.end.addingTimeInterval(-604_800), basis: .utcBilling)
        let priorCost = boundedMetric(model: "prior cost", window: priorWindow, cost: Cost(amount: 2, currencyCode: "USD", source: .providerReported))
        let freshUsage = boundedMetric(model: "fresh usage", window: windows.today, cost: nil)
        try store.save([oldUsage, oldCost, priorCost])

        let diagnostic = try OpenAIRefreshPersistence.apply(
            OpenAIRefreshBatch(usage: .success([freshUsage]), cost: .failure(.networkUnavailable)),
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

    @Test("cost success with usage failure updates OpenAI cost and stales retained usage")
    func costSuccessUsageFailurePersistsPartialOutcome() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: gregorianGMTCalendar())
        let oldUsage = boundedMetric(model: "old usage", window: windows.today, cost: nil)
        let oldCost = boundedMetric(model: "old cost", window: windows.utcBillingWeek, cost: Cost(amount: 3, currencyCode: "USD", source: .providerReported))
        let freshCost = boundedMetric(model: "fresh cost", window: windows.utcBillingWeek, cost: Cost(amount: 4, currencyCode: "USD", source: .providerReported))
        try store.save([oldUsage, oldCost])

        _ = try OpenAIRefreshPersistence.apply(
            OpenAIRefreshBatch(usage: .failure(.networkUnavailable), cost: .success([freshCost])),
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

    @Test("cancelled OpenAI persistence preserves rows and returns cancelled")
    func cancelledPersistencePreservesRows() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let retained = metric(provider: .openAI, model: "retained")
        try store.save([retained])

        let diagnostic = try OpenAIRefreshPersistence.apply(.cancelled, to: store)

        #expect(try store.allMetrics() == [retained])
        #expect(diagnostic.state == .cancelled)
        #expect(diagnostic.failureReason == nil)
    }

    @Test("fully cancelled OpenAI batch preserves rows and returns cancelled")
    func cancelledBatchPreservesRows() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: gregorianGMTCalendar())
        let retained = boundedMetric(model: "retained", window: windows.today, cost: nil)
        try store.save([retained])
        let initializedBefore = try store.hasInitializedMetrics()

        let diagnostic = try OpenAIRefreshPersistence.apply(
            OpenAIRefreshBatch(usage: .cancelled, cost: .cancelled),
            to: store,
            windows: windows,
            now: now
        )

        #expect(try store.allMetrics() == [retained])
        #expect(try store.hasInitializedMetrics() == initializedBefore)
        #expect(diagnostic.state == .cancelled)
    }

    private func metric(provider: ProviderKind, model: String) -> UsageMetric {
        UsageMetric(provider: provider, accountLabel: nil, projectLabel: nil, modelLabel: model, deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(timeIntervalSince1970: 100), freshness: .fresh)
    }

    private func boundedMetric(model: String, window: ExactUsageWindow, cost: Cost?) -> UsageMetric {
        UsageMetric(provider: .openAI, accountLabel: "org", projectLabel: nil, modelLabel: model, deploymentLabel: nil, provenance: .bounded(source: .providerAPI, window: window), tokenUsage: TokenUsage(inputTokens: cost == nil ? 1 : 0, outputTokens: 0), cost: cost, limitStatus: .unsupportedByProviderAPI, refreshedAt: window.start, freshness: .fresh)
    }

    private func fetch(_ endpoint: UsageProviderEndpoint, client: OpenAIOrganizationClient) async -> OpenAIRefreshResult {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 60)
        switch endpoint {
        case .usage:
            return await client.fetchUsage(credential: "secret", organization: "org", interval: interval, now: Date(timeIntervalSince1970: 30), calendar: .current)
        case .cost:
            return await client.fetchCosts(credential: "secret", organization: "org", interval: interval, now: Date(timeIntervalSince1970: 30), calendar: .current)
        }
    }

}

enum UsageProviderEndpoint: CaseIterable, CustomTestStringConvertible, Sendable {
    case usage
    case cost

    var testDescription: String { String(describing: self) }
}

private actor OpenAIRecordingHTTPClient: HTTPClient {
    private var responses: [HTTPResponse]
    private let error: Error?
    private(set) var requests: [HTTPRequest] = []

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
