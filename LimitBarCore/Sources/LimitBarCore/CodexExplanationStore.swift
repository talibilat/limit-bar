import Foundation
import SQLite3

public enum CodexExplanationStoreError: Error, Equatable {
    case openFailed
    case schemaFailed
    case writeFailed
    case readFailed
}

public final class SQLiteCodexExplanationStore: @unchecked Sendable {
    private static let schemaVersion = 2
    private static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60

    private static let createTableV1SQL = """
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
    """
    private static let createTableSQL = """
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
        window_identifier TEXT CHECK (window_identifier IS NULL OR length(window_identifier) BETWEEN 1 AND 128),
        CHECK (cached_input_tokens <= input_tokens),
        CHECK (reason IS NULL OR status = 'unavailable'),
        CHECK (quota_reset_boundary IS NULL OR status IN ('available', 'partial', 'observed_zero'))
    );
    """
    private static let createRecordedIndexSQL = "CREATE INDEX codex_explanation_findings_recorded ON codex_explanation_findings (recorded_at);"

    private let maximumRecords: Int
    private let retention: TimeInterval
    private var database: OpaquePointer?

    public init(
        path: String,
        maximumRecords: Int = 100,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        busyTimeoutMilliseconds: Int32 = 5_000
    ) throws {
        guard maximumRecords > 0, retention.isFinite, retention >= 0 else { throw CodexExplanationStoreError.schemaFailed }
        self.maximumRecords = maximumRecords
        self.retention = retention
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw CodexExplanationStoreError.openFailed
        }
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        do {
            try createSchema()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public static func inMemory(maximumRecords: Int = 100, retention: TimeInterval = 30 * 24 * 60 * 60) throws -> SQLiteCodexExplanationStore {
        try SQLiteCodexExplanationStore(path: ":memory:", maximumRecords: maximumRecords, retention: retention)
    }

    public static func applicationSupportStore(fileManager: FileManager = .default) throws -> SQLiteCodexExplanationStore {
        let applicationSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = applicationSupport.appendingPathComponent("LimitBar", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteCodexExplanationStore(path: directory.appendingPathComponent("codex-explanations.sqlite").path)
    }

    public func record(_ state: CodexQuotaExplanationState, now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite else { throw CodexExplanationStoreError.writeFailed }
        let normalized = NormalizedFinding(state: state)
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare("""
            INSERT INTO codex_explanation_findings
                (recorded_at, status, reason, adapter_version, interval_start, interval_end, quota_reset_boundary, coverage_start, coverage_end,
                 quota_movement_percent, input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens,
                 session_count, evidence_count, observation_count, barrier_categories, window_identifier)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            bind(normalized.status, at: 2, in: statement)
            bindNullable(normalized.reason, at: 3, in: statement)
            bind(normalized.adapterVersion, at: 4, in: statement)
            bindNullable(normalized.intervalStart, at: 5, in: statement)
            bindNullable(normalized.intervalEnd, at: 6, in: statement)
            bindNullable(normalized.quotaResetBoundary, at: 7, in: statement)
            bindNullable(normalized.coverageStart, at: 8, in: statement)
            bindNullable(normalized.coverageEnd, at: 9, in: statement)
            bindNullable(normalized.quotaMovementPercent, at: 10, in: statement)
            sqlite3_bind_int64(statement, 11, normalized.tokens.input)
            sqlite3_bind_int64(statement, 12, normalized.tokens.cachedInput)
            sqlite3_bind_int64(statement, 13, normalized.tokens.output)
            sqlite3_bind_int64(statement, 14, normalized.tokens.reasoningOutput)
            sqlite3_bind_int64(statement, 15, Int64(normalized.sessionCount))
            sqlite3_bind_int64(statement, 16, Int64(normalized.evidenceCount))
            sqlite3_bind_int64(statement, 17, Int64(normalized.observationCount))
            bind(normalized.barrierCategories.joined(separator: ","), at: 18, in: statement)
            bindNullable(normalized.windowIdentifier, at: 19, in: statement)
            try stepDone(statement, error: .writeFailed)
            try pruneInTransaction(now: now)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func latest(now: Date = Date()) throws -> CodexQuotaExplanationState? {
        try prune(now: now)
        let statement = try prepare("""
        SELECT status, reason, adapter_version, interval_start, interval_end, coverage_start, coverage_end,
               quota_reset_boundary, quota_movement_percent, input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens,
               session_count, evidence_count, observation_count, barrier_categories, window_identifier
        FROM codex_explanation_findings ORDER BY recorded_at DESC, id DESC LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw CodexExplanationStoreError.readFailed }
        return try state(from: statement, now: now)
    }

    public func recordCount(now: Date = Date()) throws -> Int {
        try prune(now: now)
        let statement = try prepare("SELECT COUNT(*) FROM codex_explanation_findings;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CodexExplanationStoreError.readFailed }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func deleteAll() throws {
        try execute("DELETE FROM codex_explanation_findings;")
    }

    private func createSchema() throws {
        let version = try schemaVersion()
        guard version <= Self.schemaVersion else { throw CodexExplanationStoreError.schemaFailed }
        let objects = try schemaObjects()
        if version == 1 {
            try migrateV1()
            return
        }
        if !objects.isEmpty || version != 0 {
            guard version == Self.schemaVersion else { throw CodexExplanationStoreError.schemaFailed }
            try validateCanonicalSchema()
            return
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(Self.createTableSQL)
            try execute(Self.createRecordedIndexSQL)
            try validateCanonicalSchema()
            try execute("PRAGMA user_version = \(Self.schemaVersion);")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func migrateV1() throws {
        guard try schemaObjects() == ["table:codex_explanation_findings", "index:codex_explanation_findings_recorded"],
              try schemaSQL(type: "table", name: "codex_explanation_findings") == Self.normalizedSQL(Self.createTableV1SQL),
              try schemaSQL(type: "index", name: "codex_explanation_findings_recorded") == Self.normalizedSQL(Self.createRecordedIndexSQL) else {
            throw CodexExplanationStoreError.schemaFailed
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("ALTER TABLE codex_explanation_findings RENAME TO codex_explanation_findings_v1;")
            try execute("DROP INDEX codex_explanation_findings_recorded;")
            try execute(Self.createTableSQL)
            try execute("""
            INSERT INTO codex_explanation_findings
                (id, recorded_at, status, reason, adapter_version, interval_start, interval_end, quota_reset_boundary,
                 coverage_start, coverage_end, quota_movement_percent, input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, session_count, evidence_count, observation_count, barrier_categories, window_identifier)
            SELECT id, recorded_at, status, reason, adapter_version, interval_start, interval_end, quota_reset_boundary,
                   coverage_start, coverage_end, quota_movement_percent, input_tokens, cached_input_tokens, output_tokens,
                   reasoning_output_tokens, session_count, evidence_count, observation_count, barrier_categories, NULL
            FROM codex_explanation_findings_v1;
            """)
            try execute("DROP TABLE codex_explanation_findings_v1;")
            try execute(Self.createRecordedIndexSQL)
            try execute("PRAGMA user_version = \(Self.schemaVersion);")
            try validateCanonicalSchema()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func validateCanonicalSchema() throws {
        guard try schemaObjects() == ["table:codex_explanation_findings", "index:codex_explanation_findings_recorded"],
              try schemaSQL(type: "table", name: "codex_explanation_findings") == Self.normalizedSQL(Self.createTableSQL),
              try schemaSQL(type: "index", name: "codex_explanation_findings_recorded") == Self.normalizedSQL(Self.createRecordedIndexSQL) else {
            throw CodexExplanationStoreError.schemaFailed
        }
    }

    private func prune(now: Date) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try pruneInTransaction(now: now)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func pruneInTransaction(now: Date) throws {
        guard now.timeIntervalSince1970.isFinite else { throw CodexExplanationStoreError.writeFailed }
        let cutoff = now.addingTimeInterval(-retention).timeIntervalSince1970
        let age = try prepare("DELETE FROM codex_explanation_findings WHERE recorded_at < ?;")
        defer { sqlite3_finalize(age) }
        sqlite3_bind_double(age, 1, cutoff)
        try stepDone(age, error: .writeFailed)
        let count = try prepare("""
        DELETE FROM codex_explanation_findings
        WHERE id NOT IN (
            SELECT id FROM codex_explanation_findings ORDER BY recorded_at DESC, id DESC LIMIT ?
        );
        """)
        defer { sqlite3_finalize(count) }
        sqlite3_bind_int64(count, 1, Int64(maximumRecords))
        try stepDone(count, error: .writeFailed)
    }

    private func state(from statement: OpaquePointer?, now: Date) throws -> CodexQuotaExplanationState {
        guard let status = stringColumn(statement, index: 0), let adapterVersion = stringColumn(statement, index: 2) else {
            throw CodexExplanationStoreError.readFailed
        }
        guard adapterVersion == CodexRolloutEvidenceAdapter.adapterVersion else { return .unavailable(.unsupportedEvidence) }
        let reason = stringColumn(statement, index: 1)
        let windowIdentifier = stringColumn(statement, index: 17)
        let movement = optionalDouble(statement, index: 8)
        let tokens = CodexMeasuredTokens(
            input: sqlite3_column_int64(statement, 9),
            cachedInput: sqlite3_column_int64(statement, 10),
            output: sqlite3_column_int64(statement, 11),
            reasoningOutput: sqlite3_column_int64(statement, 12)
        )
        if status == "observed_zero" {
            guard let movement,
                  let intervalStart = optionalDate(statement, index: 3),
                  let intervalEnd = optionalDate(statement, index: 4),
                  let quotaResetBoundary = optionalDate(statement, index: 7) else {
                return .unavailable(.unsupportedEvidence)
            }
            if quotaResetBoundary <= now { return .unavailable(.expiredQuotaWindow) }
            return .observedZero(CodexQuotaObservedZero(
                intervalStart: intervalStart,
                intervalEnd: intervalEnd,
                calculatedQuotaMovementPercent: movement,
                quotaResetBoundary: quotaResetBoundary,
                observationIdentities: [],
                evidenceIdentities: [],
                quotaWindowIdentity: windowIdentifier.flatMap {
                    try? QuotaWindowIdentity(product: .codex, identifier: $0, resetBoundary: quotaResetBoundary)
                },
                observationIdentityCount: Int(sqlite3_column_int64(statement, 15)),
                evidenceIdentityCount: Int(sqlite3_column_int64(statement, 14))
            ))
        }
        if status == "unavailable", let reason, let value = CodexQuotaExplanationUnavailableReason(rawValue: reason) {
            return .unavailable(value)
        }
        guard let intervalStart = optionalDate(statement, index: 3), let intervalEnd = optionalDate(statement, index: 4),
              let coverageStart = optionalDate(statement, index: 5), let coverageEnd = optionalDate(statement, index: 6),
              let quotaResetBoundary = optionalDate(statement, index: 7),
              let movement else { throw CodexExplanationStoreError.readFailed }
        if quotaResetBoundary <= now { return .unavailable(.expiredQuotaWindow) }
        let barriers = (stringColumn(statement, index: 16) ?? "").split(separator: ",").compactMap { CodexEvidenceBarrier(rawValue: String($0)) }
        let explanation = CodexQuotaExplanation(
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            quotaResetBoundary: quotaResetBoundary,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            calculatedQuotaMovementPercent: movement,
            observedLocalBreakdown: CodexObservedLocalBreakdown(tokens: tokens, sessionCount: Int(sqlite3_column_int64(statement, 13))),
            unattributed: true,
            inferredAllocation: nil,
            observationIdentities: [],
            evidenceIdentities: [],
            observationIdentityCount: Int(sqlite3_column_int64(statement, 15)),
            evidenceIdentityCount: Int(sqlite3_column_int64(statement, 14)),
            adapterVersion: adapterVersion,
            barriers: barriers,
            quotaWindowIdentity: windowIdentifier.flatMap {
                try? QuotaWindowIdentity(product: .codex, identifier: $0, resetBoundary: quotaResetBoundary)
            }
        )
        if status == "available" { return .available(explanation) }
        if status == "partial" { return .partial(explanation) }
        throw CodexExplanationStoreError.readFailed
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CodexExplanationStoreError.schemaFailed }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func schemaObjects() throws -> Set<String> {
        let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var objects = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let type = stringColumn(statement, index: 0), let name = stringColumn(statement, index: 1) else { throw CodexExplanationStoreError.schemaFailed }
            objects.insert("\(type):\(name)")
        }
        return objects
    }

    private func schemaSQL(type: String, name: String) throws -> String {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(type, at: 1, in: statement)
        bind(name, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let sql = stringColumn(statement, index: 0) else { throw CodexExplanationStoreError.schemaFailed }
        return Self.normalizedSQL(sql)
    }

    private static func normalizedSQL(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ";"))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CodexExplanationStoreError.schemaFailed }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw CodexExplanationStoreError.schemaFailed }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?, error: CodexExplanationStoreError) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindNullable(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        bind(value, at: index, in: statement)
    }

    private func bindNullable(_ value: Date?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }

    private func bindNullable(_ value: Double?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_double(statement, index, value)
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func optionalDouble(_ statement: OpaquePointer?, index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func optionalDate(_ statement: OpaquePointer?, index: Int32) -> Date? {
        optionalDouble(statement, index: index).map { Date(timeIntervalSince1970: $0) }
    }
}

private struct NormalizedFinding {
    let status: String
    let reason: String?
    let adapterVersion: String
    let intervalStart: Date?
    let intervalEnd: Date?
    let quotaResetBoundary: Date?
    let coverageStart: Date?
    let coverageEnd: Date?
    let quotaMovementPercent: Double?
    let tokens: CodexMeasuredTokens
    let sessionCount: Int
    let evidenceCount: Int
    let observationCount: Int
    let barrierCategories: [String]
    let windowIdentifier: String?

    init(state: CodexQuotaExplanationState) {
        switch state {
        case let .available(explanation):
            self.init(status: "available", explanation: explanation, reason: nil)
        case let .partial(explanation):
            self.init(status: "partial", explanation: explanation, reason: nil)
        case let .observedZero(value):
            self.init(
                status: "observed_zero",
                reason: nil,
                adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
                intervalStart: value.intervalStart,
                intervalEnd: value.intervalEnd,
                quotaResetBoundary: value.quotaResetBoundary,
                coverageStart: nil,
                coverageEnd: nil,
                quotaMovementPercent: value.calculatedQuotaMovementPercent,
                tokens: CodexMeasuredTokens(input: 0, cachedInput: 0, output: 0, reasoningOutput: 0),
                sessionCount: 0,
                evidenceCount: value.evidenceIdentityCount,
                observationCount: value.observationIdentityCount,
                barrierCategories: [],
                windowIdentifier: value.quotaWindowIdentity?.identifier
            )
        case let .unavailable(value):
            self.init(
                status: "unavailable",
                reason: value.rawValue,
                adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
                intervalStart: nil,
                intervalEnd: nil,
                quotaResetBoundary: nil,
                coverageStart: nil,
                coverageEnd: nil,
                quotaMovementPercent: nil,
                tokens: CodexMeasuredTokens(input: 0, cachedInput: 0, output: 0, reasoningOutput: 0),
                sessionCount: 0,
                evidenceCount: 0,
                observationCount: 0,
                barrierCategories: [],
                windowIdentifier: nil
            )
        }
    }

    private init(status: String, explanation: CodexQuotaExplanation, reason: String?) {
        self.status = status
        self.reason = reason
        adapterVersion = explanation.adapterVersion
        intervalStart = explanation.intervalStart
        intervalEnd = explanation.intervalEnd
        quotaResetBoundary = explanation.quotaResetBoundary
        coverageStart = explanation.coverageStart
        coverageEnd = explanation.coverageEnd
        quotaMovementPercent = explanation.calculatedQuotaMovementPercent
        tokens = explanation.observedLocalBreakdown.tokens
        sessionCount = explanation.observedLocalBreakdown.sessionCount
        evidenceCount = explanation.evidenceIdentityCount
        observationCount = explanation.observationIdentityCount
        barrierCategories = explanation.barriers.map(\.rawValue).sorted()
        windowIdentifier = explanation.quotaWindowIdentity?.identifier
    }

    private init(
        status: String,
        reason: String?,
        adapterVersion: String,
        intervalStart: Date?,
        intervalEnd: Date?,
        quotaResetBoundary: Date?,
        coverageStart: Date?,
        coverageEnd: Date?,
        quotaMovementPercent: Double?,
        tokens: CodexMeasuredTokens,
        sessionCount: Int,
        evidenceCount: Int,
        observationCount: Int,
        barrierCategories: [String],
        windowIdentifier: String?
    ) {
        self.status = status
        self.reason = reason
        self.adapterVersion = adapterVersion
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.quotaResetBoundary = quotaResetBoundary
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
        self.quotaMovementPercent = quotaMovementPercent
        self.tokens = tokens
        self.sessionCount = sessionCount
        self.evidenceCount = evidenceCount
        self.observationCount = observationCount
        self.barrierCategories = barrierCategories
        self.windowIdentifier = windowIdentifier
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
