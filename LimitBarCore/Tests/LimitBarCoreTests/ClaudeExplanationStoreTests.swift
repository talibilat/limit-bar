import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Claude Code explanation store")
struct ClaudeExplanationStoreTests {
    @Test("persists normalized movement and deletes independently")
    func persistenceAndDeletion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteClaudeExplanationStore(path: url.path)
        let now = Date(timeIntervalSince1970: 100)
        let value = ClaudeQuotaExplanation(
            providerProduct: .claudeCode,
            intervalStart: now,
            intervalEnd: now.addingTimeInterval(60),
            quotaResetBoundary: now.addingTimeInterval(600),
            reportedQuotaMovementPercent: 2,
            attribution: .unavailable(.receiverNotConfigured),
            unattributed: true,
            inferredAllocation: nil,
            observationIdentities: [],
            observationIdentityCount: 2,
            observationSpan: 60,
            evidenceAge: 0,
            methodVersion: ClaudeQuotaExplanationEngine.methodVersion,
            sourceAdapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion,
            sourceVersion: nil
        )

        try store.record(.movement(value), now: now)
        let reopened = try SQLiteClaudeExplanationStore(path: url.path)

        guard case let .movement(restored) = try reopened.latest(now: now) else {
            Issue.record("Expected restored movement")
            return
        }
        #expect(restored.reportedQuotaMovementPercent == 2)
        #expect(restored.observationIdentityCount == 2)
        #expect(restored.observationIdentities.isEmpty)
        guard case let .movement(aged) = try reopened.latest(now: now.addingTimeInterval(700)) else {
            Issue.record("Expected completed retained movement")
            return
        }
        #expect(aged.evidenceAge == 640)
        #expect(aged.lifecycle == .completed)
        try reopened.deleteAll()
        #expect(try reopened.latest(now: now) == nil)
    }

    @Test("retention is bounded and source adapter changes fail closed")
    func boundsAndVersions() throws {
        let store = try SQLiteClaudeExplanationStore.inMemory(maximumRecords: 2, retention: 100)
        let now = Date(timeIntervalSince1970: 1_000)
        try store.record(.unavailable(.insufficientObservations), now: now.addingTimeInterval(-200))
        try store.record(.unavailable(.counterDecreased), now: now.addingTimeInterval(-20))
        try store.record(.unavailable(.incompatibleQuotaWindow), now: now)
        #expect(try store.recordCount(now: now) == 2)
        #expect(try store.latest(now: now) == .unavailable(.incompatibleQuotaWindow))
        #expect(try store.recordCount(now: now.addingTimeInterval(101)) == 0)
    }

    @Test("future and malformed schemas are rejected without mutation")
    func rejectsUnknownSchemasWithoutMutation() throws {
        for sql in [
            "PRAGMA user_version = 2;",
            "CREATE TABLE claude_explanation_findings (id INTEGER PRIMARY KEY); CREATE INDEX claude_explanation_findings_recorded ON claude_explanation_findings (id); PRAGMA user_version = 1;",
            "CREATE TABLE claude_explanation_findings (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at REAL NOT NULL, payload TEXT NOT NULL); CREATE INDEX claude_explanation_findings_recorded ON claude_explanation_findings (id); PRAGMA user_version = 1;",
        ] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            var database: OpaquePointer?
            #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(database)
            let original = try Data(contentsOf: url)

            #expect(throws: ClaudeExplanationStoreError.schemaFailed) {
                try SQLiteClaudeExplanationStore(path: url.path)
            }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test("interrupted writes roll back inserted and retention changes")
    func interruptedWriteRollsBack() throws {
        struct Interruption: Error {}
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteClaudeExplanationStore(path: url.path, maximumRecords: 1, retention: 10)
        let now = Date(timeIntervalSince1970: 100)
        try store.record(.unavailable(.insufficientObservations), now: now)

        #expect(throws: Interruption.self) {
            try store.recordForTesting(.unavailable(.counterDecreased), now: now.addingTimeInterval(20)) {
                throw Interruption()
            }
        }
        #expect(try store.recordCount(now: now) == 1)
        #expect(try store.latest(now: now) == .unavailable(.insufficientObservations))
    }
}
