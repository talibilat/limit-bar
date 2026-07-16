import Foundation
import LimitBarCore

enum OpenAISettingsRefreshResult {
    case supported(OpenAIRefreshBatch)
    case unsupported
    case adminRequired
    case expired
    case failure(ProviderFailureReason)
}

struct OpenAIRefreshService {
    private let client = OpenAIOrganizationClient(httpClient: URLSessionHTTPClient())

    struct Batch {
        let result: OpenAISettingsRefreshResult
        let windows: CurrentUsageWindows
        let generation: UInt64
    }

    func fetch(credential: String, organization: String, method: ProviderAuthMethod) async -> Batch? {
        let generation = await UsageDatabase.shared.providerConfigurationGeneration(for: .openAI)
        let now = Date()
        let calendar = Calendar.current
        guard let windows = try? CurrentUsageWindows.resolve(at: now, calendar: calendar) else { return nil }
        let usageInterval = DateInterval(start: windows.currentWeek.start, end: min(now, windows.currentWeek.end))
        if method == .openAIOAuth {
            let validation = await client.validateOAuth(accessToken: credential, interval: usageInterval)
            guard !Task.isCancelled else { return nil }
            switch validation {
            case .supported:
                break
            case .unsupported:
                return Batch(result: .unsupported, windows: windows, generation: generation)
            case .adminCredentialRequired:
                return Batch(result: .adminRequired, windows: windows, generation: generation)
            case .expired:
                return Batch(result: .expired, windows: windows, generation: generation)
            case let .failed(reason):
                return Batch(result: .failure(reason), windows: windows, generation: generation)
            case .cancelled:
                return nil
            }
        }
        let usage = await client.fetchUsage(credential: credential, organization: organization, windows: windows, now: now)
        guard !Task.isCancelled else { return nil }
        let costs = await client.fetchCosts(credential: credential, organization: organization, windows: windows, now: now)
        guard !Task.isCancelled else { return nil }
        return Batch(result: .supported(OpenAIRefreshBatch(usage: usage, cost: costs)), windows: windows, generation: generation)
    }

    func apply(_ result: OpenAIRefreshResult, windows: CurrentUsageWindows, generation: UInt64) async -> ProviderDiagnostic {
        await UsageDatabase.shared.applyOpenAI(result, windows: windows, expectedGeneration: generation)
    }
}
