import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Usage attribution store")
struct UsageAttributionStoreTests {
    @Test("round trips normalized breakdowns and replaces one source revision")
    func roundTripAndReplace() throws {
        let store = try SQLiteUsageAttributionStore.inMemory()
        let now = try date("2026-07-12T12:00:00Z")
        let builtIn = try breakdown(source: .builtInLocalLog, project: "alpha", observedAt: now)
        let customID = try #require(UUID(uuidString: "9598575e-259b-47df-9f34-f161c9015e65"))
        let custom = try breakdown(source: .custom(customID), project: "custom", observedAt: now)

        try store.replace([builtIn], source: .builtInLocalLog, sourceRevision: "revision-a", now: now)
        try store.replace([custom], source: .custom(customID), sourceRevision: "revision-c", now: now)
        try store.replace([try breakdown(source: .builtInLocalLog, project: "beta", observedAt: now)], source: .builtInLocalLog, sourceRevision: "revision-b", now: now)

        let retained = try store.all(now: now)
        #expect(Set(retained.compactMap(\.project?.id)) == ["beta", "custom"])
        #expect(retained.allSatisfy { $0.evidenceKind == .observedLocalBreakdown })
    }

    @Test("independent deletion survives restart and suppresses an unchanged source revision")
    func deletionSuppressionSurvivesRestart() throws {
        let path = temporaryDatabasePath()
        let now = try date("2026-07-12T12:00:00Z")
        let value = try breakdown(source: .builtInLocalLog, project: "alpha", observedAt: now)
        do {
            let store = try SQLiteUsageAttributionStore(path: path)
            try store.replace([value], source: .builtInLocalLog, sourceRevision: "revision-a", now: now)
            try store.deleteAll(now: now)
            #expect(try store.all(now: now).isEmpty)
        }

        let reopened = try SQLiteUsageAttributionStore(path: path)
        try reopened.replace([value], source: .builtInLocalLog, sourceRevision: "revision-a", now: now.addingTimeInterval(1))
        #expect(try reopened.all(now: now.addingTimeInterval(1)).isEmpty)
        try reopened.replace([value], source: .builtInLocalLog, sourceRevision: "revision-b", now: now.addingTimeInterval(2))
        #expect(try reopened.all(now: now.addingTimeInterval(2)) == [value])
    }

    @Test("retention is bounded by observed age and row count")
    func boundedRetention() throws {
        let now = try date("2026-07-12T12:00:00Z")
        let store = try SQLiteUsageAttributionStore.inMemory(maximumRecords: 2, retention: 60)
        let old = try breakdown(source: .builtInLocalLog, project: "old", observedAt: now.addingTimeInterval(-61))
        let first = try breakdown(source: .builtInLocalLog, project: "first", observedAt: now.addingTimeInterval(-2))
        let second = try breakdown(source: .builtInLocalLog, project: "second", observedAt: now.addingTimeInterval(-1))
        let third = try breakdown(source: .builtInLocalLog, project: "third", observedAt: now)

        try store.replace([old, first, second, third], source: .builtInLocalLog, sourceRevision: "revision-a", now: now)

        #expect(try store.all(now: now).compactMap(\.project?.id) == ["second", "third"])
    }

    @Test("removing custom sources preserves built-in attribution")
    func customSourceDeletionIsScoped() throws {
        let store = try SQLiteUsageAttributionStore.inMemory()
        let now = try date("2026-07-12T12:00:00Z")
        let customID = try #require(UUID(uuidString: "9598575e-259b-47df-9f34-f161c9015e65"))
        try store.replace([try breakdown(source: .builtInLocalLog, project: "built-in", observedAt: now)], source: .builtInLocalLog, sourceRevision: "built-in", now: now)
        try store.replace([try breakdown(source: .custom(customID), project: "custom", observedAt: now)], source: .custom(customID), sourceRevision: "custom", now: now)

        try store.deleteCustomSources(excluding: [], now: now)

        let retained = try store.all(now: now)
        #expect(retained.count == 1)
        #expect(retained.first?.source == .builtInLocalLog)
    }

    @Test("unknown and malformed store schemas fail closed without mutation")
    func unknownSchemasFailClosed() throws {
        let future = temporaryDatabasePath()
        let malformed = temporaryDatabasePath()
        try execute("PRAGMA user_version = 2;", path: future)
        try execute("CREATE TABLE usage_attribution_breakdowns (id TEXT PRIMARY KEY); PRAGMA user_version = 1;", path: malformed)
        let futureBytes = try Data(contentsOf: URL(fileURLWithPath: future))
        let malformedBytes = try Data(contentsOf: URL(fileURLWithPath: malformed))

        #expect(throws: UsageAttributionStoreError.schemaFailed) { try SQLiteUsageAttributionStore(path: future) }
        #expect(throws: UsageAttributionStoreError.schemaFailed) { try SQLiteUsageAttributionStore(path: malformed) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: future)) == futureBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: malformed)) == malformedBytes)
    }

    private func breakdown(source: UsageMetricSource, project: String, observedAt: Date) throws -> ObservedLocalAttributionBreakdown {
        let window = try ExactUsageWindow(
            timeWindow: .today,
            start: try date("2026-07-12T00:00:00Z"),
            end: try date("2026-07-13T00:00:00Z"),
            basis: .localCalendar
        )
        return ObservedLocalAttributionBreakdown(
            source: source,
            provider: source == .builtInLocalLog ? .openAI : .custom,
            window: window,
            model: "gpt-5",
            deployment: nil,
            project: CollectorAttribution(id: project, label: project.capitalized),
            agent: CollectorAttribution(id: "reviewer", label: "Reviewer"),
            tokenUsage: TokenUsage(inputTokens: 3, outputTokens: 2),
            eventIDs: [try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))],
            observedAt: observedAt
        )
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func execute(_ sql: String, path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw UsageAttributionStoreError.openFailed }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw UsageAttributionStoreError.schemaFailed }
    }
}
