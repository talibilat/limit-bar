import CryptoKit
import Foundation

public enum ClaudeQuotaExplanationUnavailableReason: String, Codable, Equatable, Sendable {
    case insufficientObservations = "insufficient_observations"
    case incompatibleQuotaWindow = "incompatible_quota_window"
    case incompatibleTimestamps = "incompatible_timestamps"
    case counterDecreased = "counter_decreased"
    case staleObservations = "stale_observations"
    case quotaAccountScopeUnavailable = "quota_account_scope_unavailable"
    case accountTransitionUnverified = "account_transition_unverified"
    case incompatibleUnit = "incompatible_unit"

    public var displayText: String {
        switch self {
        case .insufficientObservations: "Collecting two measured Claude Code reports."
        case .incompatibleQuotaWindow: "Measured reports do not belong to one exact Claude Code quota window."
        case .incompatibleTimestamps: "Measured report times cannot be compared safely."
        case .counterDecreased: "Reported quota usage decreased within the exact window."
        case .staleObservations: "Measured Claude Code reports are outside retained coverage."
        case .quotaAccountScopeUnavailable: "Retained quota observations have no trustworthy account binding, so movement is not calculated."
        case .accountTransitionUnverified: "The selected observations cross an unverified account transition."
        case .incompatibleUnit: "The selected observations use incompatible quota units."
        }
    }
}

public enum ClaudeAttributionUnavailableReason: String, Codable, Equatable, Sendable {
    case receiverNotConfigured = "receiver_not_configured"
    case accountBindingUnavailable = "account_binding_unavailable"
    case gap
    case partialCoverage = "partial_coverage"
    case unsupportedEvidence = "unsupported_evidence"
}

public enum ClaudeQuotaObservationUnit: String, Codable, Equatable, Sendable {
    case percentageUsed = "percentage_used"
    case requests
}

public struct ClaudeScopedQuotaObservation: Equatable, Sendable {
    public let observation: MeasuredQuotaObservation
    public let accountIdentity: String?
    public let unit: ClaudeQuotaObservationUnit

    public init(observation: MeasuredQuotaObservation, accountIdentity: String?, unit: ClaudeQuotaObservationUnit) {
        self.observation = observation
        self.accountIdentity = accountIdentity
        self.unit = unit
    }
}

public enum ClaudeExplanationLifecycle: String, Codable, Equatable, Sendable {
    case active
    case completed
}

public enum ClaudeExplanationProvenanceKind: String, Codable, Equatable, Sendable {
    case reported
    case calculated
    case measured
    case unavailable
}

public struct ClaudeExplanationProvenance: Codable, Equatable, Sendable {
    public let reportedQuota: ClaudeExplanationProvenanceKind
    public let movement: ClaudeExplanationProvenanceKind
    public let localBreakdown: ClaudeExplanationProvenanceKind

    public init(localBreakdown: ClaudeExplanationProvenanceKind) {
        reportedQuota = .reported
        movement = .calculated
        self.localBreakdown = localBreakdown
    }
}

public struct ClaudeObservedLocalBreakdown: Codable, Equatable, Sendable {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreationTokens: Int64
    public let modelCounts: [String: Int]
    public let sessionCount: Int
    public let evidenceCount: Int

    public init(inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64, cacheCreationTokens: Int64, modelCounts: [String: Int], sessionCount: Int, evidenceCount: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.modelCounts = modelCounts
        self.sessionCount = sessionCount
        self.evidenceCount = evidenceCount
    }
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
    public let lifecycle: ClaudeExplanationLifecycle
    public let reportedQuotaMovementPercent: Double
    public let attribution: ClaudeQuotaAttribution
    public let unattributed: Bool
    public let inferredAllocation: InferredQuotaAllocation?
    public let observationIdentities: [QuotaObservationIdentity]
    public let evidenceIdentities: [String]
    public let observationIdentityCount: Int
    public let evidenceIdentityCount: Int
    public let observationSpan: TimeInterval
    public let evidenceAge: TimeInterval
    public let methodVersion: String
    public let sourceAdapterVersion: String
    public let sourceVersion: String?
    public let provenance: ClaudeExplanationProvenance

    public init(
        providerProduct: ProviderProduct,
        intervalStart: Date,
        intervalEnd: Date,
        quotaResetBoundary: Date,
        lifecycle: ClaudeExplanationLifecycle = .active,
        reportedQuotaMovementPercent: Double,
        attribution: ClaudeQuotaAttribution,
        unattributed: Bool,
        inferredAllocation: InferredQuotaAllocation?,
        observationIdentities: [QuotaObservationIdentity],
        evidenceIdentities: [String] = [],
        observationIdentityCount: Int? = nil,
        evidenceIdentityCount: Int? = nil,
        observationSpan: TimeInterval,
        evidenceAge: TimeInterval,
        methodVersion: String,
        sourceAdapterVersion: String,
        sourceVersion: String?,
        provenance: ClaudeExplanationProvenance? = nil
    ) {
        self.providerProduct = providerProduct
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.quotaResetBoundary = quotaResetBoundary
        self.lifecycle = lifecycle
        self.reportedQuotaMovementPercent = reportedQuotaMovementPercent
        self.attribution = attribution
        self.unattributed = unattributed
        self.inferredAllocation = inferredAllocation
        self.observationIdentities = observationIdentities
        self.evidenceIdentities = evidenceIdentities
        self.observationIdentityCount = observationIdentityCount ?? observationIdentities.count
        self.evidenceIdentityCount = evidenceIdentityCount ?? evidenceIdentities.count
        self.observationSpan = observationSpan
        self.evidenceAge = evidenceAge
        self.methodVersion = methodVersion
        self.sourceAdapterVersion = sourceAdapterVersion
        self.sourceVersion = sourceVersion
        self.provenance = provenance ?? ClaudeExplanationProvenance(localBreakdown: .unavailable)
    }

    public func read(at now: Date) -> Self {
        Self(
            providerProduct: providerProduct,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            quotaResetBoundary: quotaResetBoundary,
            lifecycle: quotaResetBoundary > now ? .active : .completed,
            reportedQuotaMovementPercent: reportedQuotaMovementPercent,
            attribution: attribution,
            unattributed: unattributed,
            inferredAllocation: inferredAllocation,
            observationIdentities: observationIdentities,
            evidenceIdentities: evidenceIdentities,
            observationIdentityCount: observationIdentityCount,
            evidenceIdentityCount: evidenceIdentityCount,
            observationSpan: observationSpan,
            evidenceAge: max(0, now.timeIntervalSince(intervalEnd)),
            methodVersion: methodVersion,
            sourceAdapterVersion: sourceAdapterVersion,
            sourceVersion: sourceVersion,
            provenance: provenance
        )
    }
}

public enum ClaudeQuotaExplanationState: Equatable, Sendable {
    case movement(ClaudeQuotaExplanation)
    case flat(ClaudeQuotaExplanation)
    case unavailable(ClaudeQuotaExplanationUnavailableReason)

    public var isMovement: Bool { if case .movement = self { true } else { false } }

    public var displayText: String {
        switch self {
        case let .movement(value): explanationText(value, movement: "+\(value.reportedQuotaMovementPercent.formatted())%")
        case let .flat(value): explanationText(value, movement: "0%") + " Flat movement does not prove that no Claude Code activity occurred."
        case let .unavailable(reason): "Claude Code explanation unavailable: \(reason.displayText)"
        }
    }

    private func explanationText(_ value: ClaudeQuotaExplanation, movement: String) -> String {
        let lifecycle = value.lifecycle == .active ? "Active exact window" : "Completed exact window"
        return "Reported Claude Code percentages; Calculated movement: \(movement). \(lifecycle), reset \(value.quotaResetBoundary.formatted(date: .abbreviated, time: .shortened)). \(attributionText(value.attribution)) Movement remains unattributed."
    }

    private func attributionText(_ attribution: ClaudeQuotaAttribution) -> String {
        switch attribution {
        case let .partial(value): "Measured Observed Local Breakdown: \(value.inputTokens) input and \(value.outputTokens) output tokens."
        case .observedZero: "Measured Observed Zero within complete configured evidence coverage."
        case let .unavailable(reason): "Measured local breakdown unavailable (\(reason.rawValue))."
        }
    }
}

public struct ClaudeQuotaExplanationInterval: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let identity: QuotaWindowIdentity
    public let intervalStart: Date
    public let intervalEnd: Date
    public let lifecycle: ClaudeExplanationLifecycle

    public init(id: String, identity: QuotaWindowIdentity, intervalStart: Date, intervalEnd: Date, lifecycle: ClaudeExplanationLifecycle) {
        self.id = id
        self.identity = identity
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.lifecycle = lifecycle
    }
}

public struct ClaudeQuotaExplanationSelection: Equatable, Sendable {
    public let interval: ClaudeQuotaExplanationInterval
    public let state: ClaudeQuotaExplanationState
    public let limitations: [ClaudeEvidenceLimitation]

    public init(interval: ClaudeQuotaExplanationInterval, state: ClaudeQuotaExplanationState, limitations: [ClaudeEvidenceLimitation]) {
        self.interval = interval
        self.state = state
        self.limitations = limitations
    }
}

public struct ClaudeQuotaExplanationCatalog: Equatable, Sendable {
    public let selections: [ClaudeQuotaExplanationSelection]
    public let defaultSelectionID: String?
    public let limitations: [ClaudeEvidenceLimitation]

    public init(selections: [ClaudeQuotaExplanationSelection], defaultSelectionID: String?, limitations: [ClaudeEvidenceLimitation] = []) {
        self.selections = selections
        self.defaultSelectionID = defaultSelectionID
        self.limitations = limitations
    }

    public var intervals: [ClaudeQuotaExplanationInterval] { selections.map(\.interval) }
    public var defaultSelection: ClaudeQuotaExplanationSelection? { selection(id: defaultSelectionID) }
    public func selection(id: String?) -> ClaudeQuotaExplanationSelection? {
        guard let id else { return nil }
        return selections.first { $0.interval.id == id }
    }

    public static let empty = Self(selections: [], defaultSelectionID: nil)
}

public enum ClaudeEvidenceSourceAvailability: Equatable, Sendable {
    case available(expectedAccountIdentity: String)
    case unavailable([ClaudeEvidenceLimitation])
}

public enum ClaudeQuotaExplanationEngine {
    public static let methodVersion = "claude-code-quota-explanation-v2"
    public static let maximumIntervals = 100

    public static func explain(
        observations: [MeasuredQuotaObservation],
        evidence: [ClaudeCodeOTLPEvidence],
        expectedAccountIdentity: String?,
        sourceConfigured: Bool,
        now: Date,
        maximumObservationAge: TimeInterval = 9 * 24 * 60 * 60
    ) -> ClaudeQuotaExplanationState {
        let scoped = observations
            .filter { now.timeIntervalSince($0.observedAt) <= maximumObservationAge }
            .map { ClaudeScopedQuotaObservation(observation: $0, accountIdentity: nil, unit: .percentageUsed) }
        let source: ClaudeEvidenceSourceAvailability
        if sourceConfigured, let expectedAccountIdentity {
            source = .available(expectedAccountIdentity: expectedAccountIdentity)
        } else {
            source = .unavailable([.receiverNotConfigured, .accountBindingUnavailable])
        }
        let result = catalog(observations: scoped, evidence: evidence, source: source, evidenceLimitations: [], now: now).defaultSelection?.state
        if let result { return result }
        if Set(observations.map(\.identity)).count > 1 { return .unavailable(.incompatibleQuotaWindow) }
        return .unavailable(observations.count >= 2 ? .staleObservations : .insufficientObservations)
    }

    public static func catalog(
        observations: [ClaudeScopedQuotaObservation],
        evidence: [ClaudeCodeOTLPEvidence],
        source: ClaudeEvidenceSourceAvailability,
        evidenceLimitations: [ClaudeEvidenceLimitation],
        now: Date
    ) -> ClaudeQuotaExplanationCatalog {
        let unique = Dictionary(observations.map { ($0.observation.stableIdentity, $0) }, uniquingKeysWith: { first, _ in first }).values
            .filter { $0.observation.identity.product == .claudeCode }
        var pairs: [(ClaudeScopedQuotaObservation, ClaudeScopedQuotaObservation)] = []
        let groups = Dictionary(grouping: unique, by: { $0.observation.identity })
        let decreasedIdentities = Set(groups.compactMap { identity, group -> QuotaWindowIdentity? in
            let ordered = group.sorted { ($0.observation.observedAt, $0.observation.stableIdentity.digest) < ($1.observation.observedAt, $1.observation.stableIdentity.digest) }
            return zip(ordered, ordered.dropFirst()).contains { $0.1.observation.percentageUsed < $0.0.observation.percentageUsed } ? identity : nil
        })
        for group in groups.values {
            let ordered = group.sorted { ($0.observation.observedAt, $0.observation.stableIdentity.digest) < ($1.observation.observedAt, $1.observation.stableIdentity.digest) }
            pairs.append(contentsOf: zip(ordered, ordered.dropFirst()).filter { $0.0.observation.observedAt < $0.1.observation.observedAt })
        }
        pairs.sort { pairSortKey($0, now: now) > pairSortKey($1, now: now) }
        let selections = pairs.prefix(maximumIntervals).map {
            evaluate($0, windowCounterDecreased: decreasedIdentities.contains($0.1.observation.identity), evidence: evidence, source: source, evidenceLimitations: evidenceLimitations, now: now)
        }
        let preferred = selections.first { $0.interval.lifecycle == .active } ?? selections.first
        var catalogLimitations = Set(evidenceLimitations)
        if case let .unavailable(values) = source { catalogLimitations.formUnion(values) }
        return ClaudeQuotaExplanationCatalog(selections: selections, defaultSelectionID: preferred?.interval.id, limitations: catalogLimitations.sorted { $0.rawValue < $1.rawValue })
    }

    private static func evaluate(
        _ pair: (ClaudeScopedQuotaObservation, ClaudeScopedQuotaObservation),
        windowCounterDecreased: Bool,
        evidence: [ClaudeCodeOTLPEvidence],
        source: ClaudeEvidenceSourceAvailability,
        evidenceLimitations: [ClaudeEvidenceLimitation],
        now: Date
    ) -> ClaudeQuotaExplanationSelection {
        let lower = pair.0
        let upper = pair.1
        let lifecycle: ClaudeExplanationLifecycle = upper.observation.identity.resetBoundary > now ? .active : .completed
        let interval = ClaudeQuotaExplanationInterval(
            id: intervalIdentity(lower: lower.observation.stableIdentity, upper: upper.observation.stableIdentity),
            identity: upper.observation.identity,
            intervalStart: lower.observation.observedAt,
            intervalEnd: upper.observation.observedAt,
            lifecycle: lifecycle
        )
        var limitations = Set(evidenceLimitations)
        if case let .unavailable(sourceLimitations) = source { limitations.formUnion(sourceLimitations) }
        if limitations.contains(.missingEvidenceBoundary) { limitations.insert(.partialCoverage) }
        if windowCounterDecreased {
            return selection(interval, .unavailable(.counterDecreased), limitations)
        }
        guard lower.unit == upper.unit, lower.unit == .percentageUsed else {
            limitations.insert(.incompatibleUnit)
            return selection(interval, .unavailable(.incompatibleUnit), limitations)
        }
        guard let lowerAccount = lower.accountIdentity, let upperAccount = upper.accountIdentity else {
            limitations.insert(.quotaAccountScopeUnavailable)
            return selection(interval, .unavailable(.quotaAccountScopeUnavailable), limitations)
        }
        guard lowerAccount == upperAccount else {
            limitations.insert(.accountTransitionUnverified)
            return selection(interval, .unavailable(.accountTransitionUnverified), limitations)
        }
        guard upper.observation.percentageUsed >= lower.observation.percentageUsed else {
            return selection(interval, .unavailable(.counterDecreased), limitations)
        }

        let overlapping = evidence.filter { $0.intervalEnd > interval.intervalStart && $0.intervalStart < interval.intervalEnd }
        let contained = overlapping.filter { $0.intervalStart >= interval.intervalStart && $0.intervalEnd <= interval.intervalEnd }
        if overlapping.count != contained.count { limitations.insert(.partialCoverage) }
        if contained.contains(where: { $0.adapterVersion != ClaudeCodeOTLPEvidenceAdapter.adapterVersion || $0.sourceVersion != ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion }) {
            limitations.insert(.unsupportedEvidence)
        }
        let matching: [ClaudeCodeOTLPEvidence]
        let attribution: ClaudeQuotaAttribution
        switch source {
        case let .available(expectedAccountIdentity):
            if limitations.contains(.unsupportedEvidence) {
                return selection(interval, .movement(unavailableEvidenceValue(interval: interval, lower: lower, upper: upper, lifecycle: lifecycle, attribution: .unsupportedEvidence, now: now)), limitations)
            }
            guard expectedAccountIdentity == lowerAccount else {
                limitations.insert(.accountTransitionUnverified)
                return selection(interval, .unavailable(.accountTransitionUnverified), limitations)
            }
            matching = Array(Dictionary(contained.filter { $0.accountIdentity == expectedAccountIdentity }.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first }).values)
            if limitations.contains(.partialCoverage) {
                attribution = .unavailable(.partialCoverage)
            } else if limitations.contains(.evidenceGap) {
                attribution = .unavailable(.gap)
            } else if matching.isEmpty {
                limitations.insert(.evidenceGap)
                attribution = .unavailable(.gap)
            } else if !hasCompleteCoverage(matching, interval: interval) {
                limitations.insert(.evidenceGap)
                attribution = .unavailable(.gap)
            } else if let value = breakdown(matching) {
                let total = value.inputTokens + value.outputTokens + value.cacheReadTokens + value.cacheCreationTokens
                attribution = total == 0 ? .observedZero(value) : .partial(value)
            } else {
                limitations.insert(.unsupportedEvidence)
                attribution = .unavailable(.unsupportedEvidence)
            }
        case let .unavailable(sourceLimitations):
            matching = []
            attribution = .unavailable(sourceLimitations.contains(.receiverNotConfigured) ? .receiverNotConfigured : .accountBindingUnavailable)
        }

        let movement = upper.observation.percentageUsed - lower.observation.percentageUsed
        let value = ClaudeQuotaExplanation(
            providerProduct: .claudeCode,
            intervalStart: interval.intervalStart,
            intervalEnd: interval.intervalEnd,
            quotaResetBoundary: interval.identity.resetBoundary,
            lifecycle: lifecycle,
            reportedQuotaMovementPercent: movement,
            attribution: attribution,
            unattributed: true,
            inferredAllocation: nil,
            observationIdentities: [lower.observation.stableIdentity, upper.observation.stableIdentity],
            evidenceIdentities: matching.map(\.identity).sorted(),
            observationSpan: interval.intervalEnd.timeIntervalSince(interval.intervalStart),
            evidenceAge: max(0, now.timeIntervalSince(interval.intervalEnd)),
            methodVersion: methodVersion,
            sourceAdapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion,
            sourceVersion: Set(matching.map(\.sourceVersion)).count == 1 ? matching.first?.sourceVersion : nil,
            provenance: ClaudeExplanationProvenance(localBreakdown: matching.isEmpty ? .unavailable : .measured)
        )
        return selection(interval, movement == 0 ? .flat(value) : .movement(value), limitations)
    }

    private static func unavailableEvidenceValue(
        interval: ClaudeQuotaExplanationInterval,
        lower: ClaudeScopedQuotaObservation,
        upper: ClaudeScopedQuotaObservation,
        lifecycle: ClaudeExplanationLifecycle,
        attribution: ClaudeAttributionUnavailableReason,
        now: Date
    ) -> ClaudeQuotaExplanation {
        ClaudeQuotaExplanation(
            providerProduct: .claudeCode,
            intervalStart: interval.intervalStart,
            intervalEnd: interval.intervalEnd,
            quotaResetBoundary: interval.identity.resetBoundary,
            lifecycle: lifecycle,
            reportedQuotaMovementPercent: upper.observation.percentageUsed - lower.observation.percentageUsed,
            attribution: .unavailable(attribution),
            unattributed: true,
            inferredAllocation: nil,
            observationIdentities: [lower.observation.stableIdentity, upper.observation.stableIdentity],
            observationSpan: interval.intervalEnd.timeIntervalSince(interval.intervalStart),
            evidenceAge: max(0, now.timeIntervalSince(interval.intervalEnd)),
            methodVersion: methodVersion,
            sourceAdapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion,
            sourceVersion: nil
        )
    }

    private static func selection(_ interval: ClaudeQuotaExplanationInterval, _ state: ClaudeQuotaExplanationState, _ limitations: Set<ClaudeEvidenceLimitation>) -> ClaudeQuotaExplanationSelection {
        ClaudeQuotaExplanationSelection(interval: interval, state: state, limitations: limitations.sorted { $0.rawValue < $1.rawValue })
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
        return ClaudeObservedLocalBreakdown(inputTokens: totals[.input] ?? 0, outputTokens: totals[.output] ?? 0, cacheReadTokens: totals[.cacheRead] ?? 0, cacheCreationTokens: totals[.cacheCreation] ?? 0, modelCounts: models, sessionCount: Set(evidence.map(\.sessionIdentity)).count, evidenceCount: evidence.count)
    }

    private static func hasCompleteCoverage(_ evidence: [ClaudeCodeOTLPEvidence], interval: ClaudeQuotaExplanationInterval) -> Bool {
        let ordered = evidence.sorted { ($0.intervalStart, $0.intervalEnd, $0.identity) < ($1.intervalStart, $1.intervalEnd, $1.identity) }
        guard let first = ordered.first, first.intervalStart == interval.intervalStart else { return false }
        var coveredEnd = first.intervalEnd
        for item in ordered.dropFirst() {
            guard item.intervalStart <= coveredEnd else { return false }
            coveredEnd = max(coveredEnd, item.intervalEnd)
        }
        return coveredEnd == interval.intervalEnd
    }

    private static func intervalIdentity(lower: QuotaObservationIdentity, upper: QuotaObservationIdentity) -> String {
        SHA256.hash(data: Data("\(lower.version.rawValue):\(lower.digest):\(upper.version.rawValue):\(upper.digest)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func pairSortKey(_ pair: (ClaudeScopedQuotaObservation, ClaudeScopedQuotaObservation), now: Date) -> String {
        let active = pair.1.observation.identity.resetBoundary > now ? "1" : "0"
        return "\(active):\(String(format: "%020.6f", pair.1.observation.observedAt.timeIntervalSince1970)):\(pair.1.observation.stableIdentity.digest)"
    }
}
