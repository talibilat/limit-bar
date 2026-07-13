import Foundation

private func displayPercentage(for ratio: Double) -> Int? {
    let percentage = ratio * 100
    guard percentage.isFinite else { return nil }
    return Int(exactly: percentage.rounded(.down))
}

public enum ProviderKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case anthropic
    case azureOpenAI
    case openAI
    // Any locally logged tool without built-in support (see CustomUsageSource).
    // Has no auth method or credential of its own, so it is intentionally
    // excluded from ProviderAuthMethod/ProviderSettings.defaultSettings.
    case custom

    public static let orderedCases: [ProviderKind] = [.anthropic, .azureOpenAI, .openAI, .custom]

    public var displayName: String {
        switch self {
        case .anthropic:
            "Anthropic"
        case .azureOpenAI:
            "Azure OpenAI"
        case .openAI:
            "Codex"
        case .custom:
            "Custom"
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
            let dayStart = calendar.startOfDay(for: date)
            let weekday = calendar.component(.weekday, from: dayStart)
            let daysSinceMonday = (weekday + 5) % 7
            guard
                let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: dayStart),
                let end = calendar.date(byAdding: .day, value: 7, to: start)
            else {
                return DateInterval(start: date, end: date)
            }
            return DateInterval(start: start, end: end)
        }
    }
}

public enum UsageMetricSource: Codable, Equatable, Hashable, Sendable {
    case providerAPI
    case builtInLocalLog
    case custom(UUID)
}

public enum UsageWindowBasis: String, Codable, Equatable, Hashable, Sendable {
    case localCalendar
    case utcBilling
}

public struct ExactUsageWindow: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable {
        case invalidInterval
        case invalidBoundaryPrecision
        case invalidAggregationVersion
    }

    public static let currentAggregationVersion = 1

    public let timeWindow: TimeWindow
    public let start: Date
    public let end: Date
    public let basis: UsageWindowBasis
    public let aggregationVersion: Int

    private enum CodingKeys: String, CodingKey {
        case timeWindow
        case start
        case end
        case basis
        case aggregationVersion
    }

    public init(
        timeWindow: TimeWindow,
        start: Date,
        end: Date,
        basis: UsageWindowBasis,
        aggregationVersion: Int = currentAggregationVersion
    ) throws {
        guard Self.isPersistableBoundary(start), Self.isPersistableBoundary(end) else {
            throw ValidationError.invalidBoundaryPrecision
        }
        guard end > start else {
            throw ValidationError.invalidInterval
        }
        guard aggregationVersion > 0 else {
            throw ValidationError.invalidAggregationVersion
        }

        self.timeWindow = timeWindow
        self.start = start
        self.end = end
        self.basis = basis
        self.aggregationVersion = aggregationVersion
    }

    private static func isPersistableBoundary(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite
            && seconds.rounded(.towardZero) == seconds
            && seconds >= -9_223_372_036_854_775_808
            && seconds < 9_223_372_036_854_775_808
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            timeWindow: container.decode(TimeWindow.self, forKey: .timeWindow),
            start: container.decode(Date.self, forKey: .start),
            end: container.decode(Date.self, forKey: .end),
            basis: container.decode(UsageWindowBasis.self, forKey: .basis),
            aggregationVersion: container.decode(Int.self, forKey: .aggregationVersion)
        )
    }
}

public enum UsageSnapshotProvenance: Codable, Equatable, Hashable, Sendable {
    case bounded(source: UsageMetricSource, window: ExactUsageWindow)
    case legacy(timeWindow: TimeWindow)

    public var timeWindow: TimeWindow {
        switch self {
        case let .bounded(_, window):
            window.timeWindow
        case let .legacy(timeWindow):
            timeWindow
        }
    }

    public var source: UsageMetricSource? {
        guard case let .bounded(source, _) = self else { return nil }
        return source
    }

    public var exactWindow: ExactUsageWindow? {
        guard case let .bounded(_, window) = self else { return nil }
        return window
    }
}

public struct CurrentUsageWindows: Codable, Equatable, Hashable, Sendable {
    public enum ResolutionError: Error, Equatable {
        case unableToResolveBoundary
    }

    public let today: ExactUsageWindow
    public let currentWeek: ExactUsageWindow
    public let utcBillingWeek: ExactUsageWindow

    public static func resolve(at date: Date, calendar: Calendar) throws -> CurrentUsageWindows {
        let todayStart = calendar.startOfDay(for: date)
        guard let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            throw ResolutionError.unableToResolveBoundary
        }

        let currentWeek = try week(containing: date, calendar: calendar, basis: .localCalendar)

        var utcCalendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else {
            throw ResolutionError.unableToResolveBoundary
        }
        utcCalendar.timeZone = utc

        return try CurrentUsageWindows(
            today: ExactUsageWindow(
                timeWindow: .today,
                start: todayStart,
                end: todayEnd,
                basis: .localCalendar
            ),
            currentWeek: currentWeek,
            utcBillingWeek: week(containing: date, calendar: utcCalendar, basis: .utcBilling)
        )
    }

    private static func week(
        containing date: Date,
        calendar: Calendar,
        basis: UsageWindowBasis
    ) throws -> ExactUsageWindow {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysSinceMonday = (weekday + 5) % 7
        guard
            let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: dayStart),
            let end = calendar.date(byAdding: .day, value: 7, to: start)
        else {
            throw ResolutionError.unableToResolveBoundary
        }

        return try ExactUsageWindow(
            timeWindow: .currentWeek,
            start: start,
            end: end,
            basis: basis
        )
    }
}

public struct UsageReplacementScope: Equatable, Sendable {
    public let provider: ProviderKind
    public let source: UsageMetricSource
    public let windows: Set<ExactUsageWindow>

    public init(provider: ProviderKind, source: UsageMetricSource, windows: Set<ExactUsageWindow>) {
        self.provider = provider
        self.source = source
        self.windows = windows
    }
}

public struct UsageScopedReplacement: Equatable, Sendable {
    public let scope: UsageReplacementScope
    public let metrics: [UsageMetric]

    public init(scope: UsageReplacementScope, metrics: [UsageMetric]) {
        self.scope = scope
        self.metrics = metrics
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
        confirmedUsageRatio.flatMap(displayPercentage)
    }

    public var confirmedUsageRatio: Double? {
        guard case let .confirmed(used, limit) = self,
              used.isFinite,
              used >= 0,
              limit.isFinite,
              limit > 0 else {
            return nil
        }

        let ratio = used / limit
        return ratio.isFinite ? ratio : nil
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
    public let provenance: UsageSnapshotProvenance
    public let tokenUsage: TokenUsage
    public let cost: Cost?
    public let limitStatus: LimitStatus
    public let refreshedAt: Date?
    public let freshness: Freshness

    public var timeWindow: TimeWindow { provenance.timeWindow }

    private enum CodingKeys: String, CodingKey {
        case provider
        case accountLabel
        case projectLabel
        case modelLabel
        case deploymentLabel
        case provenance
        case timeWindow
        case tokenUsage
        case cost
        case limitStatus
        case refreshedAt
        case freshness
    }

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
        self.provenance = .legacy(timeWindow: timeWindow)
        self.tokenUsage = tokenUsage
        self.cost = cost
        self.limitStatus = limitStatus
        self.refreshedAt = refreshedAt
        self.freshness = freshness
    }

    public init(
        provider: ProviderKind,
        accountLabel: String?,
        projectLabel: String?,
        modelLabel: String,
        deploymentLabel: String?,
        provenance: UsageSnapshotProvenance,
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
        self.provenance = provenance
        self.tokenUsage = tokenUsage
        self.cost = cost
        self.limitStatus = limitStatus
        self.refreshedAt = refreshedAt
        self.freshness = freshness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provenance: UsageSnapshotProvenance
        if let decoded = try container.decodeIfPresent(UsageSnapshotProvenance.self, forKey: .provenance) {
            provenance = decoded
        } else {
            provenance = .legacy(timeWindow: try container.decode(TimeWindow.self, forKey: .timeWindow))
        }

        self.init(
            provider: try container.decode(ProviderKind.self, forKey: .provider),
            accountLabel: try container.decodeIfPresent(String.self, forKey: .accountLabel),
            projectLabel: try container.decodeIfPresent(String.self, forKey: .projectLabel),
            modelLabel: try container.decode(String.self, forKey: .modelLabel),
            deploymentLabel: try container.decodeIfPresent(String.self, forKey: .deploymentLabel),
            provenance: provenance,
            tokenUsage: try container.decode(TokenUsage.self, forKey: .tokenUsage),
            cost: try container.decodeIfPresent(Cost.self, forKey: .cost),
            limitStatus: try container.decode(LimitStatus.self, forKey: .limitStatus),
            refreshedAt: try container.decodeIfPresent(Date.self, forKey: .refreshedAt),
            freshness: try container.decode(Freshness.self, forKey: .freshness)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(accountLabel, forKey: .accountLabel)
        try container.encodeIfPresent(projectLabel, forKey: .projectLabel)
        try container.encode(modelLabel, forKey: .modelLabel)
        try container.encodeIfPresent(deploymentLabel, forKey: .deploymentLabel)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(cost, forKey: .cost)
        try container.encode(limitStatus, forKey: .limitStatus)
        try container.encodeIfPresent(refreshedAt, forKey: .refreshedAt)
        try container.encode(freshness, forKey: .freshness)
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
