import Foundation

public enum WorkloadPlanningValidationError: Error, Equatable {
    case invalidInput
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
    public let adapterVersion: String
    public let clientVersion: String

    public init(
        product: ProviderProduct,
        kind: PlannedWorkloadKind,
        quotaWindowKind: WorkloadQuotaWindowKind,
        executionMode: WorkloadExecutionMode,
        concurrency: Int,
        workUnits: Int,
        adapterVersion: String,
        clientVersion: String
    ) throws {
        guard product == .claudeCode || product == .codex,
              (1...64).contains(concurrency), (1...10_000).contains(workUnits),
              Self.validVersion(adapterVersion), Self.validVersion(clientVersion) else {
            throw WorkloadPlanningValidationError.invalidInput
        }
        self.product = product
        self.kind = kind
        self.quotaWindowKind = quotaWindowKind
        self.executionMode = executionMode
        self.concurrency = concurrency
        self.workUnits = workUnits
        self.adapterVersion = adapterVersion
        self.clientVersion = clientVersion
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || byte == 45 || byte == 46 || byte == 95
            }
    }
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
    public let id: String
    public let product: ProviderProduct
    public let kind: PlannedWorkloadKind
    public let quotaWindowKind: WorkloadQuotaWindowKind
    public let executionMode: WorkloadExecutionMode
    public let concurrency: Int
    public let completedWorkUnits: Int
    public let startedAt: Date
    public let endedAt: Date
    public let measuredQuotaUsedPercent: Double
    public let quotaUnit: WorkloadQuotaUnit
    public let outcome: MeasuredHistoricalRunOutcome
    public let adapterVersion: String
    public let clientVersion: String
    public let evidenceIDs: [String]

    public init(
        id: String,
        product: ProviderProduct,
        kind: PlannedWorkloadKind,
        quotaWindowKind: WorkloadQuotaWindowKind,
        executionMode: WorkloadExecutionMode,
        concurrency: Int,
        completedWorkUnits: Int,
        startedAt: Date,
        endedAt: Date,
        measuredQuotaUsedPercent: Double,
        quotaUnit: WorkloadQuotaUnit,
        outcome: MeasuredHistoricalRunOutcome,
        adapterVersion: String,
        clientVersion: String,
        evidenceIDs: [String]
    ) throws {
        let validID: (String) -> Bool = { value in
            !value.isEmpty && value.utf8.count <= 128
                && value.utf8.allSatisfy { byte in
                    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                        || byte == 45 || byte == 46 || byte == 95
                }
        }
        guard validID(id), product == .claudeCode || product == .codex,
              (1...64).contains(concurrency), (1...10_000).contains(completedWorkUnits),
              startedAt.timeIntervalSince1970.isFinite, endedAt.timeIntervalSince1970.isFinite,
              endedAt > startedAt, measuredQuotaUsedPercent.isFinite,
              (0...100).contains(measuredQuotaUsedPercent),
              validID(adapterVersion), validID(clientVersion),
              !evidenceIDs.isEmpty, evidenceIDs.count <= 256,
              evidenceIDs.allSatisfy(validID), Set(evidenceIDs).count == evidenceIDs.count,
              outcome != .observedZero || measuredQuotaUsedPercent == 0,
              outcome != .completed || measuredQuotaUsedPercent > 0 else {
            throw WorkloadPlanningValidationError.invalidInput
        }
        self.id = id
        self.product = product
        self.kind = kind
        self.quotaWindowKind = quotaWindowKind
        self.executionMode = executionMode
        self.concurrency = concurrency
        self.completedWorkUnits = completedWorkUnits
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.measuredQuotaUsedPercent = measuredQuotaUsedPercent == 0 ? 0 : measuredQuotaUsedPercent
        self.quotaUnit = quotaUnit
        self.outcome = outcome
        self.adapterVersion = adapterVersion
        self.clientVersion = clientVersion
        self.evidenceIDs = evidenceIDs.sorted()
    }
}

public struct CurrentWorkloadQuotaEvidence: Equatable, Sendable {
    public let observation: MeasuredQuotaObservation
    public let forecast: QuotaInsightState

    public init(observation: MeasuredQuotaObservation, forecast: QuotaInsightState) {
        self.observation = observation
        self.forecast = forecast
    }
}

public enum WorkloadComparabilityMethod: String, Codable, Equatable, Sendable {
    case strictMeasuredOperationsV1 = "strict_measured_operations_v1"
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
    case incompatibleClientVersion = "incompatible_client_version"
    case incompatibleAdapterVersion = "incompatible_adapter_version"
    case incompleteOutcome = "incomplete_outcome"
    case failedOutcome = "failed_outcome"
    case gap = "gap"
    case unavailableEvidence = "unavailable_evidence"
    case observedZeroUnsupported = "observed_zero_unsupported"
    case duplicateRun = "duplicate_run"
    case conflictingRunIdentity = "conflicting_run_identity"
}

public enum WorkloadPlanningUnavailableReason: String, Codable, Equatable, Sendable {
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
    case likelyCompletionBeforeExhaustion = "likely_completion_before_exhaustion"
    case likelyInsufficientCurrentQuota = "likely_insufficient_current_quota"
    case likelyResetBeforeCompletion = "likely_reset_before_completion"
    case likelyExhaustionBeforeCompletion = "likely_exhaustion_before_completion"
}

public enum WorkloadPlanningIndeterminateReason: String, Codable, Equatable, Sendable {
    case requirementOverlapsAvailableQuota = "requirement_overlaps_available_quota"
    case completionOverlapsExhaustion = "completion_overlaps_exhaustion"
    case completionOverlapsReset = "completion_overlaps_reset"
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
    case syntheticFixtureValidationOnly = "synthetic_fixture_validation_only"
    case providerWeightingUnknown = "provider_weighting_unknown"
    case noCompletionGuarantee = "no_completion_guarantee"
    case futureProviderBehaviorUnknown = "future_provider_behavior_unknown"
    case linearPerUnitScaling = "linear_per_unit_scaling"
}

public struct WorkloadPlanningMethodMetadata: Equatable, Sendable {
    public let comparabilityMethod: WorkloadComparabilityMethod
    public let rangeMethod: WorkloadRequirementRangeMethod
    public let minimumComparableRuns: Int
}

public struct WorkloadPlanningSample: Equatable, Sendable {
    public let includedRunIDs: [String]
    public let evidenceIDs: [String]
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
    public let supportingRunIDs: [String]
    public let reason: WorkloadPlanningReason
    public let limitation: WorkloadPlanningLimitation
}

public struct WorkloadPlanningCurrentEvidenceSummary: Equatable, Sendable {
    public let identity: QuotaWindowIdentity
    public let observationIdentity: QuotaObservationIdentity
    public let forecastInputIdentities: [QuotaObservationIdentity]
    public let forecastMethod: QuotaForecastMethod
    public let evidenceAge: TimeInterval
    public let availablePercent: Double
    public let calculatedExhaustionRange: ClosedRange<Date>?
}

public struct AvailableWorkloadPlanningAssessment: Equatable, Sendable {
    public let conclusion: WorkloadPlanningConclusion
    public let requirementPercent: QuotaInsightRange
    public let durationSeconds: QuotaInsightRange
    public let availablePercent: Double
    public let resetBoundary: Date
    public let calculatedExhaustionRange: ClosedRange<Date>?
    public let currentEvidenceAge: TimeInterval
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
    public let availablePercent: Double
    public let resetBoundary: Date
    public let calculatedExhaustionRange: ClosedRange<Date>?
    public let currentEvidenceAge: TimeInterval
    public let currentEvidence: WorkloadPlanningCurrentEvidenceSummary
    public let sample: WorkloadPlanningSample
    public let metadata: WorkloadPlanningMethodMetadata
    public let reasons: [WorkloadPlanningReason]
    public let limitations: [WorkloadPlanningLimitation]
    public let options: [WorkloadPlanningOption]
}

public struct UnavailableWorkloadPlanningAssessment: Equatable, Sendable {
    public let reason: WorkloadPlanningUnavailableReason
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
        comparabilityMethod: .strictMeasuredOperationsV1,
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

    public static func assess(
        _ plan: PlannedWorkload,
        historicalRuns: [MeasuredHistoricalRun],
        currentEvidence: CurrentWorkloadQuotaEvidence?,
        now: Date
    ) -> WorkloadPlanningState {
        let classified = classify(historicalRuns, for: plan)
        let sample = sample(included: classified.included, excluded: classified.excluded)
        func unavailable(_ reason: WorkloadPlanningUnavailableReason) -> WorkloadPlanningState {
            .unavailable(UnavailableWorkloadPlanningAssessment(
                reason: reason, sample: sample, metadata: metadata, limitations: limitations
            ))
        }

        guard !historicalRuns.isEmpty else { return unavailable(.noHistoricalRuns) }
        guard !classified.included.isEmpty else {
            let incompleteReasons: Set<WorkloadPlanningExclusionReason> = [
                .incompleteOutcome, .failedOutcome, .gap, .unavailableEvidence, .observedZeroUnsupported,
                .duplicateRun, .conflictingRunIdentity,
            ]
            let excludedReasons = Set(classified.excluded.keys)
            return unavailable(excludedReasons.isSubset(of: incompleteReasons)
                ? .incompleteHistoricalRuns
                : .incompatibleHistoricalRuns)
        }
        guard classified.included.count >= minimumComparableRuns else { return unavailable(.insufficientComparableRuns) }
        guard let currentEvidence else { return unavailable(.missingCurrentQuotaEvidence) }
        guard case let .qualified(forecast) = currentEvidence.forecast else {
            return unavailable(.unqualifiedCurrentQuotaEvidence)
        }
        let observation = currentEvidence.observation
        guard forecast.identity == observation.identity,
              forecast.forecastMethod == .pairwisePositiveSlopeInterquartileV2,
              forecast.inputObservationIdentities.contains(observation.stableIdentity),
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
        guard classified.included.allSatisfy({ $0.quotaUnit == .providerReportedPercentage }) else {
            return unavailable(.unsafeQuotaConversion)
        }

        let normalizedRequirements = classified.included
            .map { $0.measuredQuotaUsedPercent / Double($0.completedWorkUnits) }
            .sorted()
        let normalizedDurations = classified.included
            .map { $0.endedAt.timeIntervalSince($0.startedAt) / Double($0.completedWorkUnits) }
            .sorted()
        let requirement = QuotaInsightRange(
            lower: percentile(normalizedRequirements, fraction: 0.25) * Double(plan.workUnits),
            upper: percentile(normalizedRequirements, fraction: 0.75) * Double(plan.workUnits)
        )
        let duration = QuotaInsightRange(
            lower: percentile(normalizedDurations, fraction: 0.25) * Double(plan.workUnits),
            upper: percentile(normalizedDurations, fraction: 0.75) * Double(plan.workUnits)
        )
        let available = max(0, 100 - observation.percentageUsed)
        let currentSummary = WorkloadPlanningCurrentEvidenceSummary(
            identity: observation.identity,
            observationIdentity: observation.stableIdentity,
            forecastInputIdentities: forecast.inputObservationIdentities,
            forecastMethod: forecast.forecastMethod,
            evidenceAge: evidenceAge,
            availablePercent: available,
            calculatedExhaustionRange: forecast.calculatedExhaustionRange
        )
        let earliestCompletion = now.addingTimeInterval(duration.lower)
        let latestCompletion = now.addingTimeInterval(duration.upper)
        let reset = observation.identity.resetBoundary
        let exhaustion = forecast.calculatedExhaustionRange
        var reasons: [WorkloadPlanningReason] = [.comparableMeasuredSampleQualified, .currentQuotaForecastQualified]
        let conclusion: WorkloadPlanningConclusion?
        let indeterminate: WorkloadPlanningIndeterminateReason?

        if requirement.lower > available {
            reasons.append(.requirementAboveAvailableQuota)
            conclusion = .likelyInsufficientCurrentQuota
            indeterminate = nil
        } else if requirement.upper > available {
            conclusion = nil
            indeterminate = .requirementOverlapsAvailableQuota
        } else if let exhaustion, exhaustion.upperBound <= earliestCompletion {
            reasons.append(.calculatedExhaustionFirst)
            conclusion = .likelyExhaustionBeforeCompletion
            indeterminate = nil
        } else if let exhaustion, exhaustion.lowerBound < latestCompletion {
            conclusion = nil
            indeterminate = .completionOverlapsExhaustion
        } else if earliestCompletion >= reset {
            reasons.append(.providerReportedResetFirst)
            conclusion = .likelyResetBeforeCompletion
            indeterminate = nil
        } else if latestCompletion > reset {
            conclusion = nil
            indeterminate = .completionOverlapsReset
        } else {
            reasons.append(.requirementBelowAvailableQuota)
            conclusion = .likelyCompletionBeforeExhaustion
            indeterminate = nil
        }

        let options = conclusion == .likelyInsufficientCurrentQuota
            ? options(for: plan, included: classified.included, allRuns: historicalRuns, requirement: requirement, available: available)
            : []
        if let conclusion {
            return .available(AvailableWorkloadPlanningAssessment(
                conclusion: conclusion,
                requirementPercent: requirement,
                durationSeconds: duration,
                availablePercent: available,
                resetBoundary: reset,
                calculatedExhaustionRange: exhaustion,
                currentEvidenceAge: evidenceAge,
                currentEvidence: currentSummary,
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
            availablePercent: available,
            resetBoundary: reset,
            calculatedExhaustionRange: exhaustion,
            currentEvidenceAge: evidenceAge,
            currentEvidence: currentSummary,
            sample: sample,
            metadata: metadata,
            reasons: reasons,
            limitations: limitations,
            options: []
        ))
    }

    private static func classify(
        _ runs: [MeasuredHistoricalRun], for plan: PlannedWorkload
    ) -> (included: [MeasuredHistoricalRun], excluded: [WorkloadPlanningExclusionReason: Int]) {
        var included: [MeasuredHistoricalRun] = []
        var excluded: [WorkloadPlanningExclusionReason: Int] = [:]
        var runsByID: [String: MeasuredHistoricalRun] = [:]
        let conflictingIDs = Set(Dictionary(grouping: runs, by: \.id).compactMap { id, values in
            values.dropFirst().allSatisfy { $0 == values[0] } ? nil : id
        })
        for run in runs {
            let duplicateReason: WorkloadPlanningExclusionReason? = runsByID[run.id].map {
                $0 == run ? .duplicateRun : .conflictingRunIdentity
            }
            if runsByID[run.id] == nil { runsByID[run.id] = run }
            let reason: WorkloadPlanningExclusionReason? = if conflictingIDs.contains(run.id) {
                .conflictingRunIdentity
            } else if let duplicateReason {
                duplicateReason
            } else if run.product != plan.product {
                .incompatibleProviderProduct
            } else if run.kind != plan.kind {
                .incompatibleWorkloadKind
            } else if run.quotaWindowKind != plan.quotaWindowKind {
                .incompatibleWindowSemantics
            } else if run.executionMode != plan.executionMode {
                .incompatibleExecutionMode
            } else if run.concurrency != plan.concurrency {
                .incompatibleConcurrency
            } else if run.quotaUnit != .providerReportedPercentage {
                .incompatibleQuotaUnit
            } else if run.clientVersion != plan.clientVersion {
                .incompatibleClientVersion
            } else if run.adapterVersion != plan.adapterVersion {
                .incompatibleAdapterVersion
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
            if let reason {
                excluded[reason, default: 0] += 1
            } else {
                included.append(run)
            }
        }
        return (included.sorted { $0.id < $1.id }, excluded)
    }

    private static func sample(
        included: [MeasuredHistoricalRun], excluded: [WorkloadPlanningExclusionReason: Int]
    ) -> WorkloadPlanningSample {
        WorkloadPlanningSample(
            includedRunIDs: included.map(\.id),
            evidenceIDs: Array(Set(included.flatMap(\.evidenceIDs))).sorted(),
            earliestStart: included.map(\.startedAt).min(),
            latestEnd: included.map(\.endedAt).max(),
            excluded: excluded
        )
    }

    private static func options(
        for plan: PlannedWorkload,
        included: [MeasuredHistoricalRun],
        allRuns: [MeasuredHistoricalRun],
        requirement: QuotaInsightRange,
        available: Double
    ) -> [WorkloadPlanningOption] {
        var result: [WorkloadPlanningOption] = []
        let lowerConcurrency = allRuns.filter {
            $0.product == plan.product && $0.kind == plan.kind && $0.quotaWindowKind == plan.quotaWindowKind
                && $0.executionMode == plan.executionMode && $0.concurrency < plan.concurrency
                && $0.quotaUnit == .providerReportedPercentage && $0.outcome == .completed
                && $0.clientVersion == plan.clientVersion && $0.adapterVersion == plan.adapterVersion
        }
        let grouped = Dictionary(grouping: lowerConcurrency, by: \.concurrency)
        let demonstrated = grouped.keys.sorted().first { concurrency in
            guard let runs = grouped[concurrency], runs.count >= minimumComparableRuns else { return false }
            let normalized = runs.map { $0.measuredQuotaUsedPercent / Double($0.completedWorkUnits) }.sorted()
            return percentile(normalized, fraction: 0.75) * Double(plan.workUnits) < requirement.lower
        }
        if let demonstrated, let runs = grouped[demonstrated] {
            result.append(WorkloadPlanningOption(
                kind: .reduceConcurrency,
                proposedValue: demonstrated,
                supportingRunIDs: runs.map(\.id).sorted(),
                reason: .requirementAboveAvailableQuota,
                limitation: .providerWeightingUnknown
            ))
        }
        let upperPerUnit = requirement.upper / Double(plan.workUnits)
        let reducedUnits = upperPerUnit > 0 ? Int((available / upperPerUnit).rounded(.down)) : 0
        if reducedUnits > 0, reducedUnits < plan.workUnits {
            result.append(WorkloadPlanningOption(
                kind: .reduceWorkUnits,
                proposedValue: reducedUnits,
                supportingRunIDs: included.map(\.id),
                reason: .requirementAboveAvailableQuota,
                limitation: .linearPerUnitScaling
            ))
        }
        result.append(WorkloadPlanningOption(
            kind: .deferUntilReset,
            proposedValue: nil,
            supportingRunIDs: [],
            reason: .providerReportedResetFirst,
            limitation: .futureProviderBehaviorUnknown
        ))
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
