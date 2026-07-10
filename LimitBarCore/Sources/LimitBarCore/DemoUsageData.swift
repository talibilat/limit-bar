import Foundation

public struct ProviderUsageCard: Equatable, Sendable {
    public let provider: ProviderKind
    public let metrics: [UsageMetric]

    public var isEmpty: Bool { metrics.isEmpty }

    public static func cards(from metrics: [UsageMetric], timeWindow: TimeWindow) -> [ProviderUsageCard] {
        ProviderKind.orderedCases.map { provider in
            ProviderUsageCard(
                provider: provider,
                metrics: metrics.filter { $0.provider == provider && $0.timeWindow == timeWindow }
            )
        }
    }
}

public enum DemoUsageData {
    public static let metrics: [UsageMetric] = [
        UsageMetric(
            provider: .anthropic,
            accountLabel: "Personal",
            projectLabel: nil,
            modelLabel: "Claude Sonnet",
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 18_420, outputTokens: 6_120),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: Date(timeIntervalSince1970: 1_783_728_000),
            freshness: .fresh
        ),
        UsageMetric(
            provider: .anthropic,
            accountLabel: "Personal",
            projectLabel: nil,
            modelLabel: "Claude Haiku",
            deploymentLabel: nil,
            timeWindow: .currentWeek,
            tokenUsage: TokenUsage(inputTokens: 42_000, outputTokens: 12_500),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: Date(timeIntervalSince1970: 1_783_728_000),
            freshness: .fresh
        ),
        UsageMetric(
            provider: .azureOpenAI,
            accountLabel: "Team Azure",
            projectLabel: nil,
            modelLabel: "gpt-4.1",
            deploymentLabel: "team-tools",
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 9_850, outputTokens: 3_210),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: Date(timeIntervalSince1970: 1_783_724_400),
            freshness: .fresh
        ),
        UsageMetric(
            provider: .azureOpenAI,
            accountLabel: "Team Azure",
            projectLabel: nil,
            modelLabel: "gpt-4.1-mini",
            deploymentLabel: "batch-review",
            timeWindow: .currentWeek,
            tokenUsage: TokenUsage(inputTokens: 88_000, outputTokens: 21_000),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: Date(timeIntervalSince1970: 1_783_724_400),
            freshness: .fresh
        ),
        UsageMetric(
            provider: .openAI,
            accountLabel: "Acme Org",
            projectLabel: "Codex Enterprise",
            modelLabel: "gpt-5.1-codex",
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 31_000, outputTokens: 8_700),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: Date(timeIntervalSince1970: 1_783_720_800),
            freshness: .stale(missedRefreshes: 2)
        ),
        UsageMetric(
            provider: .openAI,
            accountLabel: "Acme Org",
            projectLabel: "Codex Enterprise",
            modelLabel: "gpt-5.1-codex",
            deploymentLabel: nil,
            timeWindow: .currentWeek,
            tokenUsage: TokenUsage(inputTokens: 144_000, outputTokens: 39_500),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: Date(timeIntervalSince1970: 1_783_720_800),
            freshness: .stale(missedRefreshes: 2)
        )
    ]
}
