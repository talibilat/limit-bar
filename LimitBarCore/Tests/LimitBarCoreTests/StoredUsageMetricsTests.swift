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
}
