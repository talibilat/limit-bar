import Foundation

public enum ClaudeQuotaExplanationUnavailableReason: String, Codable, Equatable, Sendable {
    case insufficientObservations = "insufficient_observations"
    case incompatibleQuotaWindow = "incompatible_quota_window"
    case incompatibleTimestamps = "incompatible_timestamps"
    case counterDecreased = "counter_decreased"
    case expiredQuotaWindow = "expired_quota_window"
    case staleObservations = "stale_observations"

    public var displayText: String {
        switch self {
        case .insufficientObservations: "Collecting two measured Claude Code reports."
        case .incompatibleQuotaWindow: "Measured reports do not belong to one exact Claude Code quota window."
        case .incompatibleTimestamps: "Measured report times cannot be compared safely."
        case .counterDecreased: "Reported quota usage decreased within the exact window."
        case .expiredQuotaWindow: "The exact provider-reported quota window has expired."
        case .staleObservations: "Measured Claude Code reports are stale."
        }
    }
}

public enum ClaudeAttributionUnavailableReason: String, Codable, Equatable, Sendable {
    case sourceNotConfigured = "source_not_configured"
    case noQualifyingEvidence = "no_qualifying_evidence"
    case accountUnverified = "account_unverified"
    case unsupportedEvidence = "unsupported_evidence"
}

public struct ClaudeObservedLocalBreakdown: Codable, Equatable, Sendable {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreationTokens: Int64
    public let modelCounts: [String: Int]
    public let sessionCount: Int
    public let evidenceCount: Int
}

public enum ClaudeQuotaAttribution: Codable, Equatable, Sendable {
    case partial(ClaudeObservedLocalBreakdown)
    case observedZero(ClaudeObservedLocalBreakdown)
    case unavailable(ClaudeAttributionUnavailableReason)
}

public struct ClaudeQuotaExplanation: Codable, Equatable, Sendable {
    public let providerProduct: ProviderProduct
    public let intervalStart: Date
    public let intervalEnd: Date
    public let quotaResetBoundary: Date
    public let reportedQuotaMovementPercent: Double
    public let attribution: ClaudeQuotaAttribution
    public let unattributed: Bool
    public let inferredAllocationPercent: Double?
    public let observationIdentities: [QuotaObservationIdentity]
    public let observationIdentityCount: Int
    public let observationSpan: TimeInterval
    public let evidenceAge: TimeInterval
    public let methodVersion: String
    public let sourceAdapterVersion: String
    public let sourceVersion: String?

    public init(
        providerProduct: ProviderProduct,
        intervalStart: Date,
        intervalEnd: Date,
        quotaResetBoundary: Date,
        reportedQuotaMovementPercent: Double,
        attribution: ClaudeQuotaAttribution,
        unattributed: Bool,
        inferredAllocationPercent: Double?,
        observationIdentities: [QuotaObservationIdentity],
        observationIdentityCount: Int? = nil,
        observationSpan: TimeInterval,
        evidenceAge: TimeInterval,
        methodVersion: String,
        sourceAdapterVersion: String,
        sourceVersion: String?
    ) {
        self.providerProduct = providerProduct
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.quotaResetBoundary = quotaResetBoundary
        self.reportedQuotaMovementPercent = reportedQuotaMovementPercent
        self.attribution = attribution
        self.unattributed = unattributed
        self.inferredAllocationPercent = inferredAllocationPercent
        self.observationIdentities = observationIdentities
        self.observationIdentityCount = observationIdentityCount ?? observationIdentities.count
        self.observationSpan = observationSpan
        self.evidenceAge = evidenceAge
        self.methodVersion = methodVersion
        self.sourceAdapterVersion = sourceAdapterVersion
        self.sourceVersion = sourceVersion
    }
}

public enum ClaudeQuotaExplanationState: Equatable, Sendable {
    case movement(ClaudeQuotaExplanation)
    case flat(ClaudeQuotaExplanation)
    case unavailable(ClaudeQuotaExplanationUnavailableReason)

    public var displayText: String {
        switch self {
        case let .movement(value):
            "Claude Code measured quota movement: +\(value.reportedQuotaMovementPercent.formatted())%. Interval: \(value.intervalStart.formatted(date: .omitted, time: .shortened))-\(value.intervalEnd.formatted(date: .omitted, time: .shortened)). \(attributionText(value.attribution)) Movement remains unattributed. Exact reset: \(value.quotaResetBoundary.formatted(date: .abbreviated, time: .shortened))."
        case let .flat(value):
            "Claude Code measured quota movement: 0%. Interval: \(value.intervalStart.formatted(date: .omitted, time: .shortened))-\(value.intervalEnd.formatted(date: .omitted, time: .shortened)). This does not prove that no Claude Code activity occurred. \(attributionText(value.attribution)) Exact reset: \(value.quotaResetBoundary.formatted(date: .abbreviated, time: .shortened))."
        case let .unavailable(reason):
            "Claude Code explanation unavailable: \(reason.displayText)"
        }
    }

    private func attributionText(_ attribution: ClaudeQuotaAttribution) -> String {
        switch attribution {
        case let .partial(value):
            "Observed Local Breakdown: \(value.inputTokens) input, \(value.outputTokens) output, \(value.cacheReadTokens) cache-read, and \(value.cacheCreationTokens) cache-creation tokens across \(value.sessionCount) sessions."
        case .observedZero:
            "Observed Zero applies only to the configured telemetry coverage."
        case let .unavailable(reason):
            "Local attribution unavailable (\(reason.rawValue))."
        }
    }
}

public enum ClaudeQuotaExplanationEngine {
    public static let methodVersion = "claude-code-quota-explanation-v1"

    public static func explain(
        observations: [MeasuredQuotaObservation],
        evidence: [ClaudeCodeOTLPEvidence],
        expectedAccountIdentity: String?,
        sourceConfigured: Bool,
        now: Date,
        maximumObservationAge: TimeInterval = 9 * 24 * 60 * 60
    ) -> ClaudeQuotaExplanationState {
        let unique = Dictionary(observations.map { ($0.stableIdentity, $0) }, uniquingKeysWith: { first, _ in first }).values
            .filter { $0.identity.product == .claudeCode && now.timeIntervalSince($0.observedAt) <= maximumObservationAge }
        let groups = Dictionary(grouping: unique, by: \.identity)
        var candidates: [(MeasuredQuotaObservation, MeasuredQuotaObservation)] = []
        var sawDecrease = false
        for group in groups.values {
            let ordered = group.sorted { ($0.observedAt, $0.stableIdentity.digest) < ($1.observedAt, $1.stableIdentity.digest) }
            let pairs = zip(ordered, ordered.dropFirst()).filter { $0.0.observedAt < $0.1.observedAt }
            if pairs.contains(where: { $0.1.percentageUsed < $0.0.percentageUsed }) {
                sawDecrease = true
                continue
            }
            if let latest = pairs.last {
                candidates.append(latest)
            }
        }
        guard let pair = candidates.max(by: { pairSortKey($0) < pairSortKey($1) }) else {
            if sawDecrease { return .unavailable(.counterDecreased) }
            let all = Array(unique).sorted { $0.observedAt < $1.observedAt }
            if observations.count >= 2 && all.count < 2 { return .unavailable(.staleObservations) }
            if all.count >= 2, all[all.count - 2].identity != all.last?.identity { return .unavailable(.incompatibleQuotaWindow) }
            return .unavailable(.insufficientObservations)
        }
        let lower = pair.0
        let upper = pair.1
        guard upper.identity.resetBoundary > now else { return .unavailable(.expiredQuotaWindow) }
        guard upper.percentageUsed >= lower.percentageUsed else { return .unavailable(.counterDecreased) }

        let intervalEvidence = evidence.filter { $0.observedAt > lower.observedAt && $0.observedAt <= upper.observedAt }
        let attribution: ClaudeQuotaAttribution
        if !sourceConfigured {
            attribution = .unavailable(.sourceNotConfigured)
        } else if intervalEvidence.contains(where: { $0.adapterVersion != ClaudeCodeOTLPEvidenceAdapter.adapterVersion || $0.sourceVersion != ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion }) {
            attribution = .unavailable(.unsupportedEvidence)
        } else if expectedAccountIdentity == nil {
            attribution = .unavailable(.accountUnverified)
        } else {
            let matching = Dictionary(
                intervalEvidence.filter { $0.accountIdentity == expectedAccountIdentity }.map { ($0.identity, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
            if matching.isEmpty {
                attribution = .unavailable(.noQualifyingEvidence)
            } else if let breakdown = breakdown(Array(matching)) {
                let total = breakdown.inputTokens + breakdown.outputTokens + breakdown.cacheReadTokens + breakdown.cacheCreationTokens
                attribution = total == 0 ? .observedZero(breakdown) : .partial(breakdown)
            } else {
                attribution = .unavailable(.unsupportedEvidence)
            }
        }
        let movement = upper.percentageUsed - lower.percentageUsed
        let sourceVersions = Set(intervalEvidence.map(\.sourceVersion))
        let value = ClaudeQuotaExplanation(
            providerProduct: .claudeCode,
            intervalStart: lower.observedAt,
            intervalEnd: upper.observedAt,
            quotaResetBoundary: upper.identity.resetBoundary,
            reportedQuotaMovementPercent: movement,
            attribution: attribution,
            unattributed: true,
            inferredAllocationPercent: nil,
            observationIdentities: [lower.stableIdentity, upper.stableIdentity],
            observationSpan: upper.observedAt.timeIntervalSince(lower.observedAt),
            evidenceAge: max(0, now.timeIntervalSince(upper.observedAt)),
            methodVersion: methodVersion,
            sourceAdapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion,
            sourceVersion: sourceVersions.count == 1 ? sourceVersions.first : nil
        )
        return movement == 0 ? .flat(value) : .movement(value)
    }

    private static func breakdown(_ evidence: [ClaudeCodeOTLPEvidence]) -> ClaudeObservedLocalBreakdown? {
        var totals: [ClaudeCodeTokenType: Int64] = [:]
        var models: [String: Int] = [:]
        for item in evidence {
            let sum = (totals[item.tokenType] ?? 0).addingReportingOverflow(item.tokenCount)
            guard !sum.overflow else { return nil }
            totals[item.tokenType] = sum.partialValue
            models[item.model, default: 0] += 1
        }
        return ClaudeObservedLocalBreakdown(
            inputTokens: totals[.input] ?? 0,
            outputTokens: totals[.output] ?? 0,
            cacheReadTokens: totals[.cacheRead] ?? 0,
            cacheCreationTokens: totals[.cacheCreation] ?? 0,
            modelCounts: models,
            sessionCount: Set(evidence.map(\.sessionIdentity)).count,
            evidenceCount: evidence.count
        )
    }

    private static func pairSortKey(_ pair: (MeasuredQuotaObservation, MeasuredQuotaObservation)) -> String {
        let priority = switch pair.1.identity.insightWindowKind {
        case .session: "2"
        case .weekly: "1"
        case .other: "0"
        }
        return String(format: "%020.6f:%@:%@", pair.1.observedAt.timeIntervalSince1970, priority, pair.1.stableIdentity.digest)
    }
}
