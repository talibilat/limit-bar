import Foundation
import Testing
@testable import LimitBarCore

@Suite("Quota consumption anomalies")
struct QuotaAnomalyTests {
    private let base = Date(timeIntervalSince1970: 1_900_000_000)

    @Test("bursty measured consumption emits an exact traceable finding")
    func burstyFinding() throws {
        let observations = try series(movements: [2, 2, 2, 2, 2, 8])
        let now = base.addingTimeInterval(61 * 60)

        guard case let .finding(finding) = QuotaAnomalyAnalytics.analyze(
            observations,
            now: now,
            maximumAge: 5 * 60
        ) else {
            Issue.record("Expected a quota consumption anomaly")
            return
        }

        #expect(finding.findingType == .quotaConsumptionAnomaly)
        #expect(finding.direction == .higher)
        #expect(finding.method == .trailingMedianRatioV1)
        #expect(finding.qualification == .qualified)
        #expect(finding.createdAt == now)
        let expectedCurrent = try period(50, 60)
        let expectedBaseline = try period(0, 50)
        #expect(finding.currentPeriod == expectedCurrent)
        #expect(finding.baselinePeriod == expectedBaseline)
        #expect(finding.currentPeriod.inclusionRule == .startExclusiveEndInclusive)
        #expect(finding.baselinePeriod.inclusionRule == .startExclusiveEndInclusive)
        #expect(finding.calculatedCurrentValue == 8)
        #expect(finding.calculatedBaselineMedian == 2)
        #expect(finding.calculatedRatio == 4)
        #expect(finding.calculatedThreshold == 3)
        #expect(finding.inputObservationIdentities == observations.map(\.stableIdentity))
        #expect(finding.interpretationVersions == [.codexLocalReportV1])
        #expect(finding.normalization == .directQuotaMovement)
        #expect(finding.attribution == .unattributed)
        #expect(finding.limitations.contains(.providerWeightingUnknown))
    }

    @Test("stable and flat Observed Zero consumption remain distinct no-finding outcomes")
    func noFindingAndObservedZero() throws {
        let stable = try series(movements: [2, 2, 2, 2, 2, 2])
        guard case let .noFinding(stableResult) = analyze(stable) else {
            Issue.record("Expected stable consumption to produce no finding")
            return
        }
        #expect(stableResult.calculatedRatio == 1)
        #expect(stableResult.calculatedCurrentValue == 2)
        #expect(stableResult.qualification == .qualified)

        let zero = try series(movements: [0, 0, 0, 0, 0, 0])
        guard case let .noFinding(zeroResult) = analyze(zero) else {
            Issue.record("Expected Observed Zero consumption to produce no finding")
            return
        }
        #expect(zeroResult.calculatedCurrentValue == 0)
        #expect(zeroResult.calculatedBaselineMedian == 0)
        #expect(zeroResult.calculatedRatio == nil)

        expectUnavailable(analyze(try series(movements: [0, 0, 0, 0, 0, 1])), .unstableBaseline)
    }

    @Test("Gap, sparse cadence, stale evidence, resets, and counter decreases are unavailable")
    func unsafeEvidence() throws {
        let observations = try series(movements: [2, 2, 2, 2, 2, 8])
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
        let original = try series(movements: [2, 2, 2, 2, 2, 8])
        let reordered = Array(([original[2], original[0]] + original.reversed() + [original[2]]))
        #expect(analyze(reordered) == analyze(original))

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
        #expect(result.inputObservationIdentities.last == correction.stableIdentity)
        #expect(result.limitations.contains(.supersededEvidenceExcluded))
        #expect(analyze(original) != corrected)
    }

    @Test("measured denominators require exact compatible complete nonzero coverage")
    func measuredDenominators() throws {
        let observations = try series(movements: [2, 2, 2, 2, 2, 8])
        let denominators = try denominatorSeries(values: [2, 2, 2, 2, 2, 1])
        guard case let .finding(finding) = QuotaAnomalyAnalytics.analyze(
            observations,
            now: base.addingTimeInterval(61 * 60),
            maximumAge: 5 * 60,
            normalization: .measuredDenominator(denominators)
        ) else {
            Issue.record("Expected a safely normalized finding")
            return
        }
        #expect(finding.normalization == .measuredDenominator(name: "input_tokens", unit: "tokens", version: "tokens_v1"))
        #expect(finding.calculatedCurrentValue == 8)
        #expect(finding.calculatedBaselineMedian == 1)
        #expect(finding.denominatorInputs == denominators)

        var zero = denominators
        zero[5] = try denominator(periodIndex: 5, value: 0)
        expectUnavailable(analyze(observations, normalization: .measuredDenominator(zero)), .zeroDenominator)

        var partial = denominators
        partial[2] = try denominator(periodIndex: 2, value: 2, coverage: 0.5)
        expectUnavailable(analyze(observations, normalization: .measuredDenominator(partial)), .partialDenominatorCoverage)

        var incompatible = denominators
        incompatible[1] = try denominator(periodIndex: 1, value: 2, version: "tokens_v2")
        expectUnavailable(analyze(observations, normalization: .measuredDenominator(incompatible)), .incompatibleDenominator)

        expectUnavailable(analyze(observations, normalization: .measuredDenominator(Array(denominators.dropLast()))), .missingDenominator)
    }

    @Test("adapter, client, and provider-format changes prevent cross-version findings")
    func evidenceVersionCompatibility() throws {
        let observations = try series(movements: [2, 2, 2, 2, 2, 8])
        let v1 = try QuotaAnomalyEvidenceVersion(adapterVersion: "adapter_v1", clientVersion: "client_v1", providerFormatVersion: "format_v1")
        let v2 = try QuotaAnomalyEvidenceVersion(adapterVersion: "adapter_v1", clientVersion: "client_v2", providerFormatVersion: "format_v1")
        var versions = Dictionary(uniqueKeysWithValues: observations.map { ($0.stableIdentity, v1) })
        versions[observations.last!.stableIdentity] = v2

        let state = QuotaAnomalyAnalytics.analyze(
            observations,
            now: base.addingTimeInterval(61 * 60),
            maximumAge: 5 * 60,
            evidenceVersions: versions
        )
        expectUnavailable(state, .incompatibleEvidence)
        guard case let .unavailable(result) = state else { return }
        #expect(result.evidenceVersions == [v1, v2])
        #expect(result.limitations.contains(.incompatibleInterpretationVersion))
    }

    @Test("different exact windows and unsupported quota contexts never form a baseline")
    func exactWindowIsolation() throws {
        let observations = try series(movements: [2, 2, 2, 2, 2, 8])
        let changedIdentity = try QuotaWindowIdentity(
            product: .codex,
            identifier: "primary:300",
            resetBoundary: observations[0].identity.resetBoundary.addingTimeInterval(3_600)
        )
        let changedWindow = try observation(identity: changedIdentity, minute: 60, percent: observations[6].percentageUsed)
        expectUnavailable(analyze(Array(observations.dropLast()) + [changedWindow]), .incompatibleEvidence)

        let unsupported = try QuotaWindowIdentity(
            product: .codex,
            identifier: "private-context",
            resetBoundary: observations[0].identity.resetBoundary
        )
        let unsupportedObservations = try observations.enumerated().map {
            try observation(identity: unsupported, minute: Double($0.offset) * 10, percent: $0.element.percentageUsed)
        }
        expectUnavailable(analyze(unsupportedObservations), .incompatibleEvidence)
    }

    @Test("free-form metadata rejects prohibited-content sentinels")
    func privacyAllowList() throws {
        let safePeriod = try period(0, 10)
        #expect(throws: QuotaAnomalyValidationError.invalidDenominator) {
            try MeasuredQuotaAnomalyDenominator(
                period: safePeriod,
                name: "PROMPT_SECRET",
                unit: "tokens",
                version: "tokens_v1",
                value: 1,
                observedAt: base
            )
        }
        #expect(throws: QuotaAnomalyValidationError.invalidEvidenceVersion) {
            try QuotaAnomalyEvidenceVersion(
                adapterVersion: "adapter_v1",
                clientVersion: "RAW_PROVIDER_PAYLOAD",
                providerFormatVersion: "format_v1"
            )
        }
    }

    private func series(movements: [Double]) throws -> [MeasuredQuotaObservation] {
        let identity = try QuotaWindowIdentity(
            product: .codex,
            identifier: "primary:300",
            resetBoundary: base.addingTimeInterval(5 * 3_600)
        )
        var value = 10.0
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

    private func denominatorSeries(values: [Double]) throws -> [MeasuredQuotaAnomalyDenominator] {
        try values.enumerated().map { try denominator(periodIndex: $0.offset, value: $0.element) }
    }

    private func denominator(
        periodIndex: Int,
        value: Double,
        coverage: Double = 1,
        version: String = "tokens_v1"
    ) throws -> MeasuredQuotaAnomalyDenominator {
        try MeasuredQuotaAnomalyDenominator(
            period: period(Double(periodIndex) * 10, Double(periodIndex + 1) * 10),
            name: "input_tokens",
            unit: "tokens",
            version: version,
            value: value,
            observedAt: base.addingTimeInterval(60 * 60),
            coverage: coverage
        )
    }

    private func expectUnavailable(_ state: QuotaAnomalyState, _ reason: QuotaAnomalyUnavailableReason) {
        guard case let .unavailable(result) = state else {
            Issue.record("Expected unavailable analysis for \(reason.rawValue)")
            return
        }
        #expect(result.reason == reason)
        #expect(result.method == .trailingMedianRatioV1)
        #expect(result.qualification == .unavailable)
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
}
