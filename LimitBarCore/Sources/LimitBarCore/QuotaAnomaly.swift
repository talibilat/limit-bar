import Foundation

public enum QuotaAnomalyValidationError: Error, Equatable {
    case invalidPeriod
    case invalidDenominator
    case invalidEvidenceVersion
}

public enum QuotaAnomalyPeriodInclusionRule: String, Codable, Equatable, Sendable {
    case startExclusiveEndInclusive = "start_exclusive_end_inclusive"
}

public struct QuotaAnomalyPeriod: Codable, Equatable, Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let inclusionRule: QuotaAnomalyPeriodInclusionRule

    public init(start: Date, end: Date) throws {
        guard start.timeIntervalSince1970.isFinite,
              end.timeIntervalSince1970.isFinite,
              start < end else { throw QuotaAnomalyValidationError.invalidPeriod }
        self.start = start
        self.end = end
        self.inclusionRule = .startExclusiveEndInclusive
    }
}

public enum QuotaAnomalyMethod: String, Codable, CaseIterable, Equatable, Sendable {
    case trailingMedianRatioV1 = "trailing_median_ratio_v1"
}

public enum QuotaAnomalyFindingType: String, Codable, Equatable, Sendable {
    case quotaConsumptionAnomaly = "quota_consumption_anomaly"
}

public enum QuotaAnomalyDirection: String, Codable, Equatable, Sendable {
    case higher
}

public enum QuotaAnomalyQualification: String, Codable, Equatable, Sendable {
    case qualified
    case unavailable
}

public enum QuotaAnomalyEvidenceClassification: String, Codable, Equatable, Hashable, Sendable {
    case reported
    case measured
    case calculated
    case inferred
}

public enum QuotaAnomalyAdapterVersion: String, Codable, Equatable, Hashable, Sendable {
    case quotaObservationV1 = "quota_observation_v1"
    case quotaObservationV2 = "quota_observation_v2"
}

public enum QuotaAnomalyClientVersion: String, Codable, Equatable, Hashable, Sendable {
    case notReported = "not_reported"
    case codex0144 = "codex_0_144"
    case codex0145 = "codex_0_145"
    case claudeSupportedV1 = "claude_supported_v1"
}

public enum QuotaAnomalyProviderFormatVersion: String, Codable, Equatable, Hashable, Sendable {
    case claudeProviderReportV1 = "claude_provider_report_v1"
    case codexLocalReportV1 = "codex_local_report_v1"
    case codexLocalReportV2 = "codex_local_report_v2"
}

public struct QuotaAnomalyEvidenceVersion: Equatable, Hashable, Sendable {
    public let adapter: QuotaAnomalyAdapterVersion
    public let client: QuotaAnomalyClientVersion
    public let providerFormat: QuotaAnomalyProviderFormatVersion

    public init(
        adapter: QuotaAnomalyAdapterVersion,
        client: QuotaAnomalyClientVersion,
        providerFormat: QuotaAnomalyProviderFormatVersion
    ) throws {
        let isSupported = switch (adapter, client, providerFormat) {
        case (.quotaObservationV1, .notReported, .claudeProviderReportV1),
             (.quotaObservationV1, .claudeSupportedV1, .claudeProviderReportV1),
             (.quotaObservationV1, .notReported, .codexLocalReportV1),
             (.quotaObservationV1, .codex0144, .codexLocalReportV1),
             (.quotaObservationV2, .codex0145, .codexLocalReportV2):
            true
        default:
            false
        }
        guard isSupported else { throw QuotaAnomalyValidationError.invalidEvidenceVersion }
        self.adapter = adapter
        self.client = client
        self.providerFormat = providerFormat
    }

    fileprivate init(
        validatedAdapter adapter: QuotaAnomalyAdapterVersion,
        client: QuotaAnomalyClientVersion,
        providerFormat: QuotaAnomalyProviderFormatVersion
    ) {
        self.adapter = adapter
        self.client = client
        self.providerFormat = providerFormat
    }
}

public enum QuotaAnomalyDenominatorKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case inputTokens = "input_tokens"
    case requests
    case agentSteps = "agent_steps"
    case completedTasks = "completed_tasks"
    case acceptedCodeChanges = "accepted_code_changes"
    case activeMinutes = "active_minutes"

    public var unit: QuotaAnomalyDenominatorUnit {
        switch self {
        case .inputTokens: .tokens
        case .activeMinutes: .minutes
        case .requests, .agentSteps, .completedTasks, .acceptedCodeChanges: .count
        }
    }
}

public enum QuotaAnomalyDenominatorUnit: String, Codable, Equatable, Hashable, Sendable {
    case tokens
    case count
    case minutes
}

public enum QuotaAnomalyDenominatorSource: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case localUsageEvents = "local_usage_events"
    case codexRolloutEvidence = "codex_rollout_evidence"
    case collectorUsageEvents = "collector_usage_events"
}

public enum QuotaAnomalyDenominatorMethodVersion: String, Codable, Equatable, Hashable, Sendable {
    case measuredIntervalAggregateV1 = "measured_interval_aggregate_v1"
}

public enum QuotaAnomalyDenominatorCoverage: Equatable, Sendable {
    case complete
    case partial(Double)
    case gap
}

public struct QuotaAnomalyDenominatorInput: Equatable, Sendable {
    public let period: QuotaAnomalyPeriod
    public let kind: QuotaAnomalyDenominatorKind
    public let source: QuotaAnomalyDenominatorSource
    public let methodVersion: QuotaAnomalyDenominatorMethodVersion
    public let value: Double?
    public let observedAt: Date?
    public let coverage: QuotaAnomalyDenominatorCoverage
    public let classification: QuotaAnomalyEvidenceClassification?

    public init(
        period: QuotaAnomalyPeriod,
        kind: QuotaAnomalyDenominatorKind,
        source: QuotaAnomalyDenominatorSource,
        methodVersion: QuotaAnomalyDenominatorMethodVersion = .measuredIntervalAggregateV1,
        value: Double?,
        observedAt: Date?,
        coverage: QuotaAnomalyDenominatorCoverage
    ) throws {
        switch coverage {
        case .complete:
            guard let value, value.isFinite, value >= 0,
                  let observedAt, observedAt.timeIntervalSince1970.isFinite,
                  observedAt >= period.end else { throw QuotaAnomalyValidationError.invalidDenominator }
        case let .partial(fraction):
            guard fraction.isFinite, fraction > 0, fraction < 1,
                  value.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  observedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= period.end }) ?? true else {
                throw QuotaAnomalyValidationError.invalidDenominator
            }
        case .gap:
            guard value == nil, observedAt == nil else { throw QuotaAnomalyValidationError.invalidDenominator }
        }
        self.period = period
        self.kind = kind
        self.source = source
        self.methodVersion = methodVersion
        self.value = value
        self.observedAt = observedAt
        self.coverage = coverage
        self.classification = coverage == .gap ? nil : .measured
    }

    fileprivate init(
        missingPeriod: QuotaAnomalyPeriod,
        kind: QuotaAnomalyDenominatorKind,
        source: QuotaAnomalyDenominatorSource,
        methodVersion: QuotaAnomalyDenominatorMethodVersion
    ) {
        self.period = missingPeriod
        self.kind = kind
        self.source = source
        self.methodVersion = methodVersion
        self.value = nil
        self.observedAt = nil
        self.coverage = .gap
        self.classification = nil
    }
}

public struct QuotaAnomalyDenominatorRequest: Equatable, Sendable {
    public let kind: QuotaAnomalyDenominatorKind
    public let source: QuotaAnomalyDenominatorSource
    public let methodVersion: QuotaAnomalyDenominatorMethodVersion
    public let inputs: [QuotaAnomalyDenominatorInput]

    public init(
        kind: QuotaAnomalyDenominatorKind,
        source: QuotaAnomalyDenominatorSource,
        methodVersion: QuotaAnomalyDenominatorMethodVersion = .measuredIntervalAggregateV1,
        inputs: [QuotaAnomalyDenominatorInput]
    ) {
        self.kind = kind
        self.source = source
        self.methodVersion = methodVersion
        self.inputs = inputs
    }
}

public enum QuotaAnomalyNormalization: Equatable, Sendable {
    case directQuotaMovement
    case measuredDenominator(QuotaAnomalyDenominatorRequest)
}

public enum QuotaAnomalyNormalizationSummary: Equatable, Sendable {
    case directQuotaMovement
    case measuredDenominator(
        kind: QuotaAnomalyDenominatorKind,
        unit: QuotaAnomalyDenominatorUnit,
        source: QuotaAnomalyDenominatorSource,
        methodVersion: QuotaAnomalyDenominatorMethodVersion
    )
}

public enum QuotaAnomalyAttribution: String, Codable, Equatable, Sendable {
    case unattributed
}

public enum QuotaAnomalyLimitation: String, Codable, Equatable, Hashable, Sendable {
    case providerWeightingUnknown = "provider_weighting_unknown"
    case noCausalAttribution = "no_causal_attribution"
    case syntheticFixtureValidationOnly = "synthetic_fixture_validation_only"
    case incompatibleAdapterVersion = "incompatible_adapter_version"
    case incompatibleClientVersion = "incompatible_client_version"
    case incompatibleProviderFormatVersion = "incompatible_provider_format_version"
    case supersededEvidenceExcluded = "superseded_evidence_excluded"
}

public enum QuotaAnomalyUnavailableReason: String, Codable, Error, Equatable, Sendable {
    case invalidEvaluation = "invalid_evaluation"
    case insufficientObservations = "insufficient_observations"
    case insufficientBaseline = "insufficient_baseline"
    case insufficientSpan = "insufficient_span"
    case staleEvidence = "stale_evidence"
    case resetOrExpired = "reset_or_expired"
    case incompatibleEvidence = "incompatible_evidence"
    case conflictingObservations = "conflicting_observations"
    case counterDecreased = "counter_decreased"
    case gap
    case unstableBaseline = "unstable_baseline"
    case missingDenominator = "missing_denominator"
    case zeroDenominator = "zero_denominator"
    case staleDenominator = "stale_denominator"
    case partialDenominatorCoverage = "partial_denominator_coverage"
    case incompatibleDenominator = "incompatible_denominator"
}

public struct QuotaAnomalyResultMetadata: Equatable, Sendable {
    public let method: QuotaAnomalyMethod
    public let qualification: QuotaAnomalyQualification
    public let createdAt: Date?
    public let implicatedIdentities: [QuotaWindowIdentity]
    public let currentPeriod: QuotaAnomalyPeriod?
    public let baselinePeriod: QuotaAnomalyPeriod?
    public let inputObservationIdentities: [QuotaObservationIdentity]
    public let interpretationVersions: [QuotaObservationInterpretationVersion]
    public let evidenceVersions: [QuotaAnomalyEvidenceVersion]
    public let inputClassifications: [QuotaAnomalyEvidenceClassification]
    public let denominatorInputs: [QuotaAnomalyDenominatorInput]
    public let limitations: [QuotaAnomalyLimitation]
}

public struct QuotaConsumptionAnomalyFinding: Equatable, Sendable {
    public let metadata: QuotaAnomalyResultMetadata
    public let findingType: QuotaAnomalyFindingType
    public let direction: QuotaAnomalyDirection
    public let identity: QuotaWindowIdentity
    public let calculatedCurrentValue: Double
    public let calculatedBaselineValues: [Double]
    public let calculatedBaselineMedian: Double
    public let calculatedRatio: Double
    public let calculatedThreshold: Double
    public let normalization: QuotaAnomalyNormalizationSummary
    public let valueClassification: QuotaAnomalyEvidenceClassification
    public let attribution: QuotaAnomalyAttribution
}

public struct QuotaAnomalyNoFinding: Equatable, Sendable {
    public let metadata: QuotaAnomalyResultMetadata
    public let identity: QuotaWindowIdentity
    public let calculatedCurrentValue: Double
    public let calculatedBaselineValues: [Double]
    public let calculatedBaselineMedian: Double
    public let calculatedRatio: Double?
    public let calculatedThreshold: Double
    public let normalization: QuotaAnomalyNormalizationSummary
    public let valueClassification: QuotaAnomalyEvidenceClassification
}

public struct QuotaAnomalyObservedZero: Equatable, Sendable {
    public let metadata: QuotaAnomalyResultMetadata
    public let identity: QuotaWindowIdentity
    public let calculatedCurrentValue: Double
    public let calculatedBaselineValues: [Double]
    public let normalization: QuotaAnomalyNormalizationSummary
    public let valueClassification: QuotaAnomalyEvidenceClassification
}

public struct UnavailableQuotaAnomalyAnalysis: Equatable, Sendable {
    public let metadata: QuotaAnomalyResultMetadata
    public let reason: QuotaAnomalyUnavailableReason
}

public enum QuotaAnomalyState: Equatable, Sendable {
    case finding(QuotaConsumptionAnomalyFinding)
    case noFinding(QuotaAnomalyNoFinding)
    case observedZero(QuotaAnomalyObservedZero)
    case unavailable(UnavailableQuotaAnomalyAnalysis)
}

enum QuotaAnomalyScoreMethod: Equatable {
    case trailingMedianRatio
    case medianAbsoluteDeviation
}

enum QuotaAnomalyScoreOutcome: Equatable {
    case finding(Double)
    case noFinding(Double?)
    case unavailable
}

struct QuotaAnomalyScoreEvaluation: Equatable {
    let baselineMedian: Double
    let outcome: QuotaAnomalyScoreOutcome
}

enum QuotaAnomalyScoring {
    static func evaluate(
        baseline: [Double],
        current: Double,
        method: QuotaAnomalyScoreMethod,
        threshold: Double
    ) -> QuotaAnomalyScoreEvaluation {
        guard baseline.count >= 3, baseline.count.isMultiple(of: 2) == false,
              baseline.allSatisfy({ $0.isFinite && $0 >= 0 }),
              current.isFinite, current >= 0,
              threshold.isFinite, threshold > 0 else {
            return QuotaAnomalyScoreEvaluation(baselineMedian: 0, outcome: .unavailable)
        }
        let ordered = baseline.sorted()
        let median = ordered[ordered.count / 2]
        switch method {
        case .trailingMedianRatio:
            guard median > 0 else {
                return QuotaAnomalyScoreEvaluation(
                    baselineMedian: median,
                    outcome: current == 0 ? .noFinding(nil) : .unavailable
                )
            }
            let ratio = current / median
            guard ratio.isFinite else { return QuotaAnomalyScoreEvaluation(baselineMedian: median, outcome: .unavailable) }
            return QuotaAnomalyScoreEvaluation(
                baselineMedian: median,
                outcome: ratio >= threshold ? .finding(ratio) : .noFinding(ratio)
            )
        case .medianAbsoluteDeviation:
            let deviations = ordered.map { abs($0 - median) }.sorted()
            let dispersion = deviations[deviations.count / 2]
            guard dispersion > 0 else {
                return QuotaAnomalyScoreEvaluation(
                    baselineMedian: median,
                    outcome: current == median ? .noFinding(nil) : .unavailable
                )
            }
            let score = 0.6745 * (current - median) / dispersion
            guard score.isFinite else { return QuotaAnomalyScoreEvaluation(baselineMedian: median, outcome: .unavailable) }
            return QuotaAnomalyScoreEvaluation(
                baselineMedian: median,
                outcome: score >= threshold ? .finding(score) : .noFinding(score)
            )
        }
    }
}

public enum QuotaAnomalyAnalytics {
    public static let method = QuotaAnomalyMethod.trailingMedianRatioV1
    public static let comparisonDuration: TimeInterval = 10 * 60
    public static let baselineDuration: TimeInterval = 50 * 60
    public static let minimumBaselineSampleCount = 5
    public static let ratioThreshold = 3.0

    public static func analyze(
        _ observations: [MeasuredQuotaObservation],
        now: Date,
        maximumAge: TimeInterval,
        expectedIdentity: QuotaWindowIdentity? = nil,
        gaps: [QuotaAnomalyPeriod] = [],
        supersededObservationIdentities: Set<QuotaObservationIdentity> = [],
        evidenceVersions suppliedEvidenceVersions: [QuotaObservationIdentity: QuotaAnomalyEvidenceVersion] = [:],
        normalization: QuotaAnomalyNormalization = .directQuotaMovement
    ) -> QuotaAnomalyState {
        let removedSupersededIdentities = Set(observations.lazy.map(\.stableIdentity))
            .intersection(supersededObservationIdentities)
        let ordered = observations
            .filter { !supersededObservationIdentities.contains($0.stableIdentity) }
            .sorted { ($0.observedAt, $0.stableIdentity.digest) < ($1.observedAt, $1.stableIdentity.digest) }
        var seen = Set<QuotaObservationIdentity>()
        let unique = ordered.filter { seen.insert($0.stableIdentity).inserted }
        let identities = Array(Set(unique.map(\.identity) + [expectedIdentity].compactMap { $0 })).sorted {
            ($0.product.rawValue, $0.identifier, $0.resetBoundary) < ($1.product.rawValue, $1.identifier, $1.resetBoundary)
        }
        let allEvidenceVersions = orderedEvidenceVersions(unique, supplied: suppliedEvidenceVersions)
        let requestedDenominators: [QuotaAnomalyDenominatorInput] = switch normalization {
        case .directQuotaMovement: []
        case let .measuredDenominator(request): request.inputs.sorted { ($0.period.start, $0.period.end) < ($1.period.start, $1.period.end) }
        }
        var limitations: [QuotaAnomalyLimitation] = [.providerWeightingUnknown, .noCausalAttribution, .syntheticFixtureValidationOnly]
        if !removedSupersededIdentities.isEmpty { limitations.append(.supersededEvidenceExcluded) }

        func metadata(
            qualification: QuotaAnomalyQualification,
            current: QuotaAnomalyPeriod? = nil,
            baseline: QuotaAnomalyPeriod? = nil,
            inputs: [MeasuredQuotaObservation]? = nil,
            evidenceVersions: [QuotaAnomalyEvidenceVersion]? = nil,
            denominatorInputs: [QuotaAnomalyDenominatorInput]? = nil,
            extraLimitations: [QuotaAnomalyLimitation] = []
        ) -> QuotaAnomalyResultMetadata {
            let effectiveInputs = inputs ?? unique
            let effectiveClassifications = Array(Set(effectiveInputs.map { observation in
                observation.source == .claudeProviderReport ? QuotaAnomalyEvidenceClassification.reported : .measured
            })).sorted { $0.rawValue < $1.rawValue }
            return QuotaAnomalyResultMetadata(
                method: method,
                qualification: qualification,
                createdAt: now.timeIntervalSince1970.isFinite ? now : nil,
                implicatedIdentities: identities,
                currentPeriod: current,
                baselinePeriod: baseline,
                inputObservationIdentities: effectiveInputs.map(\.stableIdentity),
                interpretationVersions: Array(Set(effectiveInputs.map(\.interpretationVersion))).sorted { $0.rawValue < $1.rawValue },
                evidenceVersions: evidenceVersions ?? allEvidenceVersions,
                inputClassifications: effectiveClassifications,
                denominatorInputs: denominatorInputs ?? requestedDenominators,
                limitations: Array(Set(limitations + extraLimitations)).sorted { $0.rawValue < $1.rawValue }
            )
        }
        func unavailable(
            _ reason: QuotaAnomalyUnavailableReason,
            current: QuotaAnomalyPeriod? = nil,
            baseline: QuotaAnomalyPeriod? = nil,
            denominatorInputs: [QuotaAnomalyDenominatorInput]? = nil,
            extraLimitations: [QuotaAnomalyLimitation] = []
        ) -> QuotaAnomalyState {
            .unavailable(UnavailableQuotaAnomalyAnalysis(
                metadata: metadata(
                    qualification: .unavailable,
                    current: current,
                    baseline: baseline,
                    denominatorInputs: denominatorInputs,
                    extraLimitations: extraLimitations
                ),
                reason: reason
            ))
        }

        guard now.timeIntervalSince1970.isFinite,
              maximumAge.isFinite, maximumAge >= 0 else { return unavailable(.invalidEvaluation) }
        guard identities.count <= 1 else { return unavailable(.incompatibleEvidence) }
        guard let identity = unique.first?.identity ?? expectedIdentity else { return unavailable(.insufficientObservations) }
        guard identity.insightWindowKind != .other else { return unavailable(.incompatibleEvidence) }
        let grouped = Dictionary(grouping: unique, by: \.observedAt)
        guard !grouped.values.contains(where: { Set($0.map(\.percentageUsed)).count > 1 }) else {
            return unavailable(.conflictingObservations)
        }
        let distinct = grouped.values.compactMap(\.first).sorted { $0.observedAt < $1.observedAt }
        guard identity.resetBoundary > now else { return unavailable(.resetOrExpired) }
        guard let latest = distinct.last else { return unavailable(.insufficientObservations) }
        let age = now.timeIntervalSince(latest.observedAt)
        guard age >= 0, age <= maximumAge else { return unavailable(.staleEvidence) }
        guard distinct.count >= minimumBaselineSampleCount + 2 else { return unavailable(.insufficientBaseline) }
        for pair in zip(distinct, distinct.dropFirst()) where pair.1.percentageUsed < pair.0.percentageUsed {
            return unavailable(.counterDecreased)
        }

        let selected = Array(distinct.suffix(minimumBaselineSampleCount + 2))
        let selectedEvidenceVersions = orderedEvidenceVersions(selected, supplied: suppliedEvidenceVersions)
        let versionLimitations = incompatibleVersionLimitations(selectedEvidenceVersions)
            + incompatibleObservationVersionLimitations(selected, supplied: suppliedEvidenceVersions)
        guard versionLimitations.isEmpty else {
            return unavailable(.incompatibleEvidence, extraLimitations: versionLimitations)
        }
        let intervals = zip(selected, selected.dropFirst()).map { lower, upper in
            (lower: lower, upper: upper, duration: upper.observedAt.timeIntervalSince(lower.observedAt), value: upper.percentageUsed - lower.percentageUsed)
        }
        guard intervals.allSatisfy({ abs($0.duration - comparisonDuration) < 0.000_001 }),
              let first = selected.first,
              latest.observedAt.timeIntervalSince(first.observedAt) == baselineDuration + comparisonDuration else {
            return unavailable(.insufficientSpan)
        }
        guard let firstInterval = intervals.first,
              let lastInterval = intervals.last,
              let currentPeriod = try? QuotaAnomalyPeriod(start: lastInterval.lower.observedAt, end: lastInterval.upper.observedAt),
              let baselinePeriod = try? QuotaAnomalyPeriod(start: firstInterval.lower.observedAt, end: intervals[minimumBaselineSampleCount - 1].upper.observedAt) else {
            return unavailable(.insufficientSpan)
        }
        guard !gaps.contains(where: { overlaps($0, currentPeriod) || overlaps($0, baselinePeriod) }) else {
            return unavailable(.gap, current: currentPeriod, baseline: baselinePeriod)
        }

        let rawValues = intervals.map(\.value)
        let normalized: (values: [Double], summary: QuotaAnomalyNormalizationSummary, denominators: [QuotaAnomalyDenominatorInput])
        switch normalization {
        case .directQuotaMovement:
            normalized = (rawValues, .directQuotaMovement, [])
        case let .measuredDenominator(request):
            switch normalize(rawValues, intervals: intervals, request: request, now: now, maximumAge: maximumAge) {
            case let .success(value): normalized = value
            case let .failure(failure):
                return unavailable(
                    failure.reason,
                    current: currentPeriod,
                    baseline: baselinePeriod,
                    denominatorInputs: failure.inputs
                )
            }
        }

        let baselineValues = Array(normalized.values.prefix(minimumBaselineSampleCount))
        guard let currentValue = normalized.values.last else {
            return unavailable(.insufficientSpan)
        }
        let resultMetadata = metadata(
            qualification: .qualified,
            current: currentPeriod,
            baseline: baselinePeriod,
            inputs: selected,
            evidenceVersions: selectedEvidenceVersions,
            denominatorInputs: normalized.denominators
        )
        if selected.allSatisfy({ $0.percentageUsed == 0 }) {
            return .observedZero(QuotaAnomalyObservedZero(
                metadata: resultMetadata,
                identity: identity,
                calculatedCurrentValue: 0,
                calculatedBaselineValues: baselineValues,
                normalization: normalized.summary,
                valueClassification: .calculated
            ))
        }
        let scoring = QuotaAnomalyScoring.evaluate(
            baseline: baselineValues,
            current: currentValue,
            method: .trailingMedianRatio,
            threshold: ratioThreshold
        )
        switch scoring.outcome {
        case let .finding(ratio):
            return .finding(QuotaConsumptionAnomalyFinding(
                metadata: resultMetadata,
                findingType: .quotaConsumptionAnomaly,
                direction: .higher,
                identity: identity,
                calculatedCurrentValue: currentValue,
                calculatedBaselineValues: baselineValues,
                calculatedBaselineMedian: scoring.baselineMedian,
                calculatedRatio: ratio,
                calculatedThreshold: ratioThreshold,
                normalization: normalized.summary,
                valueClassification: .calculated,
                attribution: .unattributed
            ))
        case let .noFinding(ratio):
            return .noFinding(QuotaAnomalyNoFinding(
                metadata: resultMetadata,
                identity: identity,
                calculatedCurrentValue: currentValue,
                calculatedBaselineValues: baselineValues,
                calculatedBaselineMedian: scoring.baselineMedian,
                calculatedRatio: ratio,
                calculatedThreshold: ratioThreshold,
                normalization: normalized.summary,
                valueClassification: .calculated
            ))
        case .unavailable:
            return unavailable(.unstableBaseline, current: currentPeriod, baseline: baselinePeriod)
        }
    }

    private struct DenominatorFailure: Error {
        let reason: QuotaAnomalyUnavailableReason
        let inputs: [QuotaAnomalyDenominatorInput]
    }

    private static func normalize(
        _ values: [Double],
        intervals: [(lower: MeasuredQuotaObservation, upper: MeasuredQuotaObservation, duration: TimeInterval, value: Double)],
        request: QuotaAnomalyDenominatorRequest,
        now: Date,
        maximumAge: TimeInterval
    ) -> Result<(values: [Double], summary: QuotaAnomalyNormalizationSummary, denominators: [QuotaAnomalyDenominatorInput]), DenominatorFailure> {
        let expectedPeriods = intervals.compactMap { try? QuotaAnomalyPeriod(start: $0.lower.observedAt, end: $0.upper.observedAt) }
        let supplied = request.inputs.sorted { ($0.period.start, $0.period.end) < ($1.period.start, $1.period.end) }
        guard Set(supplied.map(\.period)).count == supplied.count else {
            return .failure(DenominatorFailure(reason: .incompatibleDenominator, inputs: supplied))
        }
        var byPeriod = Dictionary(grouping: supplied, by: \.period)
        let completed = expectedPeriods.map { period in
            byPeriod.removeValue(forKey: period)?.first ?? QuotaAnomalyDenominatorInput(
                missingPeriod: period,
                kind: request.kind,
                source: request.source,
                methodVersion: request.methodVersion
            )
        }
        guard byPeriod.isEmpty else {
            return .failure(DenominatorFailure(reason: .incompatibleDenominator, inputs: completed + byPeriod.values.flatMap { $0 }))
        }
        for denominator in completed {
            guard denominator.kind == request.kind,
                  denominator.source == request.source,
                  denominator.methodVersion == request.methodVersion else {
                return .failure(DenominatorFailure(reason: .incompatibleDenominator, inputs: completed))
            }
            switch denominator.coverage {
            case .gap:
                return .failure(DenominatorFailure(reason: .missingDenominator, inputs: completed))
            case .partial:
                return .failure(DenominatorFailure(reason: .partialDenominatorCoverage, inputs: completed))
            case .complete:
                break
            }
            guard let value = denominator.value, value > 0 else {
                return .failure(DenominatorFailure(reason: .zeroDenominator, inputs: completed))
            }
            guard let observedAt = denominator.observedAt else {
                return .failure(DenominatorFailure(reason: .missingDenominator, inputs: completed))
            }
            let age = now.timeIntervalSince(observedAt)
            guard age >= 0, age <= maximumAge else {
                return .failure(DenominatorFailure(reason: .staleDenominator, inputs: completed))
            }
        }
        let denominatorValues = completed.compactMap(\.value)
        guard denominatorValues.count == completed.count else {
            return .failure(DenominatorFailure(reason: .missingDenominator, inputs: completed))
        }
        let normalizedValues = zip(values, denominatorValues).map(/)
        guard normalizedValues.allSatisfy(\.isFinite) else {
            return .failure(DenominatorFailure(reason: .incompatibleDenominator, inputs: completed))
        }
        return .success((
            normalizedValues,
            .measuredDenominator(
                kind: request.kind,
                unit: request.kind.unit,
                source: request.source,
                methodVersion: request.methodVersion
            ),
            completed
        ))
    }

    private static func overlaps(_ lhs: QuotaAnomalyPeriod, _ rhs: QuotaAnomalyPeriod) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    private static func orderedEvidenceVersions(
        _ observations: [MeasuredQuotaObservation],
        supplied: [QuotaObservationIdentity: QuotaAnomalyEvidenceVersion]
    ) -> [QuotaAnomalyEvidenceVersion] {
        Array(Set(observations.map { supplied[$0.stableIdentity] ?? defaultEvidenceVersion(for: $0) })).sorted {
            ($0.adapter.rawValue, $0.client.rawValue, $0.providerFormat.rawValue)
                < ($1.adapter.rawValue, $1.client.rawValue, $1.providerFormat.rawValue)
        }
    }

    static func defaultEvidenceVersion(for observation: MeasuredQuotaObservation) -> QuotaAnomalyEvidenceVersion {
        QuotaAnomalyEvidenceVersion(
            validatedAdapter: .quotaObservationV1,
            client: .notReported,
            providerFormat: observation.source == .claudeProviderReport ? .claudeProviderReportV1 : .codexLocalReportV1
        )
    }

    static func isCompatible(
        _ version: QuotaAnomalyEvidenceVersion,
        with observation: MeasuredQuotaObservation
    ) -> Bool {
        observationVersionLimitations(version, observation: observation).isEmpty
    }

    private static func incompatibleObservationVersionLimitations(
        _ observations: [MeasuredQuotaObservation],
        supplied: [QuotaObservationIdentity: QuotaAnomalyEvidenceVersion]
    ) -> [QuotaAnomalyLimitation] {
        var result = Set<QuotaAnomalyLimitation>()
        for observation in observations {
            guard let version = supplied[observation.stableIdentity] else { continue }
            result.formUnion(observationVersionLimitations(version, observation: observation))
        }
        return result.sorted { $0.rawValue < $1.rawValue }
    }

    private static func observationVersionLimitations(
        _ version: QuotaAnomalyEvidenceVersion,
        observation: MeasuredQuotaObservation
    ) -> [QuotaAnomalyLimitation] {
        var result: [QuotaAnomalyLimitation] = []
        if version.adapter != .quotaObservationV1 {
            result.append(.incompatibleAdapterVersion)
        }
        let expectedFormat: QuotaAnomalyProviderFormatVersion = observation.source == .claudeProviderReport
            ? .claudeProviderReportV1
            : .codexLocalReportV1
        if version.providerFormat != expectedFormat {
            result.append(.incompatibleProviderFormatVersion)
        }
        let clientIsCompatible = switch (observation.identity.product, observation.source, version.client) {
        case (.claudeCode, .claudeProviderReport, .notReported),
             (.claudeCode, .claudeProviderReport, .claudeSupportedV1),
             (.codex, .codexLocalReport, .notReported),
             (.codex, .codexLocalReport, .codex0144):
            true
        default:
            false
        }
        if !clientIsCompatible { result.append(.incompatibleClientVersion) }
        return result
    }

    private static func incompatibleVersionLimitations(
        _ versions: [QuotaAnomalyEvidenceVersion]
    ) -> [QuotaAnomalyLimitation] {
        var result: [QuotaAnomalyLimitation] = []
        if Set(versions.map(\.adapter)).count > 1 { result.append(.incompatibleAdapterVersion) }
        if Set(versions.map(\.client)).count > 1 { result.append(.incompatibleClientVersion) }
        if Set(versions.map(\.providerFormat)).count > 1 { result.append(.incompatibleProviderFormatVersion) }
        return result
    }
}
