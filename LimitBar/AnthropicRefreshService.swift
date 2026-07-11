import Foundation
import LimitBarCore

struct URLSessionHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return HTTPResponse(statusCode: response.statusCode, data: data)
    }
}

struct AnthropicRefreshService {
    private let client = AnthropicAdminClient(httpClient: URLSessionHTTPClient())

    func fetch(apiKey: String) async -> AnthropicRefreshResult {
        let now = Date()
        let calendar = Calendar.current
        let interval = TimeWindow.currentWeek.interval(containing: now, calendar: calendar)
        let usageResult = await client.fetchUsage(apiKey: apiKey, interval: interval, now: now, calendar: calendar)
        let result: AnthropicRefreshResult
        switch usageResult {
        case let .success(usageMetrics):
            let costResult = await client.fetchCost(apiKey: apiKey, interval: interval, now: now, calendar: calendar)
            if case let .success(costMetrics) = costResult {
                result = .success(usageMetrics + costMetrics)
            } else {
                result = .success(usageMetrics)
            }
        case let .failure(reason):
            result = .failure(reason)
        }
        return result
    }

    func apply(_ result: AnthropicRefreshResult) -> ProviderDiagnostic {
        do {
            let store = try SQLiteUsageMetricStore.applicationSupportStore()
            return try AnthropicRefreshPersistence.apply(result, to: store)
        } catch {
            return ProviderDiagnostic(provider: .anthropic, state: .failed, failureReason: .refreshFailed, updatedAt: Date())
        }
    }
}
