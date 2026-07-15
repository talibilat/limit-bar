import XCTest
import LimitBarCore
@testable import LimitBar

final class ForensicInvestigationPresentationTests: XCTestCase {
    func testUnavailableForecastPreservesReasonMethodAndEvidenceMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: now.addingTimeInterval(3_600))
        let state = QuotaInsightAnalytics.analyze([], now: now, maximumAge: 300, expectedIdentity: identity)

        let presentation = ForensicInvestigationPresentation.forecast(state)

        XCTAssertTrue(presentation.summary.contains("Unavailable"))
        XCTAssertTrue(presentation.details.contains("insufficient_observations"))
        XCTAssertTrue(presentation.details.contains("pairwise_positive_slope_interquartile_v2"))
        XCTAssertTrue(presentation.details.contains("0 Measured observations"))
        XCTAssertFalse(presentation.summary.contains("exhaust"))
    }

    func testAnomalyObservedZeroIsDistinctFromGapAndNoFinding() throws {
        let fixture = try anomalyFixture(values: [0, 0, 0, 0, 0, 0, 0])
        let observedZero = QuotaAnomalyAnalytics.analyze(fixture.observations, now: fixture.now, maximumAge: 300)
        let gap = QuotaAnomalyAnalytics.analyze(fixture.observations, now: fixture.now, maximumAge: 300, gaps: [fixture.gap])

        XCTAssertEqual(ForensicInvestigationPresentation.anomaly(observedZero).status, "Observed Zero")
        XCTAssertEqual(ForensicInvestigationPresentation.anomaly(gap).status, "Unavailable - Gap")
        XCTAssertNotEqual(ForensicInvestigationPresentation.anomaly(observedZero).status, "No finding")
    }

    func testAPIProductsAreFactualUnavailableDecisionsNotSupportedSelections() {
        let snapshot = ForensicInvestigationSnapshot.empty(publishedAt: Date(timeIntervalSince1970: 1_900_000_000))

        XCTAssertEqual(snapshot.supportedProducts, [])
        XCTAssertEqual(snapshot.apiEvidenceNotice, APIProviderQuotaPathAvailability.fixedUnavailableSummary)
        XCTAssertFalse(snapshot.apiEvidenceNotice.contains("zero"))
    }

    func testHalfOpenRangeIntersectionExcludesTouchingBoundaries() {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let end = start.addingTimeInterval(60)

        XCTAssertFalse(ForensicInvestigationPresentation.intersects(start: start.addingTimeInterval(-60), end: start, rangeStart: start, rangeEnd: end))
        XCTAssertFalse(ForensicInvestigationPresentation.intersects(start: end, end: end.addingTimeInterval(60), rangeStart: start, rangeEnd: end))
        XCTAssertTrue(ForensicInvestigationPresentation.intersects(start: start, end: end, rangeStart: start, rangeEnd: end))
    }

    func testTraceDetailsRevealTruncatedStableIdentitiesWithoutFullDigest() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "limit:primary:300", resetBoundary: now.addingTimeInterval(3_600))
        let observations = try [10.0, 12, 14, 16].enumerated().map { index, value in
            try MeasuredQuotaObservation(identity: identity, percentageUsed: value, observedAt: now.addingTimeInterval(Double(index - 3) * 600), source: .codexLocalReport)
        }
        let state = QuotaInsightAnalytics.analyze(observations, now: now, maximumAge: 60)

        let details = ForensicInvestigationPresentation.forecast(state).details

        XCTAssertTrue(details.contains(String(observations[0].stableIdentity.digest.prefix(12))))
        XCTAssertFalse(details.contains(observations[0].stableIdentity.digest))
    }

    func testCodexExplanationUsesCanonicalLimitIdentityAndDoesNotDuplicateAnalyticsRecord() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = now.addingTimeInterval(3_600)
        let snapshot = CodexRateLimitSnapshot(
            planType: "plus",
            primary: CodexRateLimitWindow(limitID: "Team-A", percentUsed: 20, windowMinutes: 300, resetsAt: reset),
            secondary: CodexRateLimitWindow(limitID: "Team-B", percentUsed: 40, windowMinutes: 10_080, resetsAt: reset),
            credits: nil,
            reportedAt: now
        )
        let observations = MeasuredQuotaObservationAdapter.codex(snapshot)
        let identity = try XCTUnwrap(observations.last?.identity)
        let explanation = CodexQuotaExplanation(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            quotaResetBoundary: reset,
            coverageStart: now.addingTimeInterval(-120),
            coverageEnd: now.addingTimeInterval(-60),
            reportedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(tokens: CodexMeasuredTokens(input: 2, cachedInput: 0, output: 1, reasoningOutput: 0), sessionCount: 1),
            unattributed: true,
            allocationPercent: nil,
            observationIdentities: [],
            evidenceIdentities: [],
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            barriers: [],
            quotaWindowIdentity: identity
        )
        let forecast = QuotaInsightAnalytics.analyze([], now: now, maximumAge: 60, expectedIdentity: identity)

        let publication = ForensicInvestigationAssembler.make(input(
            now: now,
            snapshot: snapshot,
            explanation: .available(explanation),
            forecasts: [identity: forecast]
        ))

        let records = try XCTUnwrap(publication.products.first { $0.product == .codex }?.records)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identity?.identifier, "team-b:secondary:10080")
    }

    func testRetainedCodexObservedZeroPreservesExactIntervalAndIsNeverGap() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let zero = CodexQuotaObservedZero(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            calculatedQuotaMovementPercent: 0,
            quotaResetBoundary: now.addingTimeInterval(3_600),
            observationIdentities: [],
            evidenceIdentities: []
        )

        let publication = ForensicInvestigationAssembler.make(input(
            now: now,
            explanation: .observedZero(zero),
            retained: true
        ))

        let record = try XCTUnwrap(publication.products.first?.records.first)
        XCTAssertEqual(record.start, zero.intervalStart)
        XCTAssertEqual(record.end, zero.intervalEnd)
        XCTAssertTrue(record.isObservedZero)
        XCTAssertFalse(record.isGap)
        XCTAssertTrue(record.freshness.contains("Retained/stale"))
    }

    private func input(
        now: Date,
        snapshot: CodexRateLimitSnapshot? = nil,
        explanation: CodexQuotaExplanationState,
        retained: Bool = false,
        forecasts: [QuotaWindowIdentity: QuotaInsightState] = [:]
    ) -> ForensicInvestigationInput {
        ForensicInvestigationInput(
            generation: 7,
            publishedAt: now,
            codexSnapshot: snapshot,
            codexExplanation: explanation,
            codexExplanationRetained: retained,
            claudeExplanationCatalog: .empty,
            forecasts: forecasts,
            anomalies: [:],
            storageAvailable: true,
            storeOpen: true
        )
    }

    private func anomalyFixture(values: [Double]) throws -> (observations: [MeasuredQuotaObservation], now: Date, gap: QuotaAnomalyPeriod) {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let now = start.addingTimeInterval(3_600)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: now.addingTimeInterval(3_600))
        let observations = try values.enumerated().map { index, value in
            try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: value,
                observedAt: start.addingTimeInterval(Double(index) * 600),
                source: .codexLocalReport
            )
        }
        let gap = try QuotaAnomalyPeriod(start: start, end: start.addingTimeInterval(600))
        return (observations, now, gap)
    }
}
