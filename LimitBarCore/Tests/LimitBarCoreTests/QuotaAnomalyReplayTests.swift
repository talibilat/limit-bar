import Testing
@testable import LimitBarCore

@Suite("Quota anomaly candidate replay")
struct QuotaAnomalyReplayTests {
    @Test("real frozen fixtures uniquely select production trailing-median ratio semantics")
    func candidateSelection() throws {
        let fixtures = try QuotaAnomalyFrozenCorpus.validatedFixtures()
        let report = try QuotaAnomalyCandidateEvaluator.evaluate(fixtures)
        let reversed = try QuotaAnomalyCandidateEvaluator.evaluate(fixtures.reversed())

        #expect(report == reversed)
        #expect(QuotaAnomalyFrozenCorpus.version == "quota_anomaly_corpus_v3")
        let computedDigest = try QuotaAnomalyFrozenCorpus.computedFreezeDigest()
        #expect(computedDigest == QuotaAnomalyFrozenCorpus.freezeDigest)
        #expect(fixtures.map(\.condition) == [.baselineShape, .bursty, .changingVersion, .flat, .gradual, .mixedIntensity, .observedZero, .reset, .sparse, .stable])
        #expect(report.selectedProductionMethod == .trailingMedianRatioV1)
        #expect(report.selectedCandidate == .trailingMedianRatio)
        #expect(report.selectedThreshold == 3)
        #expect(report.baselineDuration == 50 * 60)
        #expect(report.comparisonDuration == 10 * 60)
        #expect(report.minimumBaselineSampleCount == 5)
        #expect(report.minimumObservationSpan == 60 * 60)
        #expect(report.selectedMetrics == QuotaAnomalyCandidateMetrics(
            fixtureCount: 10,
            correctCount: 10,
            falsePositiveCount: 0,
            falseNegativeCount: 0,
            unsafeAvailabilityMismatchCount: 0
        ))

        let ratioTwo = try #require(report.candidates.first { $0.method == .trailingMedianRatio && $0.threshold == 2 })
        #expect(ratioTwo.metrics.falsePositiveCount == 1)
        let ratioFour = try #require(report.candidates.first { $0.method == .trailingMedianRatio && $0.threshold == 4 })
        #expect(ratioFour.metrics.falseNegativeCount == 1)
        #expect(report.candidates.filter { $0.method == .medianAbsoluteDeviation }.allSatisfy {
            $0.metrics.unsafeAvailabilityMismatchCount >= 2
        })
        #expect(report.selectedBaselineShape == QuotaAnomalyBaselineShape(
            comparisonDuration: 10 * 60,
            baselineSampleCount: 5,
            baselineDuration: 50 * 60,
            minimumObservationSpan: 60 * 60
        ))
        #expect(report.baselineShapeCandidates.count == 4)
        #expect(report.baselineShapeCandidates.filter { $0.shape != report.selectedBaselineShape }.allSatisfy {
            $0.metrics.correctCount < 10
        })
        let threeSample = try #require(report.baselineShapeCandidates.first {
            $0.shape.comparisonDuration == 10 * 60 && $0.shape.baselineSampleCount == 3
        })
        #expect(threeSample.metrics.falseNegativeCount >= 1)
        #expect(threeSample.metrics.unsafeAvailabilityMismatchCount >= 1)
    }

    @Test("sparse, reset, and changing-version fixtures execute production qualification")
    func failureFixturesUseProductionSemantics() throws {
        let fixtures = try QuotaAnomalyFrozenCorpus.validatedFixtures()
        let sparse = try #require(fixtures.first { $0.condition == .sparse })
        let reset = try #require(fixtures.first { $0.condition == .reset })
        let changed = try #require(fixtures.first { $0.condition == .changingVersion })

        #expect(sparse.observations.count == 6)
        #expect(unavailableReason(sparse) == .insufficientBaseline)
        #expect(reset.observations.count == 7)
        #expect(unavailableReason(reset) == .resetOrExpired)
        #expect(changed.observations.count == 7)
        guard case let .unavailable(changedResult) = analyze(changed) else {
            Issue.record("Expected changing-version fixture to be unavailable")
            return
        }
        #expect(changedResult.reason == .incompatibleEvidence)
        #expect(changedResult.metadata.limitations.contains(.incompatibleAdapterVersion))
        #expect(changedResult.metadata.limitations.contains(.incompatibleClientVersion))
        #expect(changedResult.metadata.limitations.contains(.incompatibleProviderFormatVersion))
    }

    @Test("fixture validation, replay order, and corpus fields are deterministic and privacy-safe")
    func validationAndPrivacy() throws {
        let fixtures = try QuotaAnomalyFrozenCorpus.validatedFixtures()
        let valid = fixtures[0]
        #expect(throws: QuotaAnomalyReplayError.invalidFixture) {
            try QuotaAnomalyReplayFixture(
                id: "Private/path",
                condition: valid.condition,
                observations: valid.observations,
                evaluationTime: valid.evaluationTime,
                maximumEvidenceAge: valid.maximumEvidenceAge,
                expectedIdentity: valid.expectedIdentity,
                expected: valid.expected
            )
        }
        #expect(throws: QuotaAnomalyReplayError.duplicateFixtureID) {
            try QuotaAnomalyCandidateEvaluator.evaluate(fixtures + [fixtures[0]])
        }
        let text = fixtures.flatMap { [$0.id, $0.condition.rawValue] }.joined(separator: " ").lowercased()
        for prohibited in ["prompt", "response", "credential", "account", "/users/", "payload", "terminal", "project"] {
            #expect(!text.contains(prohibited))
        }
    }

    private func analyze(_ fixture: QuotaAnomalyReplayFixture) -> QuotaAnomalyState {
        QuotaAnomalyAnalytics.analyze(
            fixture.observations,
            now: fixture.evaluationTime,
            maximumAge: fixture.maximumEvidenceAge,
            expectedIdentity: fixture.expectedIdentity,
            evidenceVersions: fixture.evidenceVersions
        )
    }

    private func unavailableReason(_ fixture: QuotaAnomalyReplayFixture) -> QuotaAnomalyUnavailableReason? {
        guard case let .unavailable(result) = analyze(fixture) else { return nil }
        return result.reason
    }
}
