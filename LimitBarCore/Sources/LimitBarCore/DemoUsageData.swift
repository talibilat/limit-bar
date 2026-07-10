import Foundation

public enum DemoUsageData {
    public static let metrics: [UsageMetric] = [
        metric(provider: .anthropic, accountLabel: "Personal", projectLabel: nil, modelLabel: "Claude Sonnet", deploymentLabel: nil, timeWindow: .today, inputTokens: 18_420, outputTokens: 6_120, refreshedAt: 1_783_728_000),
        metric(provider: .anthropic, accountLabel: "Personal", projectLabel: nil, modelLabel: "Claude Haiku", deploymentLabel: nil, timeWindow: .currentWeek, inputTokens: 42_000, outputTokens: 12_500, refreshedAt: 1_783_728_000),
        metric(provider: .azureOpenAI, accountLabel: "Team Azure", projectLabel: nil, modelLabel: "gpt-4.1", deploymentLabel: "team-tools", timeWindow: .today, inputTokens: 9_850, outputTokens: 3_210, refreshedAt: 1_783_724_400),
        metric(provider: .azureOpenAI, accountLabel: "Team Azure", projectLabel: nil, modelLabel: "gpt-4.1-mini", deploymentLabel: "batch-review", timeWindow: .currentWeek, inputTokens: 88_000, outputTokens: 21_000, refreshedAt: 1_783_724_400),
        metric(provider: .openAI, accountLabel: "Acme Org", projectLabel: "Codex Enterprise", modelLabel: "gpt-5.1-codex", deploymentLabel: nil, timeWindow: .today, inputTokens: 31_000, outputTokens: 8_700, refreshedAt: 1_783_720_800, freshness: .stale(missedRefreshes: 2))
    ]

    private static func metric(
        provider: ProviderKind,
        accountLabel: String?,
        projectLabel: String?,
        modelLabel: String,
        deploymentLabel: String?,
        timeWindow: TimeWindow,
        inputTokens: Int,
        outputTokens: Int,
        refreshedAt: TimeInterval,
        freshness: Freshness = .fresh
    ) -> UsageMetric {
        UsageMetric(
            provider: provider,
            accountLabel: accountLabel,
            projectLabel: projectLabel,
            modelLabel: modelLabel,
            deploymentLabel: deploymentLabel,
            timeWindow: timeWindow,
            tokenUsage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: Date(timeIntervalSince1970: refreshedAt),
            freshness: freshness
        )
    }
}
