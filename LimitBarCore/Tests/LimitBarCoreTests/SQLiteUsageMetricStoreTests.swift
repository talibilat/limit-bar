import Foundation
import Testing
@testable import LimitBarCore

@Suite("SQLite usage metric store")
struct SQLiteUsageMetricStoreTests {
    @Test("saves and queries normalized metrics by time window")
    func savesAndQueriesNormalizedMetricsByTimeWindow() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let today = metric(provider: .anthropic, timeWindow: .today, modelLabel: "Claude Sonnet")
        let week = metric(provider: .openAI, timeWindow: .currentWeek, modelLabel: "gpt-5.1-codex")

        try store.save([today, week])

        #expect(try store.metrics(for: .today) == [today])
        #expect(try store.metrics(for: .currentWeek) == [week])
    }

    @Test("queries metrics across all providers")
    func queriesMetricsAcrossAllProviders() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let metrics = [
            metric(provider: .anthropic, timeWindow: .today, modelLabel: "Claude Sonnet"),
            metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "gpt-4.1"),
            metric(provider: .openAI, timeWindow: .today, modelLabel: "gpt-5.1-codex")
        ]

        try store.save(metrics)

        #expect(try store.allMetrics() == metrics)
    }

    @Test("deletes metrics older than retention cutoff")
    func deletesMetricsOlderThanRetentionCutoff() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let old = metric(provider: .anthropic, timeWindow: .today, modelLabel: "old", refreshedAt: Date(timeIntervalSince1970: 100))
        let current = metric(provider: .anthropic, timeWindow: .today, modelLabel: "current", refreshedAt: Date(timeIntervalSince1970: 1_000))

        try store.save([old, current])
        let deleted = try store.deleteMetrics(olderThan: Date(timeIntervalSince1970: 500))

        #expect(deleted == 1)
        #expect(try store.allMetrics() == [current])
    }

    @Test("refresh failure retains values and marks metrics stale")
    func refreshFailureRetainsValuesAndMarksMetricsStale() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let fresh = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "gpt-4.1", freshness: .fresh)

        try store.save([fresh])
        try store.markMetricsStale(timeWindow: .today, missedRefreshes: 2)

        let retained = try #require(try store.metrics(for: .today).first)
        #expect(retained.tokenUsage == fresh.tokenUsage)
        #expect(retained.limitStatus == fresh.limitStatus)
        #expect(retained.freshness == .stale(missedRefreshes: 2))
    }

    @Test("schema stores normalized fields and excludes sensitive fields")
    func schemaStoresNormalizedFieldsAndExcludesSensitiveFields() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let columns = try store.schemaColumnNames()

        #expect(columns.isSuperset(of: ["provider", "time_window", "model_label", "input_tokens", "output_tokens", "limit_status", "freshness_status"]))
        #expect(!columns.contains("prompt"))
        #expect(!columns.contains("response"))
        #expect(!columns.contains("raw_provider_response"))
        #expect(!columns.contains("request_body"))
        #expect(!columns.contains("terminal_output"))
        #expect(!columns.contains("source_code"))
        #expect(!columns.contains("api_key"))
        #expect(!columns.contains("access_token"))
        #expect(!columns.contains("refresh_token"))
    }

    @Test("health reports open database")
    func healthReportsOpenDatabase() throws {
        let store = try SQLiteUsageMetricStore.inMemory()

        #expect(store.health().isOpen)
        #expect(store.health().message == "SQLite store opened")
    }

    private func metric(
        provider: ProviderKind,
        timeWindow: TimeWindow,
        modelLabel: String,
        refreshedAt: Date = Date(timeIntervalSince1970: 1_783_728_000),
        freshness: Freshness = .fresh
    ) -> UsageMetric {
        UsageMetric(
            provider: provider,
            accountLabel: "Account",
            projectLabel: "Project",
            modelLabel: modelLabel,
            deploymentLabel: provider == .azureOpenAI ? "deployment" : nil,
            timeWindow: timeWindow,
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 5),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: refreshedAt,
            freshness: freshness
        )
    }
}
