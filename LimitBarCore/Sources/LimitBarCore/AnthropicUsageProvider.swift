import Foundation

public enum AnthropicProviderOutcome: Equatable, Sendable {
    case connected
    case failed(ProviderFailureReason)
}

public enum AnthropicRefreshResult: Equatable, Sendable {
    case success([UsageMetric])
    case failure(ProviderFailureReason)
}

public struct AnthropicAdminClient: Sendable {
    private let httpClient: any HTTPClient
    private let baseURL: URL

    public init(httpClient: any HTTPClient, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    public func validate(apiKey: String, interval: DateInterval) async -> AnthropicProviderOutcome {
        do {
            let response = try await httpClient.send(request(apiKey: apiKey, interval: interval))
            switch response.statusCode {
            case 200:
                guard (try? AnthropicUsageMapper.decode(response.data)) != nil else {
                    return .failed(.refreshFailed)
                }
                return .connected
            case 401:
                return .failed(.authenticationRejected)
            case 403:
                return .failed(.insufficientPermissions)
            default:
                return .failed(.refreshFailed)
            }
        } catch {
            return .failed(.networkUnavailable)
        }
    }

    public func fetchUsage(apiKey: String, interval: DateInterval, now: Date, calendar: Calendar) async -> AnthropicRefreshResult {
        var page: String?
        var buckets: [AnthropicUsageMapper.Bucket] = []
        do {
            repeat {
                let response = try await httpClient.send(request(apiKey: apiKey, interval: interval, page: page))
                switch response.statusCode {
                case 200:
                    let decoded = try AnthropicUsageMapper.decode(response.data)
                    buckets.append(contentsOf: decoded.data)
                    page = decoded.hasMore == true ? decoded.nextPage : nil
                case 401:
                    return .failure(.authenticationRejected)
                case 403:
                    return .failure(.insufficientPermissions)
                default:
                    return .failure(.refreshFailed)
                }
            } while page != nil
            return .success(try AnthropicUsageMapper.metrics(from: buckets, now: now, calendar: calendar))
        } catch is DecodingError {
            return .failure(.refreshFailed)
        } catch {
            return .failure(.networkUnavailable)
        }
    }

    public func fetchCost(apiKey: String, interval: DateInterval, now: Date, calendar: Calendar) async -> AnthropicRefreshResult {
        do {
            let response = try await httpClient.send(request(apiKey: apiKey, interval: interval, path: "v1/organizations/cost_report"))
            guard response.statusCode == 200 else { return .failure(.refreshFailed) }
            return .success(try AnthropicCostMapper.metrics(from: response.data, now: now, calendar: calendar))
        } catch is DecodingError {
            return .failure(.refreshFailed)
        } catch {
            return .failure(.networkUnavailable)
        }
    }

    private func request(apiKey: String, interval: DateInterval, page: String? = nil, path: String = "v1/organizations/usage_report/messages") -> HTTPRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let formatter = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: formatter.string(from: interval.start)),
            URLQueryItem(name: "ending_at", value: formatter.string(from: interval.end))
        ]
        if path.contains("usage_report") {
            components.queryItems?.append(URLQueryItem(name: "group_by[]", value: "model"))
            components.queryItems?.append(URLQueryItem(name: "bucket_width", value: "1h"))
        }
        if let page {
            components.queryItems?.append(URLQueryItem(name: "page", value: page))
        }
        return HTTPRequest(
            url: components.url!,
            method: .get,
            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        )
    }
}

public enum AnthropicUsageMapper {
    struct Response: Decodable {
        let data: [Bucket]
        let hasMore: Bool?
        let nextPage: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case nextPage = "next_page"
        }
    }

    struct Bucket: Decodable {
        let startingAt: String
        let endingAt: String
        let results: [Row]

        enum CodingKeys: String, CodingKey {
            case startingAt = "starting_at"
            case endingAt = "ending_at"
            case results
        }
    }

    struct Row: Decodable {
        let model: String?
        let dimensionLabel: String?
        let inputTokens: Int?
        let uncachedInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheCreation: CacheCreation?
        let cacheReadInputTokens: Int?
        let outputTokens: Int
        let limitUsed: Double?
        let limitValue: Double?

        enum CodingKeys: String, CodingKey {
            case model
            case dimensionLabel = "dimension_label"
            case inputTokens = "input_tokens"
            case uncachedInputTokens = "uncached_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheCreation = "cache_creation"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case outputTokens = "output_tokens"
            case limitUsed = "limit_used"
            case limitValue = "limit_value"
        }
    }

    struct CacheCreation: Decodable {
        let ephemeral1hInputTokens: Int?
        let ephemeral5mInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
            case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        }
    }

    private struct Key: Hashable {
        let window: TimeWindow
        let label: String
    }

    private struct Aggregate {
        var input = 0
        var output = 0
        var limitUsed: Double?
        var limitValue: Double?
        var latest: Date
    }

    static func decode(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    public static func metrics(from data: Data, now: Date, calendar: Calendar) throws -> [UsageMetric] {
        try metrics(from: decode(data).data, now: now, calendar: calendar)
    }

    static func metrics(from buckets: [Bucket], now: Date, calendar: Calendar) throws -> [UsageMetric] {
        let formatter = ISO8601DateFormatter()
        var aggregates: [Key: Aggregate] = [:]

        for bucket in buckets {
            guard let start = formatter.date(from: bucket.startingAt),
                  let end = formatter.date(from: bucket.endingAt) else {
                continue
            }
            for row in bucket.results {
                let label = nonempty(row.model) ?? nonempty(row.dimensionLabel)
                guard let label, row.outputTokens >= 0 else { continue }
                let inputParts = [
                    row.inputTokens ?? 0,
                    row.uncachedInputTokens ?? 0,
                    row.cacheCreationInputTokens ?? 0,
                    row.cacheCreation?.ephemeral1hInputTokens ?? 0,
                    row.cacheCreation?.ephemeral5mInputTokens ?? 0,
                    row.cacheReadInputTokens ?? 0
                ]
                guard inputParts.allSatisfy({ $0 >= 0 }) else { continue }
                let rowInput = try inputParts.reduce(0, checkedSum)

                for window in [TimeWindow.today, .currentWeek] {
                    let interval = window.interval(containing: now, calendar: calendar)
                    guard start < interval.end, end > interval.start else { continue }
                    let key = Key(window: window, label: label)
                    var aggregate = aggregates[key] ?? Aggregate(latest: end)
                    aggregate.input = try checkedSum(aggregate.input, rowInput)
                    aggregate.output = try checkedSum(aggregate.output, row.outputTokens)
                    _ = try checkedSum(aggregate.input, aggregate.output)
                    aggregate.latest = max(aggregate.latest, end)
                    if let used = row.limitUsed, let limit = row.limitValue, limit > 0 {
                        aggregate.limitUsed = (aggregate.limitUsed ?? 0) + used
                        aggregate.limitValue = limit
                    }
                    aggregates[key] = aggregate
                }
            }
        }

        return aggregates.map { key, aggregate in
            let limitStatus: LimitStatus
            if let used = aggregate.limitUsed, let limit = aggregate.limitValue {
                limitStatus = .confirmed(used: used, limit: limit)
            } else {
                limitStatus = .unsupportedByProviderAPI
            }
            return UsageMetric(
                provider: .anthropic,
                accountLabel: nil,
                projectLabel: nil,
                modelLabel: key.label,
                deploymentLabel: nil,
                timeWindow: key.window,
                tokenUsage: TokenUsage(inputTokens: aggregate.input, outputTokens: aggregate.output),
                cost: nil,
                limitStatus: limitStatus,
                refreshedAt: aggregate.latest,
                freshness: .fresh
            )
        }
        .sorted { lhs, rhs in
            let leftWindow = lhs.timeWindow == .today ? 0 : 1
            let rightWindow = rhs.timeWindow == .today ? 0 : 1
            return (leftWindow, lhs.modelLabel) < (rightWindow, rhs.modelLabel)
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw AnthropicMappingError.tokenOverflow }
        return sum
    }
}

public enum AnthropicCostMapper {
    private struct Response: Decodable { let data: [Bucket] }
    private struct Bucket: Decodable {
        let startingAt: String
        let endingAt: String
        let results: [Row]

        enum CodingKeys: String, CodingKey {
            case startingAt = "starting_at"
            case endingAt = "ending_at"
            case results
        }
    }
    private struct Row: Decodable { let description: String; let amount: String; let currency: String }
    private struct Key: Hashable { let window: TimeWindow; let label: String; let currency: String }
    private struct Aggregate { var cents: Decimal; var latest: Date }

    public static func metrics(from data: Data, now: Date, calendar: Calendar) throws -> [UsageMetric] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let formatter = ISO8601DateFormatter()
        var aggregates: [Key: Aggregate] = [:]
        for bucket in response.data {
            guard let start = formatter.date(from: bucket.startingAt), let end = formatter.date(from: bucket.endingAt) else { continue }
            for row in bucket.results {
                let label = row.description.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, let cents = Decimal(string: row.amount) else { continue }
                for window in [TimeWindow.today, .currentWeek] {
                    let interval = window.interval(containing: now, calendar: calendar)
                    guard start < interval.end, end > interval.start else { continue }
                    let key = Key(window: window, label: label, currency: row.currency)
                    var aggregate = aggregates[key] ?? Aggregate(cents: 0, latest: end)
                    aggregate.cents = try checkedAdd(aggregate.cents, cents)
                    aggregate.latest = max(aggregate.latest, end)
                    aggregates[key] = aggregate
                }
            }
        }
        let metrics = aggregates.map { key, aggregate in
            UsageMetric(
                provider: .anthropic,
                accountLabel: nil,
                projectLabel: nil,
                modelLabel: key.label,
                deploymentLabel: nil,
                timeWindow: key.window,
                tokenUsage: TokenUsage(inputTokens: 0, outputTokens: 0),
                cost: Cost(amount: aggregate.cents / 100, currencyCode: key.currency, source: .providerReported),
                limitStatus: .unsupportedByProviderAPI,
                refreshedAt: aggregate.latest,
                freshness: .fresh
            )
        }
        return metrics.sorted { lhs, rhs in
            let left = lhs.timeWindow == .today ? 0 : 1
            let right = rhs.timeWindow == .today ? 0 : 1
            return (left, lhs.modelLabel) < (right, rhs.modelLabel)
        }
    }

    private static func checkedAdd(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var lhs = lhs
        var rhs = rhs
        var result = Decimal()
        guard NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError else {
            throw AnthropicMappingError.costOverflow
        }
        return result
    }
}

public enum AnthropicMappingError: Error, Equatable {
    case tokenOverflow
    case costOverflow
}

public enum AnthropicRefreshPersistence {
    public static func apply(_ result: AnthropicRefreshResult, to store: SQLiteUsageMetricStore, now: Date = Date()) throws -> ProviderDiagnostic {
        switch result {
        case let .success(metrics):
            try store.markMetricsInitialized()
            try store.replaceMetrics(provider: .anthropic, timeWindows: [.today, .currentWeek], with: metrics)
            return ProviderDiagnostic(provider: .anthropic, state: .connected, failureReason: nil, updatedAt: now)
        case let .failure(reason):
            try store.markMetricsStale(provider: .anthropic, timeWindows: [.today, .currentWeek], missedRefreshes: 2)
            return ProviderDiagnostic(provider: .anthropic, state: .failed, failureReason: reason, updatedAt: now)
        }
    }
}
