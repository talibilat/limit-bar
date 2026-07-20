import XCTest
import LimitBarCore
@testable import LimitBar

final class HistoricalUsagePresentationTests: XCTestCase {
    func testDailyChartUsesAtMostFifteenWholeDaysIncludingGaps() throws {
        let buckets = try (0..<20).map { try dailyBucket($0) }

        let presentation = HistoricalUsageChartPresentation(dailyBuckets: buckets)

        XCTAssertEqual(presentation.buckets.count, 15)
        XCTAssertEqual(presentation.domain?.lowerBound, buckets[5].period.window.start)
        XCTAssertEqual(presentation.domain?.upperBound, buckets[19].period.window.end)
    }

    func testDailyChartLabelsUseDatesRatherThanTimes() throws {
        let bucket = try dailyBucket(0)
        let presentation = HistoricalUsageChartPresentation(dailyBuckets: [bucket])

        let label = presentation.dateLabel(for: bucket.period)

        XCTAssertTrue(label.contains("Jul"))
        XCTAssertFalse(label.contains("AM"))
        XCTAssertFalse(label.contains("PM"))
    }

    func testDailyChartShowsOnlyOneEntryForTheSameCalendarDateAcrossTimeZones() throws {
        var buckets = try (0..<15).map { try dailyBucket($0) }
        buckets.append(try dailyBucket(9, timeZoneIdentifier: "America/New_York"))

        let presentation = HistoricalUsageChartPresentation(dailyBuckets: buckets)

        XCTAssertEqual(presentation.buckets.count, 15)
        XCTAssertEqual(Set(presentation.dateLabels).count, 15)
    }

    func testLargeTokenCountsUseCompactSuffixes() {
        XCTAssertEqual(HistoricalUsageChartPresentation.compactTokenCount(1_000_000), "1M")
        XCTAssertEqual(HistoricalUsageChartPresentation.compactTokenCount(1_500_000_000), "1.5B")
        XCTAssertEqual(HistoricalUsageChartPresentation.compactTokenCount(2_000_000_000_000), "2T")
    }

    private func dailyBucket(_ day: Int, timeZoneIdentifier: String = "UTC") throws -> HistoricalUsageTrendBucket {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZoneIdentifier))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: day + 1)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        let window = try ExactUsageWindow(
            timeWindow: .today,
            start: start,
            end: end,
            basis: .localCalendar
        )
        return HistoricalUsageTrendBucket(
            period: try HistoricalUsageTrendPeriod(window: window, timeZoneIdentifier: timeZoneIdentifier),
            value: .gap
        )
    }
}
