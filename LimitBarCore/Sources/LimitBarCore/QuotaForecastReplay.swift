import Foundation
import CryptoKit

public enum QuotaForecastReplayError: Error, Equatable {
    case invalidFixture
    case duplicateFixtureID
    case corpusDigestMismatch
}

public enum QuotaForecastFixtureOrigin: String, Codable, CaseIterable, Equatable, Sendable {
    case synthetic
    case anonymized
    case observed
}

public enum QuotaForecastReplayPartition: String, Codable, CaseIterable, Equatable, Sendable {
    case development
    case heldOut
}

public enum QuotaForecastEvidenceCondition: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case stable
    case flat
    case bursty
    case resetExpired = "reset_expired"
    case decreasing
    case sparse
    case stale
    case exactDuplicate = "exact_duplicate"
    case outOfOrder = "out_of_order"
    case missing
    case incompatibleWindow = "incompatible_window"
    case conflictingObservations = "conflicting_observations"
}

public enum QuotaForecastOutcomeAvailability: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case exhausted
    case nonExhausting = "non_exhausting"
    case censored
}

public enum QuotaForecastObservedOutcome: Equatable, Sendable {
    case exhausted(at: Date)
    case didNotExhaustBeforeReset
    case censored
}

public struct QuotaForecastReplayFixture: Equatable, Sendable {
    public let id: String
    public let product: ProviderProduct
    public let origin: QuotaForecastFixtureOrigin
    public let partition: QuotaForecastReplayPartition
    public let evidenceCondition: QuotaForecastEvidenceCondition
    public let observations: [MeasuredQuotaObservation]
    public let evaluationTime: Date
    public let maximumEvidenceAge: TimeInterval
    public let observedOutcome: QuotaForecastObservedOutcome
    public let expectedIdentity: QuotaWindowIdentity?

    public init(
        id: String,
        product: ProviderProduct,
        origin: QuotaForecastFixtureOrigin,
        partition: QuotaForecastReplayPartition,
        evidenceCondition: QuotaForecastEvidenceCondition,
        observations: [MeasuredQuotaObservation],
        evaluationTime: Date,
        maximumEvidenceAge: TimeInterval,
        observedOutcome: QuotaForecastObservedOutcome,
        expectedIdentity: QuotaWindowIdentity? = nil
    ) throws {
        let allowedID = !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        let identities = Set(observations.map(\.identity))
        guard allowedID,
              product == .claudeCode || product == .codex,
              observations.allSatisfy({ $0.identity.product == product }),
              observations.allSatisfy({
                  ($0.identity.product == .claudeCode && $0.source == .claudeProviderReport)
                      || ($0.identity.product == .codex && $0.source == .codexLocalReport)
              }),
              expectedIdentity.map({ $0.product == product }) ?? true,
              (identities.count <= 1 || (evidenceCondition == .incompatibleWindow && observedOutcome == .censored)),
              evaluationTime.timeIntervalSince1970.isFinite,
              maximumEvidenceAge.isFinite, maximumEvidenceAge >= 0,
              observations.allSatisfy({ $0.observedAt <= evaluationTime }) else {
            throw QuotaForecastReplayError.invalidFixture
        }
        switch observedOutcome {
        case let .exhausted(at):
            guard let reset = identities.first?.resetBoundary,
                  at.timeIntervalSince1970.isFinite,
                  at >= evaluationTime, at <= reset else {
                throw QuotaForecastReplayError.invalidFixture
            }
        case .didNotExhaustBeforeReset:
            guard identities.count == 1 else { throw QuotaForecastReplayError.invalidFixture }
        case .censored:
            break
        }
        self.id = id
        self.product = product
        self.origin = origin
        self.partition = partition
        self.evidenceCondition = evidenceCondition
        self.observations = observations
        self.evaluationTime = evaluationTime
        self.maximumEvidenceAge = maximumEvidenceAge
        self.observedOutcome = observedOutcome
        self.expectedIdentity = expectedIdentity
    }
}

public struct QuotaForecastReplayMetrics: Equatable, Sendable {
    public let sampleCount: Int
    public let qualifiedCount: Int
    public let qualificationCoverage: Double?
    public let unavailableFrequency: Double?
    public let unavailableCounts: [QuotaInsightUnavailableReason: Int]
    public let observableExhaustionSampleCount: Int
    public let exhaustionIntervalCoverageCount: Int
    public let exhaustionIntervalCoverageRate: Double?
    public let exhaustionIntervalErrorsMinutes: [Double?]
    public let falseExhaustionBeforeResetCount: Int
    public let resetBoundaryViolationCount: Int
    public let nonExhaustingCount: Int
    public let censoredCount: Int
}

public struct QuotaForecastReplayComposition: Equatable, Sendable {
    public let product: ProviderProduct
    public let evidenceCondition: QuotaForecastEvidenceCondition
    public let origin: QuotaForecastFixtureOrigin
    public let sampleCount: Int
    public let observationCounts: [Int]
    public let observationSpansMinutes: [Double]
    public let cadenceMinutes: [[Double]]
    public let missingObservationSampleCount: Int
    public let quotaWindowKinds: [QuotaInsightWindowKind]
    public let minutesFromFirstObservationToReset: [Double]
    public let outcomeAvailability: [QuotaForecastOutcomeAvailability: Int]
}

public struct QuotaForecastReplaySegment: Equatable, Sendable {
    public let product: ProviderProduct
    public let evidenceCondition: QuotaForecastEvidenceCondition
    public let metrics: QuotaForecastReplayMetrics
}

public enum QuotaForecastQualityAssessmentStatus: String, Codable, Equatable, Sendable {
    case unavailableNoObservedHeldOutCompletedWindows = "unavailable_no_observed_held_out_completed_windows"
}

public enum QuotaForecastQualityThresholdStatus: String, Codable, Equatable, Sendable {
    case unavailable
}

public struct QuotaForecastReplayReport: Equatable, Sendable {
    public let method: QuotaForecastMethod
    public let developmentFixtureCount: Int
    public let heldOutFixtureIDs: [String]
    public let heldOutOriginCounts: [QuotaForecastFixtureOrigin: Int]
    public let observedHeldOutCompletedWindowCount: Int
    public let qualityAssessmentStatus: QuotaForecastQualityAssessmentStatus
    public let forecastQualityThresholdStatus: QuotaForecastQualityThresholdStatus
    public let strongerProductClaimEnabled: Bool
    public let developmentMetrics: QuotaForecastReplayMetrics
    public let algorithmReplayMetrics: QuotaForecastReplayMetrics
    public let composition: [QuotaForecastReplayComposition]
    public let segments: [QuotaForecastReplaySegment]
    public let limitations: [String]
}

public enum QuotaForecastReplayEvaluator {
    public static let documentedLimitations = [
        "The frozen corpus is synthetic and its algorithm replay metrics are not empirical forecast quality evidence.",
        "There are zero observed held-out completed windows, so forecast quality assessment and any quality threshold are unavailable.",
        "No stronger product claim is enabled.",
        "Provider weighting and capacity behavior are unknown, so provider products and evidence conditions remain separate.",
        "Censored outcomes, observation cadence, missing evidence, and provider or client changes limit interpretation.",
        "The corpus digest is a drift-review boundary, not statistical independence.",
        "Corpus membership or content changes require a corpus version or digest review before scoring.",
        "No additional conservative, balanced, or responsive forecast profiles were evaluated.",
    ]

    public static func evaluate(_ fixtures: [QuotaForecastReplayFixture]) throws -> QuotaForecastReplayReport {
        guard Set(fixtures.map(\.id)).count == fixtures.count else {
            throw QuotaForecastReplayError.duplicateFixtureID
        }
        let heldOut = fixtures.filter { $0.partition == .heldOut }.sorted { $0.id < $1.id }
        let development = fixtures.filter { $0.partition == .development }.sorted { $0.id < $1.id }
        let originCounts = Dictionary(grouping: heldOut, by: \.origin).mapValues(\.count)
        let observedCompletedCount = heldOut.count { fixture in
            guard fixture.origin == .observed else { return false }
            if case .censored = fixture.observedOutcome { return false }
            return true
        }
        struct CompositionKey: Hashable {
            let product: ProviderProduct
            let evidenceCondition: QuotaForecastEvidenceCondition
            let origin: QuotaForecastFixtureOrigin
        }
        struct SegmentKey: Hashable {
            let product: ProviderProduct
            let evidenceCondition: QuotaForecastEvidenceCondition
        }
        let compositionGroups = Dictionary(grouping: heldOut) {
            CompositionKey(product: $0.product, evidenceCondition: $0.evidenceCondition, origin: $0.origin)
        }
        let composition = compositionGroups.map {
            QuotaForecastReplayComposition(
                product: $0.key.product,
                evidenceCondition: $0.key.evidenceCondition,
                origin: $0.key.origin,
                sampleCount: $0.value.count,
                observationCounts: $0.value.map { $0.observations.count }.sorted(),
                observationSpansMinutes: $0.value.map { fixture in
                    guard let first = fixture.observations.map(\.observedAt).min(),
                          let last = fixture.observations.map(\.observedAt).max() else { return 0 }
                    return last.timeIntervalSince(first) / 60
                }.sorted(),
                cadenceMinutes: $0.value.map { fixture in
                    let dates = Array(Set(fixture.observations.map(\.observedAt))).sorted()
                    return zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) / 60 }
                }.sorted { $0.lexicographicallyPrecedes($1) },
                missingObservationSampleCount: $0.value.count(where: { $0.observations.isEmpty }),
                quotaWindowKinds: $0.value.compactMap { $0.observations.first?.identity.insightWindowKind },
                minutesFromFirstObservationToReset: $0.value.compactMap { fixture in
                    fixture.observations.map(\.observedAt).min().map {
                        fixture.observations[0].identity.resetBoundary.timeIntervalSince($0) / 60
                    }
                }.sorted(),
                outcomeAvailability: Dictionary(grouping: $0.value, by: { fixture in
                    switch fixture.observedOutcome {
                    case .exhausted: .exhausted
                    case .didNotExhaustBeforeReset: .nonExhausting
                    case .censored: .censored
                    }
                }).mapValues(\.count)
            )
        }.sorted {
            ($0.product.rawValue, $0.evidenceCondition.rawValue, $0.origin.rawValue)
                < ($1.product.rawValue, $1.evidenceCondition.rawValue, $1.origin.rawValue)
        }
        let segmentGroups = Dictionary(grouping: heldOut) {
            SegmentKey(product: $0.product, evidenceCondition: $0.evidenceCondition)
        }
        let segments = segmentGroups.map {
            QuotaForecastReplaySegment(
                product: $0.key.product,
                evidenceCondition: $0.key.evidenceCondition,
                metrics: metrics(for: $0.value)
            )
        }.sorted {
            ($0.product.rawValue, $0.evidenceCondition.rawValue)
                < ($1.product.rawValue, $1.evidenceCondition.rawValue)
        }
        return QuotaForecastReplayReport(
            method: .pairwisePositiveSlopeInterquartileV2,
            developmentFixtureCount: fixtures.count - heldOut.count,
            heldOutFixtureIDs: heldOut.map(\.id),
            heldOutOriginCounts: originCounts,
            observedHeldOutCompletedWindowCount: observedCompletedCount,
            qualityAssessmentStatus: .unavailableNoObservedHeldOutCompletedWindows,
            forecastQualityThresholdStatus: .unavailable,
            strongerProductClaimEnabled: false,
            developmentMetrics: metrics(for: development),
            algorithmReplayMetrics: metrics(for: heldOut),
            composition: composition,
            segments: segments,
            limitations: documentedLimitations
        )
    }

    private static func metrics(for fixtures: [QuotaForecastReplayFixture]) -> QuotaForecastReplayMetrics {
        var qualifiedCount = 0
        var unavailableCounts: [QuotaInsightUnavailableReason: Int] = [:]
        var observableExhaustionCount = 0
        var exhaustionCoverageCount = 0
        var intervalErrors: [Double?] = []
        var falseExhaustionCount = 0
        var resetViolationCount = 0
        var nonExhaustingCount = 0
        var censoredCount = 0

        for fixture in fixtures {
            let state = QuotaInsightAnalytics.analyze(fixture.observations, now: fixture.evaluationTime, maximumAge: fixture.maximumEvidenceAge, expectedIdentity: fixture.expectedIdentity)
            var exhaustionRange: ClosedRange<Date>?
            var resetBoundary: Date?
            switch state {
            case let .qualified(finding):
                qualifiedCount += 1
                exhaustionRange = finding.calculatedExhaustionRange
                resetBoundary = finding.identity.resetBoundary
                if let exhaustionRange, exhaustionRange.upperBound > finding.identity.resetBoundary {
                    resetViolationCount += 1
                }
            case let .unavailable(finding):
                unavailableCounts[finding.reason, default: 0] += 1
                resetBoundary = finding.implicatedIdentities.count == 1 ? finding.implicatedIdentities[0].resetBoundary : nil
            }

            switch fixture.observedOutcome {
            case let .exhausted(at):
                observableExhaustionCount += 1
                if let exhaustionRange {
                    if exhaustionRange.contains(at) {
                        exhaustionCoverageCount += 1
                        intervalErrors.append(0)
                    } else {
                        let distance = at < exhaustionRange.lowerBound
                            ? exhaustionRange.lowerBound.timeIntervalSince(at)
                            : at.timeIntervalSince(exhaustionRange.upperBound)
                        intervalErrors.append(distance / 60)
                    }
                } else {
                    intervalErrors.append(nil)
                }
            case .didNotExhaustBeforeReset:
                nonExhaustingCount += 1
                if let exhaustionRange, let resetBoundary, exhaustionRange.lowerBound < resetBoundary {
                    falseExhaustionCount += 1
                }
            case .censored:
                censoredCount += 1
            }
        }

        let sampleCount = fixtures.count
        return QuotaForecastReplayMetrics(
            sampleCount: sampleCount,
            qualifiedCount: qualifiedCount,
            qualificationCoverage: sampleCount == 0 ? nil : Double(qualifiedCount) / Double(sampleCount),
            unavailableFrequency: sampleCount == 0 ? nil : Double(sampleCount - qualifiedCount) / Double(sampleCount),
            unavailableCounts: unavailableCounts,
            observableExhaustionSampleCount: observableExhaustionCount,
            exhaustionIntervalCoverageCount: exhaustionCoverageCount,
            exhaustionIntervalCoverageRate: observableExhaustionCount == 0 ? nil : Double(exhaustionCoverageCount) / Double(observableExhaustionCount),
            exhaustionIntervalErrorsMinutes: intervalErrors.sorted {
                switch ($0, $1) {
                case let (left?, right?): left < right
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): false
                }
            },
            falseExhaustionBeforeResetCount: falseExhaustionCount,
            resetBoundaryViolationCount: resetViolationCount,
            nonExhaustingCount: nonExhaustingCount,
            censoredCount: censoredCount
        )
    }
}

public enum QuotaForecastFrozenCorpus {
    public static let version = "quota_forecast_corpus_v1"
    public static let freezeDigest = "45288bb930da7b86f07cf27a9d9b197994b35f9eaf460bffd211de5ec1d07acb"

    public static func validatedFixtures() throws -> [QuotaForecastReplayFixture] {
        let fixtures = try makeFixtures()
        guard computedFreezeDigest(fixtures) == freezeDigest else {
            throw QuotaForecastReplayError.corpusDigestMismatch
        }
        return fixtures
    }

    public static func computedFreezeDigest() throws -> String {
        computedFreezeDigest(try makeFixtures())
    }

    private static func makeFixtures() throws -> [QuotaForecastReplayFixture] {
        try [
            fixture(id: "development-claude-stable-01", index: 0, product: .claudeCode, partition: .development, condition: .stable, values: [(0, 20), (10, 22), (20, 24), (30, 26)], resetMinute: 240, evaluationMinute: 31, outcome: .censored),
            fixture(id: "development-codex-bursty-01", index: 1, product: .codex, partition: .development, condition: .bursty, values: [(0, 10), (10, 11), (20, 15), (30, 30)], resetMinute: 300, evaluationMinute: 31, outcome: .censored),
            fixture(id: "heldout-codex-stable-01", index: 2, product: .codex, condition: .stable, values: [(0, 70), (10, 72), (20, 74), (30, 76)], resetMinute: 240, evaluationMinute: 31, outcomeMinute: 150),
            fixture(id: "heldout-claude-bursty-01", index: 3, product: .claudeCode, condition: .bursty, values: [(0, 20), (10, 21), (20, 25), (30, 40)], resetMinute: 300, evaluationMinute: 31, outcomeMinute: 120),
            fixture(id: "heldout-claude-flat-01", index: 4, product: .claudeCode, condition: .flat, values: [(0, 20), (10, 20), (20, 20), (30, 20)], resetMinute: 240, evaluationMinute: 31, outcome: .didNotExhaustBeforeReset),
            fixture(id: "heldout-codex-expired-01", index: 5, product: .codex, condition: .resetExpired, values: [(0, 20), (10, 22), (20, 24), (30, 26)], resetMinute: 30, evaluationMinute: 31, outcome: .didNotExhaustBeforeReset),
            fixture(id: "heldout-claude-decreasing-01", index: 6, product: .claudeCode, condition: .decreasing, values: [(0, 20), (10, 24), (20, 22), (30, 25)], resetMinute: 240, evaluationMinute: 31, outcome: .censored),
            fixture(id: "heldout-codex-sparse-01", index: 7, product: .codex, condition: .sparse, values: [(0, 20), (20, 25)], resetMinute: 240, evaluationMinute: 21, outcome: .censored),
            fixture(id: "heldout-claude-stale-01", index: 8, product: .claudeCode, condition: .stale, values: [(0, 20), (10, 22), (20, 24), (30, 26)], resetMinute: 240, evaluationMinute: 60, maximumAge: 600, outcome: .censored),
            fixture(id: "heldout-codex-duplicate-01", index: 9, product: .codex, condition: .exactDuplicate, values: [(0, 70), (10, 72), (10, 72), (20, 74), (30, 76)], resetMinute: 240, evaluationMinute: 31, outcomeMinute: 180),
            fixture(id: "heldout-claude-out-of-order-01", index: 10, product: .claudeCode, condition: .outOfOrder, values: [(30, 13), (10, 11), (20, 12), (0, 10)], resetMinute: 240, evaluationMinute: 31, outcome: .didNotExhaustBeforeReset),
            fixture(id: "heldout-codex-missing-01", index: 11, product: .codex, condition: .missing, values: [], resetMinute: 240, evaluationMinute: 31, outcome: .censored),
            fixture(id: "heldout-claude-incompatible-01", index: 12, product: .claudeCode, condition: .incompatibleWindow, values: [(0, 20)], resetMinute: 240, evaluationMinute: 31, outcome: .censored, incompatibleResetMinute: 300),
            fixture(id: "heldout-codex-conflicting-01", index: 13, product: .codex, condition: .conflictingObservations, values: [(0, 20), (10, 22), (20, 24), (30, 26)], resetMinute: 240, evaluationMinute: 31, outcome: .censored, conflictingPercentAtMinute: (10, 23)),
        ]
    }

    private static func fixture(
        id: String,
        index: Int,
        product: ProviderProduct,
        partition: QuotaForecastReplayPartition = .heldOut,
        condition: QuotaForecastEvidenceCondition,
        values: [(Double, Double)],
        resetMinute: Double,
        evaluationMinute: Double,
        maximumAge: TimeInterval = 600,
        outcomeMinute: Double? = nil,
        outcome: QuotaForecastObservedOutcome? = nil,
        incompatibleResetMinute: Double? = nil,
        conflictingPercentAtMinute: (Double, Double)? = nil
    ) throws -> QuotaForecastReplayFixture {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 86_400)
        let reset = start.addingTimeInterval(resetMinute * 60)
        let identity = try QuotaWindowIdentity(
            product: product,
            identifier: product == .claudeCode ? "session:session" : "primary:300",
            resetBoundary: reset
        )
        let source: QuotaObservationSource = product == .claudeCode ? .claudeProviderReport : .codexLocalReport
        var observations = try values.map { minute, percent in
            try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: percent,
                observedAt: start.addingTimeInterval(minute * 60),
                source: source
            )
        }
        if let incompatibleResetMinute {
            let otherIdentity = try QuotaWindowIdentity(
                product: product,
                identifier: product == .claudeCode ? "session:session" : "primary:300",
                resetBoundary: start.addingTimeInterval(incompatibleResetMinute * 60)
            )
            observations.append(try MeasuredQuotaObservation(identity: otherIdentity, percentageUsed: 21, observedAt: start.addingTimeInterval(10 * 60), source: source))
        }
        if let conflictingPercentAtMinute {
            observations.append(try MeasuredQuotaObservation(identity: identity, percentageUsed: conflictingPercentAtMinute.1, observedAt: start.addingTimeInterval(conflictingPercentAtMinute.0 * 60), source: source))
        }
        let observedOutcome = outcomeMinute.map { .exhausted(at: start.addingTimeInterval($0 * 60)) }
            ?? outcome ?? .censored
        return try QuotaForecastReplayFixture(
            id: id,
            product: product,
            origin: .synthetic,
            partition: partition,
            evidenceCondition: condition,
            observations: observations,
            evaluationTime: start.addingTimeInterval(evaluationMinute * 60),
            maximumEvidenceAge: maximumAge,
            observedOutcome: observedOutcome,
            expectedIdentity: identity
        )
    }

    private static func computedFreezeDigest(_ fixtures: [QuotaForecastReplayFixture]) -> String {
        var data = Data()
        data.appendField(version)
        data.appendField(QuotaForecastMethod.pairwisePositiveSlopeInterquartileV2.rawValue)
        for fixture in fixtures.sorted(by: { $0.id < $1.id }) {
            data.appendField(fixture.id)
            data.appendField(fixture.partition.rawValue)
            data.appendField(fixture.product.rawValue)
            data.appendField(fixture.origin.rawValue)
            data.appendField(fixture.evidenceCondition.rawValue)
            data.appendCanonical(fixture.evaluationTime.timeIntervalSince1970)
            data.appendCanonical(fixture.maximumEvidenceAge)
            if let expected = fixture.expectedIdentity {
                data.appendField(expected.product.rawValue)
                data.appendField(expected.identifier)
                data.appendCanonical(expected.resetBoundary.timeIntervalSince1970)
            } else {
                data.appendField("")
            }
            for observation in fixture.observations {
                data.appendField(observation.identity.product.rawValue)
                data.appendField(observation.identity.identifier.precomposedStringWithCanonicalMapping)
                data.appendCanonical(observation.identity.resetBoundary.timeIntervalSince1970)
                data.appendCanonical(observation.observedAt.timeIntervalSince1970)
                data.appendCanonical(observation.percentageUsed)
                data.appendField(observation.source.rawValue)
                data.appendField(observation.normalizationVersion.rawValue)
                data.appendField(observation.interpretationVersion.rawValue)
            }
            switch fixture.observedOutcome {
            case let .exhausted(at):
                data.appendField("exhausted")
                data.appendCanonical(at.timeIntervalSince1970)
            case .didNotExhaustBeforeReset:
                data.appendField("did_not_exhaust_before_reset")
            case .censored:
                data.appendField("censored")
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum QuotaForecastReplayMarkdown {
    public static func render(_ report: QuotaForecastReplayReport) -> String {
        let metrics = report.algorithmReplayMetrics
        let development = report.developmentMetrics
        let unavailable = metrics.unavailableCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "- `\($0.key.rawValue)`: \($0.value)" }
            .joined(separator: "\n")
        let composition = report.composition.map {
            let counts = $0.observationCounts.map(String.init).joined(separator: ",")
            let spans = $0.observationSpansMinutes.map { String(format: "%.0f", $0) }.joined(separator: ",")
            let cadence = $0.cadenceMinutes.map { $0.map { String(format: "%.0f", $0) }.joined(separator: ",") }.joined(separator: ";")
            let windows = $0.quotaWindowKinds.map(String.init(describing:)).joined(separator: ",")
            let resetHorizons = $0.minutesFromFirstObservationToReset.map { String(format: "%.0f", $0) }.joined(separator: ",")
            let outcomes = $0.outcomeAvailability.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ",")
            return "- \($0.product.displayName), `\($0.evidenceCondition.rawValue)`, `\($0.origin.rawValue)`: \($0.sampleCount); observation counts [\(counts)]; spans [\(spans)] minutes; cadence [\(cadence)] minutes; missing \($0.missingObservationSampleCount); windows [\(windows)]; first-observation-to-reset [\(resetHorizons)] minutes; outcomes [\(outcomes)]"
        }.joined(separator: "\n")
        let segments = report.segments.map {
            let value = $0.metrics
            let unavailable = value.unavailableCounts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ",")
            let errors = formatErrors(value.exhaustionIntervalErrorsMinutes)
            return "- \($0.product.displayName), `\($0.evidenceCondition.rawValue)`: \(value.qualifiedCount)/\(value.sampleCount) qualified (\(percent(value.qualificationCoverage))); unavailable \(percent(value.unavailableFrequency)) [\(unavailable)]; interval coverage \(value.exhaustionIntervalCoverageCount)/\(value.observableExhaustionSampleCount) (\(percent(value.exhaustionIntervalCoverageRate))); errors [\(errors)]; false projections \(value.falseExhaustionBeforeResetCount); reset violations \(value.resetBoundaryViolationCount); non-exhausting \(value.nonExhaustingCount); censored \(value.censoredCount)"
        }.joined(separator: "\n")
        let errors = formatErrors(metrics.exhaustionIntervalErrorsMinutes)
        let limitations = report.limitations.map { "- \($0)" }.joined(separator: "\n")
        let origins = report.heldOutOriginCounts.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")

        return """
        # Quota Forecast Frozen Synthetic Replay Baseline

        Method: `\(report.method.rawValue)`
        Corpus: `\(QuotaForecastFrozenCorpus.version)`
        Freeze digest: `\(QuotaForecastFrozenCorpus.freezeDigest)`

        This report records deterministic algorithm replay behavior from the checked-in synthetic corpus.
        It is not empirical forecast quality validation and does not relabel calculated output as provider-reported information.

        ## Quality Assessment

        - Observed held-out completed windows: \(report.observedHeldOutCompletedWindowCount)
        - Quality assessment: `\(report.qualityAssessmentStatus.rawValue)`
        - Forecast quality threshold: `\(report.forecastQualityThresholdStatus.rawValue)`
        - Stronger product claim enabled: \(report.strongerProductClaimEnabled)

        ## Partition

        - Development fixtures excluded from scoring: \(report.developmentFixtureCount)
        - Held-out fixtures: \(metrics.sampleCount)
        - Held-out origins: \(origins)

        ## Development Algorithm Replay Metrics

        - Development qualification coverage: \(development.qualifiedCount)/\(development.sampleCount) (\(percent(development.qualificationCoverage)))
        - Development unavailable frequency: \(development.sampleCount - development.qualifiedCount)/\(development.sampleCount) (\(percent(development.unavailableFrequency)))
        - Development observable exhaustion samples: \(development.observableExhaustionSampleCount)
        - Development interval coverage: \(development.exhaustionIntervalCoverageCount)/\(development.observableExhaustionSampleCount) (\(percent(development.exhaustionIntervalCoverageRate)))
        - Development interval errors: \(formatErrors(development.exhaustionIntervalErrorsMinutes))
        - Development false projections: \(development.falseExhaustionBeforeResetCount)
        - Development reset violations: \(development.resetBoundaryViolationCount)
        - Development non-exhausting outcomes: \(development.nonExhaustingCount)
        - Development censored outcomes: \(development.censoredCount)

        ## Synthetic Algorithm Replay Metrics

        - Qualification coverage: \(metrics.qualifiedCount)/\(metrics.sampleCount) (\(percent(metrics.qualificationCoverage)))
        - Unavailable frequency: \(metrics.sampleCount - metrics.qualifiedCount)/\(metrics.sampleCount) (\(percent(metrics.unavailableFrequency)))
        - Observable exhaustion samples: \(metrics.observableExhaustionSampleCount)
        - Exhaustion interval coverage: \(metrics.exhaustionIntervalCoverageCount)/\(metrics.observableExhaustionSampleCount) (\(percent(metrics.exhaustionIntervalCoverageRate)))
        - Observable exhaustion interval errors: \(errors)
        - False exhaustion-before-reset projections: \(metrics.falseExhaustionBeforeResetCount)
        - Reset-boundary violations: \(metrics.resetBoundaryViolationCount)
        - Non-exhausting outcomes: \(metrics.nonExhaustingCount)
        - Censored outcomes: \(metrics.censoredCount)

        ### Unavailable Outcomes

        \(unavailable)

        ## Fixture Composition

        \(composition)

        ## Provider and evidence-condition segments

        \(segments)

        ## Limitations

        \(limitations)
        """ + "\n"
    }

    private static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "not applicable"
    }

    private static func formatErrors(_ values: [Double?]) -> String {
        guard !values.isEmpty else { return "none" }
        return values.map { $0.map { String(format: "%.1f minutes", $0) } ?? "not available" }.joined(separator: ", ")
    }
}

private extension Data {
    mutating func appendField(_ value: String) {
        let bytes = Data(value.utf8)
        var count = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &count) { append(contentsOf: $0) }
        append(bytes)
    }

    mutating func appendCanonical(_ value: Double) {
        var bits = (value == 0 ? 0 : value).bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }
}
