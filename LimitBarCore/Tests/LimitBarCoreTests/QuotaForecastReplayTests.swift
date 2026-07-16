import Foundation
import Testing
@testable import LimitBarCore

@Suite("Quota forecast replay")
struct QuotaForecastReplayTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("fixture validation rejects unsafe identities and duplicate membership while development fixtures are never scored")
    func fixtureValidationAndPartitionSeparation() throws {
        #expect(throws: QuotaForecastReplayError.invalidFixture) {
            try fixture(id: "Private Account/one", partition: .heldOut)
        }

        let development = try fixture(id: "development-stable-01", partition: .development)
        let heldOut = try fixture(id: "heldout-stable-01", partition: .heldOut)
        #expect(throws: QuotaForecastReplayError.duplicateFixtureID) {
            try QuotaForecastReplayEvaluator.evaluate([development, heldOut, heldOut])
        }

        let report = try QuotaForecastReplayEvaluator.evaluate([development, heldOut])
        #expect(report.developmentFixtureCount == 1)
        #expect(report.algorithmReplayMetrics.sampleCount == 1)
        #expect(report.heldOutFixtureIDs == ["heldout-stable-01"])
        #expect(!report.heldOutFixtureIDs.contains("development-stable-01"))
        #expect(report.method == .pairwisePositiveSlopeInterquartileV2)
    }

    @Test("fixtures reject inconsistent windows and impossible temporal outcomes while empty censored evidence remains valid")
    func fixtureTemporalValidity() throws {
        let first = try observations(reset: base.addingTimeInterval(4 * 3_600))
        let second = try observations(reset: base.addingTimeInterval(5 * 3_600))
        let evaluation = base.addingTimeInterval(31 * 60)

        #expect(throws: QuotaForecastReplayError.invalidFixture) {
            try replayFixture(observations: [first[0], second[1]], evaluationTime: evaluation, outcome: .censored)
        }
        let incompatible = try replayFixture(observations: [first[0], second[1]], evaluationTime: evaluation, outcome: .censored, condition: .incompatibleWindow)
        #expect(QuotaInsightAnalytics.analyze(incompatible.observations, now: evaluation, maximumAge: 600).unavailableReason == .incompatibleEvidence)
        #expect(throws: QuotaForecastReplayError.invalidFixture) {
            try replayFixture(observations: first + [try measuredQuotaObservation(base: base, identity: first[0].identity, minute: 32, percent: 78)], evaluationTime: evaluation, outcome: .censored)
        }
        #expect(throws: QuotaForecastReplayError.invalidFixture) {
            try replayFixture(observations: first, evaluationTime: evaluation, outcome: .exhausted(at: evaluation.addingTimeInterval(-1)))
        }
        #expect(throws: QuotaForecastReplayError.invalidFixture) {
            try replayFixture(observations: first, evaluationTime: evaluation, outcome: .exhausted(at: first[0].identity.resetBoundary.addingTimeInterval(1)))
        }
        #expect(throws: QuotaForecastReplayError.invalidFixture) {
            try replayFixture(observations: [], evaluationTime: evaluation, outcome: .didNotExhaustBeforeReset)
        }

        let empty = try replayFixture(observations: [], evaluationTime: evaluation, outcome: .censored, expectedIdentity: first[0].identity)
        #expect(empty.observations.isEmpty)
    }

    @Test("frozen synthetic replay matches literal expected metrics without dropping unavailable or censored outcomes")
    func frozenHeldOutMetrics() throws {
        let computedDigest = try QuotaForecastFrozenCorpus.computedFreezeDigest()
        #expect(computedDigest == "45288bb930da7b86f07cf27a9d9b197994b35f9eaf460bffd211de5ec1d07acb")
        let fixtures = try QuotaForecastFrozenCorpus.validatedFixtures()
        let report = try QuotaForecastReplayEvaluator.evaluate(fixtures)
        let reversedReport = try QuotaForecastReplayEvaluator.evaluate(fixtures.reversed())
        let metrics = report.algorithmReplayMetrics

        #expect(report == reversedReport)
        #expect(QuotaForecastFrozenCorpus.version == "quota_forecast_corpus_v1")
        #expect(report.developmentFixtureCount == 2)
        #expect(report.heldOutOriginCounts == [.synthetic: 12])
        #expect(report.observedHeldOutCompletedWindowCount == 0)
        #expect(report.qualityAssessmentStatus == .unavailableNoObservedHeldOutCompletedWindows)
        #expect(report.forecastQualityThresholdStatus == .unavailable)
        #expect(report.strongerProductClaimEnabled == false)
        #expect(report.developmentMetrics.sampleCount == 2)
        #expect(report.developmentMetrics.qualifiedCount == 2)
        #expect(report.developmentMetrics.qualificationCoverage == 1)
        #expect(report.developmentMetrics.unavailableFrequency == 0)
        #expect(report.developmentMetrics.unavailableCounts.isEmpty)
        #expect(report.developmentMetrics.observableExhaustionSampleCount == 0)
        #expect(report.developmentMetrics.exhaustionIntervalCoverageRate == nil)
        #expect(report.developmentMetrics.exhaustionIntervalErrorsMinutes.isEmpty)
        #expect(report.developmentMetrics.falseExhaustionBeforeResetCount == 0)
        #expect(report.developmentMetrics.resetBoundaryViolationCount == 0)
        #expect(report.developmentMetrics.nonExhaustingCount == 0)
        #expect(report.developmentMetrics.censoredCount == 2)
        #expect(metrics.sampleCount == 12)
        #expect(metrics.qualifiedCount == 4)
        #expect(metrics.qualificationCoverage == 1.0 / 3.0)
        #expect(metrics.unavailableFrequency == 2.0 / 3.0)
        #expect(metrics.unavailableCounts == [
            .insufficientObservations: 2,
            .staleEvidence: 1,
            .resetOrExpired: 1,
            .counterDecreased: 1,
            .noPositiveBurn: 1,
            .incompatibleEvidence: 1,
            .conflictingObservations: 1,
        ])
        #expect(Set(fixtures.filter { $0.partition == .heldOut }.map(\.evidenceCondition)) == Set(QuotaForecastEvidenceCondition.allCases))
        let incompatible = try #require(fixtures.first { $0.evidenceCondition == .incompatibleWindow })
        #expect(Set(incompatible.observations.map(\.identity)).count == 2)
        let conflicting = try #require(fixtures.first { $0.evidenceCondition == .conflictingObservations })
        #expect(Set(conflicting.observations.map(\.observedAt)).count < conflicting.observations.count)
        #expect(metrics.observableExhaustionSampleCount == 3)
        #expect(metrics.exhaustionIntervalCoverageCount == 2)
        #expect(metrics.exhaustionIntervalCoverageRate == 2.0 / 3.0)
        #expect(metrics.exhaustionIntervalErrorsMinutes == [0, 0, 30])
        #expect(metrics.falseExhaustionBeforeResetCount == 0)
        #expect(metrics.resetBoundaryViolationCount == 0)
        #expect(metrics.nonExhaustingCount == 3)
        #expect(metrics.censoredCount == 6)

        #expect(report.composition.map(\.sampleCount).reduce(0, +) == 12)
        #expect(report.composition.filter { $0.product == .claudeCode }.map(\.sampleCount).reduce(0, +) == 6)
        #expect(report.composition.filter { $0.product == .codex }.map(\.sampleCount).reduce(0, +) == 6)
        let missing = try #require(report.composition.first { $0.evidenceCondition == .missing })
        #expect(missing.observationCounts == [0])
        #expect(missing.observationSpansMinutes == [0])
        #expect(missing.missingObservationSampleCount == 1)
        let missingFixture = try #require(fixtures.first { $0.evidenceCondition == .missing })
        let expectedIdentity = try #require(missingFixture.expectedIdentity)
        #expect(QuotaInsightAnalytics.analyze(missingFixture.observations, now: missingFixture.evaluationTime, maximumAge: missingFixture.maximumEvidenceAge, expectedIdentity: expectedIdentity).unavailableIdentities == [expectedIdentity])
        let sparse = try #require(report.composition.first { $0.evidenceCondition == .sparse })
        #expect(sparse.cadenceMinutes == [[20]])
        #expect(sparse.outcomeAvailability == [.censored: 1])
        #expect(report.segments.count == 12)
        #expect(report.segments.allSatisfy { $0.metrics.sampleCount > 0 })
        #expect(report.segments.allSatisfy { $0.metrics.qualificationCoverage != nil && $0.metrics.unavailableFrequency != nil })
        #expect(report.limitations == QuotaForecastReplayEvaluator.documentedLimitations)

        let prohibited = ["prompt", "response", "credential", "account", "/Users/", "payload", "terminal"]
        let fixtureIDs = fixtures.map(\.id).joined(separator: " ").lowercased()
        for sentinel in prohibited {
            #expect(!fixtureIDs.contains(sentinel.lowercased()))
        }
    }

    @Test("evaluation report is deterministic, segmented, conservative, and privacy-safe")
    func markdownReport() throws {
        let report = try QuotaForecastReplayEvaluator.evaluate(QuotaForecastFrozenCorpus.validatedFixtures())
        let markdown = QuotaForecastReplayMarkdown.render(report)

        #expect(markdown == QuotaForecastReplayMarkdown.render(report))
        #expect(markdown.contains("Method: `pairwise_positive_slope_interquartile_v2`"))
        #expect(markdown.contains("# Quota Forecast Frozen Synthetic Replay Baseline"))
        #expect(markdown.contains("Observed held-out completed windows: 0"))
        #expect(markdown.contains("Quality assessment: `unavailable_no_observed_held_out_completed_windows`"))
        #expect(markdown.contains("Forecast quality threshold: `unavailable`"))
        #expect(markdown.contains("Stronger product claim enabled: false"))
        #expect(markdown.contains("Held-out origins: synthetic=12"))
        #expect(markdown.contains("## Synthetic Algorithm Replay Metrics"))
        #expect(markdown.contains("## Development Algorithm Replay Metrics"))
        #expect(markdown.contains("Development qualification coverage: 2/2 (100.0%)"))
        #expect(markdown.contains("Development censored outcomes: 2"))
        #expect(markdown.contains("Held-out fixtures: 12"))
        #expect(markdown.contains("Qualification coverage: 4/12 (33.3%)"))
        #expect(markdown.contains("Unavailable frequency: 8/12 (66.7%)"))
        #expect(markdown.contains("Exhaustion interval coverage: 2/3 (66.7%)"))
        #expect(markdown.contains("Observable exhaustion interval errors: 0.0 minutes, 0.0 minutes, 30.0 minutes"))
        #expect(markdown.contains("## Provider and evidence-condition segments"))
        #expect(markdown.contains("not empirical forecast quality evidence"))
        #expect(!markdown.lowercased().contains("private"))
        #expect(!markdown.contains("/Users/"))
        #expect(!markdown.lowercased().contains("prompt"))
    }

    @Test("fixtures findings reports diagnostics and technical artifacts exclude prohibited content and local digests")
    func completePrivacyBoundary() throws {
        let fixtures = try QuotaForecastFrozenCorpus.validatedFixtures()
        let report = try QuotaForecastReplayEvaluator.evaluate(fixtures)
        let markdown = QuotaForecastReplayMarkdown.render(report)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let methodDocument = try String(contentsOf: root.appendingPathComponent("docs/QUOTA_FORECAST_METHOD_V2.md"), encoding: .utf8)
        let reportDocument = try String(contentsOf: root.appendingPathComponent("docs/QUOTA_FORECAST_EVALUATION.md"), encoding: .utf8)
        let fixtureText = fixtures.flatMap { fixture in
            [fixture.id, fixture.product.rawValue, fixture.origin.rawValue, fixture.partition.rawValue, fixture.evidenceCondition.rawValue]
                + fixture.observations.flatMap { observation in
                    [observation.identity.identifier, observation.source.rawValue, observation.normalizationVersion.rawValue, observation.interpretationVersion.rawValue]
                }
        }.joined(separator: "\n")
        let qualifiedFixture = try #require(fixtures.first { $0.id == "heldout-codex-stable-01" })
        let state = QuotaInsightAnalytics.analyze(qualifiedFixture.observations, now: qualifiedFixture.evaluationTime, maximumAge: qualifiedFixture.maximumEvidenceAge)
        guard case let .qualified(finding) = state else {
            Issue.record("Expected qualified fixture")
            return
        }
        let diagnostic = try DiagnosticExport.make(from: DiagnosticExportInput(
            generatedAt: qualifiedFixture.evaluationTime,
            appVersion: DiagnosticVersion(major: 1, minor: 0, patch: 0),
            appBuild: 1,
            operatingSystemVersion: DiagnosticVersion(major: 15, minor: 0, patch: 0),
            providerStatuses: [],
            databaseState: .available,
            importCounts: DiagnosticImportCounts(accepted: 0, rejected: 0),
            resourceLimitReasons: [],
            quotaFindings: [try DiagnosticQuotaFinding(
                product: .codex,
                windowKind: .session,
                status: .qualified,
                qualification: .qualified,
                measuredObservationCount: finding.measuredObservationCount,
                measuredSpanMinutes: Int(finding.measuredSpan / 60),
                forecastMethod: .pairwisePositiveSlopeInterquartileV2,
                calculatedBurnPercentPerHour: DiagnosticNumberRange(lower: finding.calculatedBurnPercentPerHour.lower, upper: finding.calculatedBurnPercentPerHour.upper)
            )]
        )).preview
        let inspected = [fixtureText, markdown, methodDocument, reportDocument, diagnostic]
        let prohibited = ["PROMPT_SECRET", "MODEL_RESPONSE", "TERMINAL_OUTPUT", "CREDENTIAL_SECRET", "/Users/private/work", "ACCOUNT_LABEL", "PROJECT_LABEL", "RAW_PROVIDER_PAYLOAD"]
        for text in inspected {
            for sentinel in prohibited { #expect(!text.contains(sentinel)) }
        }
        for identity in finding.inputObservationIdentities {
            #expect(identity.digest.count == 64)
            #expect(!diagnostic.contains(identity.digest))
            #expect(!markdown.contains(identity.digest))
        }
    }

    @Test("checked-in evaluation artifact exactly matches the frozen renderer")
    func checkedInArtifactMatchesRenderer() throws {
        let report = try QuotaForecastReplayEvaluator.evaluate(QuotaForecastFrozenCorpus.validatedFixtures())
        let generated = Data(QuotaForecastReplayMarkdown.render(report).utf8)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let checkedIn = try Data(contentsOf: root.appendingPathComponent("docs/QUOTA_FORECAST_EVALUATION.md"))
        #expect(generated == checkedIn)
    }

    private func fixture(id: String, partition: QuotaForecastReplayPartition) throws -> QuotaForecastReplayFixture {
        let reset = base.addingTimeInterval(4 * 3_600)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: reset)
        let observations = try zip([0.0, 10, 20, 30], [70.0, 72, 74, 76]).map { minute, percent in
            try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: percent,
                observedAt: base.addingTimeInterval(minute * 60),
                source: .codexLocalReport
            )
        }
        return try QuotaForecastReplayFixture(
            id: id,
            product: .codex,
            origin: .synthetic,
            partition: partition,
            evidenceCondition: .stable,
            observations: observations,
            evaluationTime: base.addingTimeInterval(31 * 60),
            maximumEvidenceAge: 600,
            observedOutcome: .censored,
            expectedIdentity: identity
        )
    }

    private func observations(reset: Date) throws -> [MeasuredQuotaObservation] {
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: reset)
        return try zip([0.0, 10, 20, 30], [70.0, 72, 74, 76]).map {
            try measuredQuotaObservation(base: base, identity: identity, minute: $0.0, percent: $0.1)
        }
    }

    private func replayFixture(
        observations: [MeasuredQuotaObservation],
        evaluationTime: Date,
        outcome: QuotaForecastObservedOutcome,
        condition: QuotaForecastEvidenceCondition = .stable,
        expectedIdentity: QuotaWindowIdentity? = nil
    ) throws -> QuotaForecastReplayFixture {
        try QuotaForecastReplayFixture(
            id: "heldout-validation-01",
            product: .codex,
            origin: .synthetic,
            partition: .heldOut,
            evidenceCondition: condition,
            observations: observations,
            evaluationTime: evaluationTime,
            maximumEvidenceAge: 600,
            observedOutcome: outcome,
            expectedIdentity: expectedIdentity ?? observations.first?.identity
        )
    }
}

func measuredQuotaObservation(
    base: Date,
    identity: QuotaWindowIdentity,
    minute: Double,
    percent: Double
) throws -> MeasuredQuotaObservation {
    try MeasuredQuotaObservation(
        identity: identity,
        percentageUsed: percent,
        observedAt: base.addingTimeInterval(minute * 60),
        source: .codexLocalReport
    )
}

private extension QuotaInsightState {
    var unavailableReason: QuotaInsightUnavailableReason? {
        guard case let .unavailable(finding) = self else { return nil }
        return finding.reason
    }


    var unavailableIdentities: [QuotaWindowIdentity]? {
        guard case let .unavailable(finding) = self else { return nil }
        return finding.implicatedIdentities
    }
}
