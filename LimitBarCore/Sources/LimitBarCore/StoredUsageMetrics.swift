import Foundation

public struct StoredUsageMetricsSnapshot: Equatable, Sendable {
    public let metrics: [UsageMetric]
    public let health: UsageStoreHealth
    public let localImport: LocalUsageImportResult
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
            try store.markMetricsInitialized()
        }

        return StoredUsageMetricsSnapshot(
            metrics: try store.allMetrics(),
            health: store.health(),
            localImport: .empty(fileURL: URL(fileURLWithPath: ""))
        )
    }

    public static func loadFromApplicationSupport(fileManager: FileManager = .default) -> StoredUsageMetricsSnapshot {
        do {
            let store = try SQLiteUsageMetricStore.applicationSupportStore(fileManager: fileManager)
            try store.deleteMetrics(olderThan: Date().addingTimeInterval(-(90 * 24 * 60 * 60)))
            if try !store.hasInitializedMetrics() {
                try store.markMetricsInitialized()
            }
            let eventsURL = try LocalUsageEventImporter.usageEventsURL(fileManager: fileManager)
            let importResult: LocalUsageImportResult
            do {
                importResult = try LocalUsageEventImporter.importEvents(from: eventsURL, to: store, now: Date(), calendar: .current)
            } catch {
                importResult = .failed(fileURL: eventsURL, message: "Local usage import failed")
            }
            return StoredUsageMetricsSnapshot(metrics: try store.allMetrics(), health: store.health(), localImport: importResult)
        } catch {
            return StoredUsageMetricsSnapshot(
                metrics: [],
                health: UsageStoreHealth(isOpen: false, message: "SQLite store unavailable"),
                localImport: .empty(fileURL: URL(fileURLWithPath: ""))
            )
        }
    }
}
