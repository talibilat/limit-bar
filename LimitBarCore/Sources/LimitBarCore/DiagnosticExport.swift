import Foundation

public struct DiagnosticVersion: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) throws {
        guard major >= 0, minor >= 0, patch >= 0 else {
            throw DiagnosticExportError.invalidVersion
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public enum DiagnosticProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case anthropic
    case azureOpenAI
    case openAI
    case custom
}

public enum DiagnosticProviderState: String, Codable, CaseIterable, Equatable, Sendable {
    case notConfigured
    case configured
    case connected
    case authenticationRequired
    case networkUnavailable
    case failed
    case cancelled
}

public struct DiagnosticProviderStatus: Codable, Equatable, Sendable {
    public let provider: DiagnosticProvider
    public let state: DiagnosticProviderState

    public init(provider: DiagnosticProvider, state: DiagnosticProviderState) {
        self.provider = provider
        self.state = state
    }
}

public enum DiagnosticDatabaseState: String, Codable, CaseIterable, Equatable, Sendable {
    case available
    case unavailable
}

public struct DiagnosticImportCounts: Codable, Equatable, Sendable {
    public let accepted: Int
    public let rejected: Int

    public init(accepted: Int, rejected: Int) throws {
        guard accepted >= 0, rejected >= 0 else {
            throw DiagnosticExportError.invalidImportCount
        }
        self.accepted = accepted
        self.rejected = rejected
    }
}

public enum DiagnosticResourceLimitReason: String, Codable, CaseIterable, Equatable, Sendable {
    case rateLimited
    case responseTooLarge
    case importLimitReached
}

public enum DiagnosticRefreshHistoryRole: String, Codable, CaseIterable, Equatable, Sendable {
    case latest
    case lastFullSuccess
}

public enum DiagnosticRefreshProduct: String, Codable, CaseIterable, Equatable, Sendable {
    case anthropicAPI = "anthropic_api"
    case openAIAPI = "openai_api"
}

public enum DiagnosticRefreshOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case success
    case partialFailure = "partial_failure"
    case cancelled
    case authenticationFailure = "authentication_failure"
    case networkFailure = "network_failure"
    case failed
}

public enum DiagnosticRefreshDuration: String, Codable, CaseIterable, Equatable, Sendable {
    case underOneSecond = "under_1_second"
    case oneToFiveSeconds = "1_to_5_seconds"
    case fiveToThirtySeconds = "5_to_30_seconds"
    case overThirtySeconds = "over_30_seconds"
}

public enum DiagnosticRefreshWindowKind: String, Codable, CaseIterable, Equatable, Sendable {
    case today
    case currentWeek
}

public struct DiagnosticRefreshHistoryRecord: Codable, Equatable, Sendable {
    public let role: DiagnosticRefreshHistoryRole
    public let product: DiagnosticRefreshProduct
    public let outcome: DiagnosticRefreshOutcome
    public let startedAt: Date
    public let duration: DiagnosticRefreshDuration
    public let affectedWindowKinds: [DiagnosticRefreshWindowKind]

    public init(
        role: DiagnosticRefreshHistoryRole,
        product: DiagnosticRefreshProduct,
        outcome: DiagnosticRefreshOutcome,
        startedAt: Date,
        duration: DiagnosticRefreshDuration,
        affectedWindowKinds: [DiagnosticRefreshWindowKind]
    ) throws {
        guard startedAt.timeIntervalSince1970.isFinite else {
            throw DiagnosticExportError.invalidTimestamp
        }
        guard Set(affectedWindowKinds.map(\.rawValue)).count == affectedWindowKinds.count else {
            throw DiagnosticExportError.invalidRefreshHistory
        }
        self.role = role
        self.product = product
        self.outcome = outcome
        self.startedAt = startedAt
        self.duration = duration
        self.affectedWindowKinds = affectedWindowKinds.sorted { $0.rawValue < $1.rawValue }
    }
}

public enum DiagnosticQuotaProduct: String, Codable, CaseIterable, Equatable, Sendable {
    case claudeCode = "claude_code"
    case codex
}

public enum DiagnosticQuotaWindowKind: String, Codable, CaseIterable, Equatable, Sendable {
    case session
    case weekly
    case other
}

public enum DiagnosticQuotaFindingStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case qualified
    case insufficientObservations = "insufficient_observations"
    case insufficientSpan = "insufficient_span"
    case staleEvidence = "stale_evidence"
    case resetOrExpired = "reset_or_expired"
    case counterDecreased = "counter_decreased"
    case noPositiveBurn = "no_positive_burn"
    case conflictingObservations = "conflicting_observations"
    case incompatibleEvidence = "incompatible_evidence"
    case invalidEvaluation = "invalid_evaluation"
}

public enum DiagnosticQuotaForecastMethod: String, Codable, CaseIterable, Equatable, Sendable {
    case pairwisePositiveSlopeInterquartileV1 = "pairwise_positive_slope_interquartile_v1"
    case pairwisePositiveSlopeInterquartileV2 = "pairwise_positive_slope_interquartile_v2"
}

public enum DiagnosticQuotaQualification: String, Codable, CaseIterable, Equatable, Sendable {
    case qualified
    case unavailable
}

public struct DiagnosticNumberRange: Codable, Equatable, Sendable {
    public let lower: Double
    public let upper: Double

    public init(lower: Double, upper: Double) throws {
        guard lower.isFinite, upper.isFinite, lower >= 0, upper >= lower, upper <= 10_000 else {
            throw DiagnosticExportError.invalidQuotaFindings
        }
        self.lower = lower
        self.upper = upper
    }
}

public struct DiagnosticQuotaFinding: Codable, Equatable, Sendable {
    public let product: DiagnosticQuotaProduct
    public let windowKind: DiagnosticQuotaWindowKind
    public let status: DiagnosticQuotaFindingStatus
    public let qualification: DiagnosticQuotaQualification
    public let measuredObservationCount: Int
    public let measuredSpanMinutes: Int
    public let forecastMethod: DiagnosticQuotaForecastMethod
    public let calculatedBurnPercentPerHour: DiagnosticNumberRange?
    public let calculatedExhaustionMinutes: DiagnosticNumberRange?

    public init(
        product: DiagnosticQuotaProduct,
        windowKind: DiagnosticQuotaWindowKind,
        status: DiagnosticQuotaFindingStatus,
        qualification: DiagnosticQuotaQualification,
        measuredObservationCount: Int,
        measuredSpanMinutes: Int,
        forecastMethod: DiagnosticQuotaForecastMethod,
        calculatedBurnPercentPerHour: DiagnosticNumberRange? = nil,
        calculatedExhaustionMinutes: DiagnosticNumberRange? = nil
    ) throws {
        guard (0...SQLiteQuotaObservationStore.maximumObservationsPerWindow).contains(measuredObservationCount),
              (0...43_200).contains(measuredSpanMinutes),
              (status == .qualified) == (qualification == .qualified),
              status == .qualified || (calculatedBurnPercentPerHour == nil && calculatedExhaustionMinutes == nil),
              status != .qualified || calculatedBurnPercentPerHour != nil else {
            throw DiagnosticExportError.invalidQuotaFindings
        }
        self.product = product
        self.windowKind = windowKind
        self.status = status
        self.qualification = qualification
        self.measuredObservationCount = measuredObservationCount
        self.measuredSpanMinutes = measuredSpanMinutes
        self.forecastMethod = forecastMethod
        self.calculatedBurnPercentPerHour = calculatedBurnPercentPerHour
        self.calculatedExhaustionMinutes = calculatedExhaustionMinutes
    }
}

public enum DiagnosticCodexExplanationStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case available
    case partial
    case observedZero = "observed_zero"
    case unavailable
}

public enum DiagnosticCodexExplanationCoverage: String, Codable, CaseIterable, Equatable, Sendable {
    case complete
    case partial
    case unavailable
}

public enum DiagnosticCodexExplanationTokenEvidence: String, Codable, CaseIterable, Equatable, Sendable {
    case positive
    case observedZero = "observed_zero"
    case none
}

public enum DiagnosticCodexExplanationRetention: String, Codable, CaseIterable, Equatable, Sendable {
    case fresh
    case retained
}

public struct DiagnosticCodexExplanationFinding: Codable, Equatable, Sendable {
    public let status: DiagnosticCodexExplanationStatus
    public let adapterVersion: String
    public let coverage: DiagnosticCodexExplanationCoverage
    public let tokenEvidence: DiagnosticCodexExplanationTokenEvidence
    public let sessionCount: Int
    public let evidenceCount: Int
    public let observationCount: Int
    public let barrierCategories: [CodexEvidenceBarrier]
    public let unavailableReason: CodexQuotaExplanationUnavailableReason?
    public let retention: DiagnosticCodexExplanationRetention

    public init(
        status: DiagnosticCodexExplanationStatus,
        adapterVersion: String,
        coverage: DiagnosticCodexExplanationCoverage,
        tokenEvidence: DiagnosticCodexExplanationTokenEvidence,
        sessionCount: Int,
        evidenceCount: Int,
        observationCount: Int,
        barrierCategories: [CodexEvidenceBarrier],
        unavailableReason: CodexQuotaExplanationUnavailableReason? = nil,
        retention: DiagnosticCodexExplanationRetention = .fresh
    ) throws {
        guard adapterVersion == CodexRolloutEvidenceAdapter.adapterVersion,
              (0...1_000).contains(sessionCount),
              (0...10_000).contains(evidenceCount),
              (0...1_000).contains(observationCount),
              Set(barrierCategories).count == barrierCategories.count,
              (status == .unavailable) == (unavailableReason != nil) else {
            throw DiagnosticExportError.invalidCodexExplanationFinding
        }
        self.status = status
        self.adapterVersion = adapterVersion
        self.coverage = coverage
        self.tokenEvidence = tokenEvidence
        self.sessionCount = sessionCount
        self.evidenceCount = evidenceCount
        self.observationCount = observationCount
        self.barrierCategories = barrierCategories.sorted { $0.rawValue < $1.rawValue }
        self.unavailableReason = unavailableReason
        self.retention = retention
    }
}

public enum DiagnosticEvidenceProvenance: String, Codable, Equatable, Sendable {
    case reported
    case measured
    case calculated
    case inferred
}

public enum DiagnosticEvidenceRangeBasis: String, Codable, Equatable, Sendable {
    case gregorianUTC = "gregorian_utc_half_open"
}

public enum DiagnosticEvidenceAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public enum DiagnosticEvidenceState: String, Codable, Equatable, Sendable {
    case available
    case observedZero = "observed_zero"
    case gap
    case noFinding = "no_finding"
    case unavailable
}

public enum DiagnosticEvidenceQualification: String, Codable, Equatable, Sendable {
    case qualified
    case unavailable
}

public enum DiagnosticEvidenceUnit: String, Codable, Equatable, Sendable {
    case percentagePoints = "percentage_points"
    case percentPerHour = "percent_per_hour"
}

public enum DiagnosticEvidenceResetInteraction: String, Codable, Equatable, Sendable {
    case beforeReportedReset = "before_reported_reset"
    case notProjectedBeforeReset = "not_projected_before_reset"
    case unavailable
}

public enum DiagnosticEvidenceLimitation: String, Codable, Equatable, Sendable {
    case providerWeightingUnknown = "provider_weighting_unknown"
    case noCausalAttribution = "no_causal_attribution"
    case fixtureValidationOnly = "fixture_validation_only"
    case probabilityNotEstablished = "probability_not_established"
    case futureWorkloadUnknown = "future_workload_unknown"
    case partialCoverage = "partial_coverage"
}

public enum DiagnosticEvidenceVersionKind: String, Codable, Equatable, Sendable {
    case method
    case adapter
    case client
    case providerFormat = "provider_format"
    case interpretation
}

public struct DiagnosticEvidenceVersion: Codable, Equatable, Sendable {
    public let kind: DiagnosticEvidenceVersionKind
    public let value: String

    public init(kind: DiagnosticEvidenceVersionKind, value: String) throws {
        guard DiagnosticExport.isBoundedEvidenceText(value) else { throw DiagnosticExportError.invalidQuotaEvidence }
        self.kind = kind
        self.value = value
    }
}

public struct DiagnosticEvidencePeriod: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) throws {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start < end else {
            throw DiagnosticExportError.invalidQuotaEvidence
        }
        self.start = start
        self.end = end
    }
}

public struct DiagnosticEvidenceMovement: Codable, Equatable, Sendable {
    public let value: Double
    public let unit: DiagnosticEvidenceUnit
    public let provenance: DiagnosticEvidenceProvenance

    public init(value: Double, unit: DiagnosticEvidenceUnit, provenance: DiagnosticEvidenceProvenance) throws {
        guard value.isFinite, (-10_000...10_000).contains(value), provenance != .inferred else {
            throw DiagnosticExportError.invalidQuotaEvidence
        }
        self.value = value == 0 ? 0 : value
        self.unit = unit
        self.provenance = provenance
    }
}

public struct DiagnosticEvidenceAllocation: Codable, Equatable, Sendable {
    public let percent: Double
    public let methodVersion: String
    public let qualification: DiagnosticEvidenceQualification
    public let provenance: DiagnosticEvidenceProvenance
    public let limitations: [DiagnosticEvidenceLimitation]

    public init(percent: Double, methodVersion: String, qualification: DiagnosticEvidenceQualification, limitations: [DiagnosticEvidenceLimitation]) throws {
        guard percent.isFinite, (0...100).contains(percent), qualification == .qualified,
              !limitations.isEmpty, limitations.count <= DiagnosticExport.maximumEvidenceLimitations,
              DiagnosticExport.isBoundedEvidenceText(methodVersion) else {
            throw DiagnosticExportError.invalidQuotaEvidence
        }
        self.percent = percent
        self.methodVersion = methodVersion
        self.qualification = qualification
        provenance = .inferred
        self.limitations = Array(Set(limitations)).sorted { $0.rawValue < $1.rawValue }
    }
}

public struct DiagnosticEvidenceForecast: Codable, Equatable, Sendable {
    public let status: DiagnosticEvidenceState
    public let methodVersion: String
    public let qualification: DiagnosticEvidenceQualification
    public let observationCount: Int
    public let observationSpanSeconds: Int
    public let evidenceAgeSeconds: Int?
    public let range: DiagnosticNumberRange?
    public let resetInteraction: DiagnosticEvidenceResetInteraction
    public let provenance: DiagnosticEvidenceProvenance
    public let limitations: [DiagnosticEvidenceLimitation]

    public init(status: DiagnosticEvidenceState, methodVersion: String, qualification: DiagnosticEvidenceQualification, observationCount: Int, observationSpanSeconds: Int, evidenceAgeSeconds: Int?, range: DiagnosticNumberRange?, resetInteraction: DiagnosticEvidenceResetInteraction, limitations: [DiagnosticEvidenceLimitation]) throws {
        guard [.available, .unavailable].contains(status),
              (status == .available) == (qualification == .qualified),
              status == .available || range == nil,
              (0...SQLiteQuotaObservationStore.maximumObservationsPerWindow).contains(observationCount),
              (0...2_592_000).contains(observationSpanSeconds),
              evidenceAgeSeconds.map({ (0...2_592_000).contains($0) }) ?? true,
              !limitations.isEmpty, limitations.count <= DiagnosticExport.maximumEvidenceLimitations,
              DiagnosticExport.isBoundedEvidenceText(methodVersion) else {
            throw DiagnosticExportError.invalidQuotaEvidence
        }
        self.status = status
        self.methodVersion = methodVersion
        self.qualification = qualification
        self.observationCount = observationCount
        self.observationSpanSeconds = observationSpanSeconds
        self.evidenceAgeSeconds = evidenceAgeSeconds
        self.range = range
        self.resetInteraction = resetInteraction
        provenance = .calculated
        self.limitations = Array(Set(limitations)).sorted { $0.rawValue < $1.rawValue }
    }
}

public struct DiagnosticEvidenceAnomaly: Codable, Equatable, Sendable {
    public let status: DiagnosticEvidenceState
    public let methodVersion: String
    public let qualification: DiagnosticEvidenceQualification
    public let currentPeriod: DiagnosticEvidencePeriod?
    public let baselinePeriod: DiagnosticEvidencePeriod?
    public let measuredInputCount: Int
    public let currentValue: Double?
    public let baselineValue: Double?
    public let result: Double?
    public let provenance: DiagnosticEvidenceProvenance
    public let limitations: [DiagnosticEvidenceLimitation]

    public init(status: DiagnosticEvidenceState, methodVersion: String, qualification: DiagnosticEvidenceQualification, currentPeriod: DiagnosticEvidencePeriod?, baselinePeriod: DiagnosticEvidencePeriod?, measuredInputCount: Int, currentValue: Double?, baselineValue: Double?, result: Double?, limitations: [DiagnosticEvidenceLimitation]) throws {
        let values = [currentValue, baselineValue, result].compactMap { $0 }
        guard [.available, .observedZero, .noFinding, .unavailable].contains(status),
              (status == .unavailable) == (qualification == .unavailable),
              status != .unavailable || values.isEmpty,
              values.allSatisfy({ $0.isFinite && (-10_000...10_000).contains($0) }),
              (0...10_000).contains(measuredInputCount),
              !limitations.isEmpty, limitations.count <= DiagnosticExport.maximumEvidenceLimitations,
              DiagnosticExport.isBoundedEvidenceText(methodVersion) else {
            throw DiagnosticExportError.invalidQuotaEvidence
        }
        self.status = status
        self.methodVersion = methodVersion
        self.qualification = qualification
        self.currentPeriod = currentPeriod
        self.baselinePeriod = baselinePeriod
        self.measuredInputCount = measuredInputCount
        self.currentValue = currentValue
        self.baselineValue = baselineValue
        self.result = result
        provenance = .calculated
        self.limitations = Array(Set(limitations)).sorted { $0.rawValue < $1.rawValue }
    }
}

public struct DiagnosticQuotaEvidenceRecord: Codable, Equatable, Sendable {
    public let traceReference: String
    public let intervalStart: Date
    public let intervalEnd: Date
    public let resetBoundary: Date?
    public let resetBoundaryAvailability: DiagnosticEvidenceAvailability
    public let movement: DiagnosticEvidenceMovement?
    public let localBreakdown: DiagnosticEvidenceState
    public let localBreakdownProvenance: DiagnosticEvidenceProvenance
    public let localTokenCount: Int64?
    public let localSessionCount: Int?
    public let unattributedMovement: Bool
    public let unattributedMovementValue: DiagnosticEvidenceMovement?
    public let inferredAllocation: DiagnosticEvidenceAllocation?
    public let forecast: DiagnosticEvidenceForecast
    public let anomaly: DiagnosticEvidenceAnomaly
    public let versions: [DiagnosticEvidenceVersion]
    public let limitations: [DiagnosticEvidenceLimitation]

    public init(traceReference: String, intervalStart: Date, intervalEnd: Date, resetBoundary: Date?, movement: DiagnosticEvidenceMovement?, localBreakdown: DiagnosticEvidenceState, localTokenCount: Int64? = nil, localSessionCount: Int? = nil, unattributedMovement: Bool, unattributedMovementValue: DiagnosticEvidenceMovement? = nil, inferredAllocation: DiagnosticEvidenceAllocation?, forecast: DiagnosticEvidenceForecast, anomaly: DiagnosticEvidenceAnomaly, versions: [DiagnosticEvidenceVersion], limitations: [DiagnosticEvidenceLimitation]) throws {
        guard DiagnosticExport.isTraceReference(traceReference), intervalStart.timeIntervalSince1970.isFinite,
              intervalEnd.timeIntervalSince1970.isFinite, intervalStart < intervalEnd,
              resetBoundary.map({ $0.timeIntervalSince1970.isFinite && $0 >= intervalEnd }) ?? true,
              [.available, .observedZero, .gap, .unavailable].contains(localBreakdown),
              localTokenCount.map({ (0...1_000_000_000_000_000).contains($0) }) ?? true,
              localSessionCount.map({ (0...1_000).contains($0) }) ?? true,
              localBreakdown == .available || localTokenCount == nil,
              localBreakdown == .available || localSessionCount == nil,
              unattributedMovement || unattributedMovementValue == nil,
              unattributedMovementValue?.provenance == .calculated || unattributedMovementValue == nil,
              !versions.isEmpty, versions.count <= DiagnosticExport.maximumEvidenceVersions,
              Set(versions.map { "\($0.kind.rawValue):\($0.value)" }).count == versions.count,
              !limitations.isEmpty, limitations.count <= DiagnosticExport.maximumEvidenceLimitations else {
            throw DiagnosticExportError.invalidQuotaEvidence
        }
        self.traceReference = traceReference
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.resetBoundary = resetBoundary
        resetBoundaryAvailability = resetBoundary == nil ? .unavailable : .available
        self.movement = movement
        self.localBreakdown = localBreakdown
        localBreakdownProvenance = .measured
        self.localTokenCount = localTokenCount
        self.localSessionCount = localSessionCount
        self.unattributedMovement = unattributedMovement
        self.unattributedMovementValue = unattributedMovementValue
        self.inferredAllocation = inferredAllocation
        self.forecast = forecast
        self.anomaly = anomaly
        self.versions = versions.sorted { ($0.kind.rawValue, $0.value) < ($1.kind.rawValue, $1.value) }
        self.limitations = Array(Set(limitations)).sorted { $0.rawValue < $1.rawValue }
    }
}

public struct DiagnosticEvidenceSelection: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let basis: DiagnosticEvidenceRangeBasis

    public init(start: Date, end: Date, basis: DiagnosticEvidenceRangeBasis) throws {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start < end else {
            throw DiagnosticExportError.invalidQuotaEvidence
        }
        self.start = start
        self.end = end
        self.basis = basis
    }
}

public struct DiagnosticQuotaEvidenceReport: Codable, Equatable, Sendable {
    public let selectedProduct: DiagnosticQuotaProduct
    public let selectedRange: DiagnosticEvidenceSelection
    public let publicationGeneration: UInt64?
    public let publicationTime: Date
    public let apiProviderEvidence: DiagnosticEvidenceAvailability
    public let records: [DiagnosticQuotaEvidenceRecord]
    public let recordLimit: Int
    public let omittedRecordCount: Int

    public init(selectedProduct: DiagnosticQuotaProduct, selectedRange: DiagnosticEvidenceSelection, publicationGeneration: UInt64?, publicationTime: Date, apiProviderEvidence: DiagnosticEvidenceAvailability, records: [DiagnosticQuotaEvidenceRecord]) throws {
        guard publicationTime.timeIntervalSince1970.isFinite, records.count <= DiagnosticExport.maximumQuotaEvidenceInputRecords else {
            throw DiagnosticExportError.invalidQuotaEvidence
        }
        let matching = records.filter { $0.intervalEnd > selectedRange.start && $0.intervalStart < selectedRange.end }
        let ordered = matching.sorted { ($0.intervalStart, $0.intervalEnd, $0.traceReference) > ($1.intervalStart, $1.intervalEnd, $1.traceReference) }
        self.selectedProduct = selectedProduct
        self.selectedRange = selectedRange
        self.publicationGeneration = publicationGeneration
        self.publicationTime = publicationTime
        self.apiProviderEvidence = apiProviderEvidence
        self.records = Array(ordered.prefix(DiagnosticExport.maximumQuotaEvidenceRecords))
        recordLimit = DiagnosticExport.maximumQuotaEvidenceRecords
        omittedRecordCount = max(0, ordered.count - DiagnosticExport.maximumQuotaEvidenceRecords)
    }
}

public struct DiagnosticExportInput: Equatable, Sendable {
    public let generatedAt: Date
    public let appVersion: DiagnosticVersion
    public let appBuild: Int
    public let operatingSystemVersion: DiagnosticVersion
    public let providerStatuses: [DiagnosticProviderStatus]
    public let databaseState: DiagnosticDatabaseState
    public let importCounts: DiagnosticImportCounts
    public let resourceLimitReasons: Set<DiagnosticResourceLimitReason>
    public let refreshHistory: [DiagnosticRefreshHistoryRecord]?
    public let quotaFindings: [DiagnosticQuotaFinding]?
    public let codexExplanation: DiagnosticCodexExplanationFinding?
    public let quotaEvidence: DiagnosticQuotaEvidenceReport?

    public init(
        generatedAt: Date,
        appVersion: DiagnosticVersion,
        appBuild: Int,
        operatingSystemVersion: DiagnosticVersion,
        providerStatuses: [DiagnosticProviderStatus],
        databaseState: DiagnosticDatabaseState,
        importCounts: DiagnosticImportCounts,
        resourceLimitReasons: Set<DiagnosticResourceLimitReason>,
        refreshHistory: [DiagnosticRefreshHistoryRecord]? = nil,
        quotaFindings: [DiagnosticQuotaFinding]? = nil,
        codexExplanation: DiagnosticCodexExplanationFinding? = nil,
        quotaEvidence: DiagnosticQuotaEvidenceReport? = nil
    ) throws {
        guard generatedAt.timeIntervalSince1970.isFinite else {
            throw DiagnosticExportError.invalidTimestamp
        }
        guard appBuild >= 0 else {
            throw DiagnosticExportError.invalidVersion
        }
        guard Set(providerStatuses.map(\.provider)).count == providerStatuses.count else {
            throw DiagnosticExportError.duplicateProvider
        }
        guard refreshHistory.map({ $0.count <= DiagnosticExport.maximumRefreshHistoryRecords }) ?? true else {
            throw DiagnosticExportError.invalidRefreshHistory
        }
        guard quotaFindings.map({ $0.count <= DiagnosticExport.maximumQuotaFindings }) ?? true else {
            throw DiagnosticExportError.invalidQuotaFindings
        }

        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.operatingSystemVersion = operatingSystemVersion
        self.providerStatuses = providerStatuses
        self.databaseState = databaseState
        self.importCounts = importCounts
        self.resourceLimitReasons = resourceLimitReasons
        self.refreshHistory = refreshHistory
        self.quotaFindings = quotaFindings
        self.codexExplanation = codexExplanation
        self.quotaEvidence = quotaEvidence
    }
}

public enum DiagnosticExportError: Error, Equatable {
    case invalidVersion
    case invalidImportCount
    case invalidTimestamp
    case duplicateProvider
    case invalidRefreshHistory
    case invalidQuotaFindings
    case unsupportedSchemaVersion(Int)
    case malformedArtifact
    case previewEncodingFailed
    case invalidCodexExplanationFinding
    case invalidQuotaEvidence
}

public struct DiagnosticExportArtifact: Equatable, Sendable {
    public let bytes: Data

    public var previewBytes: Data { bytes }

    public var preview: String {
        get throws {
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw DiagnosticExportError.previewEncodingFailed
            }
            return value
        }
    }

    public func save(to destination: URL) throws {
        try bytes.write(to: destination, options: .atomic)
    }
}

public struct DiagnosticExportReport: Codable, Equatable, Sendable {
    public struct Application: Codable, Equatable, Sendable {
        public let version: DiagnosticVersion
        public let build: Int
    }

    public struct OperatingSystem: Codable, Equatable, Sendable {
        public let version: DiagnosticVersion
    }

    public struct Database: Codable, Equatable, Sendable {
        public let state: DiagnosticDatabaseState
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let application: Application
    public let operatingSystem: OperatingSystem
    public let providers: [DiagnosticProviderStatus]
    public let database: Database
    public let imports: DiagnosticImportCounts
    public let resourceLimitReasons: [DiagnosticResourceLimitReason]
    public let refreshHistory: [DiagnosticRefreshHistoryRecord]?
    public let quotaFindings: [DiagnosticQuotaFinding]?
    public let codexExplanation: DiagnosticCodexExplanationFinding?
    public let quotaEvidence: DiagnosticQuotaEvidenceReport?
}

public typealias DiagnosticExportReportV1 = DiagnosticExportReport

private struct LegacyDiagnosticExportReportV1: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let application: DiagnosticExportReport.Application
    let operatingSystem: DiagnosticExportReport.OperatingSystem
    let providers: [DiagnosticProviderStatus]
    let database: DiagnosticExportReport.Database
    let imports: DiagnosticImportCounts
    let resourceLimitReasons: [DiagnosticResourceLimitReason]
    let refreshHistory: [DiagnosticRefreshHistoryRecord]?
}

private struct LegacyDiagnosticQuotaFindingV3: Codable {
    let product: DiagnosticQuotaProduct
    let windowKind: DiagnosticQuotaWindowKind
    let status: DiagnosticQuotaFindingStatus
    let measuredObservationCount: Int
    let measuredSpanMinutes: Int
    let forecastMethod: DiagnosticQuotaForecastMethod?
    let calculatedBurnPercentPerHour: DiagnosticNumberRange?
    let calculatedExhaustionMinutes: DiagnosticNumberRange?
}

private struct LegacyDiagnosticExportReportV3: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let application: DiagnosticExportReport.Application
    let operatingSystem: DiagnosticExportReport.OperatingSystem
    let providers: [DiagnosticProviderStatus]
    let database: DiagnosticExportReport.Database
    let imports: DiagnosticImportCounts
    let resourceLimitReasons: [DiagnosticResourceLimitReason]
    let refreshHistory: [DiagnosticRefreshHistoryRecord]?
    let quotaFindings: [LegacyDiagnosticQuotaFindingV3]?
}

public enum DiagnosticExport {
    public static let currentSchemaVersion = 6
    public static let maximumRefreshHistoryRecords = 20
    public static let maximumQuotaFindings = 8
    public static let maximumQuotaEvidenceRecords = 8
    public static let maximumQuotaEvidenceInputRecords = 100
    public static let maximumEvidenceTextLength = 128
    public static let maximumEvidenceVersions = 8
    public static let maximumEvidenceLimitations = 8

    public static func make(from input: DiagnosticExportInput) throws -> DiagnosticExportArtifact {
        let report = DiagnosticExportReport(
            schemaVersion: currentSchemaVersion,
            generatedAt: roundedDownToMinute(input.generatedAt),
            application: .init(version: input.appVersion, build: input.appBuild),
            operatingSystem: .init(version: input.operatingSystemVersion),
            providers: input.providerStatuses.sorted { $0.provider.rawValue < $1.provider.rawValue },
            database: .init(state: input.databaseState),
            imports: input.importCounts,
            resourceLimitReasons: input.resourceLimitReasons.sorted { $0.rawValue < $1.rawValue },
            refreshHistory: try input.refreshHistory?.map {
                try DiagnosticRefreshHistoryRecord(
                    role: $0.role,
                    product: $0.product,
                    outcome: $0.outcome,
                    startedAt: roundedDownToMinute($0.startedAt),
                    duration: $0.duration,
                    affectedWindowKinds: $0.affectedWindowKinds
                )
            },
            quotaFindings: input.quotaFindings?.sorted {
                ($0.product.rawValue, $0.windowKind.rawValue) < ($1.product.rawValue, $1.windowKind.rawValue)
            },
            codexExplanation: input.codexExplanation,
            quotaEvidence: input.quotaEvidence
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(report)
        bytes.append(0x0A)
        return DiagnosticExportArtifact(bytes: bytes)
    }

    public static func decode(_ bytes: Data) throws -> DiagnosticExportReport {
        struct VersionEnvelope: Decodable { let schemaVersion: Int }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(VersionEnvelope.self, from: bytes) else {
            throw DiagnosticExportError.malformedArtifact
        }
        guard (1...currentSchemaVersion).contains(envelope.schemaVersion) else {
            throw DiagnosticExportError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        decoder.dateDecodingStrategy = .iso8601
        do {
            let report: DiagnosticExportReport
            if envelope.schemaVersion == 1 {
                let legacy = try decoder.decode(LegacyDiagnosticExportReportV1.self, from: bytes)
                report = DiagnosticExportReport(
                    schemaVersion: legacy.schemaVersion,
                    generatedAt: legacy.generatedAt,
                    application: legacy.application,
                    operatingSystem: legacy.operatingSystem,
                    providers: legacy.providers,
                    database: legacy.database,
                    imports: legacy.imports,
                    resourceLimitReasons: legacy.resourceLimitReasons,
                    refreshHistory: legacy.refreshHistory,
                    quotaFindings: nil,
                    codexExplanation: nil,
                    quotaEvidence: nil
                )
            } else if envelope.schemaVersion == 2 || envelope.schemaVersion == 3 || envelope.schemaVersion == 4 {
                let legacy = try decoder.decode(LegacyDiagnosticExportReportV3.self, from: bytes)
                let quotaFindings = try legacy.quotaFindings?.map {
                    try DiagnosticQuotaFinding(
                        product: $0.product,
                        windowKind: $0.windowKind,
                        status: $0.status,
                        qualification: $0.status == .qualified ? .qualified : .unavailable,
                        measuredObservationCount: $0.measuredObservationCount,
                        measuredSpanMinutes: $0.measuredSpanMinutes,
                        forecastMethod: $0.forecastMethod ?? .pairwisePositiveSlopeInterquartileV1,
                        calculatedBurnPercentPerHour: $0.calculatedBurnPercentPerHour.map {
                            try DiagnosticNumberRange(lower: $0.lower, upper: $0.upper)
                        },
                        calculatedExhaustionMinutes: $0.calculatedExhaustionMinutes.map {
                            try DiagnosticNumberRange(lower: $0.lower, upper: $0.upper)
                        }
                    )
                }
                report = DiagnosticExportReport(
                    schemaVersion: legacy.schemaVersion,
                    generatedAt: legacy.generatedAt,
                    application: legacy.application,
                    operatingSystem: legacy.operatingSystem,
                    providers: legacy.providers,
                    database: legacy.database,
                    imports: legacy.imports,
                    resourceLimitReasons: legacy.resourceLimitReasons,
                    refreshHistory: legacy.refreshHistory,
                    quotaFindings: quotaFindings,
                    codexExplanation: nil,
                    quotaEvidence: nil
                )
            } else {
                report = try decoder.decode(DiagnosticExportReport.self, from: bytes)
            }
            let history = try report.refreshHistory?.map {
                try DiagnosticRefreshHistoryRecord(
                    role: $0.role,
                    product: $0.product,
                    outcome: $0.outcome,
                    startedAt: $0.startedAt,
                    duration: $0.duration,
                    affectedWindowKinds: $0.affectedWindowKinds
                )
            }
            try report.quotaEvidence.map(validateEvidence)
            _ = try DiagnosticExportInput(
                generatedAt: report.generatedAt,
                appVersion: DiagnosticVersion(
                    major: report.application.version.major,
                    minor: report.application.version.minor,
                    patch: report.application.version.patch
                ),
                appBuild: report.application.build,
                operatingSystemVersion: DiagnosticVersion(
                    major: report.operatingSystem.version.major,
                    minor: report.operatingSystem.version.minor,
                    patch: report.operatingSystem.version.patch
                ),
                providerStatuses: report.providers,
                databaseState: report.database.state,
                importCounts: DiagnosticImportCounts(
                    accepted: report.imports.accepted,
                    rejected: report.imports.rejected
                ),
                resourceLimitReasons: Set(report.resourceLimitReasons),
                refreshHistory: history,
                quotaFindings: try report.quotaFindings?.map {
                    try DiagnosticQuotaFinding(
                        product: $0.product,
                        windowKind: $0.windowKind,
                        status: $0.status,
                        qualification: $0.qualification,
                        measuredObservationCount: $0.measuredObservationCount,
                        measuredSpanMinutes: $0.measuredSpanMinutes,
                        forecastMethod: $0.forecastMethod,
                        calculatedBurnPercentPerHour: $0.calculatedBurnPercentPerHour.map {
                            try DiagnosticNumberRange(lower: $0.lower, upper: $0.upper)
                        },
                        calculatedExhaustionMinutes: $0.calculatedExhaustionMinutes.map {
                            try DiagnosticNumberRange(lower: $0.lower, upper: $0.upper)
                        }
                    )
                },
                codexExplanation: try report.codexExplanation.map {
                    try DiagnosticCodexExplanationFinding(
                        status: $0.status,
                        adapterVersion: $0.adapterVersion,
                        coverage: $0.coverage,
                        tokenEvidence: $0.tokenEvidence,
                        sessionCount: $0.sessionCount,
                        evidenceCount: $0.evidenceCount,
                        observationCount: $0.observationCount,
                        barrierCategories: $0.barrierCategories,
                        unavailableReason: $0.unavailableReason,
                        retention: $0.retention
                    )
                },
                quotaEvidence: report.quotaEvidence
            )
            return report
        } catch {
            throw DiagnosticExportError.malformedArtifact
        }
    }

    private static func roundedDownToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    static func isBoundedEvidenceText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumEvidenceTextLength
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func isTraceReference(_ value: String) -> Bool {
        (1...24).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || $0 == 45
        }
    }

    private static func validateEvidence(_ value: DiagnosticQuotaEvidenceReport) throws {
        guard value.recordLimit == maximumQuotaEvidenceRecords,
              value.records.count <= maximumQuotaEvidenceRecords,
              (0...maximumQuotaEvidenceInputRecords).contains(value.omittedRecordCount),
              value.publicationTime.timeIntervalSince1970.isFinite else {
            throw DiagnosticExportError.invalidQuotaEvidence
        }
        _ = try DiagnosticEvidenceSelection(start: value.selectedRange.start, end: value.selectedRange.end, basis: value.selectedRange.basis)
        for record in value.records {
            let movement = try record.movement.map {
                try DiagnosticEvidenceMovement(value: $0.value, unit: $0.unit, provenance: $0.provenance)
            }
            let allocation = try record.inferredAllocation.map {
                try DiagnosticEvidenceAllocation(percent: $0.percent, methodVersion: $0.methodVersion, qualification: $0.qualification, limitations: $0.limitations)
            }
            let forecast = try DiagnosticEvidenceForecast(
                status: record.forecast.status,
                methodVersion: record.forecast.methodVersion,
                qualification: record.forecast.qualification,
                observationCount: record.forecast.observationCount,
                observationSpanSeconds: record.forecast.observationSpanSeconds,
                evidenceAgeSeconds: record.forecast.evidenceAgeSeconds,
                range: record.forecast.range,
                resetInteraction: record.forecast.resetInteraction,
                limitations: record.forecast.limitations
            )
            let anomaly = try DiagnosticEvidenceAnomaly(
                status: record.anomaly.status,
                methodVersion: record.anomaly.methodVersion,
                qualification: record.anomaly.qualification,
                currentPeriod: try record.anomaly.currentPeriod.map { try DiagnosticEvidencePeriod(start: $0.start, end: $0.end) },
                baselinePeriod: try record.anomaly.baselinePeriod.map { try DiagnosticEvidencePeriod(start: $0.start, end: $0.end) },
                measuredInputCount: record.anomaly.measuredInputCount,
                currentValue: record.anomaly.currentValue,
                baselineValue: record.anomaly.baselineValue,
                result: record.anomaly.result,
                limitations: record.anomaly.limitations
            )
            let versions = try record.versions.map { try DiagnosticEvidenceVersion(kind: $0.kind, value: $0.value) }
            let validated = try DiagnosticQuotaEvidenceRecord(
                traceReference: record.traceReference,
                intervalStart: record.intervalStart,
                intervalEnd: record.intervalEnd,
                resetBoundary: record.resetBoundary,
                movement: movement,
                localBreakdown: record.localBreakdown,
                localTokenCount: record.localTokenCount,
                localSessionCount: record.localSessionCount,
                unattributedMovement: record.unattributedMovement,
                unattributedMovementValue: try record.unattributedMovementValue.map {
                    try DiagnosticEvidenceMovement(value: $0.value, unit: $0.unit, provenance: $0.provenance)
                },
                inferredAllocation: allocation,
                forecast: forecast,
                anomaly: anomaly,
                versions: versions,
                limitations: record.limitations
            )
            guard validated == record else { throw DiagnosticExportError.invalidQuotaEvidence }
        }
    }
}
