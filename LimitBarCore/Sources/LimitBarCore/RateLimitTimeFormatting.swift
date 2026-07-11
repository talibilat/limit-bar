import Foundation

// Shared by the Claude and Codex rate limit rows: a reset that is more than a
// day away is more useful as "which day, what time" than a countdown that
// keeps changing; a reset inside the same day is more useful as a countdown.
public enum RateLimitTimeFormatting {
    public static func remainingText(now: Date, resetsAt: Date, calendar: Calendar = .current) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else {
            return "Resetting now"
        }

        let dayInSeconds: TimeInterval = 24 * 60 * 60
        if interval >= dayInSeconds {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? Locale.current
            formatter.setLocalizedDateFormatFromTemplate("EEEE j:mm")
            return formatter.string(from: resetsAt)
        }

        let totalMinutes = Int((interval / 60).rounded(.up))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, let m):
            return "\(m)m"
        case (let h, 0):
            return "\(h)h"
        default:
            return "\(hours)h \(minutes)m"
        }
    }
}
