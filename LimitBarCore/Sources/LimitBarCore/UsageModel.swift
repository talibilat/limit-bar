import Foundation

public enum ProviderKind: String, CaseIterable, Codable, Equatable, Sendable {
    case anthropic
    case azureOpenAI
    case openAI

    public static let orderedCases: [ProviderKind] = [.anthropic, .azureOpenAI, .openAI]

    public var displayName: String {
        switch self {
        case .anthropic:
            "Anthropic"
        case .azureOpenAI:
            "Azure OpenAI"
        case .openAI:
            "OpenAI"
        }
    }
}

public enum TimeWindow: String, CaseIterable, Codable, Equatable, Sendable {
    case today
    case currentWeek

    public var displayName: String {
        switch self {
        case .today:
            "Today"
        case .currentWeek:
            "Current Week"
        }
    }

    public func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .currentWeek:
            return calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, end: date)
        }
    }
}
