import Testing
@testable import LimitBarCore

@Suite("Demo usage data")
struct DemoUsageDataTests {
    @Test("today is the default selected window")
    func todayIsDefaultSelectedWindow() {
        #expect(TimeWindow.defaultSelection == .today)
    }

    @Test("provider cards are always in fixed provider order")
    func providerCardsAreAlwaysInFixedOrder() {
        let cards = ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: .today)

        #expect(cards.map(\.provider) == [.anthropic, .azureOpenAI, .openAI])
    }

    @Test("switching time windows does not reorder cards")
    func switchingTimeWindowsDoesNotReorderCards() {
        let today = ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: .today)
        let week = ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: .currentWeek)

        #expect(today.map(\.provider) == week.map(\.provider))
    }

    @Test("demo metrics include provider-specific row metadata")
    func demoMetricsIncludeProviderSpecificRowMetadata() throws {
        let cards = ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: .today)
        let anthropic = try #require(cards.first { $0.provider == .anthropic }?.metrics.first)
        let azure = try #require(cards.first { $0.provider == .azureOpenAI }?.metrics.first)
        let openAI = try #require(cards.first { $0.provider == .openAI }?.metrics.first)

        #expect(anthropic.modelLabel == "Claude Sonnet")
        #expect(anthropic.tokenUsage.totalTokens == anthropic.tokenUsage.inputTokens + anthropic.tokenUsage.outputTokens)
        #expect(azure.deploymentLabel == "team-tools")
        #expect(openAI.accountLabel == "Acme Org")
        #expect(openAI.projectLabel == "Codex Enterprise")
    }

    @Test("demo metrics include unsupported and stale states")
    func demoMetricsIncludeUnsupportedAndStaleStates() {
        let metrics = DemoUsageData.metrics

        #expect(metrics.contains { $0.limitStatus.displayText == "Unsupported by provider API" })
        #expect(metrics.contains { $0.freshness.isStale })
    }

    @Test("empty cards stay present")
    func emptyCardsStayPresent() {
        let cards = ProviderUsageCard.cards(from: [], timeWindow: .today)

        #expect(cards.count == 3)
        #expect(cards.allSatisfy { $0.isEmpty })
    }
}
