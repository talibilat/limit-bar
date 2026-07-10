import Foundation

private func displayPercentage(for ratio: Double) -> Int {
    Int((ratio * 100).rounded(.down))
}

public enum ProviderKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case anthropic
    case azureOpenAI
    case openAI

    public static let orderedCases: [ProviderKind] = [.anthropic, .azureOpenAI, .openAI]

    public var displayName: String {
        switch self {
        case .anthropic:
            "Anthropic"
        case .azureOpenAI:
            "Azure OpenAI"
        case .openAI:
            "OpenAI"
        }
    }
}

public enum TimeWindow: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case today
    case currentWeek

    public var displayName: String {
        switch self {
        case .today:
            "Today"
        case .currentWeek:
            "Current Week"
        }
    }

    public func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .currentWeek:
            return calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, end: date)
        }
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int

    public var totalTokens: Int { inputTokens + outputTokens }

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum CostSource: String, Codable, Equatable, Sendable {
    case providerReported
    case calculatedEstimate

    public var displayLabel: String {
        switch self {
        case .providerReported:
            "Provider reported"
        case .calculatedEstimate:
            "Calculated estimate"
        }
    }
}

public struct Cost: Codable, Equatable, Sendable {
    public let amount: Decimal
    public let currencyCode: String
    public let source: CostSource

    public init(amount: Decimal, currencyCode: String, source: CostSource) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.source = source
    }
}

public enum LimitStatus: Codable, Equatable, Sendable {
    case confirmed(used: Double, limit: Double)
    case unsupportedByProviderAPI
    case disconnected
    case unavailable

    public var confirmedUsagePercentage: Int? {
        confirmedUsageRatio.map(displayPercentage)
    }

    public var confirmedUsageRatio: Double? {
        guard case let .confirmed(used, limit) = self, limit > 0 else {
            return nil
        }

        return used / limit
    }
}

public enum Freshness: Codable, Equatable, Sendable {
    case fresh
    case stale(missedRefreshes: Int)

    public var isStale: Bool {
        if case .stale = self { true } else { false }
    }

    public static func from(missedRefreshes: Int) -> Freshness {
        missedRefreshes >= 2 ? .stale(missedRefreshes: missedRefreshes) : .fresh
    }
}

public struct UsageMetric: Codable, Equatable, Sendable {
    public let provider: ProviderKind
    public let accountLabel: String?
    public let projectLabel: String?
    public let modelLabel: String
    public let deploymentLabel: String?
    public let timeWindow: TimeWindow
    public let tokenUsage: TokenUsage
    public let cost: Cost?
    public let limitStatus: LimitStatus
    public let refreshedAt: Date?
    public let freshness: Freshness

    public init(
        provider: ProviderKind,
        accountLabel: String?,
        projectLabel: String?,
        modelLabel: String,
        deploymentLabel: String?,
        timeWindow: TimeWindow,
        tokenUsage: TokenUsage,
        cost: Cost?,
        limitStatus: LimitStatus,
        refreshedAt: Date?,
        freshness: Freshness
    ) {
        self.provider = provider
        self.accountLabel = accountLabel
        self.projectLabel = projectLabel
        self.modelLabel = modelLabel
        self.deploymentLabel = deploymentLabel
        self.timeWindow = timeWindow
        self.tokenUsage = tokenUsage
        self.cost = cost
        self.limitStatus = limitStatus
        self.refreshedAt = refreshedAt
        self.freshness = freshness
    }
}

public enum MenuBarStatusColor: String, Codable, Equatable, Sendable {
    case green
    case yellow
    case red
    case gray
}

public struct MenuBarStatus: Codable, Equatable, Sendable {
    public let color: MenuBarStatusColor
    public let confirmedUsagePercentage: Int?

    public init(color: MenuBarStatusColor, confirmedUsagePercentage: Int?) {
        self.color = color
        self.confirmedUsagePercentage = confirmedUsagePercentage
    }

    public static func from(metrics: [UsageMetric]) -> MenuBarStatus {
        let ratios = metrics.compactMap(\.limitStatus.confirmedUsageRatio)
        let worstRatio = ratios.max()

        guard let worstRatio else {
            return MenuBarStatus(color: .gray, confirmedUsagePercentage: nil)
        }

        let worstPercentage = displayPercentage(for: worstRatio)

        if metrics.contains(where: { $0.freshness.isStale }) {
            return MenuBarStatus(color: .gray, confirmedUsagePercentage: worstPercentage)
        }

        if worstRatio >= 0.9 {
            return MenuBarStatus(color: .red, confirmedUsagePercentage: worstPercentage)
        }

        if worstRatio >= 0.7 {
            return MenuBarStatus(color: .yellow, confirmedUsagePercentage: worstPercentage)
        }

        return MenuBarStatus(color: .green, confirmedUsagePercentage: worstPercentage)
    }
}
