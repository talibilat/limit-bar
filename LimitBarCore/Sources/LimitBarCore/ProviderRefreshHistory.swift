import Foundation

public enum ProviderRefreshHistoryProvider: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case anthropic
    case azureOpenAI
    case openAI
    case custom

    public init(_ provider: ProviderKind) {
        switch provider {
        case .anthropic: self = .anthropic
        case .azureOpenAI: self = .azureOpenAI
        case .openAI: self = .openAI
        case .custom: self = .custom
        }
    }
}

public enum ProviderRefreshOperationClass: String, CaseIterable, Codable, Equatable, Sendable {
    case usage
    case rateLimits
    case usageAndRateLimits
}

public enum ProviderRefreshOutcome: String, CaseIterable, Codable, Equatable, Sendable {
    case success
    case cancelled
    case authentication
    case network
    case failure
}

public enum ProviderRefreshDurationBucket: String, CaseIterable, Codable, Equatable, Sendable {
    case underOneSecond
    case oneToFiveSeconds
    case fiveToThirtySeconds
    case overThirtySeconds

    public init(duration: TimeInterval) throws {
        guard duration.isFinite, duration >= 0 else {
            throw ProviderRefreshHistoryValidationError.invalidDuration
        }

        switch duration {
        case ..<1: self = .underOneSecond
        case ..<5: self = .oneToFiveSeconds
        case ..<30: self = .fiveToThirtySeconds
        default: self = .overThirtySeconds
        }
    }
}

public enum ProviderRefreshWindowKind: String, CaseIterable, Codable, Equatable, Sendable {
    case today
    case currentWeek
}

public enum ProviderRefreshWindowBasis: String, CaseIterable, Codable, Equatable, Sendable {
    case localCalendar
    case utcBilling
}

public struct ProviderRefreshWindow: Codable, Equatable, Hashable, Sendable {
    public let kind: ProviderRefreshWindowKind
    public let start: Date
    public let end: Date
    public let basis: ProviderRefreshWindowBasis
    public let aggregationVersion: Int

    public init(
        kind: ProviderRefreshWindowKind,
        start: Date,
        end: Date,
        basis: ProviderRefreshWindowBasis,
        aggregationVersion: Int
    ) throws {
        guard start.timeIntervalSince1970.isFinite,
              end.timeIntervalSince1970.isFinite,
              end > start else {
            throw ProviderRefreshHistoryValidationError.invalidWindow
        }
        guard aggregationVersion > 0 else {
            throw ProviderRefreshHistoryValidationError.invalidWindow
        }

        self.kind = kind
        self.start = start
        self.end = end
        self.basis = basis
        self.aggregationVersion = aggregationVersion
    }

    public init(_ window: ExactUsageWindow) {
        kind = switch window.timeWindow {
        case .today: .today
        case .currentWeek: .currentWeek
        }
        start = window.start
        end = window.end
        basis = switch window.basis {
        case .localCalendar: .localCalendar
        case .utcBilling: .utcBilling
        }
        aggregationVersion = window.aggregationVersion
    }
}

public enum ProviderRefreshHistoryValidationError: Error, Equatable {
    case invalidDuration
    case invalidStartTime
    case invalidWindow
    case noAffectedWindows
}

public struct ProviderRefreshHistoryEntry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let provider: ProviderRefreshHistoryProvider
    public let operation: ProviderRefreshOperationClass
    public let outcome: ProviderRefreshOutcome
    public let startedAt: Date
    public let duration: ProviderRefreshDurationBucket
    public let affectedWindows: [ProviderRefreshWindow]

    public init(
        provider: ProviderRefreshHistoryProvider,
        operation: ProviderRefreshOperationClass,
        outcome: ProviderRefreshOutcome,
        startedAt: Date,
        duration: TimeInterval,
        affectedWindows: [ProviderRefreshWindow]
    ) throws {
        guard startedAt.timeIntervalSince1970.isFinite else {
            throw ProviderRefreshHistoryValidationError.invalidStartTime
        }
        guard !affectedWindows.isEmpty else {
            throw ProviderRefreshHistoryValidationError.noAffectedWindows
        }

        schemaVersion = Self.currentSchemaVersion
        self.provider = provider
        self.operation = operation
        self.outcome = outcome
        self.startedAt = startedAt
        self.duration = try ProviderRefreshDurationBucket(duration: duration)
        self.affectedWindows = affectedWindows.sorted(by: Self.windowSort)
    }

    private static func windowSort(_ lhs: ProviderRefreshWindow, _ rhs: ProviderRefreshWindow) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.basis != rhs.basis { return lhs.basis.rawValue < rhs.basis.rawValue }
        return lhs.aggregationVersion < rhs.aggregationVersion
    }
}

public actor ProviderRefreshHistory {
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumEntriesPerProvider = 200

    private var entriesByProvider: [ProviderRefreshHistoryProvider: [ProviderRefreshHistoryEntry]] = [:]

    public init() {}

    public func record(_ entry: ProviderRefreshHistoryEntry, now: Date = Date()) {
        entriesByProvider[entry.provider, default: []].append(entry)
        prune(now: now)
    }

    public func entries(
        for provider: ProviderRefreshHistoryProvider,
        now: Date = Date()
    ) -> [ProviderRefreshHistoryEntry] {
        prune(now: now)
        return entriesByProvider[provider] ?? []
    }

    public func deleteEntries(for provider: ProviderRefreshHistoryProvider) {
        entriesByProvider[provider] = nil
    }

    public func deleteAllEntries() {
        entriesByProvider.removeAll()
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)

        for provider in ProviderRefreshHistoryProvider.allCases {
            let retained = (entriesByProvider[provider] ?? [])
                .enumerated()
                .filter { $0.element.startedAt >= cutoff }
                .sorted { lhs, rhs in
                    if lhs.element.startedAt != rhs.element.startedAt {
                        return lhs.element.startedAt > rhs.element.startedAt
                    }
                    return lhs.offset > rhs.offset
                }
                .prefix(Self.maximumEntriesPerProvider)
                .map(\.element)
            entriesByProvider[provider] = retained.isEmpty ? nil : retained
        }
    }
}
