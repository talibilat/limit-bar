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
        do {
            let response = try await httpClient.send(request(apiKey: apiKey, interval: interval))
            switch response.statusCode {
            case 200:
                return .success(try AnthropicUsageMapper.metrics(from: response.data, now: now, calendar: calendar))
            case 401:
                return .failure(.authenticationRejected)
            case 403:
                return .failure(.insufficientPermissions)
            default:
                return .failure(.refreshFailed)
            }
        } catch {
            return .failure(.networkUnavailable)
        }
    }

    private func request(apiKey: String, interval: DateInterval) -> HTTPRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/organizations/usage_report/messages"), resolvingAgainstBaseURL: false)!
        let formatter = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: formatter.string(from: interval.start)),
            URLQueryItem(name: "ending_at", value: formatter.string(from: interval.end))
        ]
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
    }

    struct Bucket: Decodable {
        let startingAt: String
        let endingAt: String
        let results: [Row]
    }

    struct Row: Decodable {
        let model: String?
        let dimensionLabel: String?
        let inputTokens: Int?
        let uncachedInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?
        let outputTokens: Int
        let cost: String?
        let currency: String?
        let limitUsed: Double?
        let limitValue: Double?
    }

    private struct Key: Hashable {
        let window: TimeWindow
        let label: String
    }

    private struct Aggregate {
        var input = 0
        var output = 0
        var cost: Decimal?
        var currency: String?
        var allRowsHaveCost = true
        var limitUsed: Double?
        var limitValue: Double?
        var latest: Date
    }

    static func decode(_ data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }

    public static func metrics(from data: Data, now: Date, calendar: Calendar) throws -> [UsageMetric] {
        let response = try decode(data)
        let formatter = ISO8601DateFormatter()
        var aggregates: [Key: Aggregate] = [:]

        for bucket in response.data {
            guard let start = formatter.date(from: bucket.startingAt),
                  let end = formatter.date(from: bucket.endingAt) else {
                continue
            }
            for row in bucket.results {
                let label = nonempty(row.model) ?? nonempty(row.dimensionLabel)
                guard let label, row.outputTokens >= 0 else { continue }
                let inputParts = [row.inputTokens ?? 0, row.uncachedInputTokens ?? 0, row.cacheCreationInputTokens ?? 0, row.cacheReadInputTokens ?? 0]
                guard inputParts.allSatisfy({ $0 >= 0 }) else { continue }
                let rowInput = try inputParts.reduce(0, checkedSum)

                for window in [TimeWindow.today, .currentWeek] {
                    let interval = window.interval(containing: now, calendar: calendar)
                    guard start >= interval.start, start < interval.end else { continue }
                    let key = Key(window: window, label: label)
                    var aggregate = aggregates[key] ?? Aggregate(latest: end)
                    aggregate.input = try checkedSum(aggregate.input, rowInput)
                    aggregate.output = try checkedSum(aggregate.output, row.outputTokens)
                    _ = try checkedSum(aggregate.input, aggregate.output)
                    aggregate.latest = max(aggregate.latest, end)
                    if let costText = row.cost, let rowCost = Decimal(string: costText), let currency = row.currency {
                        aggregate.cost = (aggregate.cost ?? 0) + rowCost
                        aggregate.currency = aggregate.currency ?? currency
                        if aggregate.currency != currency { aggregate.allRowsHaveCost = false }
                    } else {
                        aggregate.allRowsHaveCost = false
                    }
                    if let used = row.limitUsed, let limit = row.limitValue, limit > 0 {
                        aggregate.limitUsed = (aggregate.limitUsed ?? 0) + used
                        aggregate.limitValue = limit
                    }
                    aggregates[key] = aggregate
                }
            }
        }

        return aggregates.map { key, aggregate in
            let cost = aggregate.allRowsHaveCost ? aggregate.cost.map {
                Cost(amount: $0, currencyCode: aggregate.currency ?? "USD", source: .providerReported)
            } : nil
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
                cost: cost,
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

public enum AnthropicMappingError: Error, Equatable {
    case tokenOverflow
}

public enum AnthropicRefreshPersistence {
    public static func apply(_ result: AnthropicRefreshResult, to store: SQLiteUsageMetricStore, now: Date = Date()) throws -> ProviderDiagnostic {
        switch result {
        case let .success(metrics):
            try store.replaceMetrics(provider: .anthropic, timeWindows: [.today, .currentWeek], with: metrics)
            return ProviderDiagnostic(provider: .anthropic, state: .connected, failureReason: nil, updatedAt: now)
        case let .failure(reason):
            try store.markMetricsStale(provider: .anthropic, timeWindows: [.today, .currentWeek], missedRefreshes: 2)
            return ProviderDiagnostic(provider: .anthropic, state: .failed, failureReason: reason, updatedAt: now)
        }
    }
}
