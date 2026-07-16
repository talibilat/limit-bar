import Foundation
import SQLite3

public enum UsageAttributionStoreError: Error, Equatable {
    case openFailed
    case schemaFailed
    case writeFailed
    case readFailed
}

/// Durable storage for measured attribution, isolated from Usage Aggregate persistence.
public final class SQLiteUsageAttributionStore: @unchecked Sendable {
    private static let schemaVersion = 1
    private static let maximumEventIdentityBytes = 4 * 1_024 * 1_024

    private static let createBreakdownsSQL = """
    CREATE TABLE usage_attribution_breakdowns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_kind TEXT NOT NULL CHECK (source_kind IN ('builtInLocalLog', 'custom')),
        source_identifier TEXT NOT NULL,
        source_revision TEXT NOT NULL,
        provider TEXT NOT NULL,
        time_window TEXT NOT NULL,
        window_start INTEGER NOT NULL,
        window_end INTEGER NOT NULL,
        window_basis TEXT NOT NULL CHECK (window_basis IN ('localCalendar', 'utcBilling')),
        aggregation_version INTEGER NOT NULL CHECK (aggregation_version > 0),
        model TEXT NOT NULL,
        deployment TEXT,
        project_id TEXT,
        project_label TEXT,
        agent_id TEXT,
        agent_label TEXT,
        input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
        output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
        event_ids TEXT NOT NULL,
        observed_at REAL NOT NULL,
        recorded_at REAL NOT NULL,
        CHECK (window_end > window_start),
        CHECK (project_id IS NOT NULL OR agent_id IS NOT NULL),
        CHECK (project_label IS NULL OR project_id IS NOT NULL),
        CHECK (agent_label IS NULL OR agent_id IS NOT NULL),
        CHECK ((source_kind = 'custom' AND source_identifier != '') OR (source_kind = 'builtInLocalLog' AND source_identifier = ''))
    );
    """
    private static let createSuppressionsSQL = """
    CREATE TABLE usage_attribution_suppressions (
        source_kind TEXT NOT NULL CHECK (source_kind IN ('builtInLocalLog', 'custom')),
        source_identifier TEXT NOT NULL,
        source_revision TEXT NOT NULL,
        suppressed_at REAL NOT NULL,
        PRIMARY KEY (source_kind, source_identifier),
        CHECK ((source_kind = 'custom' AND source_identifier != '') OR (source_kind = 'builtInLocalLog' AND source_identifier = ''))
    );
    """
    private static let createObservedIndexSQL = "CREATE INDEX usage_attribution_observed ON usage_attribution_breakdowns (observed_at, id);"

    private let maximumRecords: Int
    private let retention: TimeInterval
    private var database: OpaquePointer?

    public init(
        path: String,
        maximumRecords: Int = 10_000,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        busyTimeoutMilliseconds: Int32 = 5_000
    ) throws {
        guard maximumRecords > 0, retention.isFinite, retention >= 0 else { throw UsageAttributionStoreError.schemaFailed }
        self.maximumRecords = maximumRecords
        self.retention = retention
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw UsageAttributionStoreError.openFailed
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

    public static func inMemory(
        maximumRecords: Int = 10_000,
        retention: TimeInterval = 30 * 24 * 60 * 60
    ) throws -> SQLiteUsageAttributionStore {
        try SQLiteUsageAttributionStore(path: ":memory:", maximumRecords: maximumRecords, retention: retention)
    }

    public func replace(
        _ breakdowns: [ObservedLocalAttributionBreakdown],
        source: UsageMetricSource,
        sourceRevision: String,
        now: Date = Date()
    ) throws {
        let encodedSource = try encode(source)
        guard validRevision(sourceRevision), now.timeIntervalSince1970.isFinite,
              breakdowns.allSatisfy({ $0.source == source }) else { throw UsageAttributionStoreError.writeFailed }
        try execute("BEGIN IMMEDIATE TRANSACTION;", error: .writeFailed)
        do {
            try prune(now: now)
            if try suppressedRevision(for: encodedSource) == sourceRevision {
                try execute("COMMIT;", error: .writeFailed)
                return
            }
            try deleteSuppression(for: encodedSource)
            try deleteRows(for: encodedSource)
            for breakdown in breakdowns {
                try insert(breakdown, source: encodedSource, sourceRevision: sourceRevision, now: now)
            }
            try prune(now: now)
            try execute("COMMIT;", error: .writeFailed)
        } catch {
            try? execute("ROLLBACK;", error: .writeFailed)
            throw error
        }
    }

    public func all(now: Date = Date()) throws -> [ObservedLocalAttributionBreakdown] {
        try all(matching: nil, now: now)
    }

    public func all(matching sourceRevisions: [UsageMetricSource: String], now: Date = Date()) throws -> [ObservedLocalAttributionBreakdown] {
        try all(matching: Optional(sourceRevisions), now: now)
    }

    public func suppressedSources(matching sourceRevisions: [UsageMetricSource: String]) throws -> Set<UsageMetricSource> {
        let statement = try prepare("SELECT source_kind, source_identifier, source_revision FROM usage_attribution_suppressions;")
        defer { sqlite3_finalize(statement) }
        var sources = Set<UsageMetricSource>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let source = try decodeSource(kind: requiredString(statement, 0), identifier: requiredString(statement, 1))
            if sourceRevisions[source] == requiredString(statement, 2) { sources.insert(source) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw UsageAttributionStoreError.readFailed }
        return sources
    }

    private func all(matching sourceRevisions: [UsageMetricSource: String]?, now: Date) throws -> [ObservedLocalAttributionBreakdown] {
        try execute("BEGIN IMMEDIATE TRANSACTION;", error: .readFailed)
        do {
            try prune(now: now)
            try execute("COMMIT;", error: .readFailed)
        } catch {
            try? execute("ROLLBACK;", error: .readFailed)
            throw error
        }
        let statement = try prepare("""
        SELECT source_kind, source_identifier, provider, time_window, window_start, window_end, window_basis,
               aggregation_version, model, deployment, project_id, project_label, agent_id, agent_label,
               input_tokens, output_tokens, event_ids, observed_at, source_revision
        FROM usage_attribution_breakdowns ORDER BY observed_at, id;
        """)
        defer { sqlite3_finalize(statement) }
        var values: [ObservedLocalAttributionBreakdown] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let value = try decode(statement)
            if sourceRevisions.map({ $0[value.source] == requiredString(statement, 18) }) ?? true {
                values.append(value)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw UsageAttributionStoreError.readFailed }
        return values
    }

    /// Deletes only attribution rows and records revisions so unchanged inputs stay deleted.
    public func deleteAll(now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite else { throw UsageAttributionStoreError.writeFailed }
        try execute("BEGIN IMMEDIATE TRANSACTION;", error: .writeFailed)
        do {
            let statement = try prepare("""
            INSERT INTO usage_attribution_suppressions (source_kind, source_identifier, source_revision, suppressed_at)
            SELECT source_kind, source_identifier, source_revision, ?
            FROM usage_attribution_breakdowns
            GROUP BY source_kind, source_identifier
            ON CONFLICT(source_kind, source_identifier) DO UPDATE SET
                source_revision = excluded.source_revision,
                suppressed_at = excluded.suppressed_at;
            """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            try stepDone(statement, error: .writeFailed)
            try execute("DELETE FROM usage_attribution_breakdowns;", error: .writeFailed)
            try prune(now: now)
            try execute("COMMIT;", error: .writeFailed)
        } catch {
            try? execute("ROLLBACK;", error: .writeFailed)
            throw error
        }
    }

    public func deleteCustomSources(excluding sourceIDs: Set<UUID>, now: Date = Date()) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;", error: .writeFailed)
        do {
            let identifiers = sourceIDs.map { $0.uuidString.lowercased() }.sorted()
            let predicate: String
            if identifiers.isEmpty {
                predicate = "source_kind = 'custom'"
            } else {
                predicate = "source_kind = 'custom' AND source_identifier NOT IN (\(Array(repeating: "?", count: identifiers.count).joined(separator: ", ")))"
            }
            for table in ["usage_attribution_breakdowns", "usage_attribution_suppressions"] {
                let statement = try prepare("DELETE FROM \(table) WHERE \(predicate);")
                defer { sqlite3_finalize(statement) }
                for (index, identifier) in identifiers.enumerated() {
                    bind(identifier, at: Int32(index + 1), in: statement)
                }
                try stepDone(statement, error: .writeFailed)
            }
            try prune(now: now)
            try execute("COMMIT;", error: .writeFailed)
        } catch {
            try? execute("ROLLBACK;", error: .writeFailed)
            throw error
        }
    }

    private func insert(
        _ value: ObservedLocalAttributionBreakdown,
        source: EncodedSource,
        sourceRevision: String,
        now: Date
    ) throws {
        guard value.observedAt.timeIntervalSince1970.isFinite,
              value.window.start.timeIntervalSince1970.rounded(.towardZero) == value.window.start.timeIntervalSince1970,
              value.window.end.timeIntervalSince1970.rounded(.towardZero) == value.window.end.timeIntervalSince1970,
              !value.eventIDs.isEmpty,
              CollectorSchemaV2.validAttribution(value.project),
              CollectorSchemaV2.validAttribution(value.agent) else { throw UsageAttributionStoreError.writeFailed }
        let eventData = try JSONEncoder().encode(value.eventIDs.map { $0.uuidString.lowercased() })
        guard eventData.count <= Self.maximumEventIdentityBytes else {
            throw UsageAttributionStoreError.writeFailed
        }
        let eventText = String(decoding: eventData, as: UTF8.self)
        let statement = try prepare("""
        INSERT INTO usage_attribution_breakdowns
            (source_kind, source_identifier, source_revision, provider, time_window, window_start, window_end,
             window_basis, aggregation_version, model, deployment, project_id, project_label, agent_id, agent_label,
             input_tokens, output_tokens, event_ids, observed_at, recorded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(source.kind, at: 1, in: statement)
        bind(source.identifier, at: 2, in: statement)
        bind(sourceRevision, at: 3, in: statement)
        bind(value.provider.rawValue, at: 4, in: statement)
        bind(value.window.timeWindow.rawValue, at: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(value.window.start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 7, Int64(value.window.end.timeIntervalSince1970))
        bind(value.window.basis.rawValue, at: 8, in: statement)
        sqlite3_bind_int64(statement, 9, Int64(value.window.aggregationVersion))
        bind(value.model, at: 10, in: statement)
        bindNullable(value.deployment, at: 11, in: statement)
        bindNullable(value.project?.id, at: 12, in: statement)
        bindNullable(value.project?.label, at: 13, in: statement)
        bindNullable(value.agent?.id, at: 14, in: statement)
        bindNullable(value.agent?.label, at: 15, in: statement)
        sqlite3_bind_int64(statement, 16, Int64(value.tokenUsage.inputTokens))
        sqlite3_bind_int64(statement, 17, Int64(value.tokenUsage.outputTokens))
        bind(eventText, at: 18, in: statement)
        sqlite3_bind_double(statement, 19, value.observedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 20, now.timeIntervalSince1970)
        try stepDone(statement, error: .writeFailed)
    }

    private func decode(_ statement: OpaquePointer?) throws -> ObservedLocalAttributionBreakdown {
        let source = try decodeSource(kind: requiredString(statement, 0), identifier: requiredString(statement, 1))
        guard let provider = ProviderKind(rawValue: requiredString(statement, 2)),
              let timeWindow = TimeWindow(rawValue: requiredString(statement, 3)),
              let basis = UsageWindowBasis(rawValue: requiredString(statement, 6)),
              let eventTexts = try? JSONDecoder().decode(
                  [String].self,
                  from: Data(requiredString(statement, 16).utf8)
              ) else {
            throw UsageAttributionStoreError.readFailed
        }
        let eventIDs = try eventTexts.map { text -> UUID in
            guard let value = UUID(uuidString: text) else { throw UsageAttributionStoreError.readFailed }
            return value
        }
        let projectID = stringColumn(statement, 10)
        let agentID = stringColumn(statement, 12)
        guard projectID != nil || agentID != nil, !eventIDs.isEmpty else { throw UsageAttributionStoreError.readFailed }
        let window: ExactUsageWindow
        do {
            window = try ExactUsageWindow(
                timeWindow: timeWindow,
                start: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))),
                end: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5))),
                basis: basis,
                aggregationVersion: Int(sqlite3_column_int64(statement, 7))
            )
        } catch {
            throw UsageAttributionStoreError.readFailed
        }
        return ObservedLocalAttributionBreakdown(
            source: source,
            provider: provider,
            window: window,
            model: requiredString(statement, 8),
            deployment: stringColumn(statement, 9),
            project: projectID.map { CollectorAttribution(id: $0, label: stringColumn(statement, 11)) },
            agent: agentID.map { CollectorAttribution(id: $0, label: stringColumn(statement, 13)) },
            tokenUsage: TokenUsage(
                inputTokens: Int(sqlite3_column_int64(statement, 14)),
                outputTokens: Int(sqlite3_column_int64(statement, 15))
            ),
            eventIDs: eventIDs,
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 17))
        )
    }

    private func prune(now: Date) throws {
        guard now.timeIntervalSince1970.isFinite else { throw UsageAttributionStoreError.writeFailed }
        let cutoff = now.addingTimeInterval(-retention).timeIntervalSince1970
        let age = try prepare("DELETE FROM usage_attribution_breakdowns WHERE observed_at < ?;")
        defer { sqlite3_finalize(age) }
        sqlite3_bind_double(age, 1, cutoff)
        try stepDone(age, error: .writeFailed)
        let count = try prepare("""
        DELETE FROM usage_attribution_breakdowns WHERE id NOT IN (
            SELECT id FROM usage_attribution_breakdowns ORDER BY observed_at DESC, id DESC LIMIT ?
        );
        """)
        defer { sqlite3_finalize(count) }
        sqlite3_bind_int64(count, 1, Int64(maximumRecords))
        try stepDone(count, error: .writeFailed)
        let suppressionAge = try prepare("DELETE FROM usage_attribution_suppressions WHERE suppressed_at < ?;")
        defer { sqlite3_finalize(suppressionAge) }
        sqlite3_bind_double(suppressionAge, 1, cutoff)
        try stepDone(suppressionAge, error: .writeFailed)
        let suppressionCount = try prepare("""
        DELETE FROM usage_attribution_suppressions
        WHERE rowid NOT IN (SELECT rowid FROM usage_attribution_suppressions ORDER BY suppressed_at DESC LIMIT ?);
        """)
        defer { sqlite3_finalize(suppressionCount) }
        sqlite3_bind_int64(suppressionCount, 1, Int64(maximumRecords))
        try stepDone(suppressionCount, error: .writeFailed)
    }

    private func suppressedRevision(for source: EncodedSource) throws -> String? {
        let statement = try prepare("SELECT source_revision FROM usage_attribution_suppressions WHERE source_kind = ? AND source_identifier = ?;")
        defer { sqlite3_finalize(statement) }
        bind(source.kind, at: 1, in: statement)
        bind(source.identifier, at: 2, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw UsageAttributionStoreError.readFailed }
        return requiredString(statement, 0)
    }

    private func deleteRows(for source: EncodedSource) throws {
        try delete(from: "usage_attribution_breakdowns", source: source)
    }

    private func deleteSuppression(for source: EncodedSource) throws {
        try delete(from: "usage_attribution_suppressions", source: source)
    }

    private func delete(from table: String, source: EncodedSource) throws {
        let statement = try prepare("DELETE FROM \(table) WHERE source_kind = ? AND source_identifier = ?;")
        defer { sqlite3_finalize(statement) }
        bind(source.kind, at: 1, in: statement)
        bind(source.identifier, at: 2, in: statement)
        try stepDone(statement, error: .writeFailed)
    }

    private func createSchema() throws {
        let version = try userVersion()
        let objects = try schemaObjects()
        if version == 0, objects.isEmpty {
            try execute("BEGIN IMMEDIATE TRANSACTION;", error: .schemaFailed)
            do {
                try execute(Self.createBreakdownsSQL, error: .schemaFailed)
                try execute(Self.createSuppressionsSQL, error: .schemaFailed)
                try execute(Self.createObservedIndexSQL, error: .schemaFailed)
                try execute("PRAGMA user_version = \(Self.schemaVersion);", error: .schemaFailed)
                try execute("COMMIT;", error: .schemaFailed)
            } catch {
                try? execute("ROLLBACK;", error: .schemaFailed)
                throw error
            }
            return
        }
        guard version == Self.schemaVersion,
              objects == [
                  "table:usage_attribution_breakdowns", "table:usage_attribution_suppressions",
                  "index:usage_attribution_observed"
              ],
              try schemaSQL(type: "table", name: "usage_attribution_breakdowns") == Self.normalized(Self.createBreakdownsSQL),
              try schemaSQL(type: "table", name: "usage_attribution_suppressions") == Self.normalized(Self.createSuppressionsSQL),
              try schemaSQL(type: "index", name: "usage_attribution_observed") == Self.normalized(Self.createObservedIndexSQL) else {
            throw UsageAttributionStoreError.schemaFailed
        }
    }

    private struct EncodedSource {
        let kind: String
        let identifier: String
    }

    private func encode(_ source: UsageMetricSource) throws -> EncodedSource {
        switch source {
        case .builtInLocalLog: EncodedSource(kind: "builtInLocalLog", identifier: "")
        case let .custom(id): EncodedSource(kind: "custom", identifier: id.uuidString.lowercased())
        case .providerAPI: throw UsageAttributionStoreError.writeFailed
        }
    }

    private func decodeSource(kind: String, identifier: String) throws -> UsageMetricSource {
        switch kind {
        case "builtInLocalLog" where identifier.isEmpty: return .builtInLocalLog
        case "custom":
            guard let id = UUID(uuidString: identifier) else { throw UsageAttributionStoreError.readFailed }
            return .custom(id)
        default: throw UsageAttributionStoreError.readFailed
        }
    }

    private func validRevision(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy { $0.isASCII }
    }

    private func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw UsageAttributionStoreError.schemaFailed }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func schemaObjects() throws -> Set<String> {
        let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var values = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            values.insert("\(requiredString(statement, 0)):\(requiredString(statement, 1))")
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw UsageAttributionStoreError.schemaFailed }
        return values
    }

    private func schemaSQL(type: String, name: String) throws -> String {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(type, at: 1, in: statement)
        bind(name, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw UsageAttributionStoreError.schemaFailed }
        return Self.normalized(requiredString(statement, 0))
    }

    private static func normalized(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ";"))
    }

    private func execute(_ sql: String, error: UsageAttributionStoreError) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageAttributionStoreError.schemaFailed }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?, error: UsageAttributionStoreError) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindNullable(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        bind(value, at: index, in: statement)
    }

    private func requiredString(_ statement: OpaquePointer?, _ index: Int32) -> String {
        stringColumn(statement, index) ?? ""
    }

    private func stringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
