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

    public static func cards(from metrics: [UsageMetric], timeWindow: TimeWindow) -> [ProviderUsageCard] {
        ProviderKind.orderedCases.map { provider in
            ProviderUsageCard(
                provider: provider,
                metrics: metrics.filter { $0.provider == provider && $0.timeWindow == timeWindow }
            )
        }
    }
}
