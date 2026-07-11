import Foundation
import Testing
@testable import LimitBarCore

@Suite("Stored usage metrics")
struct StoredUsageMetricsTests {
    @Test("fresh store starts empty without demo metrics")
    func freshStoreStartsEmpty() throws {
        let store = try SQLiteUsageMetricStore.inMemory()

        let snapshot = try StoredUsageMetrics.load(from: store)

        #expect(snapshot.metrics.isEmpty)
        #expect(try store.allMetrics().isEmpty)
        #expect(snapshot.health.isOpen)
    }

    @Test("repeated fresh loads stay empty")
    func repeatedFreshLoadsStayEmpty() throws {
        let store = try SQLiteUsageMetricStore.inMemory()

        _ = try StoredUsageMetrics.load(from: store)
        let second = try StoredUsageMetrics.load(from: store)

        #expect(second.metrics.isEmpty)
        #expect(try store.allMetrics().isEmpty)
    }

    @Test("load applies ninety day retention before returning metrics")
    func loadAppliesNinetyDayRetentionBeforeReturningMetrics() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let now = Date(timeIntervalSince1970: 10_000_000)
        let old = metric(modelLabel: "old", refreshedAt: now.addingTimeInterval(-(91 * 24 * 60 * 60)))
        let retained = metric(modelLabel: "retained", refreshedAt: now)

        try store.save([old, retained])
        let snapshot = try StoredUsageMetrics.load(from: store, now: now)

        #expect(snapshot.metrics == [retained])
    }

    @Test("JSONL import failure does not hide healthy SQLite store")
    func jsonlImportFailureDoesNotHideHealthySQLiteStore() throws {
        let applicationSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = TemporaryApplicationSupportFileManager(applicationSupport: applicationSupport)
        let limitBarDirectory = applicationSupport.appendingPathComponent("LimitBar", isDirectory: true)
        try FileManager.default.createDirectory(at: limitBarDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: limitBarDirectory.appendingPathComponent("usage-events.jsonl"), withIntermediateDirectories: true)

        let snapshot = StoredUsageMetrics.loadFromApplicationSupport(fileManager: fileManager)

        #expect(snapshot.health.isOpen)
        #expect(snapshot.health.message == "SQLite store opened")
        #expect(snapshot.azureImport.failureMessage == "Azure JSONL import failed")
        #expect(snapshot.metrics.isEmpty)
    }

    @Test("JSONL import populates only confirmed Azure metrics")
    func jsonlImportPopulatesOnlyAzureMetrics() throws {
        let applicationSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = TemporaryApplicationSupportFileManager(applicationSupport: applicationSupport)
        let limitBarDirectory = applicationSupport.appendingPathComponent("LimitBar", isDirectory: true)
        try FileManager.default.createDirectory(at: limitBarDirectory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try #"{"provider":"azureOpenAI","timestamp":"\#(timestamp)","model":"imported-model","inputTokens":10,"outputTokens":5}"#
            .write(to: limitBarDirectory.appendingPathComponent("usage-events.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = StoredUsageMetrics.loadFromApplicationSupport(fileManager: fileManager)
        let azureMetrics = snapshot.metrics.filter { $0.provider == .azureOpenAI }

        #expect(!azureMetrics.isEmpty)
        #expect(azureMetrics.allSatisfy { $0.modelLabel == "imported-model" })
        #expect(!snapshot.metrics.contains { $0.provider == .anthropic })
        #expect(!snapshot.metrics.contains { $0.provider == .openAI })
    }

    @Test("initialized empty store does not reseed demo metrics")
    func initializedEmptyStoreDoesNotReseedDemoMetrics() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        _ = try StoredUsageMetrics.load(from: store)
        try store.replaceMetrics(provider: .anthropic, timeWindows: [.today, .currentWeek], with: [])
        try store.replaceMetrics(provider: .azureOpenAI, timeWindows: [.today, .currentWeek], with: [])
        try store.replaceMetrics(provider: .openAI, timeWindows: [.today, .currentWeek], with: [])

        let snapshot = try StoredUsageMetrics.load(from: store)

        #expect(snapshot.metrics.isEmpty)
    }

    private func metric(modelLabel: String, refreshedAt: Date) -> UsageMetric {
        UsageMetric(
            provider: .anthropic,
            accountLabel: "Account",
            projectLabel: nil,
            modelLabel: modelLabel,
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: refreshedAt,
            freshness: .fresh
        )
    }
}

private final class TemporaryApplicationSupportFileManager: FileManager, @unchecked Sendable {
    private let applicationSupport: URL

    init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport
        super.init()
    }

    override func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        applicationSupport
    }
}
