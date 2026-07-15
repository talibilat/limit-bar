import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Codex explanation store")
struct CodexExplanationStoreTests {
    @Test("latest compatible explanation survives reopen with bounded normalized fields")
    func latestSurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let explanation = CodexQuotaExplanation(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            quotaResetBoundary: now.addingTimeInterval(3_600),
            coverageStart: now.addingTimeInterval(-130),
            coverageEnd: now.addingTimeInterval(-50),
            reportedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(
                tokens: CodexMeasuredTokens(input: 3, cachedInput: 1, output: 2, reasoningOutput: 1),
                sessionCount: 1
            ),
            unattributed: true,
            allocationPercent: nil,
            observationIdentities: [],
            evidenceIdentities: ["private-digest-not-persisted"],
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            barriers: []
        )

        try SQLiteCodexExplanationStore(path: url.path).record(.available(explanation), now: now)
        let reopened = try SQLiteCodexExplanationStore(path: url.path)

        guard case let .available(restored) = try reopened.latest(now: now) else {
            Issue.record("Expected stored available explanation")
            return
        }
        #expect(restored.reportedQuotaMovementPercent == 2)
        #expect(restored.observedLocalBreakdown.tokens == CodexMeasuredTokens(input: 3, cachedInput: 1, output: 2, reasoningOutput: 1))
        #expect(restored.evidenceIdentities.isEmpty)
        #expect(restored.evidenceIdentityCount == 1)
        #expect(restored.observationIdentityCount == 0)
        #expect(try !SQLiteCodexExplanationTestDatabase.dump(path: url.path).contains("private-digest-not-persisted"))
    }

    @Test("retained available findings expire at their quota reset")
    func retainedFindingExpiresAtReset() throws {
        let store = try SQLiteCodexExplanationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let explanation = CodexQuotaExplanation(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            quotaResetBoundary: now.addingTimeInterval(60),
            coverageStart: now.addingTimeInterval(-130),
            coverageEnd: now.addingTimeInterval(-50),
            reportedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(
                tokens: CodexMeasuredTokens(input: 3, cachedInput: 1, output: 2, reasoningOutput: 1),
                sessionCount: 1
            ),
            unattributed: true,
            allocationPercent: nil,
            observationIdentities: [],
            evidenceIdentities: ["private-digest-not-persisted"],
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            barriers: []
        )

        try store.record(.available(explanation), now: now)

        guard case .available = try store.latest(now: now) else {
            Issue.record("Expected available before reset")
            return
        }
        #expect(try store.latest(now: now.addingTimeInterval(60)) == .unavailable(.expiredQuotaWindow))
    }

    @Test("retained findings from another adapter version are unsupported")
    func rejectsRetainedIncompatibleAdapterVersion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try SQLiteCodexExplanationTestDatabase.execute(path: url.path, sql: """
        CREATE TABLE codex_explanation_findings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recorded_at REAL NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('available', 'partial', 'observed_zero', 'unavailable')),
            reason TEXT,
            adapter_version TEXT NOT NULL,
            interval_start REAL,
            interval_end REAL,
            quota_reset_boundary REAL,
            coverage_start REAL,
            coverage_end REAL,
            quota_movement_percent REAL,
            input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
            cached_input_tokens INTEGER NOT NULL CHECK (cached_input_tokens >= 0),
            output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
            reasoning_output_tokens INTEGER NOT NULL CHECK (reasoning_output_tokens >= 0),
            session_count INTEGER NOT NULL CHECK (session_count >= 0),
            evidence_count INTEGER NOT NULL CHECK (evidence_count >= 0),
            observation_count INTEGER NOT NULL CHECK (observation_count >= 0),
            barrier_categories TEXT NOT NULL,
            CHECK (cached_input_tokens <= input_tokens),
            CHECK (reason IS NULL OR status = 'unavailable'),
            CHECK (quota_reset_boundary IS NULL OR status IN ('available', 'partial', 'observed_zero'))
        );
        CREATE INDEX codex_explanation_findings_recorded ON codex_explanation_findings (recorded_at);
        INSERT INTO codex_explanation_findings VALUES (1, 1800000000, 'available', NULL, 'old-adapter', 1799999900, 1799999960, 1800003600, 1799999890, 1799999970, 2.5, 8, 3, 4, 1, 2, 3, 2, '');
        PRAGMA user_version = 1;
        """)

        let store = try SQLiteCodexExplanationStore(path: url.path)

        #expect(try store.latest(now: now) == .unavailable(.unsupportedEvidence))
    }

    @Test("retention prunes by age and count transactionally")
    func retentionPrunes() throws {
        let store = try SQLiteCodexExplanationStore.inMemory(maximumRecords: 2, retention: 100)
        let now = Date(timeIntervalSince1970: 1_000)

        try store.record(.unavailable(.gap), now: now.addingTimeInterval(-200))
        try store.record(.unavailable(.insufficientObservations), now: now.addingTimeInterval(-20))
        try store.record(.observedZero(CodexQuotaObservedZero(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            calculatedQuotaMovementPercent: 1,
            quotaResetBoundary: now.addingTimeInterval(600),
            observationIdentities: [],
            evidenceIdentities: [],
            observationIdentityCount: 2,
            evidenceIdentityCount: 1
        )), now: now.addingTimeInterval(-10))
        try store.record(.unavailable(.unsupportedEvidence), now: now)

        #expect(try store.recordCount(now: now) == 2)
        #expect(try store.latest(now: now) == .unavailable(.unsupportedEvidence))
    }

    @Test("future and malformed schemas are rejected without mutation")
    func rejectsUnknownSchemas() throws {
        let future = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let malformed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer {
            try? FileManager.default.removeItem(at: future)
            try? FileManager.default.removeItem(at: malformed)
        }
        try SQLiteCodexExplanationTestDatabase.execute(path: future.path, sql: "PRAGMA user_version = 2;")
        try SQLiteCodexExplanationTestDatabase.execute(path: malformed.path, sql: "CREATE TABLE codex_explanation_findings (id INTEGER PRIMARY KEY); PRAGMA user_version = 1;")

        #expect(throws: CodexExplanationStoreError.schemaFailed) {
            try SQLiteCodexExplanationStore(path: future.path)
        }
        #expect(throws: CodexExplanationStoreError.schemaFailed) {
            try SQLiteCodexExplanationStore(path: malformed.path)
        }
        #expect(try SQLiteCodexExplanationTestDatabase.userVersion(path: future.path) == 2)
        #expect(try SQLiteCodexExplanationTestDatabase.schemaDump(path: malformed.path).contains("codex_explanation_findings"))
    }

    @Test("explicit deletion is independent")
    func deleteAll() throws {
        let store = try SQLiteCodexExplanationStore.inMemory()
        try store.record(.unavailable(.gap), now: Date(timeIntervalSince1970: 1))

        try store.deleteAll()

        #expect(try store.recordCount(now: Date(timeIntervalSince1970: 1)) == 0)
        #expect(try store.latest(now: Date(timeIntervalSince1970: 1)) == nil)
    }
}

private enum SQLiteCodexExplanationTestDatabase {
    static func execute(path: String, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw CodexExplanationStoreError.openFailed }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CodexExplanationStoreError.schemaFailed }
    }

    static func userVersion(path: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw CodexExplanationStoreError.openFailed }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else { throw CodexExplanationStoreError.schemaFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CodexExplanationStoreError.schemaFailed }
        return Int(sqlite3_column_int(statement, 0))
    }

    static func dump(path: String) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw CodexExplanationStoreError.openFailed }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT group_concat(coalesce(status, '') || coalesce(reason, '') || coalesce(adapter_version, ''), '|') FROM codex_explanation_findings;", -1, &statement, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: text)
    }

    static func schemaDump(path: String) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw CodexExplanationStoreError.openFailed }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT group_concat(name, '|') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';", -1, &statement, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: text)
    }
}
