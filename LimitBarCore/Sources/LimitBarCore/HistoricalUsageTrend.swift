import Foundation

public struct HistoricalUsageTrendPeriod: Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable {
        case unsupportedWindow
        case invalidTimeZone
        case invalidUTCTimeZone
        case periodDoesNotMatchTimeZone
    }

    public let window: ExactUsageWindow
    public let timeZoneIdentifier: String

    public init(window: ExactUsageWindow, timeZoneIdentifier: String) throws {
        guard window.timeWindow == .today || window.timeWindow == .currentWeek else {
            throw ValidationError.unsupportedWindow
        }
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw ValidationError.invalidTimeZone
        }
        if window.basis == .utcBilling, timeZoneIdentifier != "UTC" {
            throw ValidationError.invalidUTCTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let expected = window.timeWindow.interval(containing: window.start, calendar: calendar)
        guard expected.start == window.start, expected.end == window.end else {
            throw ValidationError.periodDoesNotMatchTimeZone
        }

        self.window = window
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public enum HistoricalUsageCoverageScope: Equatable, Hashable, Sendable {
    case providerTotal
    case model(String)
}

public struct HistoricalUsageObservedScope: Equatable, Hashable, Sendable {
    public let provider: ProviderKind
    public let source: UsageMetricSource
    public let period: HistoricalUsageTrendPeriod

    public init(provider: ProviderKind, source: UsageMetricSource, period: HistoricalUsageTrendPeriod) {
        self.provider = provider
        self.source = source
        self.period = period
    }
}

public struct HistoricalUsageCalculatedCost: Equatable, Sendable {
    public enum ValidationError: Error, Equatable {
        case invalidCostSource
        case negativeAmount
        case missingPricingRevision
    }

    public let cost: Cost
    public let pricingRevision: String
    public let pricingEffectiveAt: Date

    public init(cost: Cost, pricingRevision: String, pricingEffectiveAt: Date) throws {
        guard cost.source == .calculatedEstimate else { throw ValidationError.invalidCostSource }
        guard cost.amount >= 0 else { throw ValidationError.negativeAmount }
        guard !pricingRevision.isEmpty else { throw ValidationError.missingPricingRevision }
        self.cost = cost
        self.pricingRevision = pricingRevision
        self.pricingEffectiveAt = pricingEffectiveAt
    }
}

public struct HistoricalUsageTrendSample: Equatable, Sendable {
    public enum ValidationError: Error, Equatable {
        case legacyMetric
        case emptyModelScope
        case negativeTokenCount
        case invalidProviderReportedCost
        case calculatedMetricRequiresPricing
        case unexpectedCalculatedCost
    }

    public let provider: ProviderKind
    public let source: UsageMetricSource
    public let coverage: HistoricalUsageCoverageScope
    public let period: HistoricalUsageTrendPeriod
    public let tokenUsage: TokenUsage
    public let providerReportedCost: Cost?
    public let calculatedCost: HistoricalUsageCalculatedCost?

    public init(
        provider: ProviderKind,
        source: UsageMetricSource,
        coverage: HistoricalUsageCoverageScope,
        period: HistoricalUsageTrendPeriod,
        tokenUsage: TokenUsage,
        providerReportedCost: Cost? = nil,
        calculatedCost: HistoricalUsageCalculatedCost? = nil
    ) throws {
        if case let .model(model) = coverage, model.isEmpty { throw ValidationError.emptyModelScope }
        guard tokenUsage.inputTokens >= 0, tokenUsage.outputTokens >= 0 else {
            throw ValidationError.negativeTokenCount
        }
        guard providerReportedCost?.source != .calculatedEstimate,
              providerReportedCost?.amount ?? 0 >= 0 else {
            throw ValidationError.invalidProviderReportedCost
        }

        self.provider = provider
        self.source = source
        self.coverage = coverage
        self.period = period
        self.tokenUsage = tokenUsage
        self.providerReportedCost = providerReportedCost
        self.calculatedCost = calculatedCost
    }

    public init(
        metric: UsageMetric,
        coverage: HistoricalUsageCoverageScope,
        localTimeZoneIdentifier: String,
        calculatedCost: HistoricalUsageCalculatedCost? = nil
    ) throws {
        guard case let .bounded(source, window) = metric.provenance else {
            throw ValidationError.legacyMetric
        }
        let timeZoneIdentifier = window.basis == .utcBilling ? "UTC" : localTimeZoneIdentifier
        let metricCalculatedCost = metric.cost?.source == .calculatedEstimate ? metric.cost : nil
        if metricCalculatedCost != nil, calculatedCost == nil {
            throw ValidationError.calculatedMetricRequiresPricing
        }
        if let metricCalculatedCost, metricCalculatedCost != calculatedCost?.cost {
            throw ValidationError.unexpectedCalculatedCost
        }
        if metricCalculatedCost == nil, calculatedCost != nil {
            throw ValidationError.unexpectedCalculatedCost
        }

        try self.init(
            provider: metric.provider,
            source: source,
            coverage: coverage,
            period: HistoricalUsageTrendPeriod(window: window, timeZoneIdentifier: timeZoneIdentifier),
            tokenUsage: metric.tokenUsage,
            providerReportedCost: metric.cost?.source == .providerReported ? metric.cost : nil,
            calculatedCost: calculatedCost
        )
    }
}

public enum HistoricalUsageObservationLifecycle: String, Equatable, Sendable {
    case provisional
    case final
    case superseded
}

public struct HistoricalUsageTrendObservation: Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let supersedesID: UUID?
    public let lifecycle: HistoricalUsageObservationLifecycle
    public let recordedAt: Date
    public let sample: HistoricalUsageTrendSample

    init(
        id: UUID,
        revision: Int,
        supersedesID: UUID?,
        lifecycle: HistoricalUsageObservationLifecycle,
        recordedAt: Date,
        sample: HistoricalUsageTrendSample
    ) {
        self.id = id
        self.revision = revision
        self.supersedesID = supersedesID
        self.lifecycle = lifecycle
        self.recordedAt = recordedAt
        self.sample = sample
    }
}

public struct HistoricalUsageTrendBucket: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case gap
        case observed([HistoricalUsageTrendObservation])
    }

    public let period: HistoricalUsageTrendPeriod
    public let value: Value

    public init(period: HistoricalUsageTrendPeriod, value: Value) {
        self.period = period
        self.value = value
    }

    public var authoritativeTotals: [HistoricalUsageTrendObservation] {
        guard case let .observed(observations) = value else { return [] }
        let totals = observations.filter { $0.sample.coverage == .providerTotal }
        let providersWithAPITotals = Set(totals.compactMap {
            $0.sample.source == .providerAPI ? $0.sample.provider : nil
        })
        return totals.filter {
            $0.sample.source == .providerAPI || !providersWithAPITotals.contains($0.sample.provider)
        }
    }

    public var modelAttributions: [HistoricalUsageTrendObservation] {
        guard case let .observed(observations) = value else { return [] }
        return observations.filter {
            if case .model = $0.sample.coverage { return true }
            return false
        }
    }

    public var preferredTokenObservations: [HistoricalUsageTrendObservation] {
        guard case let .observed(observations) = value else { return [] }
        return Dictionary(grouping: observations, by: { $0.sample.provider }).values.flatMap { provider in
            let totals = provider.filter { $0.sample.coverage == .providerTotal }
            if let apiTotal = totals.first(where: { $0.sample.source == .providerAPI }) {
                return [apiTotal]
            }
            if !totals.isEmpty { return totals }
            return provider.filter {
                if case .model = $0.sample.coverage { return true }
                return false
            }
        }
    }

    public var preferredCostObservations: [HistoricalUsageTrendObservation] {
        guard case let .observed(observations) = value else { return [] }
        return Dictionary(grouping: observations, by: { $0.sample.provider }).values.flatMap { provider in
            let costs = provider.filter {
                $0.sample.providerReportedCost != nil || $0.sample.calculatedCost != nil
            }
            return costs.contains(where: { $0.sample.source == .providerAPI })
                ? costs.filter { $0.sample.source == .providerAPI }
                : costs
        }
    }

    public var preferredTotalTokens: Int? {
        var total = 0
        for observation in preferredTokenObservations {
            let result = total.addingReportingOverflow(observation.sample.tokenUsage.totalTokens)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }
}

public enum HistoricalUsageRetention: Int, CaseIterable, Sendable {
    case days30 = 30
    case days90 = 90
    case days365 = 365
    case days730 = 730

    public static let `default`: Self = .days365

    public var displayName: String { "\(rawValue) days" }
}

public struct HistoricalUsageSnapshot: Equatable, Sendable {
    public let dailyBuckets: [HistoricalUsageTrendBucket]
    public let weeklyBuckets: [HistoricalUsageTrendBucket]
    public let health: UsageStoreHealth
    public let retention: HistoricalUsageRetention

    public init(
        dailyBuckets: [HistoricalUsageTrendBucket],
        weeklyBuckets: [HistoricalUsageTrendBucket],
        health: UsageStoreHealth,
        retention: HistoricalUsageRetention
    ) {
        self.dailyBuckets = dailyBuckets
        self.weeklyBuckets = weeklyBuckets
        self.health = health
        self.retention = retention
    }

    public static let loading = HistoricalUsageSnapshot(
        dailyBuckets: [],
        weeklyBuckets: [],
        health: UsageStoreHealth(isOpen: false, message: "Loading historical usage"),
        retention: .default
    )
}
