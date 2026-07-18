import Foundation
import SQLite3

public enum ActivityReceiptStoreError: Error, Equatable {
    case openFailed, schemaFailed, writeFailed, readFailed
    case duplicateRecord, conflictingRecord, outOfOrder, incompatibleRuns, futureTimestamp
}

public final class SQLiteActivityReceiptStore: @unchecked Sendable {
    private static let schemaVersion = 1
    private static let createSQL = """
    CREATE TABLE activity_receipts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contract_version INTEGER NOT NULL CHECK (contract_version = 1),
        source TEXT NOT NULL CHECK (source IN ('claudeCode', 'codexExec')),
        adapter_schema TEXT NOT NULL,
        client_version TEXT NOT NULL,
        run_identity TEXT NOT NULL,
        operation_identity TEXT NOT NULL,
        occurred_at REAL NOT NULL,
        model TEXT NOT NULL,
        mode TEXT NOT NULL,
        concurrency INTEGER NOT NULL CHECK (concurrency BETWEEN 0 AND 64),
        token_semantics TEXT NOT NULL,
        lifecycle TEXT NOT NULL CHECK (lifecycle IN ('modelAttempt', 'compaction', 'recoveryReplay', 'cache', 'unknown')),
        attempt TEXT NOT NULL CHECK (attempt IN ('normal', 'retry', 'unknown')),
        role TEXT NOT NULL CHECK (role IN ('primary', 'subagent', 'unknown')),
        outcome TEXT NOT NULL CHECK (outcome IN ('succeeded', 'failed', 'unknown')),
        input_tokens INTEGER NOT NULL CHECK (input_tokens BETWEEN 0 AND 1000000000000000),
        cached_input_tokens INTEGER NOT NULL CHECK (cached_input_tokens BETWEEN 0 AND 1000000000000000),
        cache_creation_input_tokens INTEGER NOT NULL CHECK (cache_creation_input_tokens BETWEEN 0 AND 1000000000000000),
        output_tokens INTEGER NOT NULL CHECK (output_tokens BETWEEN 0 AND 1000000000000000),
        reasoning_output_tokens INTEGER NOT NULL CHECK (reasoning_output_tokens BETWEEN 0 AND 1000000000000000),
        recorded_at REAL NOT NULL,
        CHECK (input_tokens + cached_input_tokens + cache_creation_input_tokens + output_tokens + reasoning_output_tokens <= 1000000000000000),
        UNIQUE (source, run_identity, operation_identity)
    );
    """
    private static let createIndexSQL = "CREATE INDEX activity_receipts_retention ON activity_receipts (occurred_at, id);"

    private let maximumRecords: Int
    private let retention: TimeInterval
    private var database: OpaquePointer?

    public init(path: String, maximumRecords: Int = 10_000, retention: TimeInterval = 30 * 24 * 60 * 60) throws {
        guard maximumRecords > 0, retention.isFinite, retention >= 0 else { throw ActivityReceiptStoreError.schemaFailed }
        self.maximumRecords = maximumRecords
        self.retention = retention
        guard sqlite3_open(path, &database) == SQLITE_OK else { sqlite3_close(database); throw ActivityReceiptStoreError.openFailed }
        sqlite3_busy_timeout(database, 5_000)
        do { try createSchema() } catch { sqlite3_close(database); database = nil; throw error }
    }

    deinit { sqlite3_close(database) }

    public static func inMemory(maximumRecords: Int = 10_000, retention: TimeInterval = 30 * 24 * 60 * 60) throws -> Self {
        try Self(path: ":memory:", maximumRecords: maximumRecords, retention: retention)
    }

    public static func applicationSupportStore() throws -> Self {
        let locations = try LimitBarFileLocations.production()
        return try Self(path: locations.activityReceiptsDatabase.path)
    }

    public func record(_ receipts: [ActivityReceipt], now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite else { throw ActivityReceiptStoreError.writeFailed }
        try execute("BEGIN IMMEDIATE TRANSACTION;", .writeFailed)
        do {
            for receipt in receipts {
                guard receipt.occurredAt <= now.addingTimeInterval(ActivityReceiptParser.maximumFutureSkew) else { throw ActivityReceiptStoreError.futureTimestamp }
                if let existing = try existing(source: receipt.compatibility.source, run: receipt.runIdentity, operation: receipt.operationIdentity) {
                    throw sameFacts(existing, receipt) ? ActivityReceiptStoreError.duplicateRecord : ActivityReceiptStoreError.conflictingRecord
                }
                if let compatibility = try compatibility(source: receipt.compatibility.source, run: receipt.runIdentity), compatibility != receipt.compatibility {
                    throw ActivityReceiptStoreError.incompatibleRuns
                }
                if let latest = try latestTimestamp(source: receipt.compatibility.source, run: receipt.runIdentity), receipt.occurredAt < latest {
                    throw ActivityReceiptStoreError.outOfOrder
                }
                try insert(receipt, now: now)
            }
            try prune(now: now)
            try execute("COMMIT;", .writeFailed)
        } catch { try? execute("ROLLBACK;", .writeFailed); throw error }
    }

    public func all(now: Date = Date()) throws -> [ActivityReceipt] {
        try execute("BEGIN IMMEDIATE TRANSACTION;", .readFailed)
        do { try prune(now: now); try execute("COMMIT;", .readFailed) } catch { try? execute("ROLLBACK;", .readFailed); throw error }
        let statement = try prepare(Self.selectColumns + " FROM activity_receipts ORDER BY occurred_at, id;")
        defer { sqlite3_finalize(statement) }
        var result: [ActivityReceipt] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let receipt = try decode(statement)
            guard receipt.occurredAt <= now.addingTimeInterval(ActivityReceiptParser.maximumFutureSkew) else { throw ActivityReceiptStoreError.readFailed }
            result.append(receipt)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ActivityReceiptStoreError.readFailed }
        return result
    }

    public func deleteAll() throws { try execute("DELETE FROM activity_receipts;", .writeFailed) }

    private func insert(_ value: ActivityReceipt, now: Date) throws {
        guard ActivityReceiptParser.isSupported(value) else { throw ActivityReceiptStoreError.writeFailed }
        let statement = try prepare("INSERT INTO activity_receipts (contract_version, source, adapter_schema, client_version, run_identity, operation_identity, occurred_at, model, mode, concurrency, token_semantics, lifecycle, attempt, role, outcome, input_tokens, cached_input_tokens, cache_creation_input_tokens, output_tokens, reasoning_output_tokens, recorded_at) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
        defer { sqlite3_finalize(statement) }
        let strings = [value.compatibility.source.rawValue, value.compatibility.adapterSchema, value.compatibility.clientVersion, value.runIdentity.uuidString.lowercased(), value.operationIdentity]
        for (offset, string) in strings.enumerated() { bind(string, Int32(offset + 1), statement) }
        sqlite3_bind_double(statement, 6, value.occurredAt.timeIntervalSince1970)
        bind(value.compatibility.model, 7, statement); bind(value.compatibility.mode, 8, statement)
        sqlite3_bind_int64(statement, 9, Int64(value.compatibility.concurrency))
        bind(value.compatibility.tokenSemantics, 10, statement); bind(value.lifecycle.rawValue, 11, statement)
        bind(value.attempt.rawValue, 12, statement); bind(value.role.rawValue, 13, statement); bind(value.outcome.rawValue, 14, statement)
        for (index, count) in [value.tokens.input, value.tokens.cachedInput, value.tokens.cacheCreationInput, value.tokens.output, value.tokens.reasoningOutput].enumerated() { sqlite3_bind_int64(statement, Int32(index + 15), count) }
        sqlite3_bind_double(statement, 20, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ActivityReceiptStoreError.writeFailed }
    }

    private func decode(_ statement: OpaquePointer?) throws -> ActivityReceipt {
        guard sqlite3_column_int64(statement, 19) == Int64(ActivityReceipt.contractVersion),
              sqlite3_column_double(statement, 20).isFinite,
              let source = ActivityReceiptSource(rawValue: string(statement, 0)), let run = UUID(uuidString: string(statement, 3)),
              let lifecycle = ActivityLifecycle(rawValue: string(statement, 10)), let attempt = ActivityAttempt(rawValue: string(statement, 11)),
              let role = ActivityRole(rawValue: string(statement, 12)), let outcome = ActivityOutcome(rawValue: string(statement, 13)) else { throw ActivityReceiptStoreError.readFailed }
        let compatibility = ActivityReceiptCompatibility(source: source, adapterSchema: string(statement, 1), clientVersion: string(statement, 2), model: string(statement, 6), mode: string(statement, 7), concurrency: Int(sqlite3_column_int64(statement, 8)), tokenSemantics: string(statement, 9))
        let tokens = ActivityTokenCounts(input: sqlite3_column_int64(statement, 14), cachedInput: sqlite3_column_int64(statement, 15), cacheCreationInput: sqlite3_column_int64(statement, 16), output: sqlite3_column_int64(statement, 17), reasoningOutput: sqlite3_column_int64(statement, 18))
        let receipt = ActivityReceipt(runIdentity: run, operationIdentity: string(statement, 4), occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), compatibility: compatibility, lifecycle: lifecycle, attempt: attempt, role: role, outcome: outcome, tokens: tokens, evidenceLimitations: ActivityEvidenceLimitation.allCases)
        guard ActivityReceiptParser.isSupported(receipt) else { throw ActivityReceiptStoreError.readFailed }
        return receipt
    }

    private static let selectColumns = "SELECT source, adapter_schema, client_version, run_identity, operation_identity, occurred_at, model, mode, concurrency, token_semantics, lifecycle, attempt, role, outcome, input_tokens, cached_input_tokens, cache_creation_input_tokens, output_tokens, reasoning_output_tokens, contract_version, recorded_at"

    private func existing(source: ActivityReceiptSource, run: UUID, operation: String) throws -> ActivityReceipt? {
        let statement = try prepare(Self.selectColumns + " FROM activity_receipts WHERE source = ? AND run_identity = ? AND operation_identity = ?;")
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, 1, statement); bind(run.uuidString.lowercased(), 2, statement); bind(operation, 3, statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw ActivityReceiptStoreError.readFailed }
        return try decode(statement)
    }

    private func sameFacts(_ first: ActivityReceipt, _ second: ActivityReceipt) -> Bool {
        first.runIdentity == second.runIdentity
            && first.operationIdentity == second.operationIdentity
            && first.compatibility == second.compatibility
            && first.lifecycle == second.lifecycle
            && first.attempt == second.attempt
            && first.role == second.role
            && first.outcome == second.outcome
            && first.tokens == second.tokens
            && first.evidenceLimitations == second.evidenceLimitations
    }

    private func compatibility(source: ActivityReceiptSource, run: UUID) throws -> ActivityReceiptCompatibility? {
        let statement = try prepare(Self.selectColumns + " FROM activity_receipts WHERE source = ? AND run_identity = ? ORDER BY id LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, 1, statement); bind(run.uuidString.lowercased(), 2, statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw ActivityReceiptStoreError.readFailed }
        return try decode(statement).compatibility
    }

    private func latestTimestamp(source: ActivityReceiptSource, run: UUID) throws -> Date? {
        let statement = try prepare("SELECT MAX(occurred_at) FROM activity_receipts WHERE source = ? AND run_identity = ?;")
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, 1, statement); bind(run.uuidString.lowercased(), 2, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ActivityReceiptStoreError.readFailed }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    private func prune(now: Date) throws {
        let age = try prepare("DELETE FROM activity_receipts WHERE occurred_at < ?;"); defer { sqlite3_finalize(age) }
        sqlite3_bind_double(age, 1, now.addingTimeInterval(-retention).timeIntervalSince1970)
        guard sqlite3_step(age) == SQLITE_DONE else { throw ActivityReceiptStoreError.writeFailed }
        let count = try prepare("DELETE FROM activity_receipts WHERE id NOT IN (SELECT id FROM activity_receipts ORDER BY occurred_at DESC, id DESC LIMIT ?);"); defer { sqlite3_finalize(count) }
        sqlite3_bind_int64(count, 1, Int64(maximumRecords)); guard sqlite3_step(count) == SQLITE_DONE else { throw ActivityReceiptStoreError.writeFailed }
    }

    private func createSchema() throws {
        let version = try scalarInt("PRAGMA user_version;")
        let objects = try objectNames()
        if version == 0, objects.isEmpty {
            try execute("BEGIN IMMEDIATE TRANSACTION;", .schemaFailed)
            do { try execute(Self.createSQL, .schemaFailed); try execute(Self.createIndexSQL, .schemaFailed); try execute("PRAGMA user_version = 1;", .schemaFailed); try execute("COMMIT;", .schemaFailed) }
            catch { try? execute("ROLLBACK;", .schemaFailed); throw error }
            return
        }
        guard version == Self.schemaVersion, objects == ["table:activity_receipts", "index:activity_receipts_retention"],
              try schemaSQL("table", "activity_receipts") == Self.normalized(Self.createSQL),
              try schemaSQL("index", "activity_receipts_retention") == Self.normalized(Self.createIndexSQL) else { throw ActivityReceiptStoreError.schemaFailed }
    }

    private func execute(_ sql: String, _ error: ActivityReceiptStoreError) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error } }
    private func prepare(_ sql: String) throws -> OpaquePointer? { var value: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &value, nil) == SQLITE_OK else { throw ActivityReceiptStoreError.schemaFailed }; return value }
    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer?) { sqlite3_bind_text(statement, index, value, -1, activitySQLiteTransient) }
    private func string(_ statement: OpaquePointer?, _ index: Int32) -> String { String(cString: sqlite3_column_text(statement, index)) }
    private func scalarInt(_ sql: String) throws -> Int { let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; guard sqlite3_step(statement) == SQLITE_ROW else { throw ActivityReceiptStoreError.schemaFailed }; return Int(sqlite3_column_int(statement, 0)) }
    private func objectNames() throws -> Set<String> { let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';"); defer { sqlite3_finalize(statement) }; var values = Set<String>(); var step = sqlite3_step(statement); while step == SQLITE_ROW { values.insert("\(string(statement, 0)):\(string(statement, 1))"); step = sqlite3_step(statement) }; guard step == SQLITE_DONE else { throw ActivityReceiptStoreError.schemaFailed }; return values }
    private func schemaSQL(_ type: String, _ name: String) throws -> String { let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;"); defer { sqlite3_finalize(statement) }; bind(type, 1, statement); bind(name, 2, statement); guard sqlite3_step(statement) == SQLITE_ROW else { throw ActivityReceiptStoreError.schemaFailed }; return Self.normalized(string(statement, 0)) }
    private static func normalized(_ sql: String) -> String { sql.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ";")) }
}

private let activitySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class ActivityReceiptImporter: @unchecked Sendable {
    private let store: SQLiteActivityReceiptStore
    private let preferencesStore: ActivitySourcePreferencesStore

    public init(store: SQLiteActivityReceiptStore, preferencesStore: ActivitySourcePreferencesStore = ActivitySourcePreferencesStore()) {
        self.store = store
        self.preferencesStore = preferencesStore
    }

    public func importClaude(data: Data, now: Date = Date()) -> ActivityReceiptImportResult { importResult(ActivityReceiptParser.parseClaude(data: data, preferences: preferencesStore.preferences, now: now), now: now) }
    public func importCodexJSONL(data: Data, now: Date = Date()) -> ActivityReceiptImportResult { importResult(ActivityReceiptParser.parseCodexJSONL(data: data, preferences: preferencesStore.preferences, now: now), now: now) }

    private func importResult(_ result: ActivityReceiptImportResult, now: Date) -> ActivityReceiptImportResult {
        guard case let .imported(receipts) = result else { return result }
        do { try store.record(receipts, now: now); return result }
        catch ActivityReceiptStoreError.duplicateRecord { return .unavailable(.duplicateRecord) }
        catch ActivityReceiptStoreError.conflictingRecord { return .unavailable(.conflictingRecord) }
        catch ActivityReceiptStoreError.outOfOrder { return .unavailable(.outOfOrder) }
        catch ActivityReceiptStoreError.incompatibleRuns { return .unavailable(.incompatibleRuns) }
        catch ActivityReceiptStoreError.futureTimestamp { return .unavailable(.futureTimestamp) }
        catch { return .unavailable(.storageUnavailable) }
    }
}
