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
