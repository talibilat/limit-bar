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
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "team-a:primary:300", resetBoundary: now.addingTimeInterval(3_600))
        let explanation = CodexQuotaExplanation(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            quotaResetBoundary: now.addingTimeInterval(3_600),
            coverageStart: now.addingTimeInterval(-130),
            coverageEnd: now.addingTimeInterval(-50),
            calculatedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(
                tokens: CodexMeasuredTokens(input: 3, cachedInput: 1, output: 2, reasoningOutput: 1),
                sessionCount: 1
            ),
            unattributed: true,
            inferredAllocation: nil,
            observationIdentities: [],
            evidenceIdentities: ["private-digest-not-persisted"],
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            barriers: [],
            quotaWindowIdentity: identity
        )

        try SQLiteCodexExplanationStore(path: url.path).record(.available(explanation), now: now)
        let reopened = try SQLiteCodexExplanationStore(path: url.path)

        guard case let .available(restored) = try reopened.latest(now: now) else {
            Issue.record("Expected stored available explanation")
            return
        }
        #expect(restored.calculatedQuotaMovementPercent == 2)
        #expect(restored.observedLocalBreakdown.tokens == CodexMeasuredTokens(input: 3, cachedInput: 1, output: 2, reasoningOutput: 1))
        #expect(restored.evidenceIdentities.isEmpty)
        #expect(restored.evidenceIdentityCount == 1)
        #expect(restored.observationIdentityCount == 0)
        #expect(restored.quotaWindowIdentity == identity)
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
            calculatedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(
                tokens: CodexMeasuredTokens(input: 3, cachedInput: 1, output: 2, reasoningOutput: 1),
                sessionCount: 1
            ),
            unattributed: true,
            inferredAllocation: nil,
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

    @Test("canonical window identity survives available partial and observed-zero restoration")
    func canonicalIdentitySurvivesEveryFindingState() throws {
        let store = try SQLiteCodexExplanationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3_600)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "team-b:secondary:10080", resetBoundary: reset)
        let explanation = CodexQuotaExplanation(
            intervalStart: now.addingTimeInterval(-120), intervalEnd: now.addingTimeInterval(-60), quotaResetBoundary: reset,
            coverageStart: now.addingTimeInterval(-120), coverageEnd: now.addingTimeInterval(-60), calculatedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(tokens: CodexMeasuredTokens(input: 2, cachedInput: 0, output: 1, reasoningOutput: 0), sessionCount: 1),
            unattributed: true, inferredAllocation: nil, observationIdentities: [], evidenceIdentities: [],
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion, barriers: [], quotaWindowIdentity: identity
        )
        for state in [CodexQuotaExplanationState.available(explanation), .partial(explanation)] {
            try store.record(state, now: now)
            let restored: CodexQuotaExplanation? = switch try store.latest(now: now) {
            case let .available(value), let .partial(value): value
            default: nil
            }
            #expect(restored?.quotaWindowIdentity == identity)
        }
        let zero = CodexQuotaObservedZero(
            intervalStart: now.addingTimeInterval(-120), intervalEnd: now.addingTimeInterval(-60),
            calculatedQuotaMovementPercent: 0, quotaResetBoundary: reset,
            observationIdentities: [], evidenceIdentities: [], quotaWindowIdentity: identity
        )
        try store.record(.observedZero(zero), now: now)
        guard case let .observedZero(restoredZero) = try store.latest(now: now) else {
            Issue.record("Expected restored Observed Zero")
            return
        }
        #expect(restoredZero.quotaWindowIdentity == identity)
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
        let zeroIdentity = try QuotaWindowIdentity(product: .codex, identifier: "team-b:secondary:10080", resetBoundary: now.addingTimeInterval(600))
        try store.record(.observedZero(CodexQuotaObservedZero(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            calculatedQuotaMovementPercent: 1,
            quotaResetBoundary: now.addingTimeInterval(600),
            observationIdentities: [],
            evidenceIdentities: [],
            quotaWindowIdentity: zeroIdentity,
            observationIdentityCount: 2,
            evidenceIdentityCount: 1
        )), now: now.addingTimeInterval(-10))
        try store.record(.unavailable(.unsupportedEvidence), now: now)

        #expect(try store.recordCount(now: now) == 2)
        #expect(try store.latest(now: now) == .unavailable(.unsupportedEvidence))
    }

    @Test("v1 migrates transactionally and preserves legacy rows without inventing window identity")
    func migratesV1WithoutInventingIdentity() throws {
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
        INSERT INTO codex_explanation_findings VALUES (1, 1800000000, 'available', NULL, 'codex-rollout-observed-0.144.4', 1799999880, 1799999940, 1800003600, 1799999870, 1799999950, 2, 3, 1, 2, 1, 1, 1, 2, '');
        PRAGMA user_version = 1;
        """)

        let store = try SQLiteCodexExplanationStore(path: url.path)
        guard case let .available(restored) = try store.latest(now: now) else {
            Issue.record("Expected migrated finding")
            return
        }
        #expect(restored.quotaWindowIdentity == nil)
        #expect(try SQLiteCodexExplanationTestDatabase.userVersion(path: url.path) == 2)
        #expect(try SQLiteCodexExplanationTestDatabase.recordCount(path: url.path) == 1)
    }

    @Test("future and malformed schemas are rejected without mutation")
    func rejectsUnknownSchemas() throws {
        let future = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let malformed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer {
            try? FileManager.default.removeItem(at: future)
            try? FileManager.default.removeItem(at: malformed)
        }
        try SQLiteCodexExplanationTestDatabase.execute(path: future.path, sql: "PRAGMA user_version = 3;")
        try SQLiteCodexExplanationTestDatabase.execute(path: malformed.path, sql: "CREATE TABLE codex_explanation_findings (id INTEGER PRIMARY KEY); PRAGMA user_version = 2;")

        #expect(throws: CodexExplanationStoreError.schemaFailed) {
            try SQLiteCodexExplanationStore(path: future.path)
        }
        #expect(throws: CodexExplanationStoreError.schemaFailed) {
            try SQLiteCodexExplanationStore(path: malformed.path)
        }
        #expect(try SQLiteCodexExplanationTestDatabase.userVersion(path: future.path) == 3)
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

    static func recordCount(path: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw CodexExplanationStoreError.openFailed }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM codex_explanation_findings;", -1, &statement, nil) == SQLITE_OK else { throw CodexExplanationStoreError.readFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CodexExplanationStoreError.readFailed }
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
