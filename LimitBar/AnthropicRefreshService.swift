import Foundation
import LimitBarCore

struct AnthropicRefreshService {
    private let client = AnthropicAdminClient(httpClient: URLSessionHTTPClient())

    struct Batch {
        let result: AnthropicRefreshBatch
        let reconciliation: AnthropicSpendRefreshResult
        let windows: CurrentUsageWindows
        let generation: UInt64
    }

    func fetch(apiKey: String, workspaceAliases: SpendIdentityAliasMap, apiKeyAliases: SpendIdentityAliasMap) async -> Batch? {
        let generation = await UsageDatabase.shared.providerConfigurationGeneration(for: .anthropic)
        let now = Date()
        let calendar = Calendar.current
        guard let windows = try? CurrentUsageWindows.resolve(at: now, calendar: calendar) else { return nil }
        let usageResult = await client.fetchUsage(apiKey: apiKey, windows: windows, now: now)
        guard !Task.isCancelled else { return nil }
        let costResult = await client.fetchCost(apiKey: apiKey, windows: windows, now: now)
        guard !Task.isCancelled else { return nil }
        let policy = SpendDimensionPolicy(workspaceAliases: workspaceAliases, apiKeyAliases: apiKeyAliases)
        let reconciliation = await client.fetchSpendReconciliation(
            apiKey: apiKey,
            interval: DateInterval(start: windows.utcBillingWeek.start, end: min(now, windows.utcBillingWeek.end)),
            policy: policy
        )
        guard !Task.isCancelled else { return nil }
        return Batch(result: AnthropicRefreshBatch(usage: usageResult, cost: costResult), reconciliation: reconciliation, windows: windows, generation: generation)
    }
}
