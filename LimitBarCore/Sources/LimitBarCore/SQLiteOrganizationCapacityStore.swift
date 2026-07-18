import Foundation
import SQLite3

public struct OrganizationStorageDiagnostics: Equatable, Sendable {
    public let schemaVersion: Int
    public let retentionDays: Int
    public let importCount: Int
    public let aggregateCount: Int
    public let oldestDay: Date?
    public let newestDay: Date?
}

public final class SQLiteOrganizationCapacityStore: @unchecked Sendable {
    public static let supportedRetentionDays = [30, 90, 180, 365]
    private static let schemaVersion = 1
    private static let importsSQL = "CREATE TABLE imports (file_digest TEXT PRIMARY KEY NOT NULL CHECK(length(file_digest) = 64), imported_at REAL NOT NULL, provenance BLOB NOT NULL);"
    private static let aggregatesSQL = "CREATE TABLE daily_aggregates (id INTEGER PRIMARY KEY AUTOINCREMENT, file_digest TEXT NOT NULL, day REAL NOT NULL, provider_product TEXT NOT NULL CHECK(provider_product IN ('claude_code','codex')), team_alias TEXT NOT NULL CHECK(length(team_alias) = 29 AND team_alias LIKE 'team-%'), payload BLOB NOT NULL, UNIQUE(day, provider_product, team_alias), FOREIGN KEY(file_digest) REFERENCES imports(file_digest) ON DELETE CASCADE);"
    private static let settingsSQL = "CREATE TABLE settings (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), retention_days INTEGER NOT NULL CHECK(retention_days IN (30,90,180,365)));"
    private static let retentionIndexSQL = "CREATE INDEX daily_aggregates_retention ON daily_aggregates(day, id);"

    private var database: OpaquePointer?

    public init(path: String) throws {
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw OrganizationCapacityError.storageUnavailable
        }
        sqlite3_busy_timeout(database, 5_000)
        do {
            try execute("PRAGMA foreign_keys = ON;")
            try createOrValidate()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public static func inMemory() throws -> Self { try Self(path: ":memory:") }

    public static func applicationSupportStore() throws -> Self {
        let locations = try LimitBarFileLocations.production()
        try FileManager.default.createDirectory(at: locations.organizationDirectory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: locations.organizationDeletionMarker.path) else {
            throw OrganizationCapacityError.deletionRecoveryRequired
        }
        return try Self(path: locations.organizationCapacityDatabase.path)
    }

    public func record(_ batch: OrganizationImportBatch, now: Date = Date()) throws {
        let validatedAggregates = try batch.aggregates.map { try $0.validated() }
        guard !batch.provenance.fileDigest.isEmpty,
              batch.provenance.privacyThreshold == OrganizationDailyAggregateImporter.privacyThreshold,
              batch.provenance.acceptedRecordCount == validatedAggregates.count else {
            throw OrganizationCapacityError.storageUnavailable
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let provenanceData = try encoder.encode(batch.provenance)
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let importStatement = try prepare("INSERT INTO imports (file_digest, imported_at, provenance) VALUES (?, ?, ?);")
            defer { sqlite3_finalize(importStatement) }
            bind(batch.provenance.fileDigest, 1, importStatement)
            sqlite3_bind_double(importStatement, 2, batch.provenance.importedAt.timeIntervalSince1970)
            bind(provenanceData, 3, importStatement)
            guard sqlite3_step(importStatement) == SQLITE_DONE else {
                if [organizationSQLiteConstraintPrimaryKey, organizationSQLiteConstraintUnique].contains(sqlite3_extended_errcode(database)) {
                    throw OrganizationCapacityError.duplicateImport
                }
                throw OrganizationCapacityError.storageUnavailable
            }
            for aggregate in validatedAggregates {
                let payload = try encoder.encode(aggregate)
                let statement = try prepare("INSERT INTO daily_aggregates (file_digest, day, provider_product, team_alias, payload) VALUES (?, ?, ?, ?, ?);")
                bind(batch.provenance.fileDigest, 1, statement)
                sqlite3_bind_double(statement, 2, aggregate.day.timeIntervalSince1970)
                bind(aggregate.providerProduct.rawValue, 3, statement)
                bind(aggregate.teamAlias, 4, statement)
                bind(payload, 5, statement)
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else {
                    if sqlite3_extended_errcode(database) == organizationSQLiteConstraintUnique {
                        throw OrganizationCapacityError.duplicateRecord
                    }
                    throw OrganizationCapacityError.storageUnavailable
                }
            }
            try prune(now: now)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func aggregates(now: Date = Date()) throws -> [OrganizationDailyAggregate] {
        try pruneTransaction(now: now)
        let statement = try prepare("SELECT payload FROM daily_aggregates ORDER BY day, provider_product, team_alias;")
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var values: [OrganizationDailyAggregate] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let payload = data(statement, 0),
                  let value = try? decoder.decode(OrganizationDailyAggregate.self, from: payload),
                  value.cohortSize >= OrganizationDailyAggregateImporter.privacyThreshold,
                  value.teamAlias.hasPrefix("team-"), value.teamAlias.count == 29 else {
                throw OrganizationCapacityError.storageUnavailable
            }
            values.append(value)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw OrganizationCapacityError.storageUnavailable }
        return values
    }

    public func provenances(now: Date = Date()) throws -> [OrganizationImportProvenance] {
        try pruneTransaction(now: now)
        let statement = try prepare("SELECT provenance FROM imports ORDER BY imported_at;")
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var values: [OrganizationImportProvenance] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let payload = data(statement, 0),
                  let value = try? decoder.decode(OrganizationImportProvenance.self, from: payload),
                  value.privacyThreshold == OrganizationDailyAggregateImporter.privacyThreshold,
                  value.acceptedRecordCount >= 0, value.suppressedRecordCount >= 0 else {
                throw OrganizationCapacityError.storageUnavailable
            }
            values.append(value)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw OrganizationCapacityError.storageUnavailable }
        return values
    }

    public func retentionDays() throws -> Int { try scalar("SELECT retention_days FROM settings WHERE singleton = 1;") }

    public func setRetentionDays(_ days: Int, now: Date = Date()) throws {
        guard Self.supportedRetentionDays.contains(days) else { throw OrganizationCapacityError.invalidValue("retention") }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare("UPDATE settings SET retention_days = ? WHERE singleton = 1;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(days))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw OrganizationCapacityError.storageUnavailable }
            try prune(now: now)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func secureEraseAndClose() throws {
        do {
            guard database != nil else { throw OrganizationCapacityError.storageUnavailable }
            try execute("PRAGMA secure_delete = ON;")
            guard try scalar("PRAGMA secure_delete;") == 1 else { throw OrganizationCapacityError.storageUnavailable }
            try execute("BEGIN EXCLUSIVE TRANSACTION;")
            do {
                try execute("DELETE FROM daily_aggregates;")
                try execute("DELETE FROM imports;")
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
            try execute("VACUUM;")
            try checkpointWAL()
            try switchToDeleteJournalMode()
            try closeChecked()
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    public func diagnostics(now: Date = Date()) throws -> OrganizationStorageDiagnostics {
        try pruneTransaction(now: now)
        let statement = try prepare("SELECT COUNT(*), MIN(day), MAX(day) FROM daily_aggregates;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw OrganizationCapacityError.storageUnavailable }
        let count = Int(sqlite3_column_int64(statement, 0))
        let oldest = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let newest = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        return OrganizationStorageDiagnostics(
            schemaVersion: Self.schemaVersion,
            retentionDays: try retentionDays(),
            importCount: try scalar("SELECT COUNT(*) FROM imports;"),
            aggregateCount: count,
            oldestDay: oldest,
            newestDay: newest
        )
    }

    private func pruneTransaction(now: Date) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try prune(now: now)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prune(now: Date) throws {
        let days = try retentionDays()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else {
            throw OrganizationCapacityError.storageUnavailable
        }
        let statement = try prepare("DELETE FROM daily_aggregates WHERE day < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw OrganizationCapacityError.storageUnavailable }
        let oldImports = try prepare("DELETE FROM imports WHERE imported_at < ? AND NOT EXISTS (SELECT 1 FROM daily_aggregates WHERE daily_aggregates.file_digest = imports.file_digest);")
        defer { sqlite3_finalize(oldImports) }
        sqlite3_bind_double(oldImports, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(oldImports) == SQLITE_DONE else { throw OrganizationCapacityError.storageUnavailable }
    }

    private func createOrValidate() throws {
        let version = try scalar("PRAGMA user_version;")
        if version == 0 {
            guard try objectNames().isEmpty else { throw OrganizationCapacityError.unknownDatabaseSchema }
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try execute(Self.importsSQL)
                try execute(Self.aggregatesSQL)
                try execute(Self.settingsSQL)
                try execute(Self.retentionIndexSQL)
                try execute("INSERT INTO settings (singleton, retention_days) VALUES (1, 90);")
                try execute("PRAGMA user_version = 1;")
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw OrganizationCapacityError.unknownDatabaseSchema
            }
        } else if version != Self.schemaVersion {
            throw OrganizationCapacityError.unknownDatabaseSchema
        }
        guard try objectNames() == ["index:daily_aggregates_retention", "table:daily_aggregates", "table:imports", "table:settings"] else {
            throw OrganizationCapacityError.unknownDatabaseSchema
        }
        try validateSQL(type: "table", name: "imports", expected: Self.importsSQL)
        try validateSQL(type: "table", name: "daily_aggregates", expected: Self.aggregatesSQL)
        try validateSQL(type: "table", name: "settings", expected: Self.settingsSQL)
        try validateSQL(type: "index", name: "daily_aggregates_retention", expected: Self.retentionIndexSQL)
        guard Self.supportedRetentionDays.contains(try retentionDays()) else { throw OrganizationCapacityError.unknownDatabaseSchema }
    }

    private func checkpointWAL() throws {
        let statement = try prepare("PRAGMA wal_checkpoint(TRUNCATE);")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 0 else {
            throw OrganizationCapacityError.storageUnavailable
        }
    }

    private func switchToDeleteJournalMode() throws {
        let statement = try prepare("PRAGMA journal_mode = DELETE;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, string(statement, 0)?.lowercased() == "delete" else {
            throw OrganizationCapacityError.storageUnavailable
        }
    }

    private func closeChecked() throws {
        guard let database else { return }
        guard sqlite3_close(database) == SQLITE_OK else { throw OrganizationCapacityError.storageUnavailable }
        self.database = nil
    }

    private func validateSQL(type: String, name: String, expected: String) throws {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(type, 1, statement)
        bind(name, 2, statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let actual = string(statement, 0), normalized(actual) == normalized(expected) else {
            throw OrganizationCapacityError.unknownDatabaseSchema
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw OrganizationCapacityError.storageUnavailable }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw OrganizationCapacityError.storageUnavailable }
        return statement
    }

    private func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw OrganizationCapacityError.storageUnavailable }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func objectNames() throws -> Set<String> {
        let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            names.insert("\(String(cString: sqlite3_column_text(statement, 0))):\(String(cString: sqlite3_column_text(statement, 1)))")
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw OrganizationCapacityError.storageUnavailable }
        return names
    }

    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, organizationSQLiteTransient)
    }

    private func bind(_ value: Data, _ index: Int32, _ statement: OpaquePointer?) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), organizationSQLiteTransient) }
    }

    private func data(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func string(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }

    private func normalized(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ";"))
    }
}

private let organizationSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let organizationSQLiteConstraintPrimaryKey = SQLITE_CONSTRAINT | (6 << 8)
private let organizationSQLiteConstraintUnique = SQLITE_CONSTRAINT | (8 << 8)
