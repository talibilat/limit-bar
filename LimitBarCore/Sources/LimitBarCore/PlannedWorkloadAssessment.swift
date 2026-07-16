import Foundation

public enum WorkloadPlanningValidationError: Error, Equatable {
    case invalidInput
}

public struct HistoricalRunIdentity: Codable, Equatable, Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}

public struct HistoricalRunRevisionIdentity: Codable, Equatable, Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}

public struct WorkloadEvidenceIdentity: Codable, Equatable, Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}

public struct WorkloadAdapterVersion: Codable, Equatable, Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}

public struct WorkloadClientVersion: Codable, Equatable, Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}

public struct WorkloadProviderFormatVersion: Codable, Equatable, Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}

public enum WorkloadRunSourceProvenance: String, Codable, CaseIterable, Equatable, Sendable {
    case normalizedCompletedRunAdapter = "normalized_completed_run_adapter"
}

public enum PlannedWorkloadKind: String, Codable, CaseIterable, Equatable, Sendable {
    case codingAgentOperations = "coding_agent_operations"
}

public enum WorkloadQuotaWindowKind: String, Codable, CaseIterable, Equatable, Sendable {
    case session
    case weekly
}

public enum WorkloadExecutionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case interactive
}

public struct PlannedWorkload: Equatable, Sendable {
    public let product: ProviderProduct
    public let kind: PlannedWorkloadKind
    public let quotaWindowKind: WorkloadQuotaWindowKind
    public let executionMode: WorkloadExecutionMode
    public let concurrency: Int
    public let workUnits: Int
    public let source: WorkloadRunSourceProvenance
    public let adapterVersion: WorkloadAdapterVersion
    public let clientVersion: WorkloadClientVersion
    public let providerFormatVersion: WorkloadProviderFormatVersion

    public init(
        product: ProviderProduct,
        kind: PlannedWorkloadKind,
        quotaWindowKind: WorkloadQuotaWindowKind,
        executionMode: WorkloadExecutionMode,
        concurrency: Int,
        workUnits: Int,
        source: WorkloadRunSourceProvenance,
        adapterVersion: WorkloadAdapterVersion,
        clientVersion: WorkloadClientVersion,
        providerFormatVersion: WorkloadProviderFormatVersion
    ) throws {
        guard product == .claudeCode || product == .codex,
              (1...64).contains(concurrency), (1...10_000).contains(workUnits) else {
            throw WorkloadPlanningValidationError.invalidInput
        }
        self.product = product
        self.kind = kind
        self.quotaWindowKind = quotaWindowKind
        self.executionMode = executionMode
        self.concurrency = concurrency
        self.workUnits = workUnits
        self.source = source
        self.adapterVersion = adapterVersion
        self.clientVersion = clientVersion
        self.providerFormatVersion = providerFormatVersion
    }
}

public struct CompletedWorkloadRunSupport: Equatable, Sendable {
    public let product: ProviderProduct
    public let kind: PlannedWorkloadKind
    public let quotaWindowKind: WorkloadQuotaWindowKind
    public let executionMode: WorkloadExecutionMode
    public let source: WorkloadRunSourceProvenance
    public let adapterVersion: WorkloadAdapterVersion
    public let clientVersion: WorkloadClientVersion
    public let providerFormatVersion: WorkloadProviderFormatVersion

    public init(
        product: ProviderProduct,
        kind: PlannedWorkloadKind,
        quotaWindowKind: WorkloadQuotaWindowKind,
        executionMode: WorkloadExecutionMode,
        source: WorkloadRunSourceProvenance,
        adapterVersion: WorkloadAdapterVersion,
        clientVersion: WorkloadClientVersion,
        providerFormatVersion: WorkloadProviderFormatVersion
    ) {
        self.product = product
        self.kind = kind
        self.quotaWindowKind = quotaWindowKind
        self.executionMode = executionMode
        self.source = source
        self.adapterVersion = adapterVersion
        self.clientVersion = clientVersion
        self.providerFormatVersion = providerFormatVersion
    }
}

public protocol CompletedWorkloadRunProviding: Sendable {
    func support() -> CompletedWorkloadRunSupport?
    func historicalRuns() -> [MeasuredHistoricalRun]
}

public struct UnsupportedCompletedWorkloadRunProvider: CompletedWorkloadRunProviding {
    public init() {}
    public func support() -> CompletedWorkloadRunSupport? { nil }
    public func historicalRuns() -> [MeasuredHistoricalRun] { [] }
}

public enum MeasuredHistoricalRunOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case completed
    case observedZero = "observed_zero"
    case incomplete
    case failed
    case gap
    case unavailable
}

public enum WorkloadQuotaUnit: String, Codable, CaseIterable, Equatable, Sendable {
    case providerReportedPercentage = "provider_reported_percentage"
}

public struct MeasuredHistoricalRun: Equatable, Sendable {
    public let identity: HistoricalRunIdentity
    public let revisionIdentity: HistoricalRunRevisionIdentity
    public let supersedesRevisionIdentity: HistoricalRunRevisionIdentity?
    public let quotaWindowIdentity: QuotaWindowIdentity
    public let quotaWindowStart: Date
    public let kind: PlannedWorkloadKind
    public let executionMode: WorkloadExecutionMode
    public let concurrency: Int
    public let completedWorkUnits: Int
    public let startedAt: Date
    public let endedAt: Date
    public let measuredQuotaUsedPercent: Double
    public let quotaUnit: WorkloadQuotaUnit
    public let outcome: MeasuredHistoricalRunOutcome
    public let source: WorkloadRunSourceProvenance
    public let adapterVersion: WorkloadAdapterVersion
    public let clientVersion: WorkloadClientVersion
    public let providerFormatVersion: WorkloadProviderFormatVersion
    public let observationIdentities: [QuotaObservationIdentity]
    public let evidenceIdentities: [WorkloadEvidenceIdentity]

    public init(
        identity: HistoricalRunIdentity,
        revisionIdentity: HistoricalRunRevisionIdentity,
        supersedesRevisionIdentity: HistoricalRunRevisionIdentity? = nil,
        quotaWindowIdentity: QuotaWindowIdentity,
        quotaWindowStart: Date,
        kind: PlannedWorkloadKind,
        executionMode: WorkloadExecutionMode,
        concurrency: Int,
        completedWorkUnits: Int,
        startedAt: Date,
        endedAt: Date,
        measuredQuotaUsedPercent: Double,
        quotaUnit: WorkloadQuotaUnit,
        outcome: MeasuredHistoricalRunOutcome,
        source: WorkloadRunSourceProvenance,
        adapterVersion: WorkloadAdapterVersion,
        clientVersion: WorkloadClientVersion,
        providerFormatVersion: WorkloadProviderFormatVersion,
        observationIdentities: [QuotaObservationIdentity],
        evidenceIdentities: [WorkloadEvidenceIdentity]
    ) throws {
        guard (1...64).contains(concurrency), (1...10_000).contains(completedWorkUnits),
              quotaWindowStart.timeIntervalSince1970.isFinite,
              startedAt.timeIntervalSince1970.isFinite, endedAt.timeIntervalSince1970.isFinite,
              quotaWindowStart < quotaWindowIdentity.resetBoundary,
              startedAt >= quotaWindowStart, endedAt <= quotaWindowIdentity.resetBoundary, endedAt > startedAt,
              measuredQuotaUsedPercent.isFinite, (0...100).contains(measuredQuotaUsedPercent),
              !observationIdentities.isEmpty, observationIdentities.count <= 256,
              Set(observationIdentities).count == observationIdentities.count,
              !evidenceIdentities.isEmpty, evidenceIdentities.count <= 256,
              Set(evidenceIdentities).count == evidenceIdentities.count,
              outcome != .observedZero || measuredQuotaUsedPercent == 0,
              outcome != .completed || measuredQuotaUsedPercent > 0 else {
            throw WorkloadPlanningValidationError.invalidInput
        }
        self.identity = identity
        self.revisionIdentity = revisionIdentity
        self.supersedesRevisionIdentity = supersedesRevisionIdentity
        self.quotaWindowIdentity = quotaWindowIdentity
        self.quotaWindowStart = quotaWindowStart
        self.kind = kind
        self.executionMode = executionMode
        self.concurrency = concurrency
        self.completedWorkUnits = completedWorkUnits
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.measuredQuotaUsedPercent = measuredQuotaUsedPercent == 0 ? 0 : measuredQuotaUsedPercent
        self.quotaUnit = quotaUnit
        self.outcome = outcome
        self.source = source
        self.adapterVersion = adapterVersion
        self.clientVersion = clientVersion
        self.providerFormatVersion = providerFormatVersion
        self.observationIdentities = observationIdentities.sorted { $0.digest < $1.digest }
        self.evidenceIdentities = evidenceIdentities.sorted { $0.value.uuidString < $1.value.uuidString }
    }
}

public struct CurrentWorkloadQuotaEvidence: Equatable, Sendable {
    public let latestObservation: MeasuredQuotaObservation
    public let forecast: QuotaInsightState

    public init(latestObservation: MeasuredQuotaObservation, forecast: QuotaInsightState) {
        self.latestObservation = latestObservation
        self.forecast = forecast
    }
}

public enum WorkloadComparabilityMethod: String, Codable, Equatable, Sendable {
    case strictMeasuredOperationsV2 = "strict_measured_operations_v2"
}

public enum WorkloadRequirementRangeMethod: String, Codable, Equatable, Sendable {
    case interquartilePerUnitV1 = "interquartile_per_unit_v1"
}

public enum WorkloadPlanningExclusionReason: String, Codable, Equatable, Hashable, Sendable {
    case incompatibleProviderProduct = "incompatible_provider_product"
    case incompatibleWorkloadKind = "incompatible_workload_kind"
    case incompatibleWindowSemantics = "incompatible_window_semantics"
    case incompatibleExecutionMode = "incompatible_execution_mode"
    case incompatibleConcurrency = "incompatible_concurrency"
    case incompatibleQuotaUnit = "incompatible_quota_unit"
    case incompatibleSource = "incompatible_source"
    case incompatibleClientVersion = "incompatible_client_version"
    case incompatibleAdapterVersion = "incompatible_adapter_version"
    case incompatibleProviderFormatVersion = "incompatible_provider_format_version"
    case incompleteOutcome = "incomplete_outcome"
    case failedOutcome = "failed_outcome"
    case gap = "gap"
    case unavailableEvidence = "unavailable_evidence"
    case observedZeroUnsupported = "observed_zero_unsupported"
    case duplicateRevision = "duplicate_revision"
    case conflictingRevisionIdentity = "conflicting_revision_identity"
    case invalidCorrectionChain = "invalid_correction_chain"
    case supersededRevision = "superseded_revision"
}

public enum WorkloadPlanningUnavailableReason: String, Codable, Equatable, Sendable {
    case unsupportedHistoricalRunAdapter = "unsupported_historical_run_adapter"
    case noHistoricalRuns = "no_historical_runs"
    case insufficientComparableRuns = "insufficient_comparable_runs"
    case incompatibleHistoricalRuns = "incompatible_historical_runs"
    case incompleteHistoricalRuns = "incomplete_historical_runs"
    case missingCurrentQuotaEvidence = "missing_current_quota_evidence"
    case unqualifiedCurrentQuotaEvidence = "unqualified_current_quota_evidence"
    case staleCurrentQuotaEvidence = "stale_current_quota_evidence"
    case expiredCurrentQuotaBoundary = "expired_current_quota_boundary"
    case incompatibleCurrentQuotaEvidence = "incompatible_current_quota_evidence"
    case unsafeQuotaConversion = "unsafe_quota_conversion"
}

public enum WorkloadPlanningConclusion: String, Codable, Equatable, Sendable {
    case likelyCompletionBeforeLimitingBoundary = "likely_completion_before_limiting_boundary"
    case likelyInsufficientCurrentQuota = "likely_insufficient_current_quota"
    case likelyResetBeforeCompletion = "likely_reset_before_completion"
    case likelyExhaustionBeforeCompletion = "likely_exhaustion_before_completion"
}

public enum WorkloadPlanningIndeterminateReason: String, Codable, Equatable, Sendable {
    case requirementOverlapsAvailableQuota = "requirement_overlaps_available_quota"
    case completionOverlapsExhaustion = "completion_overlaps_exhaustion"
    case completionOverlapsReset = "completion_overlaps_reset"
    case exhaustionOverlapsReset = "exhaustion_overlaps_reset"
}

public enum WorkloadQuotaBoundaryInteraction: String, Codable, Equatable, Sendable {
    case exhaustionExpectedFirst = "exhaustion_expected_first"
    case resetExpectedFirst = "reset_expected_first"
    case indeterminateOverlap = "indeterminate_overlap"
}

public enum WorkloadPlanningReason: String, Codable, Equatable, Sendable {
    case comparableMeasuredSampleQualified = "comparable_measured_sample_qualified"
    case currentQuotaForecastQualified = "current_quota_forecast_qualified"
    case requirementBelowAvailableQuota = "requirement_below_available_quota"
    case requirementAboveAvailableQuota = "requirement_above_available_quota"
    case providerReportedResetFirst = "provider_reported_reset_first"
    case calculatedExhaustionFirst = "calculated_exhaustion_first"
}

public enum WorkloadPlanningLimitation: String, Codable, Equatable, Sendable {
    case unsupportedHistoricalRunAdapter = "unsupported_historical_run_adapter"
    case syntheticFixtureValidationOnly = "synthetic_fixture_validation_only"
    case providerWeightingUnknown = "provider_weighting_unknown"
    case noCompletionGuarantee = "no_completion_guarantee"
    case futureProviderBehaviorUnknown = "future_provider_behavior_unknown"
    case postResetCapacityUnknown = "post_reset_capacity_unknown"
    case linearPerUnitScaling = "linear_per_unit_scaling"
}

public enum WorkloadForecastQualification: String, Codable, Equatable, Sendable {
    case qualified
    case unavailable
}

public struct WorkloadPlanningMethodMetadata: Equatable, Sendable {
    public let comparabilityMethod: WorkloadComparabilityMethod
    public let rangeMethod: WorkloadRequirementRangeMethod
    public let minimumComparableRuns: Int
}

public struct WorkloadPlanningSample: Equatable, Sendable {
    public let includedRunIdentities: [HistoricalRunIdentity]
    public let includedRevisionIdentities: [HistoricalRunRevisionIdentity]
    public let supersededRevisionIdentities: [HistoricalRunRevisionIdentity]
    public let observationIdentities: [QuotaObservationIdentity]
    public let evidenceIdentities: [WorkloadEvidenceIdentity]
    public let earliestStart: Date?
    public let latestEnd: Date?
    public let excluded: [WorkloadPlanningExclusionReason: Int]
}

public enum WorkloadPlanningOptionKind: String, Codable, Equatable, Sendable {
    case reduceConcurrency = "reduce_concurrency"
    case reduceWorkUnits = "reduce_work_units"
    case deferUntilReset = "defer_until_reset"
}

public struct WorkloadPlanningOption: Equatable, Sendable {
    public let kind: WorkloadPlanningOptionKind
    public let proposedValue: Int?
    public let supportingRevisionIdentities: [HistoricalRunRevisionIdentity]
    public let observationIdentities: [QuotaObservationIdentity]
    public let evidenceIdentities: [WorkloadEvidenceIdentity]
    public let reason: WorkloadPlanningReason
    public let limitation: WorkloadPlanningLimitation
}

public struct WorkloadPlanningCurrentEvidenceSummary: Equatable, Sendable {
    public let identity: QuotaWindowIdentity
    public let latestObservationIdentity: QuotaObservationIdentity
    public let latestObservedAt: Date
    public let forecastInputIdentities: [QuotaObservationIdentity]
    public let forecastMethod: QuotaForecastMethod
    public let forecastQualification: WorkloadForecastQualification
    public let forecastUnavailableReason: QuotaInsightUnavailableReason?
    public let evidenceAge: TimeInterval?
    public let availablePercent: Double
    public let unboundedExhaustionRange: ClosedRange<Date>?
    public let boundaryInteraction: WorkloadQuotaBoundaryInteraction?
}

public struct AvailableWorkloadPlanningAssessment: Equatable, Sendable {
    public let conclusion: WorkloadPlanningConclusion
    public let requirementPercent: QuotaInsightRange
    public let durationSeconds: QuotaInsightRange
    public let currentEvidence: WorkloadPlanningCurrentEvidenceSummary
    public let sample: WorkloadPlanningSample
    public let metadata: WorkloadPlanningMethodMetadata
    public let reasons: [WorkloadPlanningReason]
    public let limitations: [WorkloadPlanningLimitation]
    public let options: [WorkloadPlanningOption]
}

public struct IndeterminateWorkloadPlanningAssessment: Equatable, Sendable {
    public let reason: WorkloadPlanningIndeterminateReason
    public let requirementPercent: QuotaInsightRange
    public let durationSeconds: QuotaInsightRange
    public let currentEvidence: WorkloadPlanningCurrentEvidenceSummary
    public let sample: WorkloadPlanningSample
    public let metadata: WorkloadPlanningMethodMetadata
    public let reasons: [WorkloadPlanningReason]
    public let limitations: [WorkloadPlanningLimitation]
    public let options: [WorkloadPlanningOption]
}

public struct UnavailableWorkloadPlanningAssessment: Equatable, Sendable {
    public let reason: WorkloadPlanningUnavailableReason
    public let currentEvidence: WorkloadPlanningCurrentEvidenceSummary?
    public let sample: WorkloadPlanningSample
    public let metadata: WorkloadPlanningMethodMetadata
    public let limitations: [WorkloadPlanningLimitation]
}

public enum WorkloadPlanningState: Equatable, Sendable {
    case available(AvailableWorkloadPlanningAssessment)
    case indeterminate(IndeterminateWorkloadPlanningAssessment)
    case unavailable(UnavailableWorkloadPlanningAssessment)
}

public enum WorkloadPlanning {
    public static let minimumComparableRuns = 4
    public static let metadata = WorkloadPlanningMethodMetadata(
        comparabilityMethod: .strictMeasuredOperationsV2,
        rangeMethod: .interquartilePerUnitV1,
        minimumComparableRuns: minimumComparableRuns
    )
    public static let limitations: [WorkloadPlanningLimitation] = [
        .syntheticFixtureValidationOnly,
        .providerWeightingUnknown,
        .noCompletionGuarantee,
        .futureProviderBehaviorUnknown,
        .linearPerUnitScaling,
    ]

    public static func unavailableForUnsupportedAdapter(
        currentEvidence: CurrentWorkloadQuotaEvidence?,
        now: Date
    ) -> WorkloadPlanningState {
        .unavailable(UnavailableWorkloadPlanningAssessment(
            reason: .unsupportedHistoricalRunAdapter,
            currentEvidence: currentEvidenceSummary(currentEvidence, now: now),
            sample: emptySample,
            metadata: metadata,
            limitations: [.unsupportedHistoricalRunAdapter] + limitations
        ))
    }

    public static func assess(
        _ plan: PlannedWorkload,
        historicalRuns: [MeasuredHistoricalRun],
        currentEvidence: CurrentWorkloadQuotaEvidence?,
        now: Date
    ) -> WorkloadPlanningState {
        let canonical = canonicalize(historicalRuns)
        let classified = classify(canonical.current, for: plan, concurrency: plan.concurrency)
        let sample = sample(
            included: classified.included,
            superseded: canonical.superseded,
            excluded: merge(canonical.excluded, classified.excluded)
        )
        let currentSummary = currentEvidenceSummary(currentEvidence, now: now)
        func unavailable(_ reason: WorkloadPlanningUnavailableReason) -> WorkloadPlanningState {
            .unavailable(UnavailableWorkloadPlanningAssessment(
                reason: reason,
                currentEvidence: currentSummary,
                sample: sample,
                metadata: metadata,
                limitations: limitations
            ))
        }

        guard !historicalRuns.isEmpty else { return unavailable(.noHistoricalRuns) }
        guard !classified.included.isEmpty else {
            let incompleteReasons: Set<WorkloadPlanningExclusionReason> = [
                .incompleteOutcome, .failedOutcome, .gap, .unavailableEvidence, .observedZeroUnsupported,
                .duplicateRevision, .conflictingRevisionIdentity, .invalidCorrectionChain,
            ]
            return unavailable(Set(sample.excluded.keys).isSubset(of: incompleteReasons)
                ? .incompleteHistoricalRuns
                : .incompatibleHistoricalRuns)
        }
        guard classified.included.count >= minimumComparableRuns else {
            return unavailable(.insufficientComparableRuns)
        }
        guard let currentEvidence else { return unavailable(.missingCurrentQuotaEvidence) }
        guard case let .qualified(forecast) = currentEvidence.forecast else {
            return unavailable(.unqualifiedCurrentQuotaEvidence)
        }
        let observation = currentEvidence.latestObservation
        guard forecast.identity == observation.identity,
              forecast.forecastMethod == .pairwisePositiveSlopeInterquartileV2,
              forecast.latestObservationIdentity == observation.stableIdentity,
              forecast.latestObservationAt == observation.observedAt,
              forecast.inputObservationIdentities.last == observation.stableIdentity,
              observation.identity.product == plan.product,
              windowKind(observation.identity) == plan.quotaWindowKind else {
            return unavailable(.incompatibleCurrentQuotaEvidence)
        }
        guard now.timeIntervalSince1970.isFinite, observation.identity.resetBoundary > now else {
            return unavailable(.expiredCurrentQuotaBoundary)
        }
        let evidenceAge = now.timeIntervalSince(observation.observedAt)
        let maximumAge = observation.identity.product == .claudeCode
            ? QuotaObservationAdapter.claudeMaximumAge
            : QuotaObservationAdapter.codexMaximumAge
        guard evidenceAge >= 0, evidenceAge <= maximumAge else {
            return unavailable(.staleCurrentQuotaEvidence)
        }

        let normalizedRequirements = classified.included
            .map { $0.measuredQuotaUsedPercent / Double($0.completedWorkUnits) }.sorted()
        let normalizedDurations = classified.included
            .map { $0.endedAt.timeIntervalSince($0.startedAt) / Double($0.completedWorkUnits) }.sorted()
        let requirement = QuotaInsightRange(
            lower: percentile(normalizedRequirements, fraction: 0.25) * Double(plan.workUnits),
            upper: percentile(normalizedRequirements, fraction: 0.75) * Double(plan.workUnits)
        )
        let duration = QuotaInsightRange(
            lower: percentile(normalizedDurations, fraction: 0.25) * Double(plan.workUnits),
            upper: percentile(normalizedDurations, fraction: 0.75) * Double(plan.workUnits)
        )
        let available = max(0, 100 - observation.percentageUsed)
        let summary = qualifiedCurrentEvidenceSummary(observation: observation, forecast: forecast, now: now)
        guard let exhaustion = summary.unboundedExhaustionRange,
              let interaction = summary.boundaryInteraction else {
            return unavailable(.incompatibleCurrentQuotaEvidence)
        }
        let earliestCompletion = now.addingTimeInterval(duration.lower)
        let latestCompletion = now.addingTimeInterval(duration.upper)
        var reasons: [WorkloadPlanningReason] = [.comparableMeasuredSampleQualified, .currentQuotaForecastQualified]
        let conclusion: WorkloadPlanningConclusion?
        let indeterminate: WorkloadPlanningIndeterminateReason?

        if requirement.lower > available {
            reasons.append(.requirementAboveAvailableQuota)
            conclusion = .likelyInsufficientCurrentQuota
            indeterminate = nil
        } else if requirement.upper >= available {
            conclusion = nil
            indeterminate = .requirementOverlapsAvailableQuota
        } else {
            reasons.append(.requirementBelowAvailableQuota)
            switch interaction {
            case .exhaustionExpectedFirst:
                reasons.append(.calculatedExhaustionFirst)
                if latestCompletion < exhaustion.lowerBound {
                    conclusion = .likelyCompletionBeforeLimitingBoundary
                    indeterminate = nil
                } else if exhaustion.upperBound < earliestCompletion {
                    conclusion = .likelyExhaustionBeforeCompletion
                    indeterminate = nil
                } else {
                    conclusion = nil
                    indeterminate = .completionOverlapsExhaustion
                }
            case .resetExpectedFirst:
                reasons.append(.providerReportedResetFirst)
                let reset = observation.identity.resetBoundary
                if latestCompletion < reset {
                    conclusion = .likelyCompletionBeforeLimitingBoundary
                    indeterminate = nil
                } else if reset < earliestCompletion {
                    conclusion = .likelyResetBeforeCompletion
                    indeterminate = nil
                } else {
                    conclusion = nil
                    indeterminate = .completionOverlapsReset
                }
            case .indeterminateOverlap:
                let earliestBoundary = min(exhaustion.lowerBound, observation.identity.resetBoundary)
                if latestCompletion < earliestBoundary {
                    conclusion = .likelyCompletionBeforeLimitingBoundary
                    indeterminate = nil
                } else {
                    conclusion = nil
                    indeterminate = .exhaustionOverlapsReset
                }
            }
        }

        let options = conclusion == .likelyInsufficientCurrentQuota
            ? options(
                for: plan,
                canonicalRuns: canonical.current,
                included: classified.included,
                requirement: requirement,
                available: available,
                current: summary
            )
            : []
        if let conclusion {
            return .available(AvailableWorkloadPlanningAssessment(
                conclusion: conclusion,
                requirementPercent: requirement,
                durationSeconds: duration,
                currentEvidence: summary,
                sample: sample,
                metadata: metadata,
                reasons: reasons,
                limitations: limitations,
                options: options
            ))
        }
        return .indeterminate(IndeterminateWorkloadPlanningAssessment(
            reason: indeterminate!,
            requirementPercent: requirement,
            durationSeconds: duration,
            currentEvidence: summary,
            sample: sample,
            metadata: metadata,
            reasons: reasons,
            limitations: limitations,
            options: []
        ))
    }

    private static let emptySample = WorkloadPlanningSample(
        includedRunIdentities: [], includedRevisionIdentities: [], supersededRevisionIdentities: [],
        observationIdentities: [], evidenceIdentities: [], earliestStart: nil, latestEnd: nil, excluded: [:]
    )

    private struct CanonicalRuns {
        let current: [MeasuredHistoricalRun]
        let superseded: [HistoricalRunRevisionIdentity]
        let excluded: [WorkloadPlanningExclusionReason: Int]
    }

    private static func canonicalize(_ runs: [MeasuredHistoricalRun]) -> CanonicalRuns {
        var excluded: [WorkloadPlanningExclusionReason: Int] = [:]
        var unique: [MeasuredHistoricalRun] = []
        var badRunIDs = Set<HistoricalRunIdentity>()
        for group in Dictionary(grouping: runs, by: \.revisionIdentity).values {
            if group.dropFirst().allSatisfy({ $0 == group[0] }) {
                unique.append(group[0])
                excluded[.duplicateRevision, default: 0] += group.count - 1
            } else {
                excluded[.conflictingRevisionIdentity, default: 0] += group.count
                badRunIDs.formUnion(group.map(\.identity))
            }
        }

        var current: [MeasuredHistoricalRun] = []
        var superseded: [HistoricalRunRevisionIdentity] = []
        for (runID, revisions) in Dictionary(grouping: unique, by: \.identity) {
            guard !badRunIDs.contains(runID) else {
                excluded[.invalidCorrectionChain, default: 0] += revisions.count
                continue
            }
            let revisionIDs = Set(revisions.map(\.revisionIdentity))
            let roots = revisions.filter { $0.supersedesRevisionIdentity == nil }
            let referencesAreInternal = revisions.allSatisfy {
                $0.supersedesRevisionIdentity.map(revisionIDs.contains) ?? true
            }
            let children = Dictionary(grouping: revisions.compactMap { revision in
                revision.supersedesRevisionIdentity.map { ($0, revision.revisionIdentity) }
            }, by: \.0)
            let referenced = Set(revisions.compactMap(\.supersedesRevisionIdentity))
            let terminals = revisions.filter { !referenced.contains($0.revisionIdentity) }
            guard roots.count == 1, terminals.count == 1, referencesAreInternal,
                  children.values.allSatisfy({ $0.count == 1 }) else {
                excluded[.invalidCorrectionChain, default: 0] += revisions.count
                continue
            }
            var visited = Set<HistoricalRunRevisionIdentity>()
            var cursor = terminals[0]
            while visited.insert(cursor.revisionIdentity).inserted,
                  let previous = cursor.supersedesRevisionIdentity,
                  let next = revisions.first(where: { $0.revisionIdentity == previous }) {
                cursor = next
            }
            guard visited.count == revisions.count, cursor.supersedesRevisionIdentity == nil else {
                excluded[.invalidCorrectionChain, default: 0] += revisions.count
                continue
            }
            current.append(terminals[0])
            let prior = revisions.filter { $0.revisionIdentity != terminals[0].revisionIdentity }
            superseded.append(contentsOf: prior.map(\.revisionIdentity))
            excluded[.supersededRevision, default: 0] += prior.count
        }
        return CanonicalRuns(
            current: current.sorted { $0.revisionIdentity.value.uuidString < $1.revisionIdentity.value.uuidString },
            superseded: superseded.sorted { $0.value.uuidString < $1.value.uuidString },
            excluded: excluded.filter { $0.value > 0 }
        )
    }

    private static func classify(
        _ runs: [MeasuredHistoricalRun],
        for plan: PlannedWorkload,
        concurrency: Int
    ) -> (included: [MeasuredHistoricalRun], excluded: [WorkloadPlanningExclusionReason: Int]) {
        var included: [MeasuredHistoricalRun] = []
        var excluded: [WorkloadPlanningExclusionReason: Int] = [:]
        for run in runs {
            let reason: WorkloadPlanningExclusionReason? = if run.quotaWindowIdentity.product != plan.product {
                .incompatibleProviderProduct
            } else if run.kind != plan.kind {
                .incompatibleWorkloadKind
            } else if windowKind(run.quotaWindowIdentity) != plan.quotaWindowKind {
                .incompatibleWindowSemantics
            } else if run.executionMode != plan.executionMode {
                .incompatibleExecutionMode
            } else if run.concurrency != concurrency {
                .incompatibleConcurrency
            } else if run.quotaUnit != .providerReportedPercentage {
                .incompatibleQuotaUnit
            } else if run.source != plan.source {
                .incompatibleSource
            } else if run.clientVersion != plan.clientVersion {
                .incompatibleClientVersion
            } else if run.adapterVersion != plan.adapterVersion {
                .incompatibleAdapterVersion
            } else if run.providerFormatVersion != plan.providerFormatVersion {
                .incompatibleProviderFormatVersion
            } else {
                switch run.outcome {
                case .completed: nil
                case .observedZero: .observedZeroUnsupported
                case .incomplete: .incompleteOutcome
                case .failed: .failedOutcome
                case .gap: .gap
                case .unavailable: .unavailableEvidence
                }
            }
            if let reason { excluded[reason, default: 0] += 1 } else { included.append(run) }
        }
        return (included, excluded)
    }

    private static func sample(
        included: [MeasuredHistoricalRun],
        superseded: [HistoricalRunRevisionIdentity],
        excluded: [WorkloadPlanningExclusionReason: Int]
    ) -> WorkloadPlanningSample {
        WorkloadPlanningSample(
            includedRunIdentities: included.map(\.identity),
            includedRevisionIdentities: included.map(\.revisionIdentity),
            supersededRevisionIdentities: superseded,
            observationIdentities: Array(Set(included.flatMap(\.observationIdentities))).sorted { $0.digest < $1.digest },
            evidenceIdentities: Array(Set(included.flatMap(\.evidenceIdentities))).sorted { $0.value.uuidString < $1.value.uuidString },
            earliestStart: included.map(\.startedAt).min(),
            latestEnd: included.map(\.endedAt).max(),
            excluded: excluded
        )
    }

    private static func options(
        for plan: PlannedWorkload,
        canonicalRuns: [MeasuredHistoricalRun],
        included: [MeasuredHistoricalRun],
        requirement: QuotaInsightRange,
        available: Double,
        current: WorkloadPlanningCurrentEvidenceSummary
    ) -> [WorkloadPlanningOption] {
        var result: [WorkloadPlanningOption] = []
        for concurrency in (1..<plan.concurrency) {
            let alternative = classify(canonicalRuns, for: plan, concurrency: concurrency).included
            guard alternative.count >= minimumComparableRuns else { continue }
            let normalized = alternative.map { $0.measuredQuotaUsedPercent / Double($0.completedWorkUnits) }.sorted()
            guard percentile(normalized, fraction: 0.75) * Double(plan.workUnits) < requirement.lower else { continue }
            result.append(WorkloadPlanningOption(
                kind: .reduceConcurrency,
                proposedValue: concurrency,
                supportingRevisionIdentities: alternative.map(\.revisionIdentity),
                observationIdentities: Array(Set(alternative.flatMap(\.observationIdentities))).sorted { $0.digest < $1.digest },
                evidenceIdentities: Array(Set(alternative.flatMap(\.evidenceIdentities))).sorted { $0.value.uuidString < $1.value.uuidString },
                reason: .requirementAboveAvailableQuota,
                limitation: .providerWeightingUnknown
            ))
            break
        }
        let upperPerUnit = requirement.upper / Double(plan.workUnits)
        let reducedUnits = upperPerUnit > 0 ? Int((available / upperPerUnit).rounded(.down)) : 0
        if reducedUnits > 0, reducedUnits < plan.workUnits {
            result.append(WorkloadPlanningOption(
                kind: .reduceWorkUnits,
                proposedValue: reducedUnits,
                supportingRevisionIdentities: included.map(\.revisionIdentity),
                observationIdentities: Array(Set(included.flatMap(\.observationIdentities))).sorted { $0.digest < $1.digest },
                evidenceIdentities: Array(Set(included.flatMap(\.evidenceIdentities))).sorted { $0.value.uuidString < $1.value.uuidString },
                reason: .requirementAboveAvailableQuota,
                limitation: .linearPerUnitScaling
            ))
        }
        if current.boundaryInteraction == .resetExpectedFirst {
            result.append(WorkloadPlanningOption(
                kind: .deferUntilReset,
                proposedValue: nil,
                supportingRevisionIdentities: included.map(\.revisionIdentity),
                observationIdentities: [current.latestObservationIdentity],
                evidenceIdentities: Array(Set(included.flatMap(\.evidenceIdentities))).sorted { $0.value.uuidString < $1.value.uuidString },
                reason: .providerReportedResetFirst,
                limitation: .postResetCapacityUnknown
            ))
        }
        return result
    }

    private static func currentEvidenceSummary(
        _ evidence: CurrentWorkloadQuotaEvidence?,
        now: Date
    ) -> WorkloadPlanningCurrentEvidenceSummary? {
        guard let evidence else { return nil }
        switch evidence.forecast {
        case let .qualified(forecast):
            let observation = evidence.latestObservation
            guard forecast.identity == observation.identity,
                  forecast.latestObservationIdentity == observation.stableIdentity,
                  forecast.latestObservationAt == observation.observedAt,
                  forecast.inputObservationIdentities.last == observation.stableIdentity else {
                let age = now.timeIntervalSince1970.isFinite ? now.timeIntervalSince(observation.observedAt) : nil
                return WorkloadPlanningCurrentEvidenceSummary(
                    identity: observation.identity,
                    latestObservationIdentity: observation.stableIdentity,
                    latestObservedAt: observation.observedAt,
                    forecastInputIdentities: forecast.inputObservationIdentities,
                    forecastMethod: forecast.forecastMethod,
                    forecastQualification: .qualified,
                    forecastUnavailableReason: nil,
                    evidenceAge: age?.isFinite == true ? age : nil,
                    availablePercent: max(0, 100 - observation.percentageUsed),
                    unboundedExhaustionRange: nil,
                    boundaryInteraction: nil
                )
            }
            return qualifiedCurrentEvidenceSummary(observation: observation, forecast: forecast, now: now)
        case let .unavailable(forecast):
            let observation = evidence.latestObservation
            let age = now.timeIntervalSince1970.isFinite ? now.timeIntervalSince(observation.observedAt) : nil
            return WorkloadPlanningCurrentEvidenceSummary(
                identity: observation.identity,
                latestObservationIdentity: observation.stableIdentity,
                latestObservedAt: observation.observedAt,
                forecastInputIdentities: forecast.inputObservationIdentities,
                forecastMethod: forecast.forecastMethod,
                forecastQualification: .unavailable,
                forecastUnavailableReason: forecast.reason,
                evidenceAge: age?.isFinite == true ? age : nil,
                availablePercent: max(0, 100 - observation.percentageUsed),
                unboundedExhaustionRange: nil,
                boundaryInteraction: nil
            )
        }
    }

    private static func qualifiedCurrentEvidenceSummary(
        observation: MeasuredQuotaObservation,
        forecast: QualifiedQuotaInsight,
        now: Date
    ) -> WorkloadPlanningCurrentEvidenceSummary {
        let remaining = max(0, 100 - observation.percentageUsed)
        let burn = forecast.calculatedBurnPercentPerHour
        let earliest = observation.observedAt.addingTimeInterval(remaining / burn.upper * 3_600)
        let latest = observation.observedAt.addingTimeInterval(remaining / burn.lower * 3_600)
        let range = earliest...latest
        let reset = observation.identity.resetBoundary
        let interaction: WorkloadQuotaBoundaryInteraction = if range.upperBound < reset {
            .exhaustionExpectedFirst
        } else if reset < range.lowerBound {
            .resetExpectedFirst
        } else {
            .indeterminateOverlap
        }
        let age = now.timeIntervalSince1970.isFinite ? now.timeIntervalSince(observation.observedAt) : nil
        return WorkloadPlanningCurrentEvidenceSummary(
            identity: observation.identity,
            latestObservationIdentity: observation.stableIdentity,
            latestObservedAt: observation.observedAt,
            forecastInputIdentities: forecast.inputObservationIdentities,
            forecastMethod: forecast.forecastMethod,
            forecastQualification: .qualified,
            forecastUnavailableReason: nil,
            evidenceAge: age?.isFinite == true ? age : nil,
            availablePercent: max(0, 100 - observation.percentageUsed),
            unboundedExhaustionRange: range,
            boundaryInteraction: interaction
        )
    }

    private static func merge(
        _ left: [WorkloadPlanningExclusionReason: Int],
        _ right: [WorkloadPlanningExclusionReason: Int]
    ) -> [WorkloadPlanningExclusionReason: Int] {
        var result = left
        for (key, value) in right { result[key, default: 0] += value }
        return result
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private static func windowKind(_ identity: QuotaWindowIdentity) -> WorkloadQuotaWindowKind? {
        switch identity.insightWindowKind {
        case .session: .session
        case .weekly: .weekly
        case .other: nil
        }
    }
}
