import Foundation

enum ProviderCostRefreshPersistence {
    static func markFailed(
        provider: ProviderKind,
        in store: SQLiteUsageMetricStore,
        window: ExactUsageWindow
    ) throws {
        try store.markMetricsStale(
            in: UsageReplacementScope(provider: provider, source: .providerAPI, windows: [window]),
            missedRefreshes: 2
        )
    }
}
