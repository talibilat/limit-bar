import Foundation
import Testing
@testable import LimitBarCore

@Suite("Usage model")
struct UsageModelTests {
    @Test("providers use the fixed display order")
    func providersUseFixedDisplayOrder() {
        #expect(ProviderKind.orderedCases == [.anthropic, .azureOpenAI, .openAI, .custom])
        #expect(ProviderKind.orderedCases.map(\.displayName) == ["Anthropic", "Azure OpenAI", "Codex", "Custom"])
    }

    @Test("today window covers the local day containing the reference date")
    func todayWindowCoversReferenceDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try #require(calendar.date(from: DateComponents(timeZone: .gmt, year: 2026, month: 7, day: 10, hour: 15, minute: 30)))

        let interval = TimeWindow.today.interval(containing: reference, calendar: calendar)

        #expect(interval.start == calendar.startOfDay(for: reference))
        #expect(interval.end == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)))
        #expect(TimeWindow.today.displayName == "Today")
    }

    @Test("current week always starts Monday even when the calendar starts weeks on Sunday")
    func currentWeekAlwaysStartsMonday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 1
        let reference = try #require(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 7, day: 10, hour: 15)))
        let expectedStart = try #require(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 7, day: 6)))
        let expectedEnd = try #require(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 7, day: 13)))

        let interval = TimeWindow.currentWeek.interval(containing: reference, calendar: calendar)

        #expect(interval.start == expectedStart)
        #expect(interval.end == expectedEnd)
        #expect(TimeWindow.currentWeek.displayName == "Current Week")
    }

    @Test("current week ends at the exclusive following Monday boundary")
    func currentWeekEndIsExclusiveFollowingMonday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 1
        let followingMonday = try #require(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 7, day: 13)))

        let previousWeek = try CurrentUsageWindows.resolve(
            at: followingMonday.addingTimeInterval(-1),
            calendar: calendar
        ).currentWeek
        let nextWeek = try CurrentUsageWindows.resolve(at: followingMonday, calendar: calendar).currentWeek

        #expect(previousWeek.end == followingMonday)
        #expect(nextWeek.start == followingMonday)
        #expect(nextWeek.basis == .localCalendar)
    }

    @Test("today follows the local calendar across spring DST")
    func todayFollowsSpringDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))

        let windows = try CurrentUsageWindows.resolve(at: reference, calendar: calendar)

        #expect(windows.today.timeWindow == .today)
        #expect(windows.today.basis == .localCalendar)
        #expect(windows.today.end.timeIntervalSince(windows.today.start) == 23 * 60 * 60)
        #expect(calendar.component(.day, from: windows.today.start) == 8)
        #expect(calendar.component(.day, from: windows.today.end) == 9)
    }

    @Test("today follows the local calendar across fall DST")
    func todayFollowsFallDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))

        let windows = try CurrentUsageWindows.resolve(at: reference, calendar: calendar)

        #expect(windows.today.end.timeIntervalSince(windows.today.start) == 25 * 60 * 60)
        #expect(calendar.component(.day, from: windows.today.start) == 1)
        #expect(calendar.component(.day, from: windows.today.end) == 2)
    }

    @Test("UTC billing week uses Monday midnight UTC boundaries")
    func utcBillingWeekUsesMondayMidnightUTC() throws {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        localCalendar.firstWeekday = 1
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let reference = try #require(utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 23, minute: 59)))
        let expectedStart = try #require(utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 6)))
        let expectedEnd = try #require(utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 13)))

        let windows = try CurrentUsageWindows.resolve(at: reference, calendar: localCalendar)

        #expect(windows.utcBillingWeek.timeWindow == .currentWeek)
        #expect(windows.utcBillingWeek.basis == .utcBilling)
        #expect(windows.utcBillingWeek.start == expectedStart)
        #expect(windows.utcBillingWeek.end == expectedEnd)
    }

    @Test("exact usage windows reject empty, reversed, and invalid-version intervals")
    func exactUsageWindowsRejectInvalidValues() {
        let start = Date(timeIntervalSince1970: 100)

        #expect(throws: ExactUsageWindow.ValidationError.invalidInterval) {
            try ExactUsageWindow(timeWindow: .today, start: start, end: start, basis: .localCalendar)
        }
        #expect(throws: ExactUsageWindow.ValidationError.invalidInterval) {
            try ExactUsageWindow(timeWindow: .today, start: start, end: start.addingTimeInterval(-1), basis: .localCalendar)
        }
        #expect(throws: ExactUsageWindow.ValidationError.invalidAggregationVersion) {
            try ExactUsageWindow(
                timeWindow: .today,
                start: start,
                end: start.addingTimeInterval(1),
                basis: .localCalendar,
                aggregationVersion: 0
            )
        }
    }

    @Test("exact usage windows reject fractional and non-finite boundaries")
    func exactUsageWindowsRejectNonIntegralBoundaries() {
        #expect(throws: ExactUsageWindow.ValidationError.invalidBoundaryPrecision) {
            try ExactUsageWindow(
                timeWindow: .today,
                start: Date(timeIntervalSince1970: 100.5),
                end: Date(timeIntervalSince1970: 200),
                basis: .localCalendar
            )
        }
        #expect(throws: ExactUsageWindow.ValidationError.invalidBoundaryPrecision) {
            try ExactUsageWindow(
                timeWindow: .today,
                start: Date(timeIntervalSince1970: 100),
                end: Date(timeIntervalSince1970: .infinity),
                basis: .localCalendar
            )
        }
    }

    @Test("decoding rejects exact usage windows with invalid bounds")
    func decodingRejectsExactUsageWindowsWithInvalidBounds() {
        let data = Data(
            #"{"timeWindow":"today","start":100,"end":100,"basis":"localCalendar","aggregationVersion":1}"#.utf8
        )

        #expect(throws: ExactUsageWindow.ValidationError.invalidInterval) {
            try JSONDecoder().decode(ExactUsageWindow.self, from: data)
        }
    }

    @Test("decoding rejects exact usage windows with invalid aggregation versions")
    func decodingRejectsExactUsageWindowsWithInvalidAggregationVersions() {
        let data = Data(
            #"{"timeWindow":"today","start":100,"end":200,"basis":"localCalendar","aggregationVersion":0}"#.utf8
        )

        #expect(throws: ExactUsageWindow.ValidationError.invalidAggregationVersion) {
            try JSONDecoder().decode(ExactUsageWindow.self, from: data)
        }
    }

    @Test("decoding rejects exact usage windows with fractional boundaries")
    func decodingRejectsExactUsageWindowsWithFractionalBoundaries() {
        let data = Data(
            #"{"timeWindow":"today","start":100.5,"end":200,"basis":"localCalendar","aggregationVersion":1}"#.utf8
        )

        #expect(throws: ExactUsageWindow.ValidationError.invalidBoundaryPrecision) {
            try JSONDecoder().decode(ExactUsageWindow.self, from: data)
        }
    }

    @Test("usage metric preserves legacy and bounded provenance")
    func usageMetricPreservesProvenance() throws {
        let legacy = metric(used: 42)
        let window = try ExactUsageWindow(
            timeWindow: .currentWeek,
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200),
            basis: .utcBilling
        )
        let bounded = metric(provenance: .bounded(source: .custom(UUID()), window: window))

        #expect(legacy.provenance == .legacy(timeWindow: .today))
        #expect(legacy.timeWindow == .today)
        #expect(legacy.provenance.source == nil)
        #expect(legacy.provenance.exactWindow == nil)
        #expect(bounded.timeWindow == .currentWeek)
        #expect(bounded.provenance.source != nil)
        #expect(bounded.provenance.exactWindow == window)
    }

    @Test("usage metric decodes legacy JSON with a time window")
    func usageMetricDecodesLegacyJSONWithTimeWindow() throws {
        let data = Data(
            #"{"provider":"anthropic","accountLabel":"Personal","projectLabel":"LimitBar","modelLabel":"claude-sonnet","timeWindow":"today","tokenUsage":{"inputTokens":10,"outputTokens":20},"limitStatus":{"unsupportedByProviderAPI":{}},"freshness":{"fresh":{}}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(UsageMetric.self, from: data)

        #expect(decoded.provenance == .legacy(timeWindow: .today))
        #expect(decoded.accountLabel == "Personal")
        #expect(decoded.projectLabel == "LimitBar")
        #expect(decoded.modelLabel == "claude-sonnet")
        #expect(decoded.tokenUsage == TokenUsage(inputTokens: 10, outputTokens: 20))
    }

    @Test("usage metric JSON round trip preserves bounded custom provenance")
    func usageMetricJSONRoundTripPreservesBoundedCustomProvenance() throws {
        let sourceID = try #require(UUID(uuidString: "4A613A87-9D4D-4208-80D5-7F6D94A6DBE7"))
        let window = try ExactUsageWindow(
            timeWindow: .currentWeek,
            start: Date(timeIntervalSince1970: 1_783_641_600),
            end: Date(timeIntervalSince1970: 1_784_246_400),
            basis: .utcBilling,
            aggregationVersion: 3
        )
        let original = metric(provenance: .bounded(source: .custom(sourceID), window: window))

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageMetric.self, from: encoded)

        #expect(decoded == original)
        #expect(decoded.provenance == .bounded(source: .custom(sourceID), window: window))
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

    @Test("confirmed limits reject non-finite quotients and nonrepresentable percentages")
    func confirmedLimitsRejectUnsafeArithmetic() {
        let overflowingRatio = LimitStatus.confirmed(used: 1e308, limit: 1e-308)
        let hugeFiniteRatio = LimitStatus.confirmed(used: 1e300, limit: 1)

        #expect(overflowingRatio.confirmedUsageRatio == nil)
        #expect(overflowingRatio.confirmedUsagePercentage == nil)
        #expect(hugeFiniteRatio.confirmedUsageRatio == 1e300)
        #expect(hugeFiniteRatio.confirmedUsagePercentage == nil)
    }

    @Test("menu bar status uses threshold colors from worst confirmed supported limit")
    func menuBarStatusUsesThresholdColors() {
        #expect(MenuBarStatus.from(metrics: [metric(used: 69)]).color == .green)
        #expect(MenuBarStatus.from(metrics: [metric(used: 70)]).color == .yellow)
        #expect(MenuBarStatus.from(metrics: [metric(used: 90)]).color == .red)
        #expect(MenuBarStatus.from(metrics: [metric(used: 40), metric(used: 82)]).confirmedUsagePercentage == 82)
    }

    @Test("menu bar thresholds compare raw usage before display rounding")
    func menuBarThresholdsCompareRawUsageBeforeDisplayRounding() {
        #expect(MenuBarStatus.from(metrics: [metric(used: 69.6)]).color == .green)
        #expect(MenuBarStatus.from(metrics: [metric(used: 69.6)]).confirmedUsagePercentage == 69)
        #expect(MenuBarStatus.from(metrics: [metric(used: 89.6)]).color == .yellow)
        #expect(MenuBarStatus.from(metrics: [metric(used: 89.6)]).confirmedUsagePercentage == 89)
    }

    @Test("menu bar status is gray for stale or unsupported data")
    func menuBarStatusIsGrayForStaleOrUnsupportedData() {
        let stale = metric(used: 80, freshness: .stale(missedRefreshes: 2))
        let unsupported = metric(limitStatus: .unsupportedByProviderAPI)
        let disconnected = metric(limitStatus: .disconnected)

        #expect(MenuBarStatus.from(metrics: [stale]).color == .gray)
        #expect(MenuBarStatus.from(metrics: [stale]).confirmedUsagePercentage == 80)
        #expect(MenuBarStatus.from(metrics: [unsupported]).color == .gray)
        #expect(MenuBarStatus.from(metrics: [unsupported]).confirmedUsagePercentage == nil)
        #expect(MenuBarStatus.from(metrics: [disconnected]).color == .gray)
        #expect(MenuBarStatus.from(metrics: [disconnected]).confirmedUsagePercentage == nil)
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
        freshness: Freshness = .fresh,
        provenance: UsageSnapshotProvenance? = nil
    ) -> UsageMetric {
        let common = (
            provider: ProviderKind.anthropic,
            accountLabel: "Personal",
            projectLabel: "LimitBar",
            modelLabel: "claude-sonnet",
            deploymentLabel: Optional<String>.none,
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 20),
            cost: Cost(amount: Decimal(string: "1.23")!, currencyCode: "USD", source: .providerReported),
            limitStatus: limitStatus ?? .confirmed(used: used, limit: 100),
            refreshedAt: Optional(Date(timeIntervalSince1970: 1_783_683_200)),
            freshness: freshness
        )

        if let provenance {
            return UsageMetric(
                provider: common.provider,
                accountLabel: common.accountLabel,
                projectLabel: common.projectLabel,
                modelLabel: common.modelLabel,
                deploymentLabel: common.deploymentLabel,
                provenance: provenance,
                tokenUsage: common.tokenUsage,
                cost: common.cost,
                limitStatus: common.limitStatus,
                refreshedAt: common.refreshedAt,
                freshness: common.freshness
            )
        }

        return UsageMetric(
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
