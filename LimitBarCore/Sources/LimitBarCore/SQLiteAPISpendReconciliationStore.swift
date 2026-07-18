import Foundation
import SQLite3

public enum APISpendStoreError: Error, Equatable { case openFailed, unknownSchema, writeFailed, readFailed }

public struct SpendConclusionDrift: Codable, Equatable, Sendable {
    public let bucket: ProviderReportedSpendBucket
    public let providerReportedChange: Decimal
    public let attributedChange: Decimal
    public let observedLocalChange: Decimal
    public let unattributedChange: Decimal
    public let previousStatus: SpendReconciliationStatus?
    public let currentStatus: SpendReconciliationStatus?
}

public struct SpendRevision: Equatable, Sendable {
    public let id: Int64
    public let recordedAt: Date
    public let conclusion: SpendReconciliationConclusion
    public let supersedesRevisionID: Int64?
    public let drifts: [SpendConclusionDrift]
}

public final class SQLiteAPISpendReconciliationStore: @unchecked Sendable {
    private static let schemaVersion = 3
    private static let v1SQL = "CREATE TABLE spend_revisions (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at REAL NOT NULL, provider TEXT NOT NULL CHECK(provider = 'anthropic'), payload BLOB NOT NULL, supersedes_id INTEGER, drift TEXT NOT NULL, FOREIGN KEY(supersedes_id) REFERENCES spend_revisions(id));"
    private static let v2SQL = "CREATE TABLE spend_revisions (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at REAL NOT NULL, provider TEXT NOT NULL CHECK(provider = 'anthropic'), payload BLOB NOT NULL, supersedes_id INTEGER, drift TEXT NOT NULL, drift_json BLOB NOT NULL, refresh_status TEXT NOT NULL CHECK(refresh_status IN ('complete')), FOREIGN KEY(supersedes_id) REFERENCES spend_revisions(id));"
    private static let v3SQL = "CREATE TABLE spend_revisions (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at REAL NOT NULL, provider TEXT NOT NULL CHECK(provider = 'anthropic'), payload BLOB NOT NULL, supersedes_id INTEGER, drift TEXT NOT NULL, drift_json BLOB NOT NULL, refresh_status TEXT NOT NULL CHECK(refresh_status IN ('complete')), conclusion_payload BLOB, pricing_revision TEXT, local_evidence_identity BLOB, local_event_count INTEGER, FOREIGN KEY(supersedes_id) REFERENCES spend_revisions(id));"
    private static let indexSQL = "CREATE INDEX spend_revisions_retention ON spend_revisions(recorded_at, id);"

    private let maximumRevisions: Int
    private let retention: TimeInterval
    private var database: OpaquePointer?

    public init(path: String, maximumRevisions: Int = 366, retention: TimeInterval = 366 * 24 * 60 * 60) throws {
        guard maximumRevisions > 0, retention >= 0, retention.isFinite else { throw APISpendStoreError.unknownSchema }
        self.maximumRevisions = maximumRevisions
        self.retention = retention
        guard sqlite3_open(path, &database) == SQLITE_OK else { sqlite3_close(database); throw APISpendStoreError.openFailed }
        sqlite3_busy_timeout(database, 5_000)
        do { try createOrMigrate() } catch { sqlite3_close(database); database = nil; throw error }
    }

    deinit { sqlite3_close(database) }
    public static func inMemory(maximumRevisions: Int = 366, retention: TimeInterval = 366 * 24 * 60 * 60) throws -> Self { try Self(path: ":memory:", maximumRevisions: maximumRevisions, retention: retention) }
    public static func applicationSupportStore() throws -> Self { try Self(path: LimitBarFileLocations.production().apiSpendReconciliationDatabase.path) }

    @discardableResult
    public func record(_ conclusion: SpendReconciliationConclusion, now: Date = Date()) throws -> SpendRevision {
        guard now.timeIntervalSince1970.isFinite else { throw APISpendStoreError.writeFailed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let providerPayload = try encoder.encode(conclusion.providerBuckets)
        let conclusionPayload = try encoder.encode(conclusion)
        let identityPayload = try conclusion.localEvidenceIdentity.map(encoder.encode)
        let latest = try revisions(now: now).last
        let drifts = conclusionDrift(current: conclusion.rows, previous: latest?.conclusion.rows ?? [])
        let driftPayload = try encoder.encode(drifts)
        try execute("BEGIN IMMEDIATE TRANSACTION;", .writeFailed)
        do {
            let statement = try prepare("INSERT INTO spend_revisions (recorded_at, provider, payload, supersedes_id, drift, drift_json, refresh_status, conclusion_payload, pricing_revision, local_evidence_identity, local_event_count) VALUES (?, 'anthropic', ?, ?, '0', ?, 'complete', ?, ?, ?, ?);")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            bind(providerPayload, 2, statement)
            if let latest { sqlite3_bind_int64(statement, 3, latest.id) } else { sqlite3_bind_null(statement, 3) }
            bind(driftPayload, 4, statement)
            bind(conclusionPayload, 5, statement)
            bind(conclusion.pricingRevision, 6, statement)
            if let identityPayload { bind(identityPayload, 7, statement) } else { sqlite3_bind_null(statement, 7) }
            sqlite3_bind_int64(statement, 8, Int64(conclusion.localEvidenceIdentity?.eventCount ?? 0))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw APISpendStoreError.writeFailed }
            let id = sqlite3_last_insert_rowid(database)
            try prune(now: now)
            try execute("COMMIT;", .writeFailed)
            return SpendRevision(id: id, recordedAt: now, conclusion: conclusion, supersedesRevisionID: latest?.id, drifts: drifts)
        } catch { try? execute("ROLLBACK;", .writeFailed); throw error }
    }

    public func revisions(now: Date = Date()) throws -> [SpendRevision] {
        try execute("BEGIN IMMEDIATE TRANSACTION;", .readFailed)
        do { try prune(now: now); try execute("COMMIT;", .readFailed) } catch { try? execute("ROLLBACK;", .readFailed); throw error }
        let statement = try prepare("SELECT id, recorded_at, conclusion_payload, supersedes_id, drift_json, pricing_revision, local_evidence_identity, local_event_count FROM spend_revisions WHERE refresh_status = 'complete' ORDER BY id;")
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        var values: [SpendRevision] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let conclusionData = data(statement, 2), let driftData = data(statement, 4),
                  let conclusion = try? decoder.decode(SpendReconciliationConclusion.self, from: conclusionData),
                  let drifts = try? decoder.decode([SpendConclusionDrift].self, from: driftData),
                  string(statement, 5) == conclusion.pricingRevision,
                  Int(sqlite3_column_int64(statement, 7)) == conclusion.localEvidenceIdentity?.eventCount ?? 0 else { throw APISpendStoreError.readFailed }
            let storedIdentity: LocalSpendEvidenceIdentity?
            if let identityData = data(statement, 6) {
                guard let decoded = try? decoder.decode(LocalSpendEvidenceIdentity.self, from: identityData) else { throw APISpendStoreError.readFailed }
                storedIdentity = decoded
            } else {
                storedIdentity = nil
            }
            guard storedIdentity == conclusion.localEvidenceIdentity else { throw APISpendStoreError.readFailed }
            let supersedes = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 3)
            values.append(SpendRevision(id: sqlite3_column_int64(statement, 0), recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), conclusion: conclusion, supersedesRevisionID: supersedes, drifts: drifts))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw APISpendStoreError.readFailed }
        return values
    }

    public func deleteAll() throws { try execute("DELETE FROM spend_revisions;", .writeFailed) }

    private func conclusionDrift(current: [SpendReconciliationRow], previous: [SpendReconciliationRow]) -> [SpendConclusionDrift] {
        let old = Dictionary(uniqueKeysWithValues: previous.compactMap { row in try? (AnthropicSpendReportImporter.fingerprint(row.providerBucket), row) })
        let new = Dictionary(uniqueKeysWithValues: current.compactMap { row in try? (AnthropicSpendReportImporter.fingerprint(row.providerBucket), row) })
        return Set(old.keys).union(new.keys).sorted().compactMap { identity in
            let before = old[identity]; let after = new[identity]
            guard let bucket = after?.providerBucket ?? before?.providerBucket else { return nil }
            let drift = SpendConclusionDrift(
                bucket: bucket,
                providerReportedChange: (after?.providerBucket.amount ?? 0) - (before?.providerBucket.amount ?? 0),
                attributedChange: (after?.attributedProviderReportedCost ?? 0) - (before?.attributedProviderReportedCost ?? 0),
                observedLocalChange: (after?.observedLocalCalculatedCost ?? 0) - (before?.observedLocalCalculatedCost ?? 0),
                unattributedChange: (after?.unattributedProviderReportedCost ?? 0) - (before?.unattributedProviderReportedCost ?? 0),
                previousStatus: before?.status,
                currentStatus: after?.status
            )
            return drift.providerReportedChange == 0 && drift.attributedChange == 0 && drift.observedLocalChange == 0 && drift.unattributedChange == 0 && drift.previousStatus == drift.currentStatus ? nil : drift
        }
    }

    private func prune(now: Date) throws {
        let old = try prepare("DELETE FROM spend_revisions WHERE recorded_at < ?;"); defer { sqlite3_finalize(old) }
        sqlite3_bind_double(old, 1, now.addingTimeInterval(-retention).timeIntervalSince1970)
        guard sqlite3_step(old) == SQLITE_DONE else { throw APISpendStoreError.writeFailed }
        let excess = try prepare("DELETE FROM spend_revisions WHERE id NOT IN (SELECT id FROM spend_revisions ORDER BY id DESC LIMIT ?);"); defer { sqlite3_finalize(excess) }
        sqlite3_bind_int64(excess, 1, Int64(maximumRevisions)); guard sqlite3_step(excess) == SQLITE_DONE else { throw APISpendStoreError.writeFailed }
    }

    private func createOrMigrate() throws {
        let version = try scalar("PRAGMA user_version;")
        if version == 0 {
            guard try objectNames().isEmpty else { throw APISpendStoreError.unknownSchema }
            try execute(Self.v3SQL, .unknownSchema); try execute(Self.indexSQL, .unknownSchema); try execute("PRAGMA user_version = 3;", .unknownSchema)
        } else if version == 1 {
            try validateFingerprint(tableSQL: Self.v1SQL)
            try migrateLegacyToV3()
        } else if version == 2 {
            try validateFingerprint(tableSQL: Self.v2SQL)
            try migrateLegacyToV3()
        } else if version != Self.schemaVersion { throw APISpendStoreError.unknownSchema }
        try validateFingerprint(tableSQL: Self.v3SQL)
    }

    private func migrateLegacyToV3() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;", .unknownSchema)
        do {
            try execute("ALTER TABLE spend_revisions RENAME TO spend_revisions_legacy;", .unknownSchema)
            try execute("DROP INDEX spend_revisions_retention;", .unknownSchema)
            try execute(Self.v3SQL, .unknownSchema)
            try execute(Self.indexSQL, .unknownSchema)
            let rows = try prepare("SELECT id, recorded_at, payload, supersedes_id FROM spend_revisions_legacy ORDER BY id;"); defer { sqlite3_finalize(rows) }
            var step = sqlite3_step(rows)
            while step == SQLITE_ROW {
                guard let payload = data(rows, 2), let buckets = try? JSONDecoder().decode([ProviderReportedSpendBucket].self, from: payload), !buckets.isEmpty else { throw APISpendStoreError.unknownSchema }
                let legacyRows = APISpendReconciler.reconcile(provider: buckets, local: []).map { row in
                    SpendReconciliationRow(providerBucket: row.providerBucket, attributedProviderReportedCost: 0, observedLocalCalculatedCost: 0, unattributedProviderReportedCost: row.providerBucket.amount, projects: [], agents: [], status: .unattributed, barriers: [.legacyConclusionUnavailable])
                }
                let conclusion = try SpendReconciliationConclusion(providerBuckets: buckets, rows: legacyRows, pricingRevision: "legacy-unavailable", localEvidenceIdentity: nil)
                let conclusionData = try JSONEncoder().encode(conclusion)
                let driftData = try JSONEncoder().encode([SpendConclusionDrift]())
                let insert = try prepare("INSERT INTO spend_revisions (id, recorded_at, provider, payload, supersedes_id, drift, drift_json, refresh_status, conclusion_payload, pricing_revision, local_evidence_identity, local_event_count) VALUES (?, ?, 'anthropic', ?, ?, '0', ?, 'complete', ?, 'legacy-unavailable', NULL, 0);")
                sqlite3_bind_int64(insert, 1, sqlite3_column_int64(rows, 0)); sqlite3_bind_double(insert, 2, sqlite3_column_double(rows, 1)); bind(payload, 3, insert)
                if sqlite3_column_type(rows, 3) == SQLITE_NULL { sqlite3_bind_null(insert, 4) } else { sqlite3_bind_int64(insert, 4, sqlite3_column_int64(rows, 3)) }
                bind(driftData, 5, insert); bind(conclusionData, 6, insert)
                guard sqlite3_step(insert) == SQLITE_DONE else { sqlite3_finalize(insert); throw APISpendStoreError.unknownSchema }
                sqlite3_finalize(insert)
                step = sqlite3_step(rows)
            }
            guard step == SQLITE_DONE else { throw APISpendStoreError.unknownSchema }
            try execute("DROP TABLE spend_revisions_legacy;", .unknownSchema)
            try execute("PRAGMA user_version = 3;", .unknownSchema); try execute("COMMIT;", .unknownSchema)
        } catch { try? execute("ROLLBACK;", .unknownSchema); throw APISpendStoreError.unknownSchema }
    }

    private func validateFingerprint(tableSQL: String) throws {
        guard try objectNames() == ["index:spend_revisions_retention", "table:spend_revisions"],
              try schemaSQL(type: "table", name: "spend_revisions") == Self.normalized(tableSQL),
              try schemaSQL(type: "index", name: "spend_revisions_retention") == Self.normalized(Self.indexSQL) else { throw APISpendStoreError.unknownSchema }
    }

    private func execute(_ sql: String, _ error: APISpendStoreError) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error } }
    private func prepare(_ sql: String) throws -> OpaquePointer? { var value: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &value, nil) == SQLITE_OK else { throw APISpendStoreError.readFailed }; return value }
    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer?) { sqlite3_bind_text(statement, index, value, -1, spendSQLiteTransient) }
    private func bind(_ value: Data, _ index: Int32, _ statement: OpaquePointer?) { _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), spendSQLiteTransient) } }
    private func data(_ statement: OpaquePointer?, _ index: Int32) -> Data? { guard sqlite3_column_type(statement, index) != SQLITE_NULL, let bytes = sqlite3_column_blob(statement, index) else { return nil }; return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))) }
    private func string(_ statement: OpaquePointer?, _ index: Int32) -> String? { guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }; return String(cString: sqlite3_column_text(statement, index)) }
    private func scalar(_ sql: String) throws -> Int { let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; guard sqlite3_step(statement) == SQLITE_ROW else { throw APISpendStoreError.readFailed }; return Int(sqlite3_column_int(statement, 0)) }
    private func objectNames() throws -> Set<String> { let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';"); defer { sqlite3_finalize(statement) }; var values = Set<String>(); var step = sqlite3_step(statement); while step == SQLITE_ROW { values.insert("\(String(cString: sqlite3_column_text(statement, 0))):\(String(cString: sqlite3_column_text(statement, 1)))"); step = sqlite3_step(statement) }; guard step == SQLITE_DONE else { throw APISpendStoreError.unknownSchema }; return values }
    private func schemaSQL(type: String, name: String) throws -> String { let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;"); defer { sqlite3_finalize(statement) }; bind(type, 1, statement); bind(name, 2, statement); guard sqlite3_step(statement) == SQLITE_ROW, let sql = string(statement, 0) else { throw APISpendStoreError.unknownSchema }; return Self.normalized(sql) }
    private static func normalized(_ sql: String) -> String { sql.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ";")) }
}

private let spendSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
