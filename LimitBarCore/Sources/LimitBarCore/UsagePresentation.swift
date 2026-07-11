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
                ProviderUsageCard(
                    provider: provider,
                    metrics: metrics.filter { $0.provider == provider && $0.timeWindow == timeWindow }
                )
            }
    }
}
