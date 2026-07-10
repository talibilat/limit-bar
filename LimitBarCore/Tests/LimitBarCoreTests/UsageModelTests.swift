import Foundation
import Testing
@testable import LimitBarCore

@Suite("Usage model")
struct UsageModelTests {
    @Test("providers use the fixed display order")
    func providersUseFixedDisplayOrder() {
        #expect(ProviderKind.orderedCases == [.anthropic, .azureOpenAI, .openAI])
        #expect(ProviderKind.orderedCases.map(\.displayName) == ["Anthropic", "Azure OpenAI", "OpenAI"])
    }

    @Test("today window covers the local day containing the reference date")
    func todayWindowCoversReferenceDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try #require(calendar.date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 7, day: 10, hour: 15, minute: 30)))

        let interval = TimeWindow.today.interval(containing: reference, calendar: calendar)

        #expect(interval.start == calendar.startOfDay(for: reference))
        #expect(interval.end == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)))
        #expect(TimeWindow.today.displayName == "Today")
    }

    @Test("current week window uses the calendar week containing the reference date")
    func currentWeekWindowUsesCalendarWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let reference = try #require(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 7, day: 10, hour: 15)))

        let interval = TimeWindow.currentWeek.interval(containing: reference, calendar: calendar)
        let expected = try #require(calendar.dateInterval(of: .weekOfYear, for: reference))

        #expect(interval == expected)
        #expect(TimeWindow.currentWeek.displayName == "Current Week")
    }
}
