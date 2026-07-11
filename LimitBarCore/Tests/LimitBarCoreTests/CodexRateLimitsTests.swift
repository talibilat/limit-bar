import Foundation
import Testing
@testable import LimitBarCore

@Suite("Codex rate limits")
struct CodexRateLimitsTests {
    @Test("parses business plan with null windows and empty credits")
    func parsesBusinessPlan() throws {
        let line = #"{"timestamp":"2026-07-10T12:08:39.061Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"plan_type":"business","rate_limit_reached_type":null}}}"#

        let snapshot = try CodexRateLimitMapper.parseLine(Data(line.utf8))

        #expect(snapshot.isBusinessPlan)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.credits?.hasCredits == false)
        #expect(snapshot.credits?.balance == 0)
    }

    @Test("parses individual plan with primary and secondary windows")
    func parsesIndividualPlanWindows() throws {
        let line = #"{"timestamp":"2025-11-16T02:39:20.308Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":2.0,"window_minutes":300,"resets_at":1763263112},"secondary":{"used_percent":25.0,"window_minutes":10080,"resets_at":1763330860}}}}"#

        let snapshot = try CodexRateLimitMapper.parseLine(Data(line.utf8))

        #expect(!snapshot.isBusinessPlan)
        #expect(snapshot.primary?.percentUsed == 2.0)
        #expect(snapshot.primary?.displayLabel == "Session (5 hours)")
        #expect(snapshot.secondary?.percentUsed == 25.0)
        #expect(snapshot.secondary?.displayLabel == "Weekly")
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1763263112))
    }

    @Test("unknown window minutes fall back to a generic label")
    func unknownWindowMinutesFallBack() throws {
        let line = #"{"timestamp":"2026-01-01T00:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":60,"resets_at":100}}}}"#

        let snapshot = try CodexRateLimitMapper.parseLine(Data(line.utf8))

        #expect(snapshot.primary?.displayLabel == "60 minute window")
    }

    @Test("missing rate_limits payload throws")
    func missingRateLimitsThrows() {
        let line = #"{"timestamp":"2026-01-01T00:00:00Z","payload":{"type":"token_count","info":{}}}"#

        #expect(throws: CodexRateLimitFailure.self) {
            try CodexRateLimitMapper.parseLine(Data(line.utf8))
        }
    }

    @Test("reader picks the freshest rate_limits entry across recent session files")
    func readerPicksFreshestEntry() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let older = root.appendingPathComponent("older.jsonl")
        let newer = root.appendingPathComponent("newer.jsonl")
        try #"{"timestamp":"2026-07-01T00:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.0,"window_minutes":300,"resets_at":100},"plan_type":"plus"}}}"#
            .write(to: older, atomically: true, encoding: .utf8)
        try #"{"timestamp":"2026-07-10T00:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40.0,"window_minutes":300,"resets_at":200},"plan_type":"plus"}}}"#
            .write(to: newer, atomically: true, encoding: .utf8)

        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let snapshot = try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: root, now: now, fileManager: fileManager)

        #expect(snapshot.primary?.percentUsed == 40.0)
    }

    @Test("reader throws when nothing recent has rate limit data")
    func readerThrowsWhenNothingFound() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        #expect(throws: CodexRateLimitFailure.self) {
            try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: root, now: Date(), fileManager: fileManager)
        }
    }

    @Test("credits estimator sums only credits-currency costs per window")
    func creditsEstimatorSumsCreditsCurrency() {
        let pricing = PricingTable(entries: [
            PricingEntry(provider: .openAI, modelLabel: "gpt-5.5", inputPricePerMillionTokens: 10, outputPricePerMillionTokens: 10, currencyCode: "credits", effectiveAt: Date(timeIntervalSince1970: 0)),
            PricingEntry(provider: .openAI, modelLabel: "gpt-5.6", inputPricePerMillionTokens: 5, outputPricePerMillionTokens: 5, currencyCode: "USD", effectiveAt: Date(timeIntervalSince1970: 0))
        ])
        let metrics = [
            UsageMetric(provider: .openAI, accountLabel: "Local logs", projectLabel: nil, modelLabel: "gpt-5.5", deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(), freshness: .fresh),
            UsageMetric(provider: .openAI, accountLabel: "Local logs", projectLabel: nil, modelLabel: "gpt-5.6", deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(), freshness: .fresh),
            UsageMetric(provider: .anthropic, accountLabel: nil, projectLabel: nil, modelLabel: "claude-fable-5", deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(), freshness: .fresh)
        ]

        let estimate = CodexCreditsEstimator.estimate(from: metrics, pricing: pricing)

        #expect(estimate.today?.amount == 10)
        #expect(estimate.today?.currencyCode == "credits")
        #expect(estimate.currentWeek == nil)
    }
}
