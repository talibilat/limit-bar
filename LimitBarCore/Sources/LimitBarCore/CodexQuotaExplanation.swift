import Foundation

public enum CodexQuotaExplanationUnavailableReason: String, Codable, Equatable, Sendable {
    case insufficientObservations = "insufficient_observations"
    case incompatibleQuotaWindow = "incompatible_quota_window"
    case incompatibleTimestamps = "incompatible_timestamps"
    case counterDecreased = "counter_decreased"
    case expiredQuotaWindow = "expired_quota_window"
    case noPositiveQuotaMovement = "no_positive_quota_movement"
    case gap
    case unsupportedEvidence = "unsupported_evidence"

    public var displayText: String {
        switch self {
        case .insufficientObservations: "Collecting two measured reports from this exact quota window."
        case .incompatibleQuotaWindow: "Measured reports cross a quota reset or exact window boundary."
        case .incompatibleTimestamps: "Measured report times cannot be compared safely."
        case .counterDecreased: "Reported quota usage decreased; this interval cannot be explained."
        case .expiredQuotaWindow: "The measured quota window has reset or expired."
        case .noPositiveQuotaMovement: "No positive reported quota movement was measured."
        case .gap: "No trustworthy local evidence covers this measured interval."
        case .unsupportedEvidence: "The local Codex evidence format is unsupported or incomplete."
        }
    }
}

public struct CodexObservedLocalBreakdown: Codable, Equatable, Sendable {
    public let tokens: CodexMeasuredTokens
    public let sessionCount: Int

    public init(tokens: CodexMeasuredTokens, sessionCount: Int) {
        self.tokens = tokens
        self.sessionCount = sessionCount
    }
}

public struct CodexQuotaExplanation: Codable, Equatable, Sendable {
    public let quotaWindowIdentity: QuotaWindowIdentity?
    public let intervalStart: Date
    public let intervalEnd: Date
    public let quotaResetBoundary: Date
    public let coverageStart: Date
    public let coverageEnd: Date
    public let reportedQuotaMovementPercent: Double
    public let observedLocalBreakdown: CodexObservedLocalBreakdown
    public let unattributed: Bool
    public let allocationPercent: Double?
    public let observationIdentities: [QuotaObservationIdentity]
    public let evidenceIdentities: [String]
    public let adapterVersion: String
    public let barriers: [CodexEvidenceBarrier]

    public init(
        intervalStart: Date,
        intervalEnd: Date,
        quotaResetBoundary: Date,
        coverageStart: Date,
        coverageEnd: Date,
        reportedQuotaMovementPercent: Double,
        observedLocalBreakdown: CodexObservedLocalBreakdown,
        unattributed: Bool,
        allocationPercent: Double?,
        observationIdentities: [QuotaObservationIdentity],
        evidenceIdentities: [String],
        observationIdentityCount: Int? = nil,
        evidenceIdentityCount: Int? = nil,
        adapterVersion: String,
        barriers: [CodexEvidenceBarrier],
        quotaWindowIdentity: QuotaWindowIdentity? = nil
    ) {
        self.intervalStart = intervalStart
        self.quotaWindowIdentity = quotaWindowIdentity
        self.intervalEnd = intervalEnd
        self.quotaResetBoundary = quotaResetBoundary
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
        self.reportedQuotaMovementPercent = reportedQuotaMovementPercent
        self.observedLocalBreakdown = observedLocalBreakdown
        self.unattributed = unattributed
        self.allocationPercent = allocationPercent
        self.observationIdentities = observationIdentities
        self.evidenceIdentities = evidenceIdentities
        self.observationIdentityCount = observationIdentityCount ?? observationIdentities.count
        self.evidenceIdentityCount = evidenceIdentityCount ?? evidenceIdentities.count
        self.adapterVersion = adapterVersion
        self.barriers = barriers
    }

    public let observationIdentityCount: Int
    public let evidenceIdentityCount: Int
}

public struct CodexQuotaObservedZero: Equatable, Sendable {
    public let intervalStart: Date
    public let intervalEnd: Date
    public let calculatedQuotaMovementPercent: Double
    public let quotaResetBoundary: Date
    public let observationIdentities: [QuotaObservationIdentity]
    public let evidenceIdentities: [String]
    public let observationIdentityCount: Int
    public let evidenceIdentityCount: Int

    public init(
        intervalStart: Date,
        intervalEnd: Date,
        calculatedQuotaMovementPercent: Double,
        quotaResetBoundary: Date,
        observationIdentities: [QuotaObservationIdentity],
        evidenceIdentities: [String],
        observationIdentityCount: Int? = nil,
        evidenceIdentityCount: Int? = nil
    ) {
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.calculatedQuotaMovementPercent = calculatedQuotaMovementPercent
        self.quotaResetBoundary = quotaResetBoundary
        self.observationIdentities = observationIdentities
        self.evidenceIdentities = evidenceIdentities
        self.observationIdentityCount = observationIdentityCount ?? observationIdentities.count
        self.evidenceIdentityCount = evidenceIdentityCount ?? evidenceIdentities.count
    }
}

public enum CodexQuotaExplanationState: Equatable, Sendable {
    case available(CodexQuotaExplanation)
    case partial(CodexQuotaExplanation)
    case observedZero(CodexQuotaObservedZero)
    case unavailable(CodexQuotaExplanationUnavailableReason)

    public var displayText: String {
        switch self {
        case let .available(value):
            "Measured quota change: +\(value.reportedQuotaMovementPercent.formatted())%. Observed Local Breakdown: \(tokenBreakdownText(value.observedLocalBreakdown)). Complete local coverage. Quota movement remains unattributed."
        case let .partial(value):
            "Measured quota change: +\(value.reportedQuotaMovementPercent.formatted())%. Observed Local Breakdown: \(tokenBreakdownText(value.observedLocalBreakdown)) with incomplete local coverage. Quota movement remains unattributed."
        case let .observedZero(value):
            "Calculated quota movement: +\(value.calculatedQuotaMovementPercent.formatted())% from Measured local quota observations. Observed Zero local activity for the covered interval. Quota movement remains unattributed."
        case let .unavailable(reason):
            "Explanation unavailable: \(reason.displayText)"
        }
    }

    private func tokenBreakdownText(_ breakdown: CodexObservedLocalBreakdown) -> String {
        let tokens = breakdown.tokens
        return "\(tokens.total) measured tokens across \(breakdown.sessionCount) privacy-safe session identity; input \(tokens.input), cached input \(tokens.cachedInput), output \(tokens.output), reasoning output \(tokens.reasoningOutput)"
    }
}

public enum CodexQuotaExplanationEngine {
    public static let methodVersion = "codex-quota-explanation-v1"

    public static func explain(
        observations: [MeasuredQuotaObservation],
        evidence: [CodexRolloutEvidence],
        coverageStart: Date?,
        coverageEnd: Date?,
        barriers: [CodexEvidenceBarrier],
        now: Date? = nil,
        maximumObservationAge: TimeInterval = 9 * 24 * 60 * 60,
        futureSkew: TimeInterval = 5 * 60
    ) -> CodexQuotaExplanationState {
        let eligible = observations.filter { isFresh($0, now: now, maximumObservationAge: maximumObservationAge, futureSkew: futureSkew) }
        let evaluated = evaluateWindows(eligible, now: now)
        let candidates = evaluated.compactMap { evaluation -> (lower: MeasuredQuotaObservation, upper: MeasuredQuotaObservation)? in
            if case let .compatible(pair) = evaluation { return pair }
            return nil
        }
        guard let selected = candidates.max(by: { lhs, rhs in
            let left = pairSortKey(lhs)
            let right = pairSortKey(rhs)
            return left < right
        }) else {
            if evaluated.contains(.counterDecreased) { return .unavailable(.counterDecreased) }
            if evaluated.contains(.expired) { return .unavailable(.expiredQuotaWindow) }
            return unavailableReason(for: eligible)
        }
        let lower = selected.lower
        let upper = selected.upper
        guard lower.identity == upper.identity else { return .unavailable(.incompatibleQuotaWindow) }
        guard lower.observedAt < upper.observedAt else { return .unavailable(.incompatibleTimestamps) }
        guard upper.percentageUsed >= lower.percentageUsed else { return .unavailable(.counterDecreased) }
        let movement = upper.percentageUsed - lower.percentageUsed
        guard movement > 0 else { return .unavailable(.noPositiveQuotaMovement) }
        if barriers.contains(.evidenceLimitExceeded), evidence.isEmpty { return .unavailable(.unsupportedEvidence) }
        let intervalEvidence = evidence.filter { $0.observedAt > lower.observedAt && $0.observedAt <= upper.observedAt }
        let effectiveCoverageStart = coverageStart ?? intervalEvidence.map(\.observedAt).min()
        let effectiveCoverageEnd = coverageEnd ?? intervalEvidence.map(\.observedAt).max()
        let completeCoverage = (effectiveCoverageStart.map { $0 <= lower.observedAt } ?? false)
            && (effectiveCoverageEnd.map { $0 >= upper.observedAt } ?? false)
        if intervalEvidence.isEmpty {
            return barriers.contains(.evidenceLimitExceeded) ? .unavailable(.unsupportedEvidence) : .unavailable(.gap)
        }
        guard let effectiveCoverageStart, let effectiveCoverageEnd else { return .unavailable(.gap) }

        var input: Int64 = 0
        var cached: Int64 = 0
        var output: Int64 = 0
        var reasoning: Int64 = 0
        for item in intervalEvidence {
            guard let nextInput = adding(input, item.tokens.input),
                  let nextCached = adding(cached, item.tokens.cachedInput),
                  let nextOutput = adding(output, item.tokens.output),
                  let nextReasoning = adding(reasoning, item.tokens.reasoningOutput) else {
                return .unavailable(.unsupportedEvidence)
            }
            input = nextInput
            cached = nextCached
            output = nextOutput
            reasoning = nextReasoning
        }
        let explanation = CodexQuotaExplanation(
            intervalStart: lower.observedAt,
            intervalEnd: upper.observedAt,
            quotaResetBoundary: upper.identity.resetBoundary,
            coverageStart: effectiveCoverageStart,
            coverageEnd: effectiveCoverageEnd,
            reportedQuotaMovementPercent: movement,
            observedLocalBreakdown: CodexObservedLocalBreakdown(
                tokens: CodexMeasuredTokens(input: input, cachedInput: cached, output: output, reasoningOutput: reasoning),
                sessionCount: Set(intervalEvidence.map(\.sessionIdentity)).count
            ),
            unattributed: true,
            allocationPercent: nil,
            observationIdentities: [lower.stableIdentity, upper.stableIdentity],
            evidenceIdentities: intervalEvidence.map { "\($0.sessionIdentity):\($0.lineOrdinal):\($0.lineSHA256)" },
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            barriers: Array(Set(barriers)).sorted { $0.rawValue < $1.rawValue },
            quotaWindowIdentity: upper.identity
        )
        if explanation.observedLocalBreakdown.tokens.total == 0, completeCoverage && barriers.isEmpty {
            return .observedZero(CodexQuotaObservedZero(
                intervalStart: lower.observedAt,
                intervalEnd: upper.observedAt,
                calculatedQuotaMovementPercent: movement,
                quotaResetBoundary: upper.identity.resetBoundary,
                observationIdentities: explanation.observationIdentities,
                evidenceIdentities: explanation.evidenceIdentities
            ))
        }
        return completeCoverage && barriers.isEmpty ? .available(explanation) : .partial(explanation)
    }

    private static func evaluateWindows(_ observations: [MeasuredQuotaObservation], now: Date?) -> [WindowEvaluation] {
        Dictionary(grouping: observations, by: \.identity).values.map { group in
            let ordered = group.sorted { ($0.observedAt, $0.stableIdentity.digest) < ($1.observedAt, $1.stableIdentity.digest) }
            var latest: (lower: MeasuredQuotaObservation, upper: MeasuredQuotaObservation)?
            for (lower, upper) in zip(ordered, ordered.dropFirst()) {
                guard lower.observedAt < upper.observedAt else { continue }
                if upper.percentageUsed < lower.percentageUsed { return .counterDecreased }
                guard upper.percentageUsed > lower.percentageUsed else { continue }
                latest = (lower, upper)
            }
            guard let latest else { return .none }
            if let now, latest.upper.identity.resetBoundary <= now { return .expired }
            return .compatible(latest)
        }
    }

    private static func isFresh(
        _ observation: MeasuredQuotaObservation,
        now: Date?,
        maximumObservationAge: TimeInterval,
        futureSkew: TimeInterval
    ) -> Bool {
        guard let now else { return true }
        let age = now.timeIntervalSince(observation.observedAt)
        return now.timeIntervalSince1970.isFinite
            && maximumObservationAge.isFinite
            && futureSkew.isFinite
            && maximumObservationAge >= 0
            && futureSkew >= 0
            && age <= maximumObservationAge
            && observation.observedAt <= now.addingTimeInterval(futureSkew)
    }

    private static func pairSortKey(_ pair: (lower: MeasuredQuotaObservation, upper: MeasuredQuotaObservation)) -> PairSortKey {
        PairSortKey(
            upperObservedAt: pair.upper.observedAt,
            priority: quotaWindowPriority(pair.upper.identity),
            digest: pair.upper.stableIdentity.digest
        )
    }

    private static func quotaWindowPriority(_ identity: QuotaWindowIdentity) -> Int {
        let components = identity.identifier.split(separator: ":", omittingEmptySubsequences: false)
        let slot: Substring?
        let minutesText: Substring?
        if components.count == 3 {
            slot = components[1]
            minutesText = components[2]
        } else if components.count == 2 {
            slot = components[0]
            minutesText = components[1]
        } else {
            slot = nil
            minutesText = nil
        }
        if slot == "primary", minutesText == "300" { return 3 }
        if slot == "primary" { return 2 }
        if slot == "secondary" { return 1 }
        return 0
    }

    private static func unavailableReason(for observations: [MeasuredQuotaObservation]) -> CodexQuotaExplanationState {
        let ordered = observations.sorted { ($0.observedAt, $0.stableIdentity.digest) < ($1.observedAt, $1.stableIdentity.digest) }
        guard ordered.count >= 2 else { return .unavailable(.insufficientObservations) }
        let lower = ordered[ordered.count - 2]
        let upper = ordered[ordered.count - 1]
        guard lower.identity == upper.identity else { return .unavailable(.incompatibleQuotaWindow) }
        guard lower.observedAt < upper.observedAt else { return .unavailable(.incompatibleTimestamps) }
        guard upper.percentageUsed >= lower.percentageUsed else { return .unavailable(.counterDecreased) }
        return .unavailable(.noPositiveQuotaMovement)
    }

    private struct PairSortKey: Comparable {
        let upperObservedAt: Date
        let priority: Int
        let digest: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.upperObservedAt != rhs.upperObservedAt { return lhs.upperObservedAt < rhs.upperObservedAt }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.digest < rhs.digest
        }
    }

    private enum WindowEvaluation: Equatable {
        case compatible((lower: MeasuredQuotaObservation, upper: MeasuredQuotaObservation))
        case counterDecreased
        case expired
        case none

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.counterDecreased, .counterDecreased), (.expired, .expired), (.none, .none): true
            case let (.compatible(left), .compatible(right)): left.lower.stableIdentity == right.lower.stableIdentity && left.upper.stableIdentity == right.upper.stableIdentity
            default: false
            }
        }
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }
}
