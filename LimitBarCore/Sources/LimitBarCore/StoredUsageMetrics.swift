import Foundation

public struct StoredUsageMetricsSnapshot: Equatable, Sendable {
    public let metrics: [UsageMetric]
    public let health: UsageStoreHealth
    public let localImport: LocalUsageImportResult
    public let attributionBreakdowns: [ObservedLocalAttributionBreakdown]

    public init(
        metrics: [UsageMetric],
        health: UsageStoreHealth,
        localImport: LocalUsageImportResult,
        attributionBreakdowns: [ObservedLocalAttributionBreakdown] = []
    ) {
        self.metrics = metrics
        self.health = health
        self.localImport = localImport
        self.attributionBreakdowns = attributionBreakdowns
    }
}

public enum StoredUsageMetrics {
    public static func load(from store: SQLiteUsageMetricStore, now: Date = Date()) throws -> StoredUsageMetricsSnapshot {
        try store.deleteMetrics(olderThan: now.addingTimeInterval(-(90 * 24 * 60 * 60)))

        if try !store.hasInitializedMetrics() {
            try store.markMetricsInitialized()
        }

        return StoredUsageMetricsSnapshot(
            metrics: try store.allMetrics(),
            health: store.health(),
            localImport: .empty(fileURL: URL(fileURLWithPath: ""))
        )
    }

}
