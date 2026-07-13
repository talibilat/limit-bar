import Foundation

public extension TimeWindow {
    static let defaultSelection: TimeWindow = .today
}

public extension LimitStatus {
    var displayText: String {
        switch self {
        case .confirmed:
            confirmedUsagePercentage.map { "\($0)%" } ?? "Unavailable"
        case .unsupportedByProviderAPI:
            "Unsupported by provider API"
        case .disconnected:
            "Disconnected"
        case .unavailable:
            "Unavailable"
        }
    }
}

public struct ProviderUsageCard: Equatable, Sendable {
    public let provider: ProviderKind
    public let metrics: [UsageMetric]

    public var isEmpty: Bool { metrics.isEmpty }

    // A provider only gets a card if it has ever produced usage (in any time
    // window, not just the one currently selected) or the user has actively
    // configured a credential for it. A provider with neither is a tool that
    // simply isn't in use on this machine, so it is left out entirely rather
    // than shown as an empty "Not configured" card.
    public static func cards(
        from metrics: [UsageMetric],
        timeWindow: TimeWindow,
        configuredProviders: Set<ProviderKind> = []
    ) -> [ProviderUsageCard] {
        let providersWithAnyUsage = Set(metrics.map(\.provider))
        return ProviderKind.orderedCases
            .filter { providersWithAnyUsage.contains($0) || configuredProviders.contains($0) }
            .map { provider in
                let candidates = metrics.filter {
                    $0.provider == provider
                        && $0.timeWindow == timeWindow
                        && $0.provenance.exactWindow != nil
                        && $0.provenance.exactWindow?.basis != .utcBilling
                }
                let apiWindows = Set(candidates.compactMap { metric -> ExactUsageWindow? in
                    guard metric.provenance.source == .providerAPI, metric.tokenUsage.totalTokens > 0 else { return nil }
                    return metric.provenance.exactWindow
                })
                return ProviderUsageCard(
                    provider: provider,
                    metrics: candidates.filter { metric in
                        guard metric.provenance.source == .builtInLocalLog,
                              let window = metric.provenance.exactWindow else { return true }
                        return !apiWindows.contains(window)
                    }
                )
            }
    }
}

public extension UsageMetric {
    var showsLimitStatus: Bool {
        !(tokenUsage.totalTokens == 0 && cost?.source == .providerReported)
    }
}

public struct UTCBillingWeekPresentation: Equatable, Sendable {
    public let title: String
    public let interval: DateInterval
    public let metrics: [UsageMetric]

    public static func from(metrics: [UsageMetric]) -> UTCBillingWeekPresentation? {
        let billingMetrics = metrics.filter {
            $0.cost?.source == .providerReported && $0.provenance.exactWindow?.basis == .utcBilling
        }
        guard let window = billingMetrics.compactMap(\.provenance.exactWindow).max(by: { $0.start < $1.start }) else { return nil }
        return UTCBillingWeekPresentation(
            title: "UTC Billing Week",
            interval: DateInterval(start: window.start, end: window.end),
            metrics: billingMetrics.filter { $0.provenance.exactWindow == window }
        )
    }
}
