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
    case unavailable
}

public struct QuotaAnomalyReplayFixture: Equatable, Sendable {
    public let id: String
    public let condition: QuotaAnomalyFixtureCondition
    public let movements: [Double]
    public let expected: QuotaAnomalyExpectedOutcome

    public init(id: String, condition: QuotaAnomalyFixtureCondition, movements: [Double], expected: QuotaAnomalyExpectedOutcome) throws {
        let allowedID = !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        guard allowedID,
              movements.allSatisfy({ $0.isFinite && $0 >= 0 }),
              (movements.count == 6 || (movements.isEmpty && expected == .unavailable)) else {
            throw QuotaAnomalyReplayError.invalidFixture
        }
        self.id = id
        self.condition = condition
        self.movements = movements
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
        guard fixture.movements.count == 6 else { return .unavailable }
        let baseline = Array(fixture.movements.prefix(5)).sorted()
        let current = fixture.movements[5]
        let median = baseline[2]
        switch method {
        case .trailingMedianRatio:
            if median == 0 { return current == 0 ? .noFinding : .unavailable }
            return current / median >= threshold ? .higherFinding : .noFinding
        case .medianAbsoluteDeviation:
            let deviations = baseline.map { abs($0 - median) }.sorted()
            let dispersion = deviations[2]
            if dispersion == 0 { return current == median ? .noFinding : .unavailable }
            let score = 0.6745 * (current - median) / dispersion
            return score >= threshold ? .higherFinding : .noFinding
        }
    }
}

public enum QuotaAnomalyFrozenCorpus {
    public static let version = "quota_anomaly_corpus_v1"
    public static let freezeDigest = "3b0d7641e652b5c2ddeaf612ca05dfe56ea424ebd8d057c684ca029fe5f3dcab"

    public static func validatedFixtures() throws -> [QuotaAnomalyReplayFixture] {
        let fixtures = try makeFixtures().sorted { $0.id < $1.id }
        guard computedFreezeDigest(fixtures) == freezeDigest else { throw QuotaAnomalyReplayError.corpusDigestMismatch }
        return fixtures
    }

    public static func computedFreezeDigest() throws -> String {
        computedFreezeDigest(try makeFixtures())
    }

    private static func makeFixtures() throws -> [QuotaAnomalyReplayFixture] {
        try [
            QuotaAnomalyReplayFixture(id: "bursty-01", condition: .bursty, movements: [2, 2, 2, 2, 2, 6.4], expected: .higherFinding),
            QuotaAnomalyReplayFixture(id: "changing-version-01", condition: .changingVersion, movements: [], expected: .unavailable),
            QuotaAnomalyReplayFixture(id: "flat-01", condition: .flat, movements: [2, 2, 2, 2, 2, 2], expected: .noFinding),
            QuotaAnomalyReplayFixture(id: "gradual-01", condition: .gradual, movements: [1, 1.2, 1.4, 1.6, 1.8, 2], expected: .noFinding),
            QuotaAnomalyReplayFixture(id: "mixed-intensity-01", condition: .mixedIntensity, movements: [1, 5, 1, 5, 1, 2], expected: .noFinding),
            QuotaAnomalyReplayFixture(id: "observed-zero-01", condition: .observedZero, movements: [0, 0, 0, 0, 0, 0], expected: .noFinding),
            QuotaAnomalyReplayFixture(id: "reset-01", condition: .reset, movements: [], expected: .unavailable),
            QuotaAnomalyReplayFixture(id: "sparse-01", condition: .sparse, movements: [], expected: .unavailable),
            QuotaAnomalyReplayFixture(id: "stable-01", condition: .stable, movements: [1, 1.1, 0.9, 1, 1, 1.1], expected: .noFinding),
        ]
    }

    private static func computedFreezeDigest(_ fixtures: [QuotaAnomalyReplayFixture]) -> String {
        var data = Data(version.utf8)
        for fixture in fixtures.sorted(by: { $0.id < $1.id }) {
            for value in [fixture.id, fixture.condition.rawValue, fixture.expected.rawValue] {
                var count = UInt64(value.utf8.count).bigEndian
                Swift.withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
                data.append(contentsOf: value.utf8)
            }
            for movement in fixture.movements {
                var bits = movement.bitPattern.bigEndian
                Swift.withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
