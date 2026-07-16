import Foundation

public struct UsageAlertEngine: Sendable {
    public private(set) var state: UsageAlertState
    private let extensionEvaluators: [any UsageAlertRuleEvaluating]

    public init(
        state: UsageAlertState = UsageAlertState(),
        extensionEvaluators: [any UsageAlertRuleEvaluating] = []
    ) {
        self.state = state
        self.extensionEvaluators = extensionEvaluators
    }

    public mutating func evaluate(
        metrics: [UsageMetric],
        enabledRules: Set<UsageAlertRule>,
        at date: Date = Date()
    ) -> [UsageAlert] {
        let alerts = pendingAlerts(metrics: metrics, enabledRules: enabledRules, at: date)
        markDelivered(alerts)
        return alerts
    }

    public mutating func deliverAlerts(
        metrics: [UsageMetric],
        enabledRules: Set<UsageAlertRule>,
        at date: Date = Date(),
        using delivery: any UsageAlertDelivering
    ) async throws -> [UsageAlert] {
        let alerts = pendingAlerts(metrics: metrics, enabledRules: enabledRules, at: date)
        var delivered: [UsageAlert] = []
        for alert in alerts {
            try await delivery.deliver(alert.notification)
            markDelivered([alert])
            delivered.append(alert)
        }
        return delivered
    }

    public mutating func reset() {
        state = UsageAlertState()
    }

    private mutating func pendingAlerts(
        metrics: [UsageMetric],
        enabledRules: Set<UsageAlertRule>,
        at date: Date
    ) -> [UsageAlert] {
        state.delivered = state.delivered.filter { $0.window.end > date }

        let eligibleMetrics = metrics.filter { metric in
            guard
                metric.freshness == .fresh,
                let refreshedAt = metric.refreshedAt,
                refreshedAt.timeIntervalSince1970.isFinite,
                let window = metric.provenance.exactWindow,
                window.aggregationVersion == ExactUsageWindow.currentAggregationVersion,
                window.start <= date,
                date < window.end
            else {
                return false
            }
            return true
        }

        var candidates: [UsageAlertCandidate] = []
        for rule in enabledRules {
            switch rule {
            case let .rateLimit(provider, threshold):
                candidates += rateLimitCandidates(
                    metrics: eligibleMetrics,
                    provider: provider,
                    threshold: threshold,
                    rule: rule
                )
            case let .cost(provider, threshold):
                candidates += costCandidates(
                    metrics: eligibleMetrics,
                    provider: provider,
                    threshold: threshold,
                    rule: rule
                )
            case .extensionRule:
                break
            }
        }

        if !extensionEvaluators.isEmpty {
            let context = UsageAlertEvaluationContext(metrics: eligibleMetrics, enabledRules: enabledRules)
            candidates += extensionEvaluators.flatMap { $0.candidates(in: context) }.filter {
                guard case .extensionRule = $0.rule else { return false }
                return enabledRules.contains($0.rule)
                    && $0.window.aggregationVersion == ExactUsageWindow.currentAggregationVersion
                    && $0.window.start <= date
                    && date < $0.window.end
            }
        }

        var seen = state.delivered
        return candidates.compactMap { candidate in
            let key = UsageAlertDeduplicationKey(rule: candidate.rule, window: candidate.window)
            guard seen.insert(key).inserted else { return nil }
            return UsageAlert(rule: candidate.rule, provider: candidate.provider, window: candidate.window)
        }
    }

    private func rateLimitCandidates(
        metrics: [UsageMetric],
        provider: ProviderKind,
        threshold: UsageAlertRateThreshold,
        rule: UsageAlertRule
    ) -> [UsageAlertCandidate] {
        let qualifying = metrics.filter { metric in
            guard metric.provider == provider,
                  let ratio = metric.limitStatus.confirmedUsageRatio else { return false }
            return ratio >= Double(threshold.rawValue) / 100
        }
        let windows = Set(qualifying.compactMap(\.provenance.exactWindow))
        return windows.map { UsageAlertCandidate(rule: rule, provider: provider, window: $0) }
    }

    private func costCandidates(
        metrics: [UsageMetric],
        provider: ProviderKind,
        threshold: UsageAlertCostThreshold,
        rule: UsageAlertRule
    ) -> [UsageAlertCandidate] {
        var totals: [ExactUsageWindow: Decimal] = [:]
        for metric in metrics where metric.provider == provider {
            guard
                let window = metric.provenance.exactWindow,
                let cost = metric.cost,
                cost.source == threshold.source,
                UsageAlertValidation.normalizedCurrencyCode(cost.currencyCode) == threshold.currencyCode,
                UsageAlertValidation.isNonnegativeFinite(cost.amount)
            else {
                continue
            }
            totals[window, default: 0] += cost.amount
        }

        return totals.compactMap { window, amount in
            guard UsageAlertValidation.isNonnegativeFinite(amount), amount >= threshold.amount else { return nil }
            return UsageAlertCandidate(rule: rule, provider: provider, window: window)
        }
    }

    private mutating func markDelivered(_ alerts: [UsageAlert]) {
        state.delivered.formUnion(alerts.map { UsageAlertDeduplicationKey(rule: $0.rule, window: $0.window) })
    }
}
