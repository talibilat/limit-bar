import Foundation
import Testing
@testable import LimitBarCore

@Suite("Codex rate limits")
struct CodexRateLimitsTests {
    @Test("parses business plan with null windows and empty credits")
    func parsesBusinessPlan() throws {
        let line = #"{"timestamp":"2026-07-10T12:08:39.061Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"plan_type":"business","rate_limit_reached_type":null}}}"#

        let snapshot = try CodexRateLimitMapper.parseLine(Data(line.utf8))

        #expect(snapshot.isBusinessPlan)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.credits?.hasCredits == false)
        #expect(snapshot.credits?.balance == 0)
    }

    @Test("parses individual plan with primary and secondary windows")
    func parsesIndividualPlanWindows() throws {
        let line = #"{"timestamp":"2025-11-16T02:39:20.308Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":2.0,"window_minutes":300,"resets_at":1763263112},"secondary":{"used_percent":25.0,"window_minutes":10080,"resets_at":1763330860}}}}"#

        let snapshot = try CodexRateLimitMapper.parseLine(Data(line.utf8))

        #expect(!snapshot.isBusinessPlan)
        #expect(snapshot.primary?.percentUsed == 2.0)
        #expect(snapshot.primary?.displayLabel == "Session (5 hours)")
        #expect(snapshot.secondary?.percentUsed == 25.0)
        #expect(snapshot.secondary?.displayLabel == "Weekly")
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1763263112))
    }

    @Test("unknown window minutes fall back to a generic label")
    func unknownWindowMinutesFallBack() throws {
        let line = #"{"timestamp":"2026-01-01T00:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":60,"resets_at":100}}}}"#

        let snapshot = try CodexRateLimitMapper.parseLine(Data(line.utf8))

        #expect(snapshot.primary?.displayLabel == "60 minute window")
    }

    @Test("limit identifiers are bounded safe tokens for exact quota identity")
    func limitIdentifiersAreSafe() {
        #expect(CodexRateLimitWindow.normalizedLimitID(nil) == "codex")
        #expect(CodexRateLimitWindow.normalizedLimitID(" Team_A ") == "team_a")
        let unusual = CodexRateLimitWindow.normalizedLimitID("team:primary:" + String(repeating: "x", count: 200))
        #expect(unusual.hasPrefix("id_"))
        #expect(unusual.count == 19)
    }

    @Test("missing rate_limits payload throws")
    func missingRateLimitsThrows() {
        let line = #"{"timestamp":"2026-01-01T00:00:00Z","payload":{"type":"token_count","info":{}}}"#

        #expect(throws: CodexRateLimitFailure.self) {
            try CodexRateLimitMapper.parseLine(Data(line.utf8))
        }
    }

    @Test("rate limit entries require a valid timestamp")
    func requiresTimestamp() {
        let missing = #"{"payload":{"rate_limits":{"primary":{"used_percent":1,"window_minutes":300}}}}"#
        let invalid = #"{"timestamp":"not-a-date","payload":{"rate_limits":{"primary":{"used_percent":1,"window_minutes":300}}}}"#
        #expect(throws: CodexRateLimitFailure.malformedResponse) { try CodexRateLimitMapper.parseLine(Data(missing.utf8)) }
        #expect(throws: CodexRateLimitFailure.malformedResponse) { try CodexRateLimitMapper.parseLine(Data(invalid.utf8)) }
    }

    @Test("reader rejects entries outside the scan window or over five minutes in the future")
    func rejectsImplausibleTimestamps() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = codexLine(timestamp: Date(timeIntervalSince1970: now.timeIntervalSince1970 - 10 * 24 * 60 * 60))
        let future = codexLine(timestamp: now.addingTimeInterval(301))
        let reader = BoundedReaderSpy(data: [old, future])
        let files = try metadataFiles(count: 2, modifiedAt: now)
        defer { try? FileManager.default.removeItem(at: files.root) }
        let cursor = EntryCursor(entries: files.files)

        #expect(throws: CodexRateLimitFailure.notFound) {
            try CodexSessionRateLimitReader.latestSnapshot(
                nextEntry: cursor.next,
                now: now,
                maximumEntries: 2,
                fileManager: .default,
                readFile: reader.read
            )
        }
    }

    @Test("percentage fields outside finite zero through one hundred are skipped")
    func invalidPercentagesAreSkipped() throws {
        let mixed = #"{"timestamp":"2026-01-01T00:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":-1,"window_minutes":300},"secondary":{"used_percent":100,"window_minutes":10080}}}}"#

        let snapshot = try CodexRateLimitMapper.parseLine(Data(mixed.utf8))

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.percentUsed == 100)
        #expect(throws: CodexRateLimitFailure.malformedResponse) {
            try CodexRateLimitMapper.parseLine(Data(#"{"payload":{"rate_limits":{"primary":{"used_percent":101,"window_minutes":300}}}}"#.utf8))
        }
        #expect(throws: CodexRateLimitFailure.malformedResponse) {
            try CodexRateLimitMapper.parseLine(Data(#"{"payload":{"rate_limits":{"primary":{"used_percent":1e999,"window_minutes":300}}}}"#.utf8))
        }
    }

    @Test("window minutes must be positive and no longer than one year")
    func invalidWindowMinutesAreSkipped() throws {
        let mixed = #"{"timestamp":"2026-01-01T00:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":1,"window_minutes":0},"secondary":{"used_percent":2,"window_minutes":525600}}}}"#

        let snapshot = try CodexRateLimitMapper.parseLine(Data(mixed.utf8))

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.windowMinutes == 525_600)
        for minutes in [-1, 525_601] {
            let json = "{\"payload\":{\"rate_limits\":{\"primary\":{\"used_percent\":1,\"window_minutes\":\(minutes)}}}}"
            #expect(throws: CodexRateLimitFailure.malformedResponse) {
                try CodexRateLimitMapper.parseLine(Data(json.utf8))
            }
        }
    }

    @Test("reader picks the freshest rate_limits entry across recent session files")
    func readerPicksFreshestEntry() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let older = root.appendingPathComponent("older.jsonl")
        let newer = root.appendingPathComponent("newer.jsonl")
        try #"{"timestamp":"2026-07-01T00:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.0,"window_minutes":300,"resets_at":100},"plan_type":"plus"}}}"#
            .write(to: older, atomically: true, encoding: .utf8)
        try #"{"timestamp":"2026-07-10T00:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40.0,"window_minutes":300,"resets_at":200},"plan_type":"plus"}}}"#
            .write(to: newer, atomically: true, encoding: .utf8)

        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T00:01:00Z"))
        let snapshot = try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: root, now: now, fileManager: fileManager)

        #expect(snapshot.primary?.percentUsed == 40.0)
    }

    @Test("reader throws when nothing recent has rate limit data")
    func readerThrowsWhenNothingFound() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        #expect(throws: CodexRateLimitFailure.self) {
            try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: root, now: Date(), fileManager: fileManager)
        }
    }

    @Test("reader honors task cancellation before scanning")
    func readerHonorsCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CodexSessionRateLimitReader.latestSnapshot(
                sessionsDirectory: FileManager.default.temporaryDirectory,
                now: Date()
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("reader checks cancellation while traversing non-JSON entries")
    func readerCancelsMidTraversal() async {
        let cursor = EntryCursor(
            entries: (0..<5).map { URL(fileURLWithPath: "/tmp/entry-\($0).txt") },
            cancelAt: 3
        )
        let task = Task {
            try CodexSessionRateLimitReader.latestSnapshot(
                nextEntry: cursor.next,
                now: Date(),
                maximumEntries: 100
            )
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cursor.visitedCount == 3)
    }

    @Test("reader bounds all traversed entries including directories and non-JSON files")
    func readerBoundsAllEntries() {
        let cursor = EntryCursor(entries: [
            URL(fileURLWithPath: "/tmp/a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/c.txt")
        ])

        #expect(throws: CodexRateLimitFailure.traversalLimitExceeded) {
            try CodexSessionRateLimitReader.latestSnapshot(
                nextEntry: cursor.next,
                now: Date(),
                maximumEntries: 2
            )
        }
        #expect(cursor.visitedCount == 3)
    }

    @Test("reader skips session files larger than eight MiB")
    func readerSkipsOversizedFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let file = root.appendingPathComponent("oversized.jsonl")
        let valid = Data(#"{"timestamp":"2026-07-10T00:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":40,"window_minutes":300}}}}"#.utf8)
        var data = valid
        data.append(Data(repeating: 0x20, count: 8 * 1_024 * 1_024))
        try data.write(to: file)

        #expect(throws: CodexRateLimitFailure.notFound) {
            try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: root, now: Date(), fileManager: fileManager)
        }
    }

    @Test("reader does not follow a session symlink outside the configured directory")
    func readerRejectsSymlinkEscape() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        try codexLine(timestamp: Date()).write(to: outside)
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("linked.jsonl"), withDestinationURL: outside)

        #expect(throws: CodexRateLimitFailure.notFound) {
            try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: root, now: Date(), fileManager: fileManager)
        }
    }

    @Test("reader rejects a configured sessions directory that is a symbolic link")
    func readerRejectsSymlinkedRoot() throws {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = parent.appendingPathComponent("target", isDirectory: true)
        let linkedRoot = parent.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: parent) }
        try codexLine(timestamp: Date()).write(to: target.appendingPathComponent("session.jsonl"))
        try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: target)

        #expect(throws: CodexRateLimitFailure.notFound) {
            try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: linkedRoot, now: Date(), fileManager: fileManager)
        }
    }

    @Test("reader rejects a file that grows beyond metadata using a maximum plus one byte read")
    func readerRejectsGrowthDuringRead() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let file = root.appendingPathComponent("growing.jsonl")
        try Data("{}".utf8).write(to: file)
        let cursor = EntryCursor(entries: [file])
        let reader = BoundedReaderSpy(data: Data(repeating: 0x20, count: 17))

        #expect(throws: CodexRateLimitFailure.notFound) {
            try CodexSessionRateLimitReader.latestSnapshot(
                nextEntry: cursor.next,
                now: Date(),
                maximumEntries: 1,
                maximumFileSize: 16,
                fileManager: fileManager,
                readFile: reader.read
            )
        }
        #expect(reader.requestedByteCounts == [17])
    }

    @Test("reader caps cumulative JSONL bytes across the scan")
    func readerCapsCumulativeBytes() throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let files = try metadataFiles(count: 3, modifiedAt: now)
        defer { try? FileManager.default.removeItem(at: files.root) }
        let cursor = EntryCursor(entries: files.files)
        let reader = BudgetReaderSpy(maximumReturnSize: 8)

        #expect(throws: CodexRateLimitFailure.notFound) {
            try CodexSessionRateLimitReader.latestSnapshot(
                nextEntry: cursor.next,
                now: now,
                maximumEntries: 3,
                maximumFileSize: 8,
                maximumTotalReadSize: 12,
                readFile: reader.read
            )
        }

        #expect(reader.requestedByteCounts == [9, 5])
        #expect(reader.returnedByteCount == 13)
    }

    @Test("reader spends its cumulative budget on newest session files first")
    func readerReadsNewestMetadataFirst() throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let files = try metadataFiles(count: 2, modifiedAt: now)
        defer { try? FileManager.default.removeItem(at: files.root) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: files.files[0].path)
        let oldData = codexLine(timestamp: now.addingTimeInterval(-60))
        let newData = codexLine(timestamp: now)
        let reader = URLMappingReader(data: [files.files[0]: oldData, files.files[1]: newData])
        let cursor = EntryCursor(entries: files.files)

        let snapshot = try CodexSessionRateLimitReader.latestSnapshot(
            nextEntry: cursor.next,
            now: now,
            maximumEntries: 2,
            maximumFileSize: 1_024,
            maximumTotalReadSize: newData.count,
            readFile: reader.read
        )

        #expect(reader.readURLs.first == files.files[1])
        #expect(snapshot.reportedAt == now)
    }

    @Test(arguments: [NewestCandidateFailure.unreadable, .grown])
    func readerContinuesPastBadNewestCandidate(failure: NewestCandidateFailure) throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let files = try metadataFiles(count: 2, modifiedAt: now)
        defer { try? FileManager.default.removeItem(at: files.root) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: files.files[0].path)
        let oldData = codexLine(timestamp: now.addingTimeInterval(-60))
        let reader = FailingNewestReader(newest: files.files[1], failure: failure, olderData: oldData)
        let cursor = EntryCursor(entries: files.files)

        let snapshot = try CodexSessionRateLimitReader.latestSnapshot(
            nextEntry: cursor.next,
            now: now,
            maximumEntries: 2,
            maximumFileSize: 1_024,
            maximumTotalReadSize: 2_048,
            readFile: reader.read
        )

        #expect(snapshot.reportedAt == now.addingTimeInterval(-60))
    }

    @Test("reader continues past an oversized newest candidate")
    func readerContinuesPastOversizedNewestCandidate() throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let files = try metadataFiles(count: 2, modifiedAt: now)
        defer { try? FileManager.default.removeItem(at: files.root) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: files.files[0].path)
        try Data(repeating: 0x20, count: 1_025).write(to: files.files[1])
        let oldData = codexLine(timestamp: now.addingTimeInterval(-60))
        let reader = URLMappingReader(data: [files.files[0]: oldData])
        let cursor = EntryCursor(entries: files.files)

        let snapshot = try CodexSessionRateLimitReader.latestSnapshot(
            nextEntry: cursor.next,
            now: now,
            maximumEntries: 2,
            maximumFileSize: 1_024,
            maximumTotalReadSize: 2_048,
            readFile: reader.read
        )

        #expect(snapshot.reportedAt == now.addingTimeInterval(-60))
        #expect(reader.readURLs == [files.files[0]])
    }

    @Test("credits estimator sums only credits-currency costs per window")
    func creditsEstimatorSumsCreditsCurrency() throws {
        let pricing = PricingTable(entries: [
            PricingEntry(provider: .openAI, modelLabel: "gpt-5.5", inputPricePerMillionTokens: 10, outputPricePerMillionTokens: 10, currencyCode: "credits", effectiveAt: Date(timeIntervalSince1970: 0)),
            PricingEntry(provider: .openAI, modelLabel: "gpt-5.6", inputPricePerMillionTokens: 5, outputPricePerMillionTokens: 5, currencyCode: "USD", effectiveAt: Date(timeIntervalSince1970: 0))
        ])
        let windows = try CurrentUsageWindows.resolve(at: Date(), calendar: .current)
        let metrics = [
            UsageMetric(provider: .openAI, accountLabel: "Local logs", projectLabel: nil, modelLabel: "gpt-5.5", deploymentLabel: nil, provenance: .bounded(source: .builtInLocalLog, window: windows.today), tokenUsage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(), freshness: .fresh),
            UsageMetric(provider: .openAI, accountLabel: "Local logs", projectLabel: nil, modelLabel: "gpt-5.6", deploymentLabel: nil, provenance: .bounded(source: .builtInLocalLog, window: windows.today), tokenUsage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(), freshness: .fresh),
            UsageMetric(provider: .anthropic, accountLabel: nil, projectLabel: nil, modelLabel: "claude-fable-5", deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(), freshness: .fresh)
        ]

        let estimate = CodexCreditsEstimator.estimate(from: metrics, pricing: pricing)

        #expect(estimate.today?.amount == 10)
        #expect(estimate.today?.currencyCode == "credits")
        #expect(estimate.currentWeek == nil)
    }

    @Test("credits estimator prefers current provider API rows without mixing local rows")
    func creditsEstimatorPrefersProviderAPI() throws {
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: gregorianGMTCalendar())
        let pricing = creditsPricing()
        let metrics = [
            creditsMetric(tokens: 1_000_000, source: .providerAPI, window: windows.today, refreshedAt: now),
            creditsMetric(tokens: 9_000_000, source: .builtInLocalLog, window: windows.today, refreshedAt: now)
        ]

        let estimate = CodexCreditsEstimator.estimate(from: metrics, pricing: pricing, windows: windows)

        #expect(estimate.today?.amount == 10)
    }

    @Test("credits estimator falls back to local and ignores legacy expired and cost-only rows")
    func creditsEstimatorFallsBackToCurrentLocal() throws {
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: gregorianGMTCalendar())
        let expired = try ExactUsageWindow(timeWindow: .today, start: windows.today.start.addingTimeInterval(-86_400), end: windows.today.end.addingTimeInterval(-86_400), basis: .localCalendar)
        let metrics = [
            creditsMetric(tokens: 2_000_000, source: .builtInLocalLog, window: windows.today, refreshedAt: now),
            creditsMetric(tokens: 8_000_000, source: .providerAPI, window: expired, refreshedAt: now),
            UsageMetric(provider: .openAI, accountLabel: nil, projectLabel: nil, modelLabel: "gpt-5.5", deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 7_000_000, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: now, freshness: .fresh),
            UsageMetric(provider: .openAI, accountLabel: nil, projectLabel: nil, modelLabel: "gpt-5.5", deploymentLabel: nil, provenance: .bounded(source: .providerAPI, window: windows.today), tokenUsage: TokenUsage(inputTokens: 0, outputTokens: 0), cost: Cost(amount: 5, currencyCode: "USD", source: .providerReported), limitStatus: .unsupportedByProviderAPI, refreshedAt: now, freshness: .fresh)
        ]

        let estimate = CodexCreditsEstimator.estimate(from: metrics, pricing: creditsPricing(), windows: windows)

        #expect(estimate.today?.amount == 20)
    }

    private func creditsPricing() -> PricingTable {
        PricingTable(entries: [PricingEntry(provider: .openAI, modelLabel: "gpt-5.5", inputPricePerMillionTokens: 10, outputPricePerMillionTokens: 10, currencyCode: "credits", effectiveAt: Date(timeIntervalSince1970: 0))])
    }

    private func creditsMetric(tokens: Int, source: UsageMetricSource, window: ExactUsageWindow, refreshedAt: Date) -> UsageMetric {
        UsageMetric(provider: .openAI, accountLabel: nil, projectLabel: nil, modelLabel: "gpt-5.5", deploymentLabel: nil, provenance: .bounded(source: source, window: window), tokenUsage: TokenUsage(inputTokens: tokens, outputTokens: 0), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: refreshedAt, freshness: .fresh)
    }
}

private final class EntryCursor: @unchecked Sendable {
    private let lock = NSLock()
    private let entries: [URL]
    private let cancelAt: Int?
    private var index = 0

    init(entries: [URL], cancelAt: Int? = nil) {
        self.entries = entries
        self.cancelAt = cancelAt
    }

    var visitedCount: Int { lock.withLock { index } }

    func next() -> URL? {
        lock.withLock {
            guard index < entries.count else { return nil }
            index += 1
            if index == cancelAt {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return entries[index - 1]
        }
    }
}

private final class BoundedReaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data]
    private(set) var requestedByteCounts: [Int] = []

    init(data: Data) { self.data = [data] }
    init(data: [Data]) { self.data = data }

    func read(_ url: URL, byteCount: Int) -> Data {
        lock.withLock {
            requestedByteCounts.append(byteCount)
            return data.removeFirst()
        }
    }
}

private final class BudgetReaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumReturnSize: Int
    private(set) var requestedByteCounts: [Int] = []
    private(set) var returnedByteCount = 0
    init(maximumReturnSize: Int) { self.maximumReturnSize = maximumReturnSize }
    func read(_ url: URL, byteCount: Int) -> Data {
        lock.withLock {
            requestedByteCounts.append(byteCount)
            let count = min(byteCount, maximumReturnSize)
            returnedByteCount += count
            return Data(repeating: 0x20, count: count)
        }
    }
}

private final class URLMappingReader: @unchecked Sendable {
    private let lock = NSLock()
    private let data: [URL: Data]
    private(set) var readURLs: [URL] = []
    init(data: [URL: Data]) { self.data = data }
    func read(_ url: URL, byteCount: Int) -> Data {
        lock.withLock {
            readURLs.append(url)
            return Data((data[url] ?? Data()).prefix(byteCount))
        }
    }
}

enum NewestCandidateFailure: Sendable {
    case unreadable
    case grown
}

private struct TestReadFailure: Error {}

private final class FailingNewestReader: @unchecked Sendable {
    private let newest: URL
    private let failure: NewestCandidateFailure
    private let olderData: Data
    init(newest: URL, failure: NewestCandidateFailure, olderData: Data) {
        self.newest = newest
        self.failure = failure
        self.olderData = olderData
    }
    func read(_ url: URL, byteCount: Int) throws -> Data {
        guard url == newest else { return Data(olderData.prefix(byteCount)) }
        switch failure {
        case .unreadable: throw TestReadFailure()
        case .grown: return Data(repeating: 0x20, count: byteCount)
        }
    }
}

private func codexLine(timestamp: Date) -> Data {
    let text = ISO8601DateFormatter().string(from: timestamp)
    return Data("{\"timestamp\":\"\(text)\",\"payload\":{\"rate_limits\":{\"primary\":{\"used_percent\":1,\"window_minutes\":300}}}}".utf8)
}

private func metadataFiles(count: Int, modifiedAt: Date) throws -> (root: URL, files: [URL]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let files = try (0..<count).map { index in
        let file = root.appendingPathComponent("\(index).jsonl")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        return file
    }
    return (root, files)
}
