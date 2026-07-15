import CryptoKit
import Foundation

public enum QuotaAnomalyReplayError: Error, Equatable {
    case invalidFixture
    case duplicateFixtureID
    case corpusDigestMismatch
    case noUniqueAcceptableCandidate
}

public enum QuotaAnomalyFixtureCondition: String, Codable, CaseIterable, Equatable, Sendable {
    case bursty
    case changingVersion = "changing_version"
    case flat
    case gradual
    case mixedIntensity = "mixed_intensity"
    case observedZero = "observed_zero"
    case reset
    case sparse
    case stable
}

public enum QuotaAnomalyExpectedOutcome: String, Codable, Equatable, Sendable {
    case higherFinding = "higher_finding"
    case noFinding = "no_finding"
    case observedZero = "observed_zero"
    case unavailable
}

public struct QuotaAnomalyReplayFixture: Equatable, Sendable {
    public let id: String
    public let condition: QuotaAnomalyFixtureCondition
    public let observations: [MeasuredQuotaObservation]
    public let evaluationTime: Date
    public let maximumEvidenceAge: TimeInterval
    public let expectedIdentity: QuotaWindowIdentity
    public let evidenceVersions: [QuotaObservationIdentity: QuotaAnomalyEvidenceVersion]
    public let expected: QuotaAnomalyExpectedOutcome

    public init(
        id: String,
        condition: QuotaAnomalyFixtureCondition,
        observations: [MeasuredQuotaObservation],
        evaluationTime: Date,
        maximumEvidenceAge: TimeInterval,
        expectedIdentity: QuotaWindowIdentity,
        evidenceVersions: [QuotaObservationIdentity: QuotaAnomalyEvidenceVersion] = [:],
        expected: QuotaAnomalyExpectedOutcome
    ) throws {
        let allowedID = !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        guard allowedID,
              evaluationTime.timeIntervalSince1970.isFinite,
              maximumEvidenceAge.isFinite, maximumEvidenceAge >= 0,
              observations.allSatisfy({ $0.identity == expectedIdentity && $0.observedAt <= evaluationTime }),
              Set(evidenceVersions.keys).isSubset(of: Set(observations.map(\.stableIdentity))) else {
            throw QuotaAnomalyReplayError.invalidFixture
        }
        self.id = id
        self.condition = condition
        self.observations = observations
        self.evaluationTime = evaluationTime
        self.maximumEvidenceAge = maximumEvidenceAge
        self.expectedIdentity = expectedIdentity
        self.evidenceVersions = evidenceVersions
        self.expected = expected
    }
}

public enum QuotaAnomalyCandidateMethod: String, Codable, Equatable, Sendable {
    case trailingMedianRatio = "trailing_median_ratio"
    case medianAbsoluteDeviation = "median_absolute_deviation"
}

public struct QuotaAnomalyCandidateMetrics: Equatable, Sendable {
    public let fixtureCount: Int
    public let correctCount: Int
    public let falsePositiveCount: Int
    public let falseNegativeCount: Int
    public let unsafeAvailabilityMismatchCount: Int

    public init(
        fixtureCount: Int,
        correctCount: Int,
        falsePositiveCount: Int,
        falseNegativeCount: Int,
        unsafeAvailabilityMismatchCount: Int
    ) {
        self.fixtureCount = fixtureCount
        self.correctCount = correctCount
        self.falsePositiveCount = falsePositiveCount
        self.falseNegativeCount = falseNegativeCount
        self.unsafeAvailabilityMismatchCount = unsafeAvailabilityMismatchCount
    }
}

public struct QuotaAnomalyCandidateResult: Equatable, Sendable {
    public let method: QuotaAnomalyCandidateMethod
    public let threshold: Double
    public let metrics: QuotaAnomalyCandidateMetrics
}

public struct QuotaAnomalyCandidateReport: Equatable, Sendable {
    public let selectedProductionMethod: QuotaAnomalyMethod
    public let selectedCandidate: QuotaAnomalyCandidateMethod
    public let selectedThreshold: Double
    public let baselineDuration: TimeInterval
    public let comparisonDuration: TimeInterval
    public let minimumBaselineSampleCount: Int
    public let selectedMetrics: QuotaAnomalyCandidateMetrics
    public let candidates: [QuotaAnomalyCandidateResult]
    public let limitations: [QuotaAnomalyLimitation]
}

public enum QuotaAnomalyCandidateEvaluator {
    public static func evaluate<S: Sequence>(_ fixtures: S) throws -> QuotaAnomalyCandidateReport where S.Element == QuotaAnomalyReplayFixture {
        let ordered = Array(fixtures).sorted { $0.id < $1.id }
        guard Set(ordered.map(\.id)).count == ordered.count else { throw QuotaAnomalyReplayError.duplicateFixtureID }
        let configurations: [(QuotaAnomalyCandidateMethod, Double)] = [
            (.trailingMedianRatio, 2),
            (.trailingMedianRatio, 3),
            (.trailingMedianRatio, 4),
            (.medianAbsoluteDeviation, 2.5),
            (.medianAbsoluteDeviation, 3.5),
        ]
        let candidates = configurations.map { method, threshold in
            QuotaAnomalyCandidateResult(
                method: method,
                threshold: threshold,
                metrics: metrics(fixtures: ordered, method: method, threshold: threshold)
            )
        }
        let acceptable = candidates.filter {
            $0.metrics.correctCount == ordered.count
                && $0.metrics.falsePositiveCount == 0
                && $0.metrics.falseNegativeCount == 0
                && $0.metrics.unsafeAvailabilityMismatchCount == 0
        }
        guard acceptable.count == 1,
              acceptable[0].method == .trailingMedianRatio,
              acceptable[0].threshold == QuotaAnomalyAnalytics.ratioThreshold else {
            throw QuotaAnomalyReplayError.noUniqueAcceptableCandidate
        }
        return QuotaAnomalyCandidateReport(
            selectedProductionMethod: .trailingMedianRatioV1,
            selectedCandidate: acceptable[0].method,
            selectedThreshold: acceptable[0].threshold,
            baselineDuration: QuotaAnomalyAnalytics.baselineDuration,
            comparisonDuration: QuotaAnomalyAnalytics.comparisonDuration,
            minimumBaselineSampleCount: QuotaAnomalyAnalytics.minimumBaselineSampleCount,
            selectedMetrics: acceptable[0].metrics,
            candidates: candidates,
            limitations: [.syntheticFixtureValidationOnly, .providerWeightingUnknown, .noCausalAttribution]
        )
    }

    private static func metrics(
        fixtures: [QuotaAnomalyReplayFixture],
        method: QuotaAnomalyCandidateMethod,
        threshold: Double
    ) -> QuotaAnomalyCandidateMetrics {
        var correct = 0
        var falsePositive = 0
        var falseNegative = 0
        var availabilityMismatch = 0
        for fixture in fixtures {
            let actual = outcome(fixture, method: method, threshold: threshold)
            if actual == fixture.expected {
                correct += 1
            } else if fixture.expected == .unavailable || actual == .unavailable {
                availabilityMismatch += 1
            } else if actual == .higherFinding {
                falsePositive += 1
            } else if fixture.expected == .higherFinding {
                falseNegative += 1
            } else {
                availabilityMismatch += 1
            }
        }
        return QuotaAnomalyCandidateMetrics(
            fixtureCount: fixtures.count,
            correctCount: correct,
            falsePositiveCount: falsePositive,
            falseNegativeCount: falseNegative,
            unsafeAvailabilityMismatchCount: availabilityMismatch
        )
    }

    private static func outcome(
        _ fixture: QuotaAnomalyReplayFixture,
        method: QuotaAnomalyCandidateMethod,
        threshold: Double
    ) -> QuotaAnomalyExpectedOutcome {
        let state = QuotaAnomalyAnalytics.analyze(
            fixture.observations,
            now: fixture.evaluationTime,
            maximumAge: fixture.maximumEvidenceAge,
            expectedIdentity: fixture.expectedIdentity,
            evidenceVersions: fixture.evidenceVersions
        )
        let values: (baseline: [Double], current: Double)
        switch state {
        case let .finding(result):
            values = (result.calculatedBaselineValues, result.calculatedCurrentValue)
        case let .noFinding(result):
            values = (result.calculatedBaselineValues, result.calculatedCurrentValue)
        case .observedZero:
            return .observedZero
        case .unavailable:
            return .unavailable
        }
        let scoreMethod: QuotaAnomalyScoreMethod = method == .trailingMedianRatio
            ? .trailingMedianRatio
            : .medianAbsoluteDeviation
        return switch QuotaAnomalyScoring.evaluate(
            baseline: values.baseline,
            current: values.current,
            method: scoreMethod,
            threshold: threshold
        ).outcome {
        case .finding: .higherFinding
        case .noFinding: .noFinding
        case .unavailable: .unavailable
        }
    }
}

public enum QuotaAnomalyFrozenCorpus {
    public static let version = "quota_anomaly_corpus_v2"
    public static let freezeDigest = "c2c4f66f44f8ebc4f38dc4239359d456fc68b1da4939a906f7d904b2bd1870ed"

    public static func validatedFixtures() throws -> [QuotaAnomalyReplayFixture] {
        let fixtures = try makeFixtures().sorted { $0.id < $1.id }
        guard computedFreezeDigest(fixtures) == freezeDigest else {
            throw QuotaAnomalyReplayError.corpusDigestMismatch
        }
        return fixtures
    }

    public static func computedFreezeDigest() throws -> String {
        computedFreezeDigest(try makeFixtures())
    }

    private static func makeFixtures() throws -> [QuotaAnomalyReplayFixture] {
        try [
            fixture(id: "bursty-01", index: 0, condition: .bursty, initial: 10, movements: [2, 2, 2, 2, 2, 6.4], expected: .higherFinding),
            fixture(id: "changing-version-01", index: 1, condition: .changingVersion, initial: 10, movements: [2, 2, 2, 2, 2, 6.4], expected: .unavailable, changingVersion: true),
            fixture(id: "flat-01", index: 2, condition: .flat, initial: 10, movements: [0, 0, 0, 0, 0, 0], expected: .noFinding),
            fixture(id: "gradual-01", index: 3, condition: .gradual, initial: 10, movements: [1, 1.2, 1.4, 1.6, 1.8, 2], expected: .noFinding),
            fixture(id: "mixed-intensity-01", index: 4, condition: .mixedIntensity, initial: 10, movements: [1, 5, 1, 5, 1, 2], expected: .noFinding),
            fixture(id: "observed-zero-01", index: 5, condition: .observedZero, initial: 0, movements: [0, 0, 0, 0, 0, 0], expected: .observedZero),
            fixture(id: "reset-01", index: 6, condition: .reset, initial: 10, movements: [1, 1, 1, 1, 1, 1], expected: .unavailable, resetMinute: 60),
            fixture(id: "sparse-01", index: 7, condition: .sparse, initial: 10, movements: [1, 1, 1, 1, 1], expected: .unavailable),
            fixture(id: "stable-01", index: 8, condition: .stable, initial: 10, movements: [1, 1.1, 0.9, 1, 1, 1.1], expected: .noFinding),
        ]
    }

    private static func fixture(
        id: String,
        index: Int,
        condition: QuotaAnomalyFixtureCondition,
        initial: Double,
        movements: [Double],
        expected: QuotaAnomalyExpectedOutcome,
        resetMinute: Double = 300,
        changingVersion: Bool = false
    ) throws -> QuotaAnomalyReplayFixture {
        let start = Date(timeIntervalSince1970: 2_000_000_000 + Double(index) * 86_400)
        let identity = try QuotaWindowIdentity(
            product: .codex,
            identifier: "primary:300",
            resetBoundary: start.addingTimeInterval(resetMinute * 60)
        )
        var percentage = initial
        var observations = [try MeasuredQuotaObservation(
            identity: identity,
            percentageUsed: percentage,
            observedAt: start,
            source: .codexLocalReport
        )]
        for (offset, movement) in movements.enumerated() {
            percentage += movement
            observations.append(try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: percentage,
                observedAt: start.addingTimeInterval(Double(offset + 1) * 10 * 60),
                source: .codexLocalReport
            ))
        }
        var versions: [QuotaObservationIdentity: QuotaAnomalyEvidenceVersion] = [:]
        if changingVersion, let latest = observations.last {
            versions[latest.stableIdentity] = QuotaAnomalyEvidenceVersion(
                adapter: .quotaObservationV2,
                client: .codex0145,
                providerFormat: .codexLocalReportV2
            )
            for observation in observations.dropLast() {
                versions[observation.stableIdentity] = QuotaAnomalyEvidenceVersion(
                    adapter: .quotaObservationV1,
                    client: .codex0144,
                    providerFormat: .codexLocalReportV1
                )
            }
        }
        return try QuotaAnomalyReplayFixture(
            id: id,
            condition: condition,
            observations: observations,
            evaluationTime: start.addingTimeInterval((Double(movements.count) * 10 + 1) * 60),
            maximumEvidenceAge: 5 * 60,
            expectedIdentity: identity,
            evidenceVersions: versions,
            expected: expected
        )
    }

    private static func computedFreezeDigest(_ fixtures: [QuotaAnomalyReplayFixture]) -> String {
        var data = Data(version.utf8)
        for fixture in fixtures.sorted(by: { $0.id < $1.id }) {
            append(fixture.id, to: &data)
            append(fixture.condition.rawValue, to: &data)
            append(fixture.expected.rawValue, to: &data)
            append(fixture.expectedIdentity.product.rawValue, to: &data)
            append(fixture.expectedIdentity.identifier, to: &data)
            append(fixture.expectedIdentity.resetBoundary.timeIntervalSince1970, to: &data)
            append(fixture.evaluationTime.timeIntervalSince1970, to: &data)
            append(fixture.maximumEvidenceAge, to: &data)
            for observation in fixture.observations {
                append(observation.stableIdentity.digest, to: &data)
                append(observation.observedAt.timeIntervalSince1970, to: &data)
                append(observation.percentageUsed, to: &data)
                if let version = fixture.evidenceVersions[observation.stableIdentity] {
                    append(version.adapter.rawValue, to: &data)
                    append(version.client.rawValue, to: &data)
                    append(version.providerFormat.rawValue, to: &data)
                }
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: String, to data: inout Data) {
        var count = UInt64(value.utf8.count).bigEndian
        Swift.withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(contentsOf: value.utf8)
    }

    private static func append(_ value: Double, to data: inout Data) {
        var bits = value.bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}
