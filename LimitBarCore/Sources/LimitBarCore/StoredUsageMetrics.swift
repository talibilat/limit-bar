import Foundation

public struct StoredUsageMetricsSnapshot: Equatable, Sendable {
    public let metrics: [UsageMetric]
    public let health: UsageStoreHealth
}

public enum StoredUsageMetrics {
    public static func load(from store: SQLiteUsageMetricStore, now: Date = Date()) throws -> StoredUsageMetricsSnapshot {
        try store.deleteMetrics(olderThan: now.addingTimeInterval(-(90 * 24 * 60 * 60)))

        if try store.allMetrics().isEmpty {
            try store.save(DemoUsageData.metrics)
        }

        return StoredUsageMetricsSnapshot(metrics: try store.allMetrics(), health: store.health())
    }

    public static func loadFromApplicationSupport(fileManager: FileManager = .default) -> StoredUsageMetricsSnapshot {
        do {
            let store = try SQLiteUsageMetricStore.applicationSupportStore(fileManager: fileManager)
            return try load(from: store)
        } catch {
            return StoredUsageMetricsSnapshot(
                metrics: DemoUsageData.metrics,
                health: UsageStoreHealth(isOpen: false, message: "SQLite store unavailable")
            )
        }
    }
}
