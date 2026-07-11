import Foundation

public struct StoredUsageMetricsSnapshot: Equatable, Sendable {
    public let metrics: [UsageMetric]
    public let health: UsageStoreHealth
    public let azureImport: AzureUsageImportResult
}

public actor StoredUsageMetricsLoader {
    public static let shared = StoredUsageMetricsLoader()

    private init() {}

    public func loadFromApplicationSupport() -> StoredUsageMetricsSnapshot {
        StoredUsageMetrics.loadFromApplicationSupport()
    }
}

public enum StoredUsageMetrics {
    public static func load(from store: SQLiteUsageMetricStore, now: Date = Date()) throws -> StoredUsageMetricsSnapshot {
        try store.deleteMetrics(olderThan: now.addingTimeInterval(-(90 * 24 * 60 * 60)))

        if try !store.hasInitializedMetrics() {
            if try store.allMetrics().isEmpty {
                try store.save(DemoUsageData.metrics)
            }
            try store.markMetricsInitialized()
        }

        return StoredUsageMetricsSnapshot(
            metrics: try store.allMetrics(),
            health: store.health(),
            azureImport: .empty(fileURL: URL(fileURLWithPath: ""))
        )
    }

    public static func loadFromApplicationSupport(fileManager: FileManager = .default) -> StoredUsageMetricsSnapshot {
        do {
            let store = try SQLiteUsageMetricStore.applicationSupportStore(fileManager: fileManager)
            try store.deleteMetrics(olderThan: Date().addingTimeInterval(-(90 * 24 * 60 * 60)))
            if try !store.hasInitializedMetrics() {
                if try store.allMetrics().isEmpty {
                    try store.save(DemoUsageData.metrics)
                }
                try store.markMetricsInitialized()
            }
            let azureURL = try AzureUsageEventImporter.usageEventsURL(fileManager: fileManager)
            let importResult: AzureUsageImportResult
            do {
                importResult = try AzureUsageEventImporter.importEvents(from: azureURL, to: store, now: Date(), calendar: .current)
            } catch {
                importResult = .failed(fileURL: azureURL, message: "Azure JSONL import failed")
            }
            return StoredUsageMetricsSnapshot(metrics: try store.allMetrics(), health: store.health(), azureImport: importResult)
        } catch {
            return StoredUsageMetricsSnapshot(
                metrics: DemoUsageData.metrics,
                health: UsageStoreHealth(isOpen: false, message: "SQLite store unavailable"),
                azureImport: .empty(fileURL: URL(fileURLWithPath: ""))
            )
        }
    }
}
