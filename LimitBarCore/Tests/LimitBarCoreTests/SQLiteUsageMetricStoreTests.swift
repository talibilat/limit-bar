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

    @Test("saving same logical metric updates the retained row")
    func savingSameLogicalMetricUpdatesTheRetainedRow() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let first = metric(provider: .anthropic, timeWindow: .today, modelLabel: "Claude Sonnet", refreshedAt: Date(timeIntervalSince1970: 100))
        let updated = metric(provider: .anthropic, timeWindow: .today, modelLabel: "Claude Sonnet", refreshedAt: Date(timeIntervalSince1970: 200), inputTokens: 42, outputTokens: 12)

        try store.save([first])
        try store.save([updated])

        #expect(try store.allMetrics() == [updated])
    }

    @Test("round trip preserves cost and confirmed limit fields")
    func roundTripPreservesCostAndConfirmedLimitFields() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let stored = metric(
            provider: .openAI,
            timeWindow: .today,
            modelLabel: "gpt-5.1-codex",
            cost: Cost(amount: Decimal(string: "12.34")!, currencyCode: "USD", source: .providerReported),
            limitStatus: .confirmed(used: 72, limit: 100)
        )

        try store.save([stored])

        #expect(try store.metrics(for: .today) == [stored])
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

    @Test("provider replacement rejects mismatched metrics before deletion")
    func providerReplacementRejectsMismatchedMetricsBeforeDeletion() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let existing = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "existing")
        let mismatched = metric(provider: .openAI, timeWindow: .today, modelLabel: "wrong-provider")
        try store.save([existing])

        #expect(throws: UsageMetricStoreError.self) {
            try store.replaceMetrics(provider: .azureOpenAI, timeWindows: [.today], with: [mismatched])
        }

        #expect(try store.allMetrics() == [existing])
    }

    @Test("provider replacement preserves other providers")
    func providerReplacementPreservesOtherProviders() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let anthropic = metric(provider: .anthropic, timeWindow: .today, modelLabel: "claude")
        let oldAzure = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "old")
        let openAI = metric(provider: .openAI, timeWindow: .today, modelLabel: "gpt")
        let newAzure = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "new")
        try store.save([anthropic, oldAzure, openAI])

        try store.replaceMetrics(provider: .azureOpenAI, timeWindows: [.today], with: [newAzure])

        #expect(try store.allMetrics() == [anthropic, openAI, newAzure])
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
        inputTokens: Int = 10,
        outputTokens: Int = 5,
        freshness: Freshness = .fresh,
        cost: Cost? = nil,
        limitStatus: LimitStatus = .unsupportedByProviderAPI
    ) -> UsageMetric {
        UsageMetric(
            provider: provider,
            accountLabel: "Account",
            projectLabel: "Project",
            modelLabel: modelLabel,
            deploymentLabel: provider == .azureOpenAI ? "deployment" : nil,
            timeWindow: timeWindow,
            tokenUsage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens),
            cost: cost,
            limitStatus: limitStatus,
            refreshedAt: refreshedAt,
            freshness: freshness
        )
    }
}
