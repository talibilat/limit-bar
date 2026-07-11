import Foundation

public struct CodexRateLimitWindow: Equatable, Sendable {
    public let percentUsed: Double
    public let windowMinutes: Int
    public let resetsAt: Date?

    public init(percentUsed: Double, windowMinutes: Int, resetsAt: Date?) {
        self.percentUsed = percentUsed
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var displayLabel: String {
        switch windowMinutes {
        case 300:
            "Session (5 hours)"
        case 10_080:
            "Weekly"
        default:
            "\(windowMinutes) minute window"
        }
    }

    public var percentRemaining: Double {
        max(0, 100 - percentUsed)
    }
}

public struct CodexCredits: Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: Decimal?

    public init(hasCredits: Bool, unlimited: Bool, balance: Decimal?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct CodexRateLimitSnapshot: Equatable, Sendable {
    public let planType: String?
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?
    public let credits: CodexCredits?
    public let reportedAt: Date

    public init(planType: String?, primary: CodexRateLimitWindow?, secondary: CodexRateLimitWindow?, credits: CodexCredits?, reportedAt: Date) {
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.reportedAt = reportedAt
    }

    // Business/org seats meter usage through a shared credit pool rather than
    // personal percentage windows, so Codex reports no primary/secondary data
    // for them (verified against live session logs: both are null on this
    // plan type). Only a calculated credits estimate is meaningful to show.
    public var isBusinessPlan: Bool {
        planType?.lowercased() == "business"
    }
}

public enum CodexRateLimitFailure: Error, Equatable, Sendable {
    case notFound
    case malformedResponse

    public var displayText: String {
        switch self {
        case .notFound:
            "No recent Codex session found. Run codex once to populate rate limit data."
        case .malformedResponse:
            "Codex session data was not understood."
        }
    }
}

public enum CodexRateLimitMapper {
    private struct RawEntry: Decodable {
        struct RawPayload: Decodable {
            struct RawWindow: Decodable {
                let used_percent: Double?
                let window_minutes: Int?
                let resets_at: Double?
            }

            struct RawCredits: Decodable {
                let has_credits: Bool?
                let unlimited: Bool?
                let balance: String?
            }

            struct RawRateLimits: Decodable {
                let primary: RawWindow?
                let secondary: RawWindow?
                let credits: RawCredits?
                let plan_type: String?
            }

            let type: String?
            let rate_limits: RawRateLimits?
        }

        let timestamp: String?
        let payload: RawPayload?
    }

    public static func parseLine(_ data: Data) throws -> CodexRateLimitSnapshot {
        guard let raw = try? JSONDecoder().decode(RawEntry.self, from: data),
              let rateLimits = raw.payload?.rate_limits else {
            throw CodexRateLimitFailure.malformedResponse
        }

        let reportedAt = raw.timestamp.flatMap(parseTimestamp) ?? Date()

        return CodexRateLimitSnapshot(
            planType: rateLimits.plan_type,
            primary: window(from: rateLimits.primary),
            secondary: window(from: rateLimits.secondary),
            credits: credits(from: rateLimits.credits),
            reportedAt: reportedAt
        )
    }

    private static func window(from raw: RawEntry.RawPayload.RawWindow?) -> CodexRateLimitWindow? {
        guard let raw, let percent = raw.used_percent, let minutes = raw.window_minutes else {
            return nil
        }
        return CodexRateLimitWindow(
            percentUsed: percent,
            windowMinutes: minutes,
            resetsAt: raw.resets_at.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func credits(from raw: RawEntry.RawPayload.RawCredits?) -> CodexCredits? {
        guard let raw else { return nil }
        let balance = raw.balance.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        return CodexCredits(hasCredits: raw.has_credits ?? false, unlimited: raw.unlimited ?? false, balance: balance)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: text) {
            return date
        }
        return ISO8601DateFormatter().date(from: text)
    }
}

// Codex only logs rate_limits locally as a side effect of each response
// (see the token_count event in ~/.codex/sessions); there is no endpoint to
// poll, so this reads the freshest one already on disk instead of guessing
// at an undocumented API.
public enum CodexSessionRateLimitReader {
    public static func latestSnapshot(
        sessionsDirectory: URL,
        now: Date,
        recentWindow: TimeInterval = 9 * 24 * 60 * 60,
        fileManager: FileManager = .default
    ) throws -> CodexRateLimitSnapshot {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CodexRateLimitFailure.notFound
        }

        let cutoff = now.addingTimeInterval(-recentWindow)
        var best: CodexRateLimitSnapshot?

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= cutoff else {
                continue
            }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            for line in contents.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let snapshot = try? CodexRateLimitMapper.parseLine(lineData) else {
                    continue
                }
                guard snapshot.primary != nil || snapshot.secondary != nil || snapshot.credits != nil else {
                    continue
                }
                if best == nil || snapshot.reportedAt > best!.reportedAt {
                    best = snapshot
                }
            }
        }

        guard let best else {
            throw CodexRateLimitFailure.notFound
        }
        return best
    }
}

// The credit-per-token rate is configured in Settings as a
// currencyCode: "credits" PricingEntry. This sums whatever the existing
// Cost calculator already produces from that entry, scoped to the "credits"
// currency so it never mixes with a manually configured dollar estimate.
public enum CodexCreditsEstimator {
    public struct Estimate: Equatable, Sendable {
        public let today: Cost?
        public let currentWeek: Cost?

        public init(today: Cost?, currentWeek: Cost?) {
            self.today = today
            self.currentWeek = currentWeek
        }
    }

    public static func estimate(from metrics: [UsageMetric], pricing: PricingTable) -> Estimate {
        Estimate(
            today: totalCreditsCost(metrics.filter { $0.provider == .openAI && $0.timeWindow == .today }, pricing: pricing),
            currentWeek: totalCreditsCost(metrics.filter { $0.provider == .openAI && $0.timeWindow == .currentWeek }, pricing: pricing)
        )
    }

    private static func totalCreditsCost(_ metrics: [UsageMetric], pricing: PricingTable) -> Cost? {
        let costs = metrics.compactMap { CostCalculator.cost(for: $0, pricing: pricing) }.filter { $0.currencyCode == "credits" }
        guard !costs.isEmpty else {
            return nil
        }
        let total = costs.reduce(Decimal(0)) { $0 + $1.amount }
        return Cost(amount: total, currencyCode: "credits", source: .calculatedEstimate)
    }
}
