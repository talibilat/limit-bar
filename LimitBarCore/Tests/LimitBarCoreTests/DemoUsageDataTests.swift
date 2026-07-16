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
        #expect(anthropic.tokenUsage.inputTokens == 18_420)
        #expect(anthropic.tokenUsage.outputTokens == 6_120)
        #expect(anthropic.tokenUsage.totalTokens == anthropic.tokenUsage.inputTokens + anthropic.tokenUsage.outputTokens)
        #expect(azure.modelLabel == "gpt-4.1")
        #expect(azure.deploymentLabel == "team-tools")
        #expect(azure.tokenUsage.inputTokens == 9_850)
        #expect(azure.tokenUsage.outputTokens == 3_210)
        #expect(azure.tokenUsage.totalTokens == 13_060)
        #expect(openAI.accountLabel == "Acme Org")
        #expect(openAI.projectLabel == "Codex Enterprise")
        #expect(openAI.modelLabel == "gpt-5.1-codex")
        #expect(openAI.tokenUsage.inputTokens == 31_000)
        #expect(openAI.tokenUsage.outputTokens == 8_700)
        #expect(openAI.tokenUsage.totalTokens == 39_700)
    }

    @Test("demo metrics include unsupported and stale states")
    func demoMetricsIncludeUnsupportedAndStaleStates() {
        let metrics = DemoUsageData.metrics

        #expect(metrics.contains { $0.limitStatus.displayText == "Unsupported by provider API" })
        #expect(metrics.contains { $0.freshness.isStale })
    }

    @Test("providers with no usage and no configuration are left out entirely")
    func providersWithNoSignalAreLeftOut() {
        let cards = ProviderUsageCard.cards(from: [], timeWindow: .today)

        #expect(cards.isEmpty)
    }

    @Test("a configured provider still shows an empty card before it has any usage")
    func configuredProviderShowsEmptyCard() {
        let cards = ProviderUsageCard.cards(from: [], timeWindow: .today, configuredProviders: [.anthropic])

        #expect(cards.map(\.provider) == [.anthropic])
        #expect(cards.allSatisfy { $0.isEmpty })
    }

    @Test("presence is decided across every window, not just the selected one")
    func presenceSpansEveryWindow() throws {
        let openAI = try #require(DemoUsageData.metrics.first { $0.provider == .openAI })

        let cards = ProviderUsageCard.cards(from: [openAI], timeWindow: .currentWeek)

        #expect(cards.map(\.provider) == [.openAI])
        #expect(cards.first?.isEmpty == true)
    }

    @Test("current week demo includes an empty OpenAI card")
    func currentWeekDemoIncludesAnEmptyOpenAICard() throws {
        let cards = ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: .currentWeek)
        let openAI = try #require(cards.first { $0.provider == .openAI })

        #expect(openAI.isEmpty)
    }
}
