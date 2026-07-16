import Foundation
import SQLite3

public enum ClaudeExplanationStoreError: Error, Equatable {
    case openFailed
    case schemaFailed
    case writeFailed
    case readFailed
}

public final class SQLiteClaudeExplanationStore: @unchecked Sendable {
    public static let schemaVersion = 1
    private static let createTableSQL = """
    CREATE TABLE claude_explanation_findings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recorded_at REAL NOT NULL,
        payload TEXT NOT NULL
    );
    """
    private static let createIndexSQL = "CREATE INDEX claude_explanation_findings_recorded ON claude_explanation_findings (recorded_at);"

    private let maximumRecords: Int
    private let retention: TimeInterval
    private var database: OpaquePointer?

    private struct SchemaColumn: Equatable {
        let position: Int
        let name: String
        let type: String
        let isNotNull: Bool
        let primaryKeyPosition: Int
    }

    private static let expectedColumns = [
        SchemaColumn(position: 0, name: "id", type: "INTEGER", isNotNull: false, primaryKeyPosition: 1),
        SchemaColumn(position: 1, name: "recorded_at", type: "REAL", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 2, name: "payload", type: "TEXT", isNotNull: true, primaryKeyPosition: 0),
    ]

    public init(
        path: String,
        maximumRecords: Int = 100,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        busyTimeoutMilliseconds: Int32 = 5_000
    ) throws {
        guard maximumRecords > 0, retention.isFinite, retention >= 0 else { throw ClaudeExplanationStoreError.schemaFailed }
        self.maximumRecords = maximumRecords
        self.retention = retention
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw ClaudeExplanationStoreError.openFailed
        }
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        do { try createSchema() } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public static func inMemory(maximumRecords: Int = 100, retention: TimeInterval = 30 * 24 * 60 * 60) throws -> SQLiteClaudeExplanationStore {
        try SQLiteClaudeExplanationStore(path: ":memory:", maximumRecords: maximumRecords, retention: retention)
    }

    public static func applicationSupportStore(fileManager: FileManager = .default) throws -> SQLiteClaudeExplanationStore {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("LimitBar", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteClaudeExplanationStore(path: directory.appendingPathComponent("claude-explanations.sqlite").path)
    }

    public func record(_ state: ClaudeQuotaExplanationState, now: Date = Date()) throws {
        try record(state, now: now, beforeCommit: nil)
    }

    func recordForTesting(
        _ state: ClaudeQuotaExplanationState,
        now: Date,
        beforeCommit: @escaping () throws -> Void
    ) throws {
        try record(state, now: now, beforeCommit: beforeCommit)
    }

    private func record(
        _ state: ClaudeQuotaExplanationState,
        now: Date,
        beforeCommit: (() throws -> Void)?
    ) throws {
        guard now.timeIntervalSince1970.isFinite else {
            throw ClaudeExplanationStoreError.writeFailed
        }
        let payload = String(decoding: try JSONEncoder().encode(StoredClaudeExplanation(state)), as: UTF8.self)
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare("INSERT INTO claude_explanation_findings (recorded_at, payload) VALUES (?, ?);")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            bind(payload, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ClaudeExplanationStoreError.writeFailed }
            try pruneInTransaction(now: now)
            try beforeCommit?()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func latest(now: Date = Date()) throws -> ClaudeQuotaExplanationState? {
        try prune(now: now)
        let statement = try prepare("SELECT payload FROM claude_explanation_findings ORDER BY recorded_at DESC, id DESC LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
              let data = String(cString: text).data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredClaudeExplanation.self, from: data) else {
            throw ClaudeExplanationStoreError.readFailed
        }
        return stored.state(now: now)
    }

    public func recordCount(now: Date = Date()) throws -> Int {
        try prune(now: now)
        let statement = try prepare("SELECT COUNT(*) FROM claude_explanation_findings;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ClaudeExplanationStoreError.readFailed }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func deleteAll() throws { try execute("DELETE FROM claude_explanation_findings;") }

    private func createSchema() throws {
        let versionStatement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(versionStatement) }
        guard sqlite3_step(versionStatement) == SQLITE_ROW else { throw ClaudeExplanationStoreError.schemaFailed }
        let version = Int(sqlite3_column_int(versionStatement, 0))
        if version == Self.schemaVersion {
            guard try objects() == ["index:claude_explanation_findings_recorded", "table:claude_explanation_findings"],
                  try schemaSQL(type: "table", name: "claude_explanation_findings") == Self.normalizedSQL(Self.createTableSQL),
                  try schemaSQL(type: "index", name: "claude_explanation_findings_recorded") == Self.normalizedSQL(Self.createIndexSQL),
                  try columns() == Self.expectedColumns,
                  try indexColumns() == ["recorded_at"] else {
                throw ClaudeExplanationStoreError.schemaFailed
            }
            return
        }
        guard version == 0, try objects().isEmpty else { throw ClaudeExplanationStoreError.schemaFailed }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(Self.createTableSQL)
            try execute(Self.createIndexSQL)
            try execute("PRAGMA user_version = \(Self.schemaVersion);")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func objects() throws -> Set<String> {
        let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var values = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let type = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else {
                throw ClaudeExplanationStoreError.schemaFailed
            }
            values.insert("\(String(cString: type)):\(String(cString: name))")
        }
        return values
    }

    private func schemaSQL(type: String, name: String) throws -> String {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(type, at: 1, in: statement)
        bind(name, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw ClaudeExplanationStoreError.schemaFailed
        }
        return Self.normalizedSQL(String(cString: text))
    }

    private func columns() throws -> [SchemaColumn] {
        let statement = try prepare("PRAGMA table_info(claude_explanation_findings);")
        defer { sqlite3_finalize(statement) }
        var result: [SchemaColumn] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1), let type = sqlite3_column_text(statement, 2),
                  sqlite3_column_type(statement, 4) == SQLITE_NULL else { throw ClaudeExplanationStoreError.schemaFailed }
            result.append(SchemaColumn(
                position: Int(sqlite3_column_int(statement, 0)),
                name: String(cString: name),
                type: String(cString: type),
                isNotNull: sqlite3_column_int(statement, 3) == 1,
                primaryKeyPosition: Int(sqlite3_column_int(statement, 5))
            ))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ClaudeExplanationStoreError.schemaFailed }
        return result
    }

    private func indexColumns() throws -> [String] {
        let statement = try prepare("PRAGMA index_info(claude_explanation_findings_recorded);")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard Int(sqlite3_column_int(statement, 0)) == result.count,
                  let name = sqlite3_column_text(statement, 2) else { throw ClaudeExplanationStoreError.schemaFailed }
            result.append(String(cString: name))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ClaudeExplanationStoreError.schemaFailed }
        return result
    }

    private static func normalizedSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
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
        guard now.timeIntervalSince1970.isFinite else { throw ClaudeExplanationStoreError.writeFailed }
        let age = try prepare("DELETE FROM claude_explanation_findings WHERE recorded_at < ?;")
        sqlite3_bind_double(age, 1, now.addingTimeInterval(-retention).timeIntervalSince1970)
        guard sqlite3_step(age) == SQLITE_DONE else { sqlite3_finalize(age); throw ClaudeExplanationStoreError.writeFailed }
        sqlite3_finalize(age)
        let count = try prepare("DELETE FROM claude_explanation_findings WHERE id NOT IN (SELECT id FROM claude_explanation_findings ORDER BY recorded_at DESC, id DESC LIMIT ?);")
        defer { sqlite3_finalize(count) }
        sqlite3_bind_int64(count, 1, Int64(maximumRecords))
        guard sqlite3_step(count) == SQLITE_DONE else { throw ClaudeExplanationStoreError.writeFailed }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ClaudeExplanationStoreError.schemaFailed }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ClaudeExplanationStoreError.schemaFailed }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

private struct StoredClaudeExplanation: Codable {
    let kind: String
    let value: ClaudeQuotaExplanation?
    let reason: ClaudeQuotaExplanationUnavailableReason?

    init(_ state: ClaudeQuotaExplanationState) {
        switch state {
        case let .movement(value): (kind, self.value, reason) = ("movement", value, nil)
        case let .flat(value): (kind, self.value, reason) = ("flat", value, nil)
        case let .unavailable(reason): (kind, value, self.reason) = ("unavailable", nil, reason)
        }
    }

    func state(now: Date) -> ClaudeQuotaExplanationState {
        guard let value else { return .unavailable(reason ?? .insufficientObservations) }
        guard value.sourceAdapterVersion == ClaudeCodeOTLPEvidenceAdapter.adapterVersion else { return .unavailable(.incompatibleQuotaWindow) }
        let normalized = value.read(at: now)
        return kind == "flat" ? .flat(normalized) : .movement(normalized)
    }
}
