import Testing
@testable import LimitBarCore

@Suite("Quota anomaly candidate replay")
struct QuotaAnomalyReplayTests {
    @Test("frozen labeled fixtures uniquely select trailing-median ratio v1")
    func candidateSelection() throws {
        let fixtures = try QuotaAnomalyFrozenCorpus.validatedFixtures()
        let report = try QuotaAnomalyCandidateEvaluator.evaluate(fixtures)
        let reversed = try QuotaAnomalyCandidateEvaluator.evaluate(fixtures.reversed())

        #expect(report == reversed)
        #expect(QuotaAnomalyFrozenCorpus.version == "quota_anomaly_corpus_v1")
        let computedDigest = try QuotaAnomalyFrozenCorpus.computedFreezeDigest()
        #expect(computedDigest == QuotaAnomalyFrozenCorpus.freezeDigest)
        #expect(fixtures.map(\.condition) == [.bursty, .changingVersion, .flat, .gradual, .mixedIntensity, .observedZero, .reset, .sparse, .stable])
        #expect(report.selectedProductionMethod == .trailingMedianRatioV1)
        #expect(report.selectedCandidate == .trailingMedianRatio)
        #expect(report.selectedThreshold == 3)
        #expect(report.baselineDuration == 50 * 60)
        #expect(report.comparisonDuration == 10 * 60)
        #expect(report.minimumBaselineSampleCount == 5)
        #expect(report.selectedMetrics == QuotaAnomalyCandidateMetrics(
            fixtureCount: 9,
            correctCount: 9,
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
        #expect(report.limitations.contains(.syntheticFixtureValidationOnly))
    }

    @Test("fixture validation and replay are deterministic and privacy-safe")
    func validationAndPrivacy() throws {
        #expect(throws: QuotaAnomalyReplayError.invalidFixture) {
            try QuotaAnomalyReplayFixture(id: "Private/path", condition: .stable, movements: [1, 1, 1, 1, 1, 1], expected: .noFinding)
        }
        let fixtures = try QuotaAnomalyFrozenCorpus.validatedFixtures()
        #expect(throws: QuotaAnomalyReplayError.duplicateFixtureID) {
            try QuotaAnomalyCandidateEvaluator.evaluate(fixtures + [fixtures[0]])
        }
        let text = fixtures.flatMap { [$0.id, $0.condition.rawValue] }.joined(separator: " ").lowercased()
        for prohibited in ["prompt", "response", "credential", "account", "/users/", "payload", "terminal", "project"] {
            #expect(!text.contains(prohibited))
        }
    }
}
