import Foundation
import Testing
@testable import LimitBarCore

@Suite("Usage alert engine")
struct UsageAlertEngineTests {
    @Test("rate alerts cross the preset thresholds once per exact window")
    func rateAlertCrossingAndRepeat() throws {
        let window = try makeWindow(start: 1_000, end: 2_000)
        let date = Date(timeIntervalSince1970: 1_500)
        let rule = UsageAlertRule.rateLimit(provider: .anthropic, threshold: .seventyPercent)
        var engine = UsageAlertEngine()

        #expect(engine.evaluate(metrics: [metric(window: window, used: 69)], enabledRules: [rule], at: date).isEmpty)
        let alerts = engine.evaluate(metrics: [metric(window: window, used: 70)], enabledRules: [rule], at: date)
        #expect(alerts.count == 1)
        #expect(alerts.first?.notification.body == "Rate limit reached 70%.")
        #expect(engine.evaluate(metrics: [metric(window: window, used: 95)], enabledRules: [rule], at: date).isEmpty)
    }

    @Test("each preset and exact boundary has independent deduplication")
    func thresholdAndBoundaryDeduplication() throws {
        let first = try makeWindow(start: 1_000, end: 2_000)
        let second = try makeWindow(start: 2_000, end: 3_000)
        let seventy = UsageAlertRule.rateLimit(provider: .anthropic, threshold: .seventyPercent)
        let ninety = UsageAlertRule.rateLimit(provider: .anthropic, threshold: .ninetyPercent)
        var engine = UsageAlertEngine()

        let firstAlerts = engine.evaluate(
            metrics: [metric(window: first, used: 95)],
            enabledRules: [seventy, ninety],
            at: Date(timeIntervalSince1970: 1_500)
        )
        let secondAlerts = engine.evaluate(
            metrics: [metric(window: second, used: 95)],
            enabledRules: [seventy, ninety],
            at: Date(timeIntervalSince1970: 2_000)
        )

        #expect(Set(firstAlerts.map(\.rule)) == [seventy, ninety])
        #expect(Set(secondAlerts.map(\.rule)) == [seventy, ninety])
    }

    @Test("rules are opt in")
    func rulesAreOptIn() throws {
        let window = try makeWindow(start: 1_000, end: 2_000)
        var engine = UsageAlertEngine()

        #expect(engine.evaluate(
            metrics: [metric(window: window, used: 100)],
            enabledRules: [],
            at: Date(timeIntervalSince1970: 1_500)
        ).isEmpty)
    }

    @Test("stale malformed unsupported legacy and unsupported-version metrics are suppressed")
    func unsafeMetricsAreSuppressed() throws {
        let current = try makeWindow(start: 1_000, end: 2_000)
        let futureVersion = try ExactUsageWindow(
            timeWindow: .today,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            basis: .localCalendar,
            aggregationVersion: ExactUsageWindow.currentAggregationVersion + 1
        )
        let rule = UsageAlertRule.rateLimit(provider: .anthropic, threshold: .seventyPercent)
        let date = Date(timeIntervalSince1970: 1_500)
        var engine = UsageAlertEngine()

        let unsafe = [
            metric(window: current, used: 90, freshness: .stale(missedRefreshes: 2)),
            metric(window: current, limitStatus: .confirmed(used: .nan, limit: 100)),
            metric(window: current, limitStatus: .confirmed(used: 90, limit: 0)),
            metric(window: current, limitStatus: .unsupportedByProviderAPI),
            metric(window: futureVersion, used: 90),
            legacyMetric(used: 90)
        ]

        #expect(engine.evaluate(metrics: unsafe, enabledRules: [rule], at: date).isEmpty)
    }

    @Test("costs aggregate only within matching currency and provenance")
    func costSeparation() throws {
        let window = try makeWindow(start: 1_000, end: 2_000)
        let threshold = try UsageAlertCostThreshold(
            amount: 10,
            currencyCode: "usd",
            source: .providerReported
        )
        let rule = UsageAlertRule.cost(provider: .anthropic, threshold: threshold)
        let date = Date(timeIntervalSince1970: 1_500)
        var engine = UsageAlertEngine()

        let separated = [
            metric(window: window, cost: Cost(amount: 6, currencyCode: "USD", source: .providerReported)),
            metric(window: window, cost: Cost(amount: 6, currencyCode: "EUR", source: .providerReported)),
            metric(window: window, cost: Cost(amount: 6, currencyCode: "USD", source: .calculatedEstimate))
        ]
        #expect(engine.evaluate(metrics: separated, enabledRules: [rule], at: date).isEmpty)

        let matching = separated + [
            metric(window: window, cost: Cost(amount: 4, currencyCode: " usd ", source: .providerReported))
        ]
        #expect(engine.evaluate(metrics: matching, enabledRules: [rule], at: date).count == 1)
    }

    @Test("invalid cost configuration and malformed costs are suppressed")
    func invalidCosts() throws {
        #expect(throws: UsageAlertCostThreshold.ValidationError.invalidAmount) {
            try UsageAlertCostThreshold(amount: 0, currencyCode: "USD", source: .providerReported)
        }
        #expect(throws: UsageAlertCostThreshold.ValidationError.invalidCurrencyCode) {
            try UsageAlertCostThreshold(amount: 10, currencyCode: "US dollars", source: .providerReported)
        }

        let window = try makeWindow(start: 1_000, end: 2_000)
        let threshold = try UsageAlertCostThreshold(amount: 10, currencyCode: "USD", source: .providerReported)
        let rule = UsageAlertRule.cost(provider: .anthropic, threshold: threshold)
        var engine = UsageAlertEngine()
        let metrics = [
            metric(window: window, cost: Cost(amount: -20, currencyCode: "USD", source: .providerReported)),
            metric(window: window, cost: Cost(amount: 20, currencyCode: "US", source: .providerReported))
        ]

        #expect(engine.evaluate(
            metrics: metrics,
            enabledRules: [rule],
            at: Date(timeIntervalSince1970: 1_500)
        ).isEmpty)
    }

    @Test("lock-screen copy excludes detailed labels and cost provenance")
    func privacySafeCopy() throws {
        let window = try makeWindow(start: 1_000, end: 2_000)
        let threshold = try UsageAlertCostThreshold(amount: 10, currencyCode: "USD", source: .calculatedEstimate)
        let rule = UsageAlertRule.cost(provider: .anthropic, threshold: threshold)
        let sensitive = metric(
            window: window,
            cost: Cost(amount: 10, currencyCode: "USD", source: .calculatedEstimate)
        )
        var engine = UsageAlertEngine()

        let alert = try #require(engine.evaluate(
            metrics: [sensitive],
            enabledRules: [rule],
            at: Date(timeIntervalSince1970: 1_500)
        ).first)
        let copy = alert.notification.title + " " + alert.notification.body

        #expect(copy == "Anthropic usage alert Cost reached USD 10.")
        #expect(!copy.contains("Secret Account"))
        #expect(!copy.contains("Secret Project"))
        #expect(!copy.contains("Secret Model"))
        #expect(!copy.contains("calculated"))
        #expect(!copy.contains("providerReported"))
    }

    @Test("reset clears every delivered alert key")
    func resetAllState() throws {
        let window = try makeWindow(start: 1_000, end: 2_000)
        let rule = UsageAlertRule.rateLimit(provider: .anthropic, threshold: .seventyPercent)
        let date = Date(timeIntervalSince1970: 1_500)
        let metrics = [metric(window: window, used: 90)]
        var engine = UsageAlertEngine()

        #expect(engine.evaluate(metrics: metrics, enabledRules: [rule], at: date).count == 1)
        #expect(engine.evaluate(metrics: metrics, enabledRules: [rule], at: date).isEmpty)
        engine.reset()
        #expect(engine.state == UsageAlertState())
        #expect(engine.evaluate(metrics: metrics, enabledRules: [rule], at: date).count == 1)
    }

    @Test("delivery is protocol based and records successful delivery")
    func protocolDelivery() async throws {
        let window = try makeWindow(start: 1_000, end: 2_000)
        let rule = UsageAlertRule.rateLimit(provider: .anthropic, threshold: .ninetyPercent)
        let delivery = RecordingDelivery()
        let metrics = [metric(window: window, used: 95)]
        let date = Date(timeIntervalSince1970: 1_500)
        var engine = UsageAlertEngine()

        let alerts = try await engine.deliverAlerts(
            metrics: metrics,
            enabledRules: [rule],
            at: date,
            using: delivery
        )

        #expect(alerts.count == 1)
        #expect(await delivery.notifications == alerts.map(\.notification))
        #expect(engine.evaluate(metrics: metrics, enabledRules: [rule], at: date).isEmpty)
    }

    private func makeWindow(start: TimeInterval, end: TimeInterval) throws -> ExactUsageWindow {
        try ExactUsageWindow(
            timeWindow: .today,
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end),
            basis: .localCalendar
        )
    }

    private func metric(
        window: ExactUsageWindow,
        used: Double = 0,
        limitStatus: LimitStatus? = nil,
        cost: Cost? = nil,
        freshness: Freshness = .fresh
    ) -> UsageMetric {
        UsageMetric(
            provider: .anthropic,
            accountLabel: "Secret Account",
            projectLabel: "Secret Project",
            modelLabel: "Secret Model",
            deploymentLabel: "Secret Deployment",
            provenance: .bounded(source: .providerAPI, window: window),
            tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1),
            cost: cost,
            limitStatus: limitStatus ?? .confirmed(used: used, limit: 100),
            refreshedAt: Date(timeIntervalSince1970: 1_400),
            freshness: freshness
        )
    }

    private func legacyMetric(used: Double) -> UsageMetric {
        UsageMetric(
            provider: .anthropic,
            accountLabel: "Secret Account",
            projectLabel: "Secret Project",
            modelLabel: "Secret Model",
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1),
            cost: nil,
            limitStatus: .confirmed(used: used, limit: 100),
            refreshedAt: Date(timeIntervalSince1970: 1_400),
            freshness: .fresh
        )
    }
}

private actor RecordingDelivery: UsageAlertDelivering {
    private(set) var notifications: [UsageAlertNotification] = []

    func deliver(_ notification: UsageAlertNotification) {
        notifications.append(notification)
    }
}
