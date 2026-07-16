import Foundation
import Testing
@testable import LimitBarCore

@Suite("Rate limit time formatting")
struct RateLimitTimeFormattingTests {
    private func utcCalendar() -> Calendar {
        var calendar = gregorianGMTCalendar()
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    @Test("shows minutes only under an hour")
    func showsMinutesOnly() {
        let now = Date(timeIntervalSince1970: 0)
        let resetsAt = now.addingTimeInterval(25 * 60)

        #expect(RateLimitTimeFormatting.remainingText(now: now, resetsAt: resetsAt, calendar: utcCalendar()) == "25m")
    }

    @Test("shows hours and minutes under a day")
    func showsHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let resetsAt = now.addingTimeInterval(4 * 3600 + 12 * 60)

        #expect(RateLimitTimeFormatting.remainingText(now: now, resetsAt: resetsAt, calendar: utcCalendar()) == "4h 12m")
    }

    @Test("shows whole hours without minutes when exact")
    func showsWholeHours() {
        let now = Date(timeIntervalSince1970: 0)
        let resetsAt = now.addingTimeInterval(3 * 3600)

        #expect(RateLimitTimeFormatting.remainingText(now: now, resetsAt: resetsAt, calendar: utcCalendar()) == "3h")
    }

    @Test("shows weekday and time at or beyond a day away")
    func showsWeekdayAndTime() throws {
        let calendar = utcCalendar()
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 12)))
        let resetsAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 19)))

        let text = RateLimitTimeFormatting.remainingText(now: now, resetsAt: resetsAt, calendar: calendar)

        #expect(text.contains("Tuesday"))
        #expect(text.contains("7:00"))
    }

    @Test("past or zero reset shows resetting now")
    func pastResetShowsResettingNow() {
        let now = Date(timeIntervalSince1970: 1000)
        let resetsAt = Date(timeIntervalSince1970: 500)

        #expect(RateLimitTimeFormatting.remainingText(now: now, resetsAt: resetsAt, calendar: utcCalendar()) == "Resetting now")
    }
}
