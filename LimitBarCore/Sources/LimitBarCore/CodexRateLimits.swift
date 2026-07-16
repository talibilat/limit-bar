import Foundation
import CryptoKit

public struct CodexRateLimitWindow: Equatable, Sendable {
    public let limitID: String
    public let percentUsed: Double
    public let windowMinutes: Int
    public let resetsAt: Date?

    public init(limitID: String = "codex", percentUsed: Double, windowMinutes: Int, resetsAt: Date?) {
        self.limitID = Self.normalizedLimitID(limitID)
        self.percentUsed = percentUsed
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public static func normalizedLimitID(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping ?? ""
        guard !trimmed.isEmpty else { return "codex" }
        let scalars = Array(trimmed.unicodeScalars)
        let isSafe = scalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }
        if isSafe, trimmed.utf8.count <= 32 { return trimmed.lowercased() }
        let digest = SHA256.hash(data: Data(trimmed.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "id_\(digest)"
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
    case traversalLimitExceeded

    public var displayText: String {
        switch self {
        case .notFound:
            "No recent Codex session found. Run codex once to populate rate limit data."
        case .malformedResponse:
            "Codex session data was not understood."
        case .traversalLimitExceeded:
            "Codex session storage contains too many entries to scan safely."
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
                let limit_id: String?
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

        guard let timestamp = raw.timestamp,
              let reportedAt = CollectorSchemaV1.parseTimestamp(timestamp) else {
            throw CodexRateLimitFailure.malformedResponse
        }

        let snapshot = CodexRateLimitSnapshot(
            planType: rateLimits.plan_type,
            primary: window(from: rateLimits.primary, limitID: rateLimits.limit_id),
            secondary: window(from: rateLimits.secondary, limitID: rateLimits.limit_id),
            credits: credits(from: rateLimits.credits),
            reportedAt: reportedAt
        )
        guard snapshot.primary != nil || snapshot.secondary != nil || snapshot.credits != nil else {
            throw CodexRateLimitFailure.malformedResponse
        }
        return snapshot
    }

    private static func window(from raw: RawEntry.RawPayload.RawWindow?, limitID: String?) -> CodexRateLimitWindow? {
        guard let raw, let percent = raw.used_percent, let minutes = raw.window_minutes,
              percent.isFinite, (0...100).contains(percent),
              (1...525_600).contains(minutes) else {
            return nil
        }
        let reset = raw.resets_at.flatMap { value -> Date? in
            guard value.isFinite else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        return CodexRateLimitWindow(
            limitID: limitID ?? "codex",
            percentUsed: percent,
            windowMinutes: minutes,
            resetsAt: reset
        )
    }

    private static func credits(from raw: RawEntry.RawPayload.RawCredits?) -> CodexCredits? {
        guard let raw else { return nil }
        let balance = raw.balance.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        return CodexCredits(hasCredits: raw.has_credits ?? false, unlimited: raw.unlimited ?? false, balance: balance)
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
        try Task.checkCancellation()
        guard let canonicalDirectory = SecureRegularFile.canonicalURL(sessionsDirectory) else {
            throw CodexRateLimitFailure.notFound
        }
        guard !SecureRegularFile.isSymbolicLink(sessionsDirectory),
              !SecureRegularFile.isSymbolicLink(sessionsDirectory.deletingLastPathComponent()) else {
            throw CodexRateLimitFailure.notFound
        }
        guard let enumerator = fileManager.enumerator(
            at: canonicalDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CodexRateLimitFailure.notFound
        }

        return try latestSnapshot(
            nextEntry: { enumerator.nextObject() as? URL },
            now: now,
            recentWindow: recentWindow,
            maximumEntries: 10_000,
            maximumFileSize: 8 * 1_024 * 1_024,
            maximumTotalReadSize: 32 * 1_024 * 1_024,
            allowedDirectory: canonicalDirectory,
            fileManager: fileManager
        )
    }

    static func latestSnapshot(
        nextEntry: () -> URL?,
        now: Date,
        recentWindow: TimeInterval = 9 * 24 * 60 * 60,
        maximumEntries: Int,
        maximumFileSize: Int = 8 * 1_024 * 1_024,
        maximumTotalReadSize: Int = 32 * 1_024 * 1_024,
        allowedDirectory: URL? = nil,
        fileManager: FileManager = .default,
        readFile: (URL, Int) throws -> Data = boundedRead
    ) throws -> CodexRateLimitSnapshot {
        try Task.checkCancellation()
        guard maximumFileSize >= 0, maximumFileSize < Int.max,
              maximumTotalReadSize >= 0, maximumTotalReadSize < Int.max else {
            throw CodexRateLimitFailure.traversalLimitExceeded
        }

        let cutoff = now.addingTimeInterval(-recentWindow)
        var best: CodexRateLimitSnapshot?
        var examinedEntries = 0
        var totalReadSize = 0
        var candidates: [(url: URL, modified: Date)] = []

        while let fileURL = nextEntry() {
            try Task.checkCancellation()
            examinedEntries += 1
            guard examinedEntries <= maximumEntries else {
                throw CodexRateLimitFailure.traversalLimitExceeded
            }
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  let fileSize = values.fileSize,
                  fileSize <= maximumFileSize,
                  modified >= cutoff else {
                continue
            }
            if let allowedDirectory {
                let rootPath = allowedDirectory.path
                guard let candidatePath = SecureRegularFile.canonicalURL(fileURL)?.path else { continue }
                guard candidatePath.hasPrefix(rootPath + "/") else { continue }
                candidates.append((URL(fileURLWithPath: candidatePath), modified))
                continue
            }
            candidates.append((fileURL, modified))
        }

        for candidate in candidates.sorted(by: { $0.modified > $1.modified }) {
            try Task.checkCancellation()
            guard totalReadSize < maximumTotalReadSize else { break }
            let remainingReadSize = maximumTotalReadSize - totalReadSize
            let readSize = min(maximumFileSize, remainingReadSize) + 1
            guard let contents = try? readFile(candidate.url, readSize) else { continue }
            guard contents.count <= remainingReadSize else { break }
            totalReadSize += contents.count
            guard contents.count <= maximumFileSize else { continue }
            guard !contents.isEmpty else {
                continue
            }
            for line in contents.split(separator: 0x0A) {
                try Task.checkCancellation()
                guard let snapshot = try? CodexRateLimitMapper.parseLine(Data(line)) else {
                    continue
                }
                guard snapshot.reportedAt >= cutoff,
                      snapshot.reportedAt <= now.addingTimeInterval(5 * 60) else {
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

    private static func boundedRead(_ fileURL: URL, byteCount: Int) throws -> Data {
        let handle = try SecureRegularFile.open(fileURL)
        defer { try? handle.close() }
        var data = Data()
        while data.count < byteCount {
            try Task.checkCancellation()
            let count = min(64 * 1_024, byteCount - data.count)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
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
        guard let windows = try? CurrentUsageWindows.resolve(at: Date(), calendar: .current) else {
            return Estimate(today: nil, currentWeek: nil)
        }
        return estimate(from: metrics, pricing: pricing, windows: windows)
    }

    public static func estimate(from metrics: [UsageMetric], pricing: PricingTable, windows: CurrentUsageWindows) -> Estimate {
        Estimate(
            today: totalCreditsCost(selectedMetrics(metrics, window: windows.today), pricing: pricing),
            currentWeek: totalCreditsCost(selectedMetrics(metrics, window: windows.currentWeek), pricing: pricing)
        )
    }

    private static func selectedMetrics(_ metrics: [UsageMetric], window: ExactUsageWindow) -> [UsageMetric] {
        let current = metrics.filter {
            $0.provider == .openAI
                && $0.provenance.exactWindow == window
                && $0.tokenUsage.totalTokens > 0
                && !$0.freshness.isStale
        }
        let provider = current.filter { $0.provenance.source == .providerAPI }
        return provider.isEmpty ? current.filter { $0.provenance.source == .builtInLocalLog } : provider
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
