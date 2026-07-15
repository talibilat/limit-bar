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

public enum QuotaAnomalyEvidenceClassification: String, Codable, Equatable, Sendable {
    case reported
    case measured
    case calculated
    case inferred
}

public enum QuotaAnomalyNormalizationSummary: Equatable, Sendable {
    case directQuotaMovement
    case measuredDenominator(name: String, unit: String, version: String)
}

public enum QuotaAnomalyAttribution: String, Codable, Equatable, Sendable {
    case unattributed
}

public enum QuotaAnomalyLimitation: String, Codable, Equatable, Hashable, Sendable {
    case providerWeightingUnknown = "provider_weighting_unknown"
    case noCausalAttribution = "no_causal_attribution"
    case syntheticFixtureValidationOnly = "synthetic_fixture_validation_only"
    case incompatibleInterpretationVersion = "incompatible_interpretation_version"
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

public struct QuotaConsumptionAnomalyFinding: Equatable, Sendable {
    public let findingType: QuotaAnomalyFindingType
    public let direction: QuotaAnomalyDirection
    public let method: QuotaAnomalyMethod
    public let qualification: QuotaAnomalyQualification
    public let createdAt: Date
    public let identity: QuotaWindowIdentity
    public let currentPeriod: QuotaAnomalyPeriod
    public let baselinePeriod: QuotaAnomalyPeriod
    public let calculatedCurrentValue: Double
    public let calculatedBaselineMedian: Double
    public let calculatedRatio: Double
    public let calculatedThreshold: Double
    public let baselineSampleCount: Int
    public let inputObservationIdentities: [QuotaObservationIdentity]
    public let interpretationVersions: [QuotaObservationInterpretationVersion]
    public let evidenceVersions: [QuotaAnomalyEvidenceVersion]
    public let inputClassifications: [QuotaAnomalyEvidenceClassification]
    public let normalization: QuotaAnomalyNormalizationSummary
    public let denominatorInputs: [MeasuredQuotaAnomalyDenominator]
    public let currentValueClassification: QuotaAnomalyEvidenceClassification
    public let baselineClassification: QuotaAnomalyEvidenceClassification
    public let scoreClassification: QuotaAnomalyEvidenceClassification
    public let attribution: QuotaAnomalyAttribution
    public let limitations: [QuotaAnomalyLimitation]
}

public struct QuotaAnomalyNoFinding: Equatable, Sendable {
    public let method: QuotaAnomalyMethod
    public let qualification: QuotaAnomalyQualification
    public let createdAt: Date
    public let identity: QuotaWindowIdentity
    public let currentPeriod: QuotaAnomalyPeriod
    public let baselinePeriod: QuotaAnomalyPeriod
    public let calculatedCurrentValue: Double
    public let calculatedBaselineMedian: Double
    public let calculatedRatio: Double?
    public let calculatedThreshold: Double
    public let inputObservationIdentities: [QuotaObservationIdentity]
    public let interpretationVersions: [QuotaObservationInterpretationVersion]
    public let evidenceVersions: [QuotaAnomalyEvidenceVersion]
    public let inputClassifications: [QuotaAnomalyEvidenceClassification]
    public let normalization: QuotaAnomalyNormalizationSummary
    public let denominatorInputs: [MeasuredQuotaAnomalyDenominator]
    public let currentValueClassification: QuotaAnomalyEvidenceClassification
    public let baselineClassification: QuotaAnomalyEvidenceClassification
    public let scoreClassification: QuotaAnomalyEvidenceClassification
    public let limitations: [QuotaAnomalyLimitation]
}

public struct UnavailableQuotaAnomalyAnalysis: Equatable, Sendable {
    public let reason: QuotaAnomalyUnavailableReason
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
    public let denominatorInputs: [MeasuredQuotaAnomalyDenominator]
    public let limitations: [QuotaAnomalyLimitation]
}

public enum QuotaAnomalyState: Equatable, Sendable {
    case finding(QuotaConsumptionAnomalyFinding)
    case noFinding(QuotaAnomalyNoFinding)
    case unavailable(UnavailableQuotaAnomalyAnalysis)
}

public struct MeasuredQuotaAnomalyDenominator: Equatable, Sendable {
    public let period: QuotaAnomalyPeriod
    public let name: String
    public let unit: String
    public let version: String
    public let value: Double
    public let observedAt: Date
    public let coverage: Double
    public let classification: QuotaAnomalyEvidenceClassification

    public init(
        period: QuotaAnomalyPeriod,
        name: String,
        unit: String,
        version: String,
        value: Double,
        observedAt: Date,
        coverage: Double = 1,
        classification: QuotaAnomalyEvidenceClassification = .measured
    ) throws {
        let allowed = { (value: String) in
            !value.isEmpty && value.utf8.count <= 64
                && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
                && !value.containsQuotaAnomalyProhibitedContent
        }
        guard allowed(name), allowed(unit), allowed(version),
              value.isFinite, value >= 0,
              observedAt.timeIntervalSince1970.isFinite, observedAt >= period.end,
              coverage.isFinite, (0...1).contains(coverage) else {
            throw QuotaAnomalyValidationError.invalidDenominator
        }
        self.period = period
        self.name = name
        self.unit = unit
        self.version = version
        self.value = value
        self.observedAt = observedAt
        self.coverage = coverage
        self.classification = classification
    }
}

public enum QuotaAnomalyNormalization: Equatable, Sendable {
    case directQuotaMovement
    case measuredDenominator([MeasuredQuotaAnomalyDenominator])
}

public struct QuotaAnomalyEvidenceVersion: Codable, Equatable, Hashable, Sendable {
    public let adapterVersion: String
    public let clientVersion: String?
    public let providerFormatVersion: String

    public init(adapterVersion: String, clientVersion: String?, providerFormatVersion: String) throws {
        let allowed = { (value: String) in
            !value.isEmpty && value.utf8.count <= 64
                && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
                && !value.containsQuotaAnomalyProhibitedContent
        }
        guard allowed(adapterVersion), allowed(providerFormatVersion), clientVersion.map(allowed) ?? true else {
            throw QuotaAnomalyValidationError.invalidEvidenceVersion
        }
        self.adapterVersion = adapterVersion
        self.clientVersion = clientVersion
        self.providerFormatVersion = providerFormatVersion
    }

    fileprivate init(trustedAdapterVersion: String, trustedProviderFormatVersion: String) {
        self.adapterVersion = trustedAdapterVersion
        self.clientVersion = nil
        self.providerFormatVersion = trustedProviderFormatVersion
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
        let ordered = observations
            .filter { !supersededObservationIdentities.contains($0.stableIdentity) }
            .sorted { ($0.observedAt, $0.stableIdentity.digest) < ($1.observedAt, $1.stableIdentity.digest) }
        var seen = Set<QuotaObservationIdentity>()
        let unique = ordered.filter { seen.insert($0.stableIdentity).inserted }
        let identities = Array(Set(unique.map(\.identity) + [expectedIdentity].compactMap { $0 })).sorted {
            ($0.product.rawValue, $0.identifier, $0.resetBoundary) < ($1.product.rawValue, $1.identifier, $1.resetBoundary)
        }
        let versions = Array(Set(unique.map(\.interpretationVersion))).sorted { $0.rawValue < $1.rawValue }
        let evidenceVersions = Array(Set(unique.map { observation in
            suppliedEvidenceVersions[observation.stableIdentity] ?? defaultEvidenceVersion(for: observation)
        })).sorted {
            ($0.adapterVersion, $0.clientVersion ?? "", $0.providerFormatVersion)
                < ($1.adapterVersion, $1.clientVersion ?? "", $1.providerFormatVersion)
        }
        let inputClassifications = Array(Set(unique.map { observation in
            observation.source == .claudeProviderReport ? QuotaAnomalyEvidenceClassification.reported : .measured
        })).sorted { $0.rawValue < $1.rawValue }
        let requestedDenominators: [MeasuredQuotaAnomalyDenominator] = switch normalization {
        case .directQuotaMovement: []
        case let .measuredDenominator(values): values.sorted { ($0.period.start, $0.period.end) < ($1.period.start, $1.period.end) }
        }
        var limitations: [QuotaAnomalyLimitation] = [.providerWeightingUnknown, .noCausalAttribution, .syntheticFixtureValidationOnly]
        if !supersededObservationIdentities.isEmpty { limitations.append(.supersededEvidenceExcluded) }

        func unavailable(
            _ reason: QuotaAnomalyUnavailableReason,
            current: QuotaAnomalyPeriod? = nil,
            baseline: QuotaAnomalyPeriod? = nil,
            createdAt: Date? = now.timeIntervalSince1970.isFinite ? now : nil,
            extraLimitations: [QuotaAnomalyLimitation] = []
        ) -> QuotaAnomalyState {
            .unavailable(UnavailableQuotaAnomalyAnalysis(
                reason: reason,
                method: method,
                qualification: .unavailable,
                createdAt: createdAt,
                implicatedIdentities: identities,
                currentPeriod: current,
                baselinePeriod: baseline,
                inputObservationIdentities: unique.map(\.stableIdentity),
                interpretationVersions: versions,
                evidenceVersions: evidenceVersions,
                inputClassifications: inputClassifications,
                denominatorInputs: requestedDenominators,
                limitations: Array(Set(limitations + extraLimitations)).sorted { $0.rawValue < $1.rawValue }
            ))
        }

        guard now.timeIntervalSince1970.isFinite,
              maximumAge.isFinite, maximumAge >= 0 else {
            return unavailable(.invalidEvaluation, createdAt: nil)
        }
        guard identities.count <= 1 else { return unavailable(.incompatibleEvidence) }
        guard let identity = unique.first?.identity ?? expectedIdentity else { return unavailable(.insufficientObservations) }
        guard identity.insightWindowKind != .other else { return unavailable(.incompatibleEvidence) }
        guard versions.count <= 1 else {
            return unavailable(.incompatibleEvidence, extraLimitations: [.incompatibleInterpretationVersion])
        }
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
        let selectedEvidenceVersions = Array(Set(selected.map { observation in
            suppliedEvidenceVersions[observation.stableIdentity] ?? defaultEvidenceVersion(for: observation)
        })).sorted {
            ($0.adapterVersion, $0.clientVersion ?? "", $0.providerFormatVersion)
                < ($1.adapterVersion, $1.clientVersion ?? "", $1.providerFormatVersion)
        }
        guard selectedEvidenceVersions.count == 1 else {
            return unavailable(.incompatibleEvidence, extraLimitations: [.incompatibleInterpretationVersion])
        }
        let intervals = zip(selected, selected.dropFirst()).map { lower, upper in
            (lower: lower, upper: upper, duration: upper.observedAt.timeIntervalSince(lower.observedAt), value: upper.percentageUsed - lower.percentageUsed)
        }
        guard intervals.allSatisfy({ abs($0.duration - comparisonDuration) < 0.000_001 }),
              let first = selected.first,
              latest.observedAt.timeIntervalSince(first.observedAt) == baselineDuration + comparisonDuration else {
            return unavailable(.insufficientSpan)
        }
        guard let currentPeriod = try? QuotaAnomalyPeriod(start: intervals.last!.lower.observedAt, end: intervals.last!.upper.observedAt),
              let baselinePeriod = try? QuotaAnomalyPeriod(start: intervals.first!.lower.observedAt, end: intervals[minimumBaselineSampleCount - 1].upper.observedAt) else {
            return unavailable(.insufficientSpan)
        }
        guard !gaps.contains(where: { overlaps($0, currentPeriod) || overlaps($0, baselinePeriod) }) else {
            return unavailable(.gap, current: currentPeriod, baseline: baselinePeriod)
        }

        let rawValues = intervals.map(\.value)
        let normalized: (values: [Double], summary: QuotaAnomalyNormalizationSummary, denominators: [MeasuredQuotaAnomalyDenominator])
        switch normalization {
        case .directQuotaMovement:
            normalized = (rawValues, .directQuotaMovement, [])
        case let .measuredDenominator(denominators):
            switch normalize(rawValues, intervals: intervals, denominators: denominators, now: now, maximumAge: maximumAge) {
            case let .success(value): normalized = value
            case let .failure(reason): return unavailable(reason, current: currentPeriod, baseline: baselinePeriod)
            }
        }

        let baselineValues = Array(normalized.values.prefix(minimumBaselineSampleCount)).sorted()
        let currentValue = normalized.values.last!
        let median = baselineValues[baselineValues.count / 2]
        let trace = selected.map(\.stableIdentity)
        let orderedLimitations = Array(Set(limitations)).sorted { $0.rawValue < $1.rawValue }
        if median == 0 {
            guard currentValue == 0 else {
                return unavailable(.unstableBaseline, current: currentPeriod, baseline: baselinePeriod)
            }
            return .noFinding(QuotaAnomalyNoFinding(
                method: method, qualification: .qualified, createdAt: now, identity: identity,
                currentPeriod: currentPeriod, baselinePeriod: baselinePeriod,
                calculatedCurrentValue: 0, calculatedBaselineMedian: 0, calculatedRatio: nil,
                calculatedThreshold: ratioThreshold, inputObservationIdentities: trace,
                interpretationVersions: versions, evidenceVersions: selectedEvidenceVersions,
                inputClassifications: inputClassifications, normalization: normalized.summary,
                denominatorInputs: normalized.denominators,
                currentValueClassification: .calculated, baselineClassification: .calculated,
                scoreClassification: .calculated,
                limitations: orderedLimitations
            ))
        }
        let ratio = currentValue / median
        guard ratio.isFinite else {
            return unavailable(.unstableBaseline, current: currentPeriod, baseline: baselinePeriod)
        }
        let direction: QuotaAnomalyDirection? = ratio >= ratioThreshold ? .higher : nil
        guard let direction else {
            return .noFinding(QuotaAnomalyNoFinding(
                method: method, qualification: .qualified, createdAt: now, identity: identity,
                currentPeriod: currentPeriod, baselinePeriod: baselinePeriod,
                calculatedCurrentValue: currentValue, calculatedBaselineMedian: median, calculatedRatio: ratio,
                calculatedThreshold: ratioThreshold, inputObservationIdentities: trace,
                interpretationVersions: versions, evidenceVersions: selectedEvidenceVersions,
                inputClassifications: inputClassifications, normalization: normalized.summary,
                denominatorInputs: normalized.denominators,
                currentValueClassification: .calculated, baselineClassification: .calculated,
                scoreClassification: .calculated,
                limitations: orderedLimitations
            ))
        }
        return .finding(QuotaConsumptionAnomalyFinding(
            findingType: .quotaConsumptionAnomaly, direction: direction, method: method,
            qualification: .qualified, createdAt: now, identity: identity,
            currentPeriod: currentPeriod, baselinePeriod: baselinePeriod,
            calculatedCurrentValue: currentValue, calculatedBaselineMedian: median,
            calculatedRatio: ratio, calculatedThreshold: ratioThreshold,
            baselineSampleCount: minimumBaselineSampleCount, inputObservationIdentities: trace,
            interpretationVersions: versions, evidenceVersions: selectedEvidenceVersions,
            inputClassifications: inputClassifications, normalization: normalized.summary,
            denominatorInputs: normalized.denominators,
            currentValueClassification: .calculated, baselineClassification: .calculated,
            scoreClassification: .calculated, attribution: .unattributed,
            limitations: orderedLimitations
        ))
    }

    private static func overlaps(_ lhs: QuotaAnomalyPeriod, _ rhs: QuotaAnomalyPeriod) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    private static func defaultEvidenceVersion(for observation: MeasuredQuotaObservation) -> QuotaAnomalyEvidenceVersion {
        QuotaAnomalyEvidenceVersion(
            trustedAdapterVersion: observation.normalizationVersion.rawValue,
            trustedProviderFormatVersion: observation.interpretationVersion.rawValue
        )
    }

    private static func normalize(
        _ values: [Double],
        intervals: [(lower: MeasuredQuotaObservation, upper: MeasuredQuotaObservation, duration: TimeInterval, value: Double)],
        denominators: [MeasuredQuotaAnomalyDenominator],
        now: Date,
        maximumAge: TimeInterval
    ) -> Result<(values: [Double], summary: QuotaAnomalyNormalizationSummary, denominators: [MeasuredQuotaAnomalyDenominator]), QuotaAnomalyUnavailableReason> {
        guard denominators.count == intervals.count else { return .failure(.missingDenominator) }
        let ordered = denominators.sorted { ($0.period.start, $0.period.end) < ($1.period.start, $1.period.end) }
        guard let first = ordered.first else { return .failure(.missingDenominator) }
        guard first.classification == .measured,
              ordered.allSatisfy({ $0.classification == .measured && $0.name == first.name && $0.unit == first.unit && $0.version == first.version }) else {
            return .failure(.incompatibleDenominator)
        }
        for (index, denominator) in ordered.enumerated() {
            guard let period = try? QuotaAnomalyPeriod(start: intervals[index].lower.observedAt, end: intervals[index].upper.observedAt),
                  denominator.period == period else { return .failure(.incompatibleDenominator) }
            guard denominator.coverage == 1 else { return .failure(.partialDenominatorCoverage) }
            guard denominator.value > 0 else { return .failure(.zeroDenominator) }
            let age = now.timeIntervalSince(denominator.observedAt)
            guard age >= 0, age <= maximumAge else { return .failure(.staleDenominator) }
        }
        let normalizedValues = zip(values, ordered).map { $0 / $1.value }
        guard normalizedValues.allSatisfy(\.isFinite) else { return .failure(.incompatibleDenominator) }
        return .success((
            normalizedValues,
            .measuredDenominator(name: first.name, unit: first.unit, version: first.version),
            ordered
        ))
    }
}

private extension String {
    var containsQuotaAnomalyProhibitedContent: Bool {
        let normalized = lowercased()
        return ["prompt", "response", "credential", "cookie", "terminal", "payload", "request-body", "request_body", "private-path", "private_path", "account-label", "account_label"]
            .contains { normalized.contains($0) }
    }
}
