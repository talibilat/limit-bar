import Foundation
import Testing
@testable import LimitBarCore

@Suite("Usage model")
struct UsageModelTests {
    @Test("providers use the fixed display order")
    func providersUseFixedDisplayOrder() {
        #expect(ProviderKind.orderedCases == [.anthropic, .azureOpenAI, .openAI])
        #expect(ProviderKind.orderedCases.map(\.displayName) == ["Anthropic", "Azure OpenAI", "OpenAI"])
    }

    @Test("today window covers the local day containing the reference date")
    func todayWindowCoversReferenceDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try #require(calendar.date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 7, day: 10, hour: 15, minute: 30)))

        let interval = TimeWindow.today.interval(containing: reference, calendar: calendar)

        #expect(interval.start == calendar.startOfDay(for: reference))
        #expect(interval.end == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)))
        #expect(TimeWindow.today.displayName == "Today")
    }

    @Test("current week window uses the calendar week containing the reference date")
    func currentWeekWindowUsesCalendarWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let reference = try #require(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 7, day: 10, hour: 15)))

        let interval = TimeWindow.currentWeek.interval(containing: reference, calendar: calendar)
        let expected = try #require(calendar.dateInterval(of: .weekOfYear, for: reference))

        #expect(interval == expected)
        #expect(TimeWindow.currentWeek.displayName == "Current Week")
    }

    @Test("token usage keeps input and output confirmed and computes total")
    func tokenUsageComputesTotal() {
        let usage = TokenUsage(inputTokens: 120, outputTokens: 80)

        #expect(usage.inputTokens == 120)
        #expect(usage.outputTokens == 80)
        #expect(usage.totalTokens == 200)
    }

    @Test("cost source labels stay honest")
    func costSourceLabelsStayHonest() {
        #expect(CostSource.providerReported.displayLabel == "Provider reported")
        #expect(CostSource.calculatedEstimate.displayLabel == "Calculated estimate")
    }

    @Test("freshness becomes stale after two missed refreshes")
    func freshnessBecomesStaleAfterTwoMissedRefreshes() {
        #expect(Freshness.from(missedRefreshes: 0) == .fresh)
        #expect(Freshness.from(missedRefreshes: 1) == .fresh)
        #expect(Freshness.from(missedRefreshes: 2) == .stale(missedRefreshes: 2))
    }

    @Test("unsupported limits do not expose confirmed percentages")
    func unsupportedLimitsDoNotExposeConfirmedPercentages() {
        #expect(LimitStatus.unsupportedByProviderAPI.confirmedUsagePercentage == nil)
        #expect(LimitStatus.disconnected.confirmedUsagePercentage == nil)
        #expect(LimitStatus.confirmed(used: 82, limit: 100).confirmedUsagePercentage == 82)
    }

    @Test("menu bar status uses threshold colors from worst confirmed supported limit")
    func menuBarStatusUsesThresholdColors() {
        #expect(MenuBarStatus.from(metrics: [metric(used: 69)]).color == .green)
        #expect(MenuBarStatus.from(metrics: [metric(used: 70)]).color == .yellow)
        #expect(MenuBarStatus.from(metrics: [metric(used: 90)]).color == .red)
        #expect(MenuBarStatus.from(metrics: [metric(used: 40), metric(used: 82)]).confirmedUsagePercentage == 82)
    }

    @Test("menu bar status is gray for stale or unsupported data")
    func menuBarStatusIsGrayForStaleOrUnsupportedData() {
        let stale = metric(used: 80, freshness: .stale(missedRefreshes: 2))
        let unsupported = metric(limitStatus: .unsupportedByProviderAPI)

        #expect(MenuBarStatus.from(metrics: [stale]).color == .gray)
        #expect(MenuBarStatus.from(metrics: [stale]).confirmedUsagePercentage == 80)
        #expect(MenuBarStatus.from(metrics: [unsupported]).color == .gray)
        #expect(MenuBarStatus.from(metrics: [unsupported]).confirmedUsagePercentage == nil)
    }

    @Test("usage metric excludes sensitive content by shape")
    func usageMetricExcludesSensitiveContentByShape() {
        let usageMetric = metric(used: 42)

        #expect(usageMetric.provider == .anthropic)
        #expect(usageMetric.accountLabel == "Personal")
        #expect(usageMetric.projectLabel == "LimitBar")
        #expect(usageMetric.modelLabel == "claude-sonnet")
        #expect(usageMetric.deploymentLabel == nil)
        #expect(usageMetric.tokenUsage.totalTokens == 30)
    }

    private func metric(
        used: Double = 50,
        limitStatus: LimitStatus? = nil,
        freshness: Freshness = .fresh
    ) -> UsageMetric {
        UsageMetric(
            provider: .anthropic,
            accountLabel: "Personal",
            projectLabel: "LimitBar",
            modelLabel: "claude-sonnet",
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 20),
            cost: Cost(amount: Decimal(string: "1.23")!, currencyCode: "USD", source: .providerReported),
            limitStatus: limitStatus ?? .confirmed(used: used, limit: 100),
            refreshedAt: Date(timeIntervalSince1970: 1_783_683_200),
            freshness: freshness
        )
    }
}
