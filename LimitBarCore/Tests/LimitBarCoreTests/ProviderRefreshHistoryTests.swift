import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Provider refresh history")
struct ProviderRefreshHistoryTests {
    @Test("duration boundaries map to fixed safe buckets", arguments: [
        (0.0, ProviderRefreshDurationBucket.underOneSecond),
        (0.999, .underOneSecond),
        (1.0, .oneToFiveSeconds),
        (4.999, .oneToFiveSeconds),
        (5.0, .fiveToThirtySeconds),
        (29.999, .fiveToThirtySeconds),
        (30.0, .overThirtySeconds),
    ])
    func durationBuckets(duration: TimeInterval, expected: ProviderRefreshDurationBucket) throws {
        #expect(try ProviderRefreshDurationBucket(duration: duration) == expected)
    }

    @Test("invalid duration and duplicate windows are rejected")
    func validation() throws {
        #expect(throws: ProviderRefreshHistoryError.invalidDuration) {
            try ProviderRefreshDurationBucket(duration: -.infinity)
        }
        let window = try #require(windows.first)
        #expect(throws: ProviderRefreshHistoryError.invalidWindows) {
            try ProviderRefreshHistoryEntry(
                product: .anthropicAPI,
                outcome: .success,
                startedAt: Date(timeIntervalSince1970: 4_000_000),
                duration: 1,
                affectedWindows: [window, window]
            )
        }
    }

    @Test("component outcomes preserve partial failure and cancellation")
    func batchOutcomeClassification() {
        #expect(ProviderRefreshOutcome(usage: AnthropicRefreshResult.success([]), cost: .failure(.networkUnavailable)) == .partialFailure)
        #expect(ProviderRefreshOutcome(usage: OpenAIRefreshResult.cancelled, cost: .cancelled) == .cancelled)
        #expect(ProviderRefreshOutcome(usage: OpenAIRefreshResult.failure(.authenticationRejected), cost: .failure(.networkUnavailable)) == .authenticationFailure)
        #expect(ProviderRefreshOutcome(usage: AnthropicRefreshResult.failure(.networkUnavailable), cost: .failure(.networkUnavailable)) == .networkFailure)
    }

    @Test("schema contains only allow-listed tables and columns")
    func schemaAllowList() throws {
        let store = try SQLiteProviderRefreshHistoryStore.inMemory()

        #expect(try store.schemaObjects() == [
            "table:provider_refresh_history", "table:provider_refresh_windows",
            "index:provider_refresh_history_product_started",
        ])
        #expect(try store.columnNames(table: "provider_refresh_history") == [
            "id", "schema_version", "product", "operation", "outcome", "started_at", "duration_bucket",
        ])
        #expect(try store.columnNames(table: "provider_refresh_windows") == [
            "entry_id", "ordinal", "window_kind", "window_start", "window_end", "calendar_basis", "aggregation_version",
        ])
    }

    @Test("schema rejects future and malformed variants without mutation")
    func adversarialSchemas() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let variants: [(String, String)] = [
            ("future", "PRAGMA user_version = 2; CREATE TABLE future_private_payload (value TEXT);"),
            ("unknown", "CREATE TABLE unrelated_private_payload (value TEXT);"),
            ("weak", """
            CREATE TABLE provider_refresh_history (
                id INTEGER PRIMARY KEY, schema_version INTEGER NOT NULL, product TEXT NOT NULL,
                operation TEXT NOT NULL, outcome TEXT NOT NULL, started_at REAL NOT NULL, duration_bucket TEXT NOT NULL
            );
            CREATE TABLE provider_refresh_windows (
                entry_id INTEGER NOT NULL, ordinal INTEGER NOT NULL, window_kind TEXT NOT NULL,
                window_start REAL NOT NULL, window_end REAL NOT NULL, calendar_basis TEXT NOT NULL,
                aggregation_version INTEGER NOT NULL, PRIMARY KEY (entry_id, ordinal)
            );
            CREATE INDEX provider_refresh_history_product_started ON provider_refresh_history(product, started_at DESC);
            PRAGMA user_version = 1;
            """),
            ("wrong-foreign-key", """
            CREATE TABLE provider_refresh_history (
                id INTEGER PRIMARY KEY,
                schema_version INTEGER NOT NULL CHECK (schema_version = 1),
                product TEXT NOT NULL CHECK (product IN ('anthropic_api', 'openai_api')),
                operation TEXT NOT NULL CHECK (operation = 'usage_and_cost'),
                outcome TEXT NOT NULL CHECK (outcome IN ('success', 'partial_failure', 'cancelled', 'authentication_failure', 'network_failure', 'failed')),
                started_at REAL NOT NULL,
                duration_bucket TEXT NOT NULL CHECK (duration_bucket IN ('under_1_second', '1_to_5_seconds', '5_to_30_seconds', 'over_30_seconds'))
            );
            CREATE TABLE provider_refresh_windows (
                entry_id INTEGER NOT NULL REFERENCES provider_refresh_history(id),
                ordinal INTEGER NOT NULL CHECK (ordinal >= 0 AND ordinal < 3),
                window_kind TEXT NOT NULL CHECK (window_kind IN ('today', 'currentWeek')),
                window_start REAL NOT NULL,
                window_end REAL NOT NULL CHECK (window_end > window_start),
                calendar_basis TEXT NOT NULL CHECK (calendar_basis IN ('localCalendar', 'utcBilling')),
                aggregation_version INTEGER NOT NULL CHECK (aggregation_version > 0),
                PRIMARY KEY (entry_id, ordinal)
            );
            CREATE INDEX provider_refresh_history_product_started ON provider_refresh_history(product, started_at DESC);
            PRAGMA user_version = 1;
            """),
        ]

        for (name, sql) in variants {
            let path = directory.appendingPathComponent("\(name).sqlite").path
            try makeDatabase(path: path, sql: sql)
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(throws: ProviderRefreshHistoryError.schemaFailed) {
                try SQLiteProviderRefreshHistoryStore(path: path)
            }
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        }
    }

    @Test("history persists across store instances")
    func persistence() throws {
        let path = temporaryPath()
        let now = Date(timeIntervalSince1970: 4_000_000)
        try SQLiteProviderRefreshHistoryStore(path: path).record(try entry(startedAt: now), now: now)

        let reopened = try SQLiteProviderRefreshHistoryStore(path: path)

        #expect(try reopened.entries(for: .anthropicAPI, now: now) == [entry(startedAt: now)])
    }

    @Test("pre-fetch failures retain an explicit entry with no affected windows")
    func prefetchFailure() throws {
        let store = try SQLiteProviderRefreshHistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 4_000_000)
        let failed = try ProviderRefreshHistoryEntry(
            product: .anthropicAPI,
            outcome: .failed,
            startedAt: now,
            duration: 0.1,
            affectedWindows: []
        )

        try store.record(failed, now: now)

        #expect(try store.entries(for: .anthropicAPI, now: now) == [failed])
    }

    @Test("history retains thirty days inclusively and two hundred newest entries per product")
    func retention() throws {
        let store = try SQLiteProviderRefreshHistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 20_000_000)
        try store.record(entry(startedAt: now.addingTimeInterval(-SQLiteProviderRefreshHistoryStore.retentionInterval)), now: now)
        try store.record(entry(startedAt: now.addingTimeInterval(-SQLiteProviderRefreshHistoryStore.retentionInterval - 0.001)), now: now)
        #expect(try store.entries(for: .anthropicAPI, now: now).map(\.startedAt) == [
            now.addingTimeInterval(-SQLiteProviderRefreshHistoryStore.retentionInterval),
        ])
        for offset in 0...SQLiteProviderRefreshHistoryStore.maximumEntriesPerProduct {
            try store.record(entry(startedAt: now.addingTimeInterval(TimeInterval(-offset))), now: now)
        }
        try store.record(entry(product: .openAIAPI, startedAt: now), now: now)

        let anthropic = try store.entries(for: .anthropicAPI, now: now)
        #expect(anthropic.count == 200)
        #expect(anthropic.first?.startedAt == now)
        #expect(anthropic.last?.startedAt == now.addingTimeInterval(-199))
        #expect(try store.entries(for: .openAIAPI, now: now).count == 1)
    }

    @Test("summary separates latest outcome from last full success")
    func summary() throws {
        let store = try SQLiteProviderRefreshHistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 4_000_000)
        try store.record(entry(outcome: .success, startedAt: now.addingTimeInterval(-10)), now: now)
        try store.record(entry(outcome: .partialFailure, startedAt: now), now: now)

        let summary = try store.summary(for: .anthropicAPI, now: now)

        #expect(summary.latest?.outcome == .partialFailure)
        #expect(summary.lastFullSuccess?.startedAt == now.addingTimeInterval(-10))
    }

    @Test("clear history is independent from other application data")
    func clearHistory() throws {
        let store = try SQLiteProviderRefreshHistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 4_000_000)
        try store.record(entry(startedAt: now), now: now)

        try store.deleteAll()

        #expect(try store.entries(for: .anthropicAPI, now: now).isEmpty)
    }

    @Test("repository failures are best effort")
    func repositoryFailureDoesNotEscape() async throws {
        let repository = ProviderRefreshHistoryRepository { throw ProviderRefreshHistoryError.openFailed }
        let now = Date(timeIntervalSince1970: 4_000_000)
        let historyEntry = try entry(startedAt: now)

        #expect(await repository.record(historyEntry, now: now) == false)
        #expect(await repository.summaries(now: now).isEmpty)
        #expect(await repository.deleteAll() == false)
    }

    private func entry(
        product: ProviderRefreshProduct = .anthropicAPI,
        outcome: ProviderRefreshOutcome = .success,
        startedAt: Date
    ) throws -> ProviderRefreshHistoryEntry {
        try ProviderRefreshHistoryEntry(
            product: product,
            outcome: outcome,
            startedAt: startedAt,
            duration: 1.5,
            affectedWindows: windows
        )
    }

    private var windows: [ExactUsageWindow] {
        get throws {
            let current = try CurrentUsageWindows.resolve(
                at: Date(timeIntervalSince1970: 4_000_000),
                calendar: Calendar(identifier: .gregorian)
            )
            return [current.today, current.currentWeek, current.utcBillingWeek]
        }
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-refresh-history-\(UUID().uuidString).sqlite")
            .path
    }

    private func makeDatabase(path: String, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw ProviderRefreshHistoryError.openFailed
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ProviderRefreshHistoryError.schemaFailed
        }
    }
}
