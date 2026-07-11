import Foundation

public enum OpenAIFeasibilityOutcome: Equatable, Sendable {
    case supported
    case unsupported
    case adminCredentialRequired
    case expired
    case failed(ProviderFailureReason)
}

public enum OpenAIRefreshResult: Equatable, Sendable {
    case success([UsageMetric])
    case failure(ProviderFailureReason)
}

public struct OpenAIOrganizationClient: Sendable {
    private let httpClient: any HTTPClient
    private let baseURL: URL

    public init(httpClient: any HTTPClient, baseURL: URL = URL(string: "https://api.openai.com")!) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    public func validateOAuth(accessToken: String, interval: DateInterval) async -> OpenAIFeasibilityOutcome {
        do {
            let response = try await httpClient.send(request(credential: accessToken, interval: interval))
            switch response.statusCode {
            case 200:
                guard (try? OpenAIUsageMapper.decode(response.data)) != nil else { return .failed(.refreshFailed) }
                return .supported
            case 401:
                return .expired
            case 403:
                return .adminCredentialRequired
            case 404:
                return .unsupported
            default:
                return .failed(.refreshFailed)
            }
        } catch {
            return .failed(.networkUnavailable)
        }
    }

    public func fetchUsage(credential: String, organization: String, interval: DateInterval, now: Date, calendar: Calendar) async -> OpenAIRefreshResult {
        var page: String?
        var buckets: [OpenAIUsageMapper.Bucket] = []
        do {
            repeat {
                let response = try await httpClient.send(request(credential: credential, interval: interval, page: page))
                switch response.statusCode {
                case 200:
                    let decoded = try OpenAIUsageMapper.decode(response.data)
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
            return .success(try OpenAIUsageMapper.metrics(from: buckets, organization: organization, now: now, calendar: calendar))
        } catch is DecodingError {
            return .failure(.refreshFailed)
        } catch {
            return .failure(.networkUnavailable)
        }
    }

    public func fetchCosts(credential: String, organization: String, interval: DateInterval, now: Date, calendar: Calendar) async -> OpenAIRefreshResult {
        var page: String?
        var buckets: [OpenAICostMapper.Bucket] = []
        do {
            repeat {
                let response = try await httpClient.send(costRequest(credential: credential, interval: interval, page: page))
                guard response.statusCode == 200 else { return .failure(.refreshFailed) }
                let decoded = try OpenAICostMapper.decode(response.data)
                buckets.append(contentsOf: decoded.data)
                page = decoded.hasMore == true ? decoded.nextPage : nil
            } while page != nil
            return .success(try OpenAICostMapper.metrics(from: buckets, organization: organization, now: now, calendar: calendar))
        } catch is DecodingError {
            return .failure(.refreshFailed)
        } catch {
            return .failure(.networkUnavailable)
        }
    }

    private func request(credential: String, interval: DateInterval, page: String? = nil) -> HTTPRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/organization/usage/completions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(interval.start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(interval.end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1m"),
            URLQueryItem(name: "group_by[]", value: "project_id"),
            URLQueryItem(name: "group_by[]", value: "model")
        ]
        if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }
        return HTTPRequest(url: components.url!, method: .get, headers: ["Authorization": "Bearer \(credential)"])
    }

    private func costRequest(credential: String, interval: DateInterval, page: String?) -> HTTPRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/organization/costs"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(interval.start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(interval.end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by[]", value: "project_id"),
            URLQueryItem(name: "group_by[]", value: "line_item")
        ]
        if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }
        return HTTPRequest(url: components.url!, method: .get, headers: ["Authorization": "Bearer \(credential)"])
    }
}

public enum OpenAIUsageMapper {
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
        let startTime: Int
        let endTime: Int
        let results: [Row]

        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case results
        }
    }

    struct Row: Decodable {
        let projectID: String?
        let projectName: String?
        let model: String?
        let inputTokens: Int
        let cachedInputTokens: Int?
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case projectName = "project_name"
            case model
            case inputTokens = "input_tokens"
            case cachedInputTokens = "input_cached_tokens"
            case outputTokens = "output_tokens"
        }
    }

    private struct Key: Hashable { let window: TimeWindow; let organization: String; let project: String; let model: String }
    private struct Aggregate { var input = 0; var output = 0; var latest: Date }

    static func decode(_ data: Data) throws -> Response { try JSONDecoder().decode(Response.self, from: data) }

    public static func metrics(from data: Data, organization: String, now: Date, calendar: Calendar) throws -> [UsageMetric] {
        try metrics(from: decode(data).data, organization: organization, now: now, calendar: calendar)
    }

    static func metrics(from buckets: [Bucket], organization: String, now: Date, calendar: Calendar) throws -> [UsageMetric] {
        let organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !organization.isEmpty else { return [] }
        var aggregates: [Key: Aggregate] = [:]
        for bucket in buckets {
            let start = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
            let end = Date(timeIntervalSince1970: TimeInterval(bucket.endTime))
            for row in bucket.results {
                let projectID = row.projectID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let projectName = row.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = row.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !projectID.isEmpty, !model.isEmpty, row.inputTokens >= 0, row.outputTokens >= 0 else { continue }
                let project = projectName?.isEmpty == false ? projectName! : projectID
                for window in [TimeWindow.today, .currentWeek] {
                    let interval = window.interval(containing: now, calendar: calendar)
                    guard start >= interval.start, end <= interval.end else { continue }
                    let key = Key(window: window, organization: organization, project: project, model: model)
                    var aggregate = aggregates[key] ?? Aggregate(latest: end)
                    aggregate.input = try checkedSum(aggregate.input, row.inputTokens)
                    aggregate.output = try checkedSum(aggregate.output, row.outputTokens)
                    _ = try checkedSum(aggregate.input, aggregate.output)
                    aggregate.latest = max(aggregate.latest, end)
                    aggregates[key] = aggregate
                }
            }
        }
        return aggregates.map { key, value in
            UsageMetric(provider: .openAI, accountLabel: key.organization, projectLabel: key.project, modelLabel: key.model, deploymentLabel: nil, timeWindow: key.window, tokenUsage: TokenUsage(inputTokens: value.input, outputTokens: value.output), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: value.latest, freshness: .fresh)
        }.sorted { ($0.timeWindow.rawValue, $0.accountLabel ?? "", $0.projectLabel ?? "", $0.modelLabel) < ($1.timeWindow.rawValue, $1.accountLabel ?? "", $1.projectLabel ?? "", $1.modelLabel) }
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw OpenAIMappingError.tokenOverflow }
        return sum
    }
}

public enum OpenAIMappingError: Error, Equatable { case tokenOverflow }

public enum OpenAICostMapper {
    struct Response: Decodable {
        let data: [Bucket]
        let hasMore: Bool?
        let nextPage: String?
        enum CodingKeys: String, CodingKey { case data; case hasMore = "has_more"; case nextPage = "next_page" }
    }
    struct Bucket: Decodable {
        let startTime: Int
        let endTime: Int
        let results: [Row]
        enum CodingKeys: String, CodingKey { case startTime = "start_time"; case endTime = "end_time"; case results }
    }
    struct Row: Decodable {
        let projectID: String?
        let lineItem: String?
        let amount: Amount?
        enum CodingKeys: String, CodingKey { case projectID = "project_id"; case lineItem = "line_item"; case amount }
    }
    struct Amount: Decodable { let value: Decimal; let currency: String }
    private struct Key: Hashable { let window: TimeWindow; let organization: String; let project: String; let lineItem: String; let currency: String }
    private struct Aggregate { var amount: Decimal; var latest: Date }

    static func decode(_ data: Data) throws -> Response { try JSONDecoder().decode(Response.self, from: data) }

    public static func metrics(from data: Data, organization: String, now: Date, calendar: Calendar) throws -> [UsageMetric] {
        try metrics(from: decode(data).data, organization: organization, now: now, calendar: calendar)
    }

    static func metrics(from buckets: [Bucket], organization: String, now: Date, calendar: Calendar) throws -> [UsageMetric] {
        let organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !organization.isEmpty else { return [] }
        var aggregates: [Key: Aggregate] = [:]
        for bucket in buckets {
            let start = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
            let end = Date(timeIntervalSince1970: TimeInterval(bucket.endTime))
            for row in bucket.results {
                let project = row.projectID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let lineItem = row.lineItem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !project.isEmpty, !lineItem.isEmpty, let amount = row.amount else { continue }
                for window in [TimeWindow.today, .currentWeek] {
                    let interval = window.interval(containing: now, calendar: calendar)
                    guard start >= interval.start, end <= interval.end else { continue }
                    let key = Key(window: window, organization: organization, project: project, lineItem: lineItem, currency: amount.currency.uppercased())
                    var aggregate = aggregates[key] ?? Aggregate(amount: 0, latest: end)
                    aggregate.amount += amount.value
                    aggregate.latest = max(aggregate.latest, end)
                    aggregates[key] = aggregate
                }
            }
        }
        return aggregates.map { key, value in
            UsageMetric(provider: .openAI, accountLabel: key.organization, projectLabel: key.project, modelLabel: key.lineItem, deploymentLabel: nil, timeWindow: key.window, tokenUsage: TokenUsage(inputTokens: 0, outputTokens: 0), cost: Cost(amount: value.amount, currencyCode: key.currency, source: .providerReported), limitStatus: .unsupportedByProviderAPI, refreshedAt: value.latest, freshness: .fresh)
        }
    }
}

public enum OpenAIRefreshPersistence {
    public static func apply(_ result: OpenAIRefreshResult, to store: SQLiteUsageMetricStore, now: Date = Date()) throws -> ProviderDiagnostic {
        switch result {
        case let .success(metrics):
            try store.markMetricsInitialized()
            try store.replaceMetrics(provider: .openAI, timeWindows: [.today, .currentWeek], with: metrics)
            return ProviderDiagnostic(provider: .openAI, state: .connected, failureReason: nil, updatedAt: now)
        case let .failure(reason):
            try store.markMetricsStale(provider: .openAI, timeWindows: [.today, .currentWeek], missedRefreshes: 2)
            return ProviderDiagnostic(provider: .openAI, state: .failed, failureReason: reason, updatedAt: now)
        }
    }
}
