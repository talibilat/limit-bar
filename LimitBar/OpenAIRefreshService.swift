import Foundation
import LimitBarCore

enum OpenAISettingsRefreshResult {
    case supported(OpenAIRefreshResult)
    case unsupported
    case adminRequired
    case expired
    case failure(ProviderFailureReason)
}

struct OpenAIRefreshService {
    private let client = OpenAIOrganizationClient(httpClient: URLSessionHTTPClient())

    func fetch(credential: String, organization: String, method: ProviderAuthMethod) async -> OpenAISettingsRefreshResult {
        let now = Date()
        let calendar = Calendar.current
        let interval = TimeWindow.currentWeek.interval(containing: now, calendar: calendar)
        if method == .openAIOAuth {
            switch await client.validateOAuth(accessToken: credential, interval: interval) {
            case .supported:
                break
            case .unsupported:
                return .unsupported
            case .adminCredentialRequired:
                return .adminRequired
            case .expired:
                return .expired
            case let .failed(reason):
                return .failure(reason)
            }
        }
        let usage = await client.fetchUsage(credential: credential, organization: organization, interval: interval, now: now, calendar: calendar)
        guard case let .success(usageMetrics) = usage else {
            if case let .failure(reason) = usage { return .failure(reason) }
            return .failure(.refreshFailed)
        }
        let costs = await client.fetchCosts(credential: credential, organization: organization, interval: interval, now: now, calendar: calendar)
        if case let .success(costMetrics) = costs {
            return .supported(.success(usageMetrics + costMetrics))
        }
        return .supported(.success(usageMetrics))
    }

    func apply(_ result: OpenAIRefreshResult) -> ProviderDiagnostic {
        do {
            let store = try SQLiteUsageMetricStore.applicationSupportStore()
            return try OpenAIRefreshPersistence.apply(result, to: store)
        } catch {
            return ProviderDiagnostic(provider: .openAI, state: .failed, failureReason: .refreshFailed, updatedAt: Date())
        }
    }
}
