import Foundation
import LimitBarCore

struct AnthropicRefreshService {
    private let client = AnthropicAdminClient(httpClient: URLSessionHTTPClient())

    struct Batch {
        let result: AnthropicRefreshBatch
        let windows: CurrentUsageWindows
        let generation: UInt64
    }

    func fetch(apiKey: String) async -> Batch? {
        let generation = await UsageDatabase.shared.providerConfigurationGeneration(for: .anthropic)
        let now = Date()
        let calendar = Calendar.current
        guard let windows = try? CurrentUsageWindows.resolve(at: now, calendar: calendar) else { return nil }
        let usageResult = await client.fetchUsage(apiKey: apiKey, windows: windows, now: now)
        guard !Task.isCancelled else { return nil }
        let costResult = await client.fetchCost(apiKey: apiKey, windows: windows, now: now)
        guard !Task.isCancelled else { return nil }
        return Batch(result: AnthropicRefreshBatch(usage: usageResult, cost: costResult), windows: windows, generation: generation)
    }

    func apply(_ batch: Batch) async -> ProviderDiagnostic {
        await UsageDatabase.shared.applyAnthropic(batch.result, windows: batch.windows, expectedGeneration: batch.generation)
    }
}
