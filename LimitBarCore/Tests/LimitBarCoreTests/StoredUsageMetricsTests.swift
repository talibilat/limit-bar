import Foundation
import Testing
@testable import LimitBarCore

@Suite("Stored usage metrics")
struct StoredUsageMetricsTests {
    @Test("loads seeded demo metrics into an empty store")
    func loadsSeededDemoMetricsIntoAnEmptyStore() throws {
        let store = try SQLiteUsageMetricStore.inMemory()

        let snapshot = try StoredUsageMetrics.load(from: store)

        #expect(snapshot.metrics == DemoUsageData.metrics)
        #expect(try store.allMetrics() == DemoUsageData.metrics)
        #expect(snapshot.health.isOpen)
    }

    @Test("does not duplicate seed metrics on repeated loads")
    func doesNotDuplicateSeedMetricsOnRepeatedLoads() throws {
        let store = try SQLiteUsageMetricStore.inMemory()

        _ = try StoredUsageMetrics.load(from: store)
        let second = try StoredUsageMetrics.load(from: store)

        #expect(second.metrics.count == DemoUsageData.metrics.count)
        #expect(try store.allMetrics().count == DemoUsageData.metrics.count)
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
