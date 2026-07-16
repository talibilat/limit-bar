import Foundation
import Testing
@testable import LimitBarCore

@Suite("Quota consumption anomalies")
struct QuotaAnomalyTests {
    private let base = Date(timeIntervalSince1970: 1_900_000_000)

    @Test("bursty measured consumption emits an exact traceable finding")
    func burstyFinding() throws {
        let observations = try series(initial: 10, movements: [2, 2, 2, 2, 2, 8])
        guard case let .finding(finding) = analyze(observations) else {
            Issue.record("Expected a quota consumption anomaly")
            return
        }
        let expectedCurrent = try period(50, 60)
        let expectedBaseline = try period(0, 50)
        #expect(finding.findingType == .quotaConsumptionAnomaly)
        #expect(finding.direction == .higher)
        #expect(finding.metadata.method == .trailingMedianRatioV1)
        #expect(finding.metadata.qualification == .qualified)
        #expect(finding.metadata.createdAt == base.addingTimeInterval(61 * 60))
        #expect(finding.metadata.currentPeriod == expectedCurrent)
        #expect(finding.metadata.baselinePeriod == expectedBaseline)
        #expect(finding.metadata.currentPeriod?.inclusionRule == .startExclusiveEndInclusive)
        #expect(finding.calculatedCurrentValue == 8)
        #expect(finding.calculatedBaselineValues == [2, 2, 2, 2, 2])
        #expect(finding.calculatedBaselineMedian == 2)
        #expect(finding.calculatedRatio == 4)
        #expect(finding.calculatedThreshold == 3)
        #expect(finding.metadata.inputObservationIdentities == observations.map(\.stableIdentity))
        #expect(finding.metadata.interpretationVersions == [.codexLocalReportV1])
        #expect(finding.metadata.inputClassifications == [.measured])
        #expect(finding.normalization == .directQuotaMovement)
        #expect(finding.attribution == .unattributed)
        #expect(finding.metadata.limitations.contains(.providerWeightingUnknown))
    }

    @Test("Observed Zero is distinct from unchanged nonzero cumulative usage")
    func observedZeroSemantics() throws {
        let flatNonzero = try series(initial: 10, movements: [0, 0, 0, 0, 0, 0])
        guard case let .noFinding(flat) = analyze(flatNonzero) else {
            Issue.record("Expected unchanged nonzero cumulative usage to be an ordinary no-finding result")
            return
        }
        #expect(flat.calculatedCurrentValue == 0)
        #expect(flat.calculatedBaselineMedian == 0)
        #expect(flat.calculatedRatio == nil)

        let zero = try series(initial: 0, movements: [0, 0, 0, 0, 0, 0])
        guard case let .observedZero(result) = analyze(zero) else {
            Issue.record("Expected an explicit Observed Zero result")
            return
        }
        #expect(result.calculatedCurrentValue == 0)
        #expect(result.calculatedBaselineValues == [0, 0, 0, 0, 0])
        #expect(result.metadata.qualification == .qualified)

        expectUnavailable(analyze(try series(initial: 0, movements: [0, 0, 0, 0, 0, 1])), .unstableBaseline)
    }

    @Test("Gap, sparse cadence, stale evidence, resets, and counter decreases are unavailable")
    func unsafeEvidence() throws {
        let observations = try series(initial: 10, movements: [2, 2, 2, 2, 2, 8])
        expectUnavailable(QuotaAnomalyAnalytics.analyze(
            observations,
            now: base.addingTimeInterval(61 * 60),
            maximumAge: 5 * 60,
            gaps: [try period(20, 30)]
        ), .gap)
        expectUnavailable(QuotaAnomalyAnalytics.analyze(
            observations,
            now: base.addingTimeInterval(70 * 60),
            maximumAge: 5 * 60
        ), .staleEvidence)

        var sparse = observations
        sparse.remove(at: 3)
        expectUnavailable(analyze(sparse), .insufficientBaseline)

        var decreased = observations
        let identity = decreased[0].identity
        decreased[3] = try observation(identity: identity, minute: 30, percent: decreased[2].percentageUsed - 1)
        expectUnavailable(analyze(decreased), .counterDecreased)

        expectUnavailable(QuotaAnomalyAnalytics.analyze(
            observations,
            now: observations[0].identity.resetBoundary,
            maximumAge: 10 * 3_600
        ), .resetOrExpired)
    }

    @Test("deduplication, ordering, conflicts, and explicit supersession are deterministic")
    func evidenceQualification() throws {
        let original = try series(initial: 10, movements: [2, 2, 2, 2, 2, 8])
        let reordered = [original[2], original[0]] + original.reversed() + [original[2]]
        #expect(analyze(Array(reordered)) == analyze(original))

        let conflict = try observation(identity: original[1].identity, minute: 10, percent: original[1].percentageUsed + 1)
        expectUnavailable(analyze(original + [conflict]), .conflictingObservations)

        let correction = try observation(identity: original[6].identity, minute: 60, percent: original[5].percentageUsed + 2)
        let corrected = QuotaAnomalyAnalytics.analyze(
            original + [correction],
            now: base.addingTimeInterval(61 * 60),
            maximumAge: 5 * 60,
            supersededObservationIdentities: [original[6].stableIdentity]
        )
        guard case let .noFinding(result) = corrected else {
            Issue.record("Expected the explicit correction to replace the superseded burst")
            return
        }
        #expect(result.metadata.inputObservationIdentities.last == correction.stableIdentity)
        #expect(result.metadata.limitations.contains(.supersededEvidenceExcluded))
        #expect(analyze(original) != corrected)

        let unmatched = try observation(identity: original[0].identity, minute: 70, percent: 30)
        let unmatchedState = QuotaAnomalyAnalytics.analyze(
            original,
            now: base.addingTimeInterval(61 * 60),
            maximumAge: 5 * 60,
            supersededObservationIdentities: [unmatched.stableIdentity]
        )
        #expect(unmatchedState == analyze(original))
        guard case let .finding(unmatchedResult) = unmatchedState else { return }
        #expect(!unmatchedResult.metadata.limitations.contains(.supersededEvidenceExcluded))
    }

    @Test("typed measured denominators retain source, coverage, missingness, and exact periods")
    func measuredDenominators() throws {
        let observations = try series(initial: 10, movements: [2, 2, 2, 2, 2, 8])
        let inputs = try denominatorSeries(values: [2, 2, 2, 2, 2, 1])
        let denominatorRequest = QuotaAnomalyDenominatorRequest(
            kind: .inputTokens,
            source: .localUsageEvents,
            inputs: inputs
        )
        guard case let .finding(finding) = analyze(observations, normalization: .measuredDenominator(denominatorRequest)) else {
            Issue.record("Expected a safely normalized finding")
            return
        }
        #expect(finding.normalization == .measuredDenominator(
            kind: .inputTokens,
            unit: .tokens,
            source: .localUsageEvents,
            methodVersion: .measuredIntervalAggregateV1
        ))
        #expect(finding.calculatedCurrentValue == 8)
        #expect(finding.calculatedBaselineMedian == 1)
        #expect(finding.metadata.denominatorInputs == inputs)
        #expect(finding.metadata.denominatorInputs.allSatisfy { $0.classification == .measured && $0.coverage == .complete })

        var zero = inputs
        zero[5] = try denominator(periodIndex: 5, value: 0)
        expectUnavailable(analyze(observations, normalization: request(with: zero)), .zeroDenominator)

        var partial = inputs
        partial[2] = try QuotaAnomalyDenominatorInput(
            period: period(20, 30),
            kind: .inputTokens,
            source: .localUsageEvents,
            value: 2,
            observedAt: base.addingTimeInterval(60 * 60),
            coverage: .partial(0.5)
        )
        let partialState = analyze(observations, normalization: request(with: partial))
        expectUnavailable(partialState, .partialDenominatorCoverage)
        guard case let .unavailable(partialResult) = partialState else { return }
        #expect(partialResult.metadata.denominatorInputs.contains { $0.coverage == QuotaAnomalyDenominatorCoverage.partial(0.5) })

        let missingState = analyze(observations, normalization: request(with: Array(inputs.dropLast())))
        expectUnavailable(missingState, .missingDenominator)
        guard case let .unavailable(missingResult) = missingState else { return }
        #expect(missingResult.metadata.denominatorInputs.count == 6)
        #expect(missingResult.metadata.denominatorInputs.last?.coverage == .gap)
        #expect(missingResult.metadata.denominatorInputs.last?.source == .localUsageEvents)
        #expect(missingResult.metadata.denominatorInputs.last?.classification == nil)

        let publicGap = try QuotaAnomalyDenominatorInput(
            period: period(50, 60),
            kind: .inputTokens,
            source: .localUsageEvents,
            value: nil,
            observedAt: nil,
            coverage: .gap
        )
        #expect(publicGap.classification == nil)

        let incompatibleRequest = QuotaAnomalyDenominatorRequest(
            kind: .requests,
            source: .localUsageEvents,
            inputs: inputs
        )
        expectUnavailable(analyze(observations, normalization: .measuredDenominator(incompatibleRequest)), .incompatibleDenominator)

        var stale = inputs
        stale[0] = try QuotaAnomalyDenominatorInput(
            period: period(0, 10),
            kind: .inputTokens,
            source: .localUsageEvents,
            value: 2,
            observedAt: base.addingTimeInterval(50 * 60),
            coverage: .complete
        )
        let staleState = analyze(observations, normalization: request(with: stale))
        expectUnavailable(staleState, .staleDenominator)
        guard case let .unavailable(staleResult) = staleState else { return }
        #expect(staleResult.metadata.denominatorInputs[0].source == .localUsageEvents)
        #expect(staleResult.metadata.denominatorInputs[0].observedAt == base.addingTimeInterval(50 * 60))
    }

    @Test("typed adapter, client, and provider-format changes identify exact incompatibilities")
    func evidenceVersionCompatibility() throws {
        let observations = try series(initial: 10, movements: [2, 2, 2, 2, 2, 8])
        let v1 = try QuotaAnomalyEvidenceVersion(adapter: .quotaObservationV1, client: .codex0144, providerFormat: .codexLocalReportV1)
        let v2 = try QuotaAnomalyEvidenceVersion(adapter: .quotaObservationV2, client: .codex0145, providerFormat: .codexLocalReportV2)
        var versions = Dictionary(uniqueKeysWithValues: observations.map { ($0.stableIdentity, v1) })
        versions[try #require(observations.last).stableIdentity] = v2

        let state = QuotaAnomalyAnalytics.analyze(
            observations,
            now: base.addingTimeInterval(61 * 60),
            maximumAge: 5 * 60,
            evidenceVersions: versions
        )
        expectUnavailable(state, .incompatibleEvidence)
        guard case let .unavailable(result) = state else { return }
        #expect(result.metadata.evidenceVersions == [v1, v2])
        #expect(result.metadata.limitations.contains(.incompatibleAdapterVersion))
        #expect(result.metadata.limitations.contains(.incompatibleClientVersion))
        #expect(result.metadata.limitations.contains(.incompatibleProviderFormatVersion))

        #expect(throws: QuotaAnomalyValidationError.invalidEvidenceVersion) {
            try QuotaAnomalyEvidenceVersion(
                adapter: .quotaObservationV1,
                client: .claudeSupportedV1,
                providerFormat: .codexLocalReportV1
            )
        }

        let claudeVersion = try QuotaAnomalyEvidenceVersion(
            adapter: .quotaObservationV1,
            client: .claudeSupportedV1,
            providerFormat: .claudeProviderReportV1
        )
        let wrongSourceVersions = Dictionary(uniqueKeysWithValues: observations.map { ($0.stableIdentity, claudeVersion) })
        let wrongSourceState = QuotaAnomalyAnalytics.analyze(
            observations,
            now: base.addingTimeInterval(61 * 60),
            maximumAge: 5 * 60,
            evidenceVersions: wrongSourceVersions
        )
        expectUnavailable(wrongSourceState, .incompatibleEvidence)
        guard case let .unavailable(wrongSource) = wrongSourceState else { return }
        #expect(wrongSource.metadata.limitations.contains(.incompatibleProviderFormatVersion))
        #expect(wrongSource.metadata.limitations.contains(.incompatibleClientVersion))
    }

    @Test("different Quota windows and unsupported contexts never form a baseline")
    func quotaWindowIsolation() throws {
        let observations = try series(initial: 10, movements: [2, 2, 2, 2, 2, 8])
        let changedIdentity = try QuotaWindowIdentity(
            product: .codex,
            identifier: "primary:300",
            resetBoundary: observations[0].identity.resetBoundary.addingTimeInterval(3_600)
        )
        let changedWindow = try observation(identity: changedIdentity, minute: 60, percent: observations[6].percentageUsed)
        expectUnavailable(analyze(Array(observations.dropLast()) + [changedWindow]), .incompatibleEvidence)

        let unsupported = try QuotaWindowIdentity(
            product: .codex,
            identifier: "unsupported-context",
            resetBoundary: observations[0].identity.resetBoundary
        )
        let unsupportedObservations = try observations.enumerated().map {
            try observation(identity: unsupported, minute: Double($0.offset) * 10, percent: $0.element.percentageUsed)
        }
        expectUnavailable(analyze(unsupportedObservations), .incompatibleEvidence)
    }

    @Test("denominator kinds and sources are a bounded positive semantic allow-list")
    func denominatorAllowList() {
        #expect(Set(QuotaAnomalyDenominatorKind.allCases) == [
            .inputTokens, .requests, .agentSteps, .completedTasks, .acceptedCodeChanges, .activeMinutes,
        ])
        #expect(Set(QuotaAnomalyDenominatorSource.allCases) == [
            .localUsageEvents, .codexRolloutEvidence, .collectorUsageEvents,
        ])
    }

    private func series(initial: Double, movements: [Double]) throws -> [MeasuredQuotaObservation] {
        let identity = try QuotaWindowIdentity(
            product: .codex,
            identifier: "primary:300",
            resetBoundary: base.addingTimeInterval(5 * 3_600)
        )
        var value = initial
        var result = [try observation(identity: identity, minute: 0, percent: value)]
        for (index, movement) in movements.enumerated() {
            value += movement
            result.append(try observation(identity: identity, minute: Double(index + 1) * 10, percent: value))
        }
        return result
    }

    private func analyze(
        _ observations: [MeasuredQuotaObservation],
        normalization: QuotaAnomalyNormalization = .directQuotaMovement
    ) -> QuotaAnomalyState {
        QuotaAnomalyAnalytics.analyze(
            observations,
            now: base.addingTimeInterval(61 * 60),
            maximumAge: 5 * 60,
            normalization: normalization
        )
    }

    private func request(with inputs: [QuotaAnomalyDenominatorInput]) -> QuotaAnomalyNormalization {
        .measuredDenominator(QuotaAnomalyDenominatorRequest(
            kind: .inputTokens,
            source: .localUsageEvents,
            inputs: inputs
        ))
    }

    private func denominatorSeries(values: [Double]) throws -> [QuotaAnomalyDenominatorInput] {
        try values.enumerated().map { try denominator(periodIndex: $0.offset, value: $0.element) }
    }

    private func denominator(periodIndex: Int, value: Double) throws -> QuotaAnomalyDenominatorInput {
        try QuotaAnomalyDenominatorInput(
            period: period(Double(periodIndex) * 10, Double(periodIndex + 1) * 10),
            kind: .inputTokens,
            source: .localUsageEvents,
            value: value,
            observedAt: base.addingTimeInterval(60 * 60),
            coverage: .complete
        )
    }

    private func observation(identity: QuotaWindowIdentity, minute: Double, percent: Double) throws -> MeasuredQuotaObservation {
        try MeasuredQuotaObservation(
            identity: identity,
            percentageUsed: percent,
            observedAt: base.addingTimeInterval(minute * 60),
            source: .codexLocalReport
        )
    }

    private func period(_ startMinute: Double, _ endMinute: Double) throws -> QuotaAnomalyPeriod {
        try QuotaAnomalyPeriod(
            start: base.addingTimeInterval(startMinute * 60),
            end: base.addingTimeInterval(endMinute * 60)
        )
    }

    private func expectUnavailable(_ state: QuotaAnomalyState, _ reason: QuotaAnomalyUnavailableReason) {
        guard case let .unavailable(result) = state else {
            Issue.record("Expected unavailable analysis for \(reason.rawValue)")
            return
        }
        #expect(result.reason == reason)
        #expect(result.metadata.method == .trailingMedianRatioV1)
        #expect(result.metadata.qualification == .unavailable)
    }
}
