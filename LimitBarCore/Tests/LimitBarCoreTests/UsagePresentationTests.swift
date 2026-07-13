import Foundation
import Testing
@testable import LimitBarCore

@Suite("Usage presentation")
struct UsagePresentationTests {
    @Test("local cards exclude UTC billing rows and billing section exposes exact interval")
    func separatesLocalCardsFromUTCBillingCosts() throws {
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let token = metric(window: windows.today, cost: nil)
        let cost = metric(window: windows.utcBillingWeek, cost: Cost(amount: 2, currencyCode: "USD", source: .providerReported))

        let cards = ProviderUsageCard.cards(from: [token, cost], timeWindow: .today)
        let billing = UTCBillingWeekPresentation.from(metrics: [token, cost])

        #expect(cards.flatMap(\.metrics) == [token])
        #expect(billing?.title == "UTC Billing Week")
        #expect(billing?.interval == DateInterval(start: windows.utcBillingWeek.start, end: windows.utcBillingWeek.end))
        #expect(billing?.metrics == [cost])
        #expect(billing?.metrics.first?.showsLimitStatus == false)
    }

    @Test("provider API tokens replace overlapping built-in tokens while stale rows remain visible")
    func providerAPIPrecedesBuiltInWithoutHidingStaleRows() throws {
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: Calendar(identifier: .gregorian))
        let local = tokenMetric(provider: .openAI, source: .builtInLocalLog, window: windows.today, model: "local", freshness: .fresh)
        let staleAPI = tokenMetric(provider: .openAI, source: .providerAPI, window: windows.today, model: "api", freshness: .stale(missedRefreshes: 2))
        let anthropicLocal = tokenMetric(provider: .anthropic, source: .builtInLocalLog, window: windows.today, model: "claude", freshness: .fresh)

        let cards = ProviderUsageCard.cards(from: [local, staleAPI, anthropicLocal], timeWindow: .today)

        #expect(cards.first { $0.provider == .openAI }?.metrics == [staleAPI])
        #expect(cards.first { $0.provider == .anthropic }?.metrics == [anthropicLocal])
    }

    @Test("legacy rows remain hidden from provider cards")
    func legacyRowsRemainHidden() {
        let legacy = UsageMetric(provider: .openAI, accountLabel: nil, projectLabel: nil, modelLabel: "legacy", deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(), freshness: .fresh)

        let cards = ProviderUsageCard.cards(from: [legacy], timeWindow: .today)

        #expect(cards.first { $0.provider == .openAI }?.metrics.isEmpty == true)
    }

    private func metric(window: ExactUsageWindow, cost: Cost?) -> UsageMetric {
        UsageMetric(provider: .anthropic, accountLabel: nil, projectLabel: nil, modelLabel: "usage", deploymentLabel: nil, provenance: .bounded(source: .providerAPI, window: window), tokenUsage: TokenUsage(inputTokens: cost == nil ? 1 : 0, outputTokens: 0), cost: cost, limitStatus: .unsupportedByProviderAPI, refreshedAt: window.start, freshness: .fresh)
    }

    private func tokenMetric(provider: ProviderKind, source: UsageMetricSource, window: ExactUsageWindow, model: String, freshness: Freshness) -> UsageMetric {
        UsageMetric(provider: provider, accountLabel: nil, projectLabel: nil, modelLabel: model, deploymentLabel: nil, provenance: .bounded(source: source, window: window), tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: window.start, freshness: freshness)
    }
}
