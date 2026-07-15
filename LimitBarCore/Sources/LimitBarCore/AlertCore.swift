import Foundation

public enum AlertValidationError: Error, Equatable {
    case invalidThreshold
    case invalidBudgetCap
    case invalidCurrencyCode
    case invalidWindowIdentity
    case duplicateRuleID
}

public enum ProviderProduct: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case claudeCode
    case codex
    case anthropicAPI
    case openAIAPI
    case azureOpenAI

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .anthropicAPI: "Anthropic API"
        case .openAIAPI: "OpenAI API"
        case .azureOpenAI: "Azure OpenAI"
        }
    }

    public init?(provider: ProviderKind) {
        switch provider {
        case .anthropic: self = .anthropicAPI
        case .openAI: self = .openAIAPI
        case .azureOpenAI: self = .azureOpenAI
        case .custom: return nil
        }
    }
}

public struct PercentageThresholds: Codable, Equatable, Hashable, Sendable {
    public let values: [Int]

    public static let suggested = PercentageThresholds(validated: [70, 90])

    public init(_ values: [Int]) throws {
        guard !values.isEmpty, values.allSatisfy({ (1...100).contains($0) }) else {
            throw AlertValidationError.invalidThreshold
        }
        self.values = Array(Set(values)).sorted()
    }

    private init(validated values: [Int]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode([Int].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

public struct QuotaAlertRule: Codable, Equatable, Sendable {
    public let id: UUID
    public let product: ProviderProduct
    public let thresholds: PercentageThresholds
    public let isEnabled: Bool

    public init(
        id: UUID = UUID(),
        product: ProviderProduct,
        thresholds: PercentageThresholds = .suggested,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.product = product
        self.thresholds = thresholds
        self.isEnabled = isEnabled
    }
}

public struct CostBudgetAlertRule: Codable, Equatable, Sendable {
    public let id: UUID
    public let product: ProviderProduct
    public let currencyCode: String
    public let source: CostSource
    public let timeWindow: TimeWindow
    public let basis: UsageWindowBasis
    public let cap: Decimal
    public let thresholds: PercentageThresholds
    public let isEnabled: Bool

    public init(
        id: UUID = UUID(),
        product: ProviderProduct,
        currencyCode: String,
        source: CostSource,
        timeWindow: TimeWindow,
        basis: UsageWindowBasis,
        cap: Decimal,
        thresholds: PercentageThresholds = .suggested,
        isEnabled: Bool = true
    ) throws {
        let normalizedCurrency = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedCurrency.utf8.count == 3,
              normalizedCurrency.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw AlertValidationError.invalidCurrencyCode
        }
        guard Self.isFinitePositive(cap) else { throw AlertValidationError.invalidBudgetCap }
        self.id = id
        self.product = product
        self.currencyCode = normalizedCurrency
        self.source = source
        self.timeWindow = timeWindow
        self.basis = basis
        self.cap = cap
        self.thresholds = thresholds
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: CodingKey {
        case id, product, currencyCode, source, timeWindow, basis, cap, thresholds, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            product: container.decode(ProviderProduct.self, forKey: .product),
            currencyCode: container.decode(String.self, forKey: .currencyCode),
            source: container.decode(CostSource.self, forKey: .source),
            timeWindow: container.decode(TimeWindow.self, forKey: .timeWindow),
            basis: container.decode(UsageWindowBasis.self, forKey: .basis),
            cap: container.decode(Decimal.self, forKey: .cap),
            thresholds: container.decode(PercentageThresholds.self, forKey: .thresholds),
            isEnabled: container.decode(Bool.self, forKey: .isEnabled)
        )
    }

    private static func isFinitePositive(_ value: Decimal) -> Bool {
        let number = NSDecimalNumber(decimal: value)
        return number != .notANumber && number.doubleValue.isFinite && value > 0
    }
}

public struct AlertPreferences: Codable, Equatable, Sendable {
    public let quotaRules: [QuotaAlertRule]
    public let costBudgetRules: [CostBudgetAlertRule]

    public init(quotaRules: [QuotaAlertRule], costBudgetRules: [CostBudgetAlertRule]) throws {
        let ids = quotaRules.map(\.id) + costBudgetRules.map(\.id)
        guard Set(ids).count == ids.count else { throw AlertValidationError.duplicateRuleID }
        self.quotaRules = quotaRules
        self.costBudgetRules = costBudgetRules
    }

    private enum CodingKeys: CodingKey { case quotaRules, costBudgetRules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            quotaRules: container.decode([QuotaAlertRule].self, forKey: .quotaRules),
            costBudgetRules: container.decode([CostBudgetAlertRule].self, forKey: .costBudgetRules)
        )
    }
}

public struct QuotaWindowIdentity: Codable, Equatable, Hashable, Sendable {
    public let product: ProviderProduct
    public let identifier: String
    public let resetBoundary: Date

    public init(product: ProviderProduct, identifier: String, resetBoundary: Date) throws {
        guard !identifier.isEmpty, resetBoundary.timeIntervalSince1970.isFinite else {
            throw AlertValidationError.invalidWindowIdentity
        }
        self.product = product
        self.identifier = identifier.precomposedStringWithCanonicalMapping
        self.resetBoundary = resetBoundary
    }

    private enum CodingKeys: CodingKey { case product, identifier, resetBoundary }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            product: container.decode(ProviderProduct.self, forKey: .product),
            identifier: container.decode(String.self, forKey: .identifier),
            resetBoundary: container.decode(Date.self, forKey: .resetBoundary)
        )
    }

    public static func claudeCode(_ limit: ClaudeRateLimit) -> QuotaWindowIdentity? {
        guard let reset = limit.resetsAt else { return nil }
        return try? QuotaWindowIdentity(
            product: .claudeCode,
            identifier: "\(limit.group.rawValue):\(limit.kind)",
            resetBoundary: reset
        )
    }

    public static func codex(slot: String, window: CodexRateLimitWindow) -> QuotaWindowIdentity? {
        guard slot == "primary" || slot == "secondary", let reset = window.resetsAt else { return nil }
        return try? QuotaWindowIdentity(
            product: .codex,
            identifier: "\(window.limitID):\(slot):\(window.windowMinutes)",
            resetBoundary: reset
        )
    }
}

public enum AlertObservationHealth: String, Codable, Equatable, Sendable {
    case healthy
    case unhealthy
}

public struct QuotaObservation: Equatable, Sendable {
    public let identity: QuotaWindowIdentity
    public let percentageUsed: Double
    public let observedAt: Date
    public let expiresAt: Date
    public let isActive: Bool
    public let health: AlertObservationHealth

    public init(
        identity: QuotaWindowIdentity,
        percentageUsed: Double,
        observedAt: Date,
        expiresAt: Date,
        isActive: Bool = true,
        health: AlertObservationHealth = .healthy
    ) {
        self.identity = identity
        self.percentageUsed = percentageUsed
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.isActive = isActive
        self.health = health
    }
}

public enum QuotaFindingAlertKind: String, Equatable, Sendable {
    case forecast
    case anomaly
}

public struct QuotaFindingAlertObservation: Equatable, Sendable {
    public let identity: QuotaWindowIdentity
    public let percentageUsed: Double
    public let kind: QuotaFindingAlertKind
    public let methodVersion: String
    public let qualification: String
    public let valueClassification: QuotaAnomalyEvidenceClassification

    init(
        identity: QuotaWindowIdentity,
        percentageUsed: Double,
        kind: QuotaFindingAlertKind,
        methodVersion: String,
        qualification: String,
        valueClassification: QuotaAnomalyEvidenceClassification
    ) {
        self.identity = identity
        self.percentageUsed = percentageUsed
        self.kind = kind
        self.methodVersion = methodVersion
        self.qualification = qualification
        self.valueClassification = valueClassification
    }
}

/// Converts forensic findings only after checking the fields needed by the alert boundary:
/// exact identity for ledger scope, qualification and method for traceability, finding evidence
/// time for freshness, an active matching quota observation for threshold evaluation, and the
/// value classification for copy that does not overstate calculated or inferred evidence.
public enum QuotaFindingAlertAdapter {
    public static func candidates(
        forecasts: [QuotaInsightState],
        anomalies: [QuotaAnomalyState],
        quota: [QuotaObservation],
        now: Date
    ) -> [QuotaFindingAlertObservation] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        let eligibleQuota = Dictionary(grouping: quota.filter { eligible($0, now: now) }, by: \.identity)
            .compactMapValues { $0.max { $0.percentageUsed < $1.percentageUsed } }
        let forecastCandidates = forecasts.compactMap { state -> QuotaFindingAlertObservation? in
            guard case let .qualified(finding) = state,
                  let observation = eligibleQuota[finding.identity],
                  finding.createdAt.timeIntervalSince1970.isFinite,
                  finding.createdAt <= now,
                  finding.evidenceAge.isFinite,
                  finding.evidenceAge >= 0,
                  isFresh(
                    finding.createdAt.addingTimeInterval(-finding.evidenceAge),
                    product: finding.identity.product,
                    now: now
                  ),
                  let exhaustion = finding.calculatedExhaustionRange,
                  exhaustion.lowerBound >= finding.createdAt.addingTimeInterval(-finding.evidenceAge),
                  exhaustion.upperBound < finding.identity.resetBoundary else { return nil }
            return QuotaFindingAlertObservation(
                identity: finding.identity,
                percentageUsed: observation.percentageUsed,
                kind: .forecast,
                methodVersion: finding.forecastMethod.rawValue,
                qualification: QuotaInsightQualificationStatus.qualified.rawValue,
                valueClassification: .calculated
            )
        }
        let anomalyCandidates = anomalies.compactMap { state -> QuotaFindingAlertObservation? in
            guard case let .finding(finding) = state,
                  finding.metadata.qualification == .qualified,
                  finding.metadata.implicatedIdentities == [finding.identity],
                  let createdAt = finding.metadata.createdAt,
                  createdAt.timeIntervalSince1970.isFinite,
                  createdAt <= now,
                  let currentPeriod = finding.metadata.currentPeriod,
                  currentPeriod.end <= createdAt,
                  isFresh(currentPeriod.end, product: finding.identity.product, now: now),
                  let observation = eligibleQuota[finding.identity] else { return nil }
            return QuotaFindingAlertObservation(
                identity: finding.identity,
                percentageUsed: observation.percentageUsed,
                kind: .anomaly,
                methodVersion: finding.metadata.method.rawValue,
                qualification: finding.metadata.qualification.rawValue,
                valueClassification: finding.valueClassification
            )
        }
        return forecastCandidates + anomalyCandidates
    }

    private static func eligible(_ observation: QuotaObservation, now: Date) -> Bool {
        observation.isActive
            && observation.health == .healthy
            && observation.percentageUsed.isFinite
            && (0...100).contains(observation.percentageUsed)
            && observation.observedAt.timeIntervalSince1970.isFinite
            && observation.observedAt <= now
            && observation.expiresAt >= now
            && observation.identity.resetBoundary > now
    }

    private static func isFresh(_ observedAt: Date, product: ProviderProduct, now: Date) -> Bool {
        let maximumAge: TimeInterval
        switch product {
        case .claudeCode: maximumAge = QuotaObservationAdapter.claudeMaximumAge
        case .codex: maximumAge = QuotaObservationAdapter.codexMaximumAge
        case .anthropicAPI, .openAIAPI, .azureOpenAI: return false
        }
        let age = now.timeIntervalSince(observedAt)
        return observedAt.timeIntervalSince1970.isFinite && age >= 0 && age <= maximumAge
    }
}

public enum QuotaObservationAdapter {
    public static let claudeMaximumAge: TimeInterval = 15 * 60
    public static let codexMaximumAge: TimeInterval = 6 * 60 * 60

    public static func claude(
        _ snapshot: ClaudeRateLimitSnapshot,
        subscriptionType: String?,
        now: Date,
        maximumAge: TimeInterval = claudeMaximumAge
    ) -> [QuotaObservation] {
        guard isFresh(snapshot.fetchedAt, now: now, maximumAge: maximumAge) else { return [] }
        return snapshot.displayLimits(forSubscriptionType: subscriptionType).compactMap { limit in
            guard limit.isActive,
                  limit.percentUsed.isFinite,
                  (0...100).contains(limit.percentUsed),
                  let reset = limit.resetsAt,
                  isFutureFinite(reset, now: now) else { return nil }
            guard let identity = QuotaWindowIdentity.claudeCode(limit) else { return nil }
            return QuotaObservation(
                identity: identity,
                percentageUsed: limit.percentUsed,
                observedAt: snapshot.fetchedAt,
                expiresAt: snapshot.fetchedAt.addingTimeInterval(maximumAge)
            )
        }
    }

    public static func codex(
        _ snapshot: CodexRateLimitSnapshot,
        now: Date,
        maximumAge: TimeInterval = codexMaximumAge
    ) -> [QuotaObservation] {
        guard !snapshot.isBusinessPlan,
              isFresh(snapshot.reportedAt, now: now, maximumAge: maximumAge) else { return [] }
        return [("primary", snapshot.primary), ("secondary", snapshot.secondary)].compactMap { slot, window in
            guard let window,
                  window.percentUsed.isFinite,
                  (0...100).contains(window.percentUsed),
                  let reset = window.resetsAt,
                  isFutureFinite(reset, now: now),
                  let identity = QuotaWindowIdentity.codex(slot: slot, window: window) else { return nil }
            return QuotaObservation(
                identity: identity,
                percentageUsed: window.percentUsed,
                observedAt: snapshot.reportedAt,
                expiresAt: snapshot.reportedAt.addingTimeInterval(maximumAge)
            )
        }
    }

    private static func isFresh(_ date: Date, now: Date, maximumAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(date)
        return date.timeIntervalSince1970.isFinite && maximumAge.isFinite && maximumAge >= 0 && age >= 0 && age <= maximumAge
    }

    private static func isFutureFinite(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date > now
    }
}

public struct CostBudgetObservation: Equatable, Sendable {
    public let product: ProviderProduct
    public let source: CostSource
    public let window: ExactUsageWindow
    public let currencyCode: String
    public let amount: Decimal
    public let observedAt: Date
    public let health: AlertObservationHealth

    public init(
        product: ProviderProduct,
        source: CostSource,
        window: ExactUsageWindow,
        currencyCode: String,
        amount: Decimal,
        observedAt: Date,
        health: AlertObservationHealth = .healthy
    ) {
        self.product = product
        self.source = source
        self.window = window
        self.currencyCode = currencyCode.uppercased()
        self.amount = amount
        self.observedAt = observedAt
        self.health = health
    }
}

public enum CostBudgetObservationBuilder {
    public static let maximumMeasurementAge: TimeInterval = 24 * 60 * 60

    private struct SelectionKey: Hashable {
        let product: ProviderProduct
        let window: ExactUsageWindow
    }

    private struct TotalKey: Hashable {
        let product: ProviderProduct
        let source: String
        let window: ExactUsageWindow
        let currency: String
    }

    public static func observations(
        metrics: [UsageMetric],
        pricing: PricingTable,
        health: AlertObservationHealth,
        now: Date = Date(),
        maximumMeasurementAge: TimeInterval = CostBudgetObservationBuilder.maximumMeasurementAge
    ) -> [CostBudgetObservation] {
        let eligible = metrics.compactMap { metric -> (UsageMetric, ProviderProduct, ExactUsageWindow, UsageMetricSource)? in
            guard !metric.freshness.isStale,
                  let product = ProviderProduct(provider: metric.provider),
                  case let .bounded(source, window) = metric.provenance,
                  source == .providerAPI || source == .builtInLocalLog,
                  let refreshedAt = metric.refreshedAt,
                  refreshedAt.timeIntervalSince1970.isFinite,
                  window.start <= refreshedAt,
                  refreshedAt <= now,
                  now.timeIntervalSince(refreshedAt) <= maximumMeasurementAge,
                  now < window.end else { return nil }
            return (metric, product, window, source)
        }
        let grouped = Dictionary(grouping: eligible) { SelectionKey(product: $0.1, window: $0.2) }
        var totals: [TotalKey: (amount: Decimal, observedAt: Date)] = [:]
        var invalidTotals = Set<TotalKey>()

        for entries in grouped.values {
            let apiEntries = entries.filter { $0.3 == .providerAPI }
            let localEntries = entries.filter { $0.3 == .builtInLocalLog }

            for (metric, product, window, _) in apiEntries {
                if let stored = metric.cost,
                   stored.source == .providerReported,
                   valid(cost: stored) {
                    add(
                        stored,
                        product: product,
                        window: window,
                        observedAt: metric.refreshedAt!,
                        to: &totals,
                        invalidTotals: &invalidTotals
                    )
                }
            }

            let apiCalculated = apiEntries.filter { hasCalculatedMeasure($0.0) }
            let localCalculated = localEntries.filter { hasCalculatedMeasure($0.0) }
            let calculatedEntries = apiCalculated.isEmpty ? localCalculated : apiCalculated
            for (metric, product, window, _) in calculatedEntries {
                let calculated: Cost?
                if let stored = metric.cost, stored.source == .calculatedEstimate {
                    calculated = stored
                } else {
                    calculated = CostCalculator.estimatedCost(for: metric, pricing: pricing)
                }
                if let calculated, valid(cost: calculated) {
                    add(
                        calculated,
                        product: product,
                        window: window,
                        observedAt: metric.refreshedAt!,
                        to: &totals,
                        invalidTotals: &invalidTotals
                    )
                }
            }
        }

        return totals.map { key, total in
            CostBudgetObservation(
                product: key.product,
                source: CostSource(rawValue: key.source)!,
                window: key.window,
                currencyCode: key.currency,
                amount: total.amount,
                observedAt: total.observedAt,
                health: health
            )
        }.sorted { lhs, rhs in
            if lhs.product != rhs.product { return lhs.product.rawValue < rhs.product.rawValue }
            if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
            return lhs.currencyCode < rhs.currencyCode
        }
    }

    private static func valid(cost: Cost) -> Bool {
        let number = NSDecimalNumber(decimal: cost.amount)
        return number != .notANumber && number.doubleValue.isFinite && cost.amount >= 0 && !cost.currencyCode.isEmpty
    }

    private static func hasCalculatedMeasure(_ metric: UsageMetric) -> Bool {
        if metric.cost?.source == .calculatedEstimate { return true }
        return metric.tokenUsage.inputTokens >= 0
            && metric.tokenUsage.outputTokens >= 0
            && (metric.tokenUsage.inputTokens > 0 || metric.tokenUsage.outputTokens > 0)
    }

    private static func add(
        _ cost: Cost,
        product: ProviderProduct,
        window: ExactUsageWindow,
        observedAt: Date,
        to totals: inout [TotalKey: (amount: Decimal, observedAt: Date)],
        invalidTotals: inout Set<TotalKey>
    ) {
        let key = TotalKey(product: product, source: cost.source.rawValue, window: window, currency: cost.currencyCode.uppercased())
        guard !invalidTotals.contains(key) else { return }
        guard let existing = totals[key] else {
            totals[key] = (cost.amount, observedAt)
            return
        }
        var lhs = existing.amount
        var rhs = cost.amount
        var sum = Decimal()
        guard NSDecimalAdd(&sum, &lhs, &rhs, .plain) == .noError,
              valid(cost: Cost(amount: sum, currencyCode: cost.currencyCode, source: cost.source)) else {
            totals.removeValue(forKey: key)
            invalidTotals.insert(key)
            return
        }
        totals[key] = (sum, max(existing.observedAt, observedAt))
    }
}

public enum AlertWindowIdentity: Codable, Equatable, Hashable, Sendable {
    case quota(QuotaWindowIdentity)
    case cost(ExactUsageWindow)

    public var boundary: Date {
        switch self {
        case let .quota(identity): identity.resetBoundary
        case let .cost(window): window.end
        }
    }

    public var canonicalIdentifier: String {
        switch self {
        case let .quota(identity):
            let identifier = identity.identifier
            return "q|\(identity.product.rawValue)|\(identifier.utf8.count):\(identifier)|\(identity.resetBoundary.timeIntervalSince1970.bitPattern)"
        case let .cost(exact):
            return "c|\(exact.timeWindow.rawValue)|\(exact.basis.rawValue)|\(exact.aggregationVersion)|\(Int64(exact.start.timeIntervalSince1970))|\(Int64(exact.end.timeIntervalSince1970))"
        }
    }
}

public struct AlertThresholdSatisfaction: Codable, Equatable, Hashable, Sendable {
    public let ruleID: UUID
    public let window: AlertWindowIdentity
    public let threshold: Int

    public init(ruleID: UUID, window: AlertWindowIdentity, threshold: Int) {
        self.ruleID = ruleID
        self.window = window
        self.threshold = threshold
    }
}

public struct AlertOccurrence: Codable, Equatable, Sendable {
    public let ruleID: UUID
    public let window: AlertWindowIdentity
    public let thresholds: [Int]

    public init(ruleID: UUID, window: AlertWindowIdentity, thresholds: [Int]) {
        self.ruleID = ruleID
        self.window = window
        self.thresholds = Array(Set(thresholds.filter { (1...100).contains($0) })).sorted()
    }
}

public struct AlertNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    public let threshold: Int

    public init(title: String, body: String, threshold: Int) {
        self.title = title
        self.body = body
        self.threshold = threshold
    }
}

public struct AlertEvaluation: Equatable, Sendable {
    public let occurrence: AlertOccurrence
    public let notification: AlertNotification
}

public enum AlertEvaluator {
    public static func evaluate(
        preferences: AlertPreferences,
        quota: [QuotaObservation],
        costs: [CostBudgetObservation],
        findings: [QuotaFindingAlertObservation] = [],
        satisfied: Set<AlertThresholdSatisfaction>,
        now: Date
    ) -> [AlertEvaluation] {
        var evaluations: [AlertEvaluation] = []
        for rule in preferences.quotaRules where rule.isEnabled {
            let eligibleFindings = findings.filter {
                $0.identity.product == rule.product
                    && $0.identity.resetBoundary > now
                    && $0.percentageUsed.isFinite
                    && (0...100).contains($0.percentageUsed)
                    && !$0.methodVersion.isEmpty
                    && $0.qualification == "qualified"
            }
            let findingObservations = Dictionary(grouping: eligibleFindings, by: \.identity).compactMap { _, values in
                values.max { lhs, rhs in
                    if lhs.percentageUsed != rhs.percentageUsed { return lhs.percentageUsed < rhs.percentageUsed }
                    // One rule threshold has one delivery opportunity per exact window.
                    return notificationPriority(lhs.kind) < notificationPriority(rhs.kind)
                }
            }
            let findingIdentities = Set(findingObservations.map(\.identity))
            let eligibleObservations = quota.filter {
                eligible($0, for: rule, now: now) && !findingIdentities.contains($0.identity)
            }
            let observations = Dictionary(grouping: eligibleObservations, by: \.identity).compactMap { _, values in
                values.max { $0.percentageUsed < $1.percentageUsed }
            }
            for observation in observations {
                let window = AlertWindowIdentity.quota(observation.identity)
                if let thresholds = newlyQualified(rule.thresholds.values, percentage: observation.percentageUsed, ruleID: rule.id, window: window, satisfied: satisfied) {
                    let highest = thresholds.last!
                    evaluations.append(AlertEvaluation(
                        occurrence: AlertOccurrence(ruleID: rule.id, window: window, thresholds: thresholds),
                        notification: AlertNotification(
                            title: "Usage alert",
                            body: "\(rule.product.displayName) quota usage reached \(highest)%.",
                            threshold: highest
                        )
                    ))
                }
            }
            for finding in findingObservations {
                let window = AlertWindowIdentity.quota(finding.identity)
                if let thresholds = newlyQualified(rule.thresholds.values, percentage: finding.percentageUsed, ruleID: rule.id, window: window, satisfied: satisfied) {
                    let highest = thresholds.last!
                    evaluations.append(AlertEvaluation(
                        occurrence: AlertOccurrence(ruleID: rule.id, window: window, thresholds: thresholds),
                        notification: findingNotification(finding, product: rule.product, threshold: highest)
                    ))
                }
            }
        }
        for rule in preferences.costBudgetRules where rule.isEnabled {
            let eligibleObservations = costs.filter { eligible($0, for: rule, now: now) }
            let observations = Dictionary(grouping: eligibleObservations, by: \.window).compactMap { _, values in
                values.max { $0.amount < $1.amount }
            }
            for observation in observations {
                let percentage = NSDecimalNumber(decimal: observation.amount / rule.cap * 100).doubleValue
                let window = AlertWindowIdentity.cost(observation.window)
                if let thresholds = newlyQualified(rule.thresholds.values, percentage: percentage, ruleID: rule.id, window: window, satisfied: satisfied) {
                    let highest = thresholds.last!
                    let prefix = rule.source == .providerReported ? "Provider-reported \(rule.product.displayName)" : "Estimated \(rule.product.displayName)"
                    evaluations.append(AlertEvaluation(
                        occurrence: AlertOccurrence(ruleID: rule.id, window: window, thresholds: thresholds),
                        notification: AlertNotification(
                            title: "Budget alert",
                            body: "\(prefix) cost reached \(highest)% of the \(rule.currencyCode) budget.",
                            threshold: highest
                        )
                    ))
                }
            }
        }
        return evaluations
    }

    private static func eligible(_ observation: QuotaObservation, for rule: QuotaAlertRule, now: Date) -> Bool {
        observation.identity.product == rule.product
            && observation.isActive
            && observation.health == .healthy
            && observation.percentageUsed.isFinite
            && (0...100).contains(observation.percentageUsed)
            && observation.observedAt.timeIntervalSince1970.isFinite
            && observation.observedAt <= now
            && observation.expiresAt >= now
            && observation.identity.resetBoundary > now
    }

    private static func eligible(_ observation: CostBudgetObservation, for rule: CostBudgetAlertRule, now: Date) -> Bool {
        let number = NSDecimalNumber(decimal: observation.amount)
        return observation.product == rule.product
            && observation.source == rule.source
            && observation.window.timeWindow == rule.timeWindow
            && observation.window.basis == rule.basis
            && observation.currencyCode == rule.currencyCode
            && observation.health == .healthy
            && number != .notANumber
            && number.doubleValue.isFinite
            && observation.amount >= 0
            && observation.observedAt.timeIntervalSince1970.isFinite
            && observation.observedAt <= now
            && observation.window.start <= now
            && observation.window.end > now
    }

    private static func newlyQualified(
        _ thresholds: [Int],
        percentage: Double,
        ruleID: UUID,
        window: AlertWindowIdentity,
        satisfied: Set<AlertThresholdSatisfaction>
    ) -> [Int]? {
        guard percentage.isFinite else { return nil }
        let newlyQualified = thresholds.filter {
            percentage >= Double($0)
                && !satisfied.contains(AlertThresholdSatisfaction(ruleID: ruleID, window: window, threshold: $0))
        }
        return newlyQualified.isEmpty ? nil : newlyQualified
    }

    private static func findingNotification(
        _ finding: QuotaFindingAlertObservation,
        product: ProviderProduct,
        threshold: Int
    ) -> AlertNotification {
        let classification = switch finding.valueClassification {
        case .reported: "Provider-reported"
        case .measured: "Measured"
        case .calculated: "Calculated"
        case .inferred: "Inferred"
        }
        return switch finding.kind {
        case .forecast:
            AlertNotification(
                title: "Quota forecast",
                body: "\(classification) \(product.displayName) forecast indicates quota may exhaust before reset. Open LimitBar for details.",
                threshold: threshold
            )
        case .anomaly:
            AlertNotification(
                title: "Quota anomaly",
                body: "\(classification) \(product.displayName) analysis found unusual quota consumption. Open LimitBar for details.",
                threshold: threshold
            )
        }
    }

    private static func notificationPriority(_ kind: QuotaFindingAlertKind) -> Int {
        switch kind {
        case .forecast: 1
        case .anomaly: 0
        }
    }
}
