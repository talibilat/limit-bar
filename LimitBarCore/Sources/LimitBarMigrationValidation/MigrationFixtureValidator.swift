import CryptoKit
import Foundation
import LimitBarCore
import SQLite3

public struct MigrationValidationReport: Equatable, Sendable {
    public let fixtureCount: Int

    public init(fixtureCount: Int) {
        self.fixtureCount = fixtureCount
    }
}

public enum MigrationFixtureValidator {
    public static func validateManifest(at manifestURL: URL) throws -> MigrationValidationReport {
        let manifestData = try Data(contentsOf: manifestURL)
        try validatePrivacy(of: manifestData)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.formatVersion == 1, !manifest.fixtures.isEmpty else {
            throw ValidationError.invalidManifest
        }

        let fixtureDirectory = manifestURL.deletingLastPathComponent()
        let listedFiles = Set(manifest.fixtures.map(\.file))
        let discoveredFiles = try Set(
            FileManager.default.contentsOfDirectory(at: fixtureDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "sql" }
                .map(\.lastPathComponent)
        )
        guard listedFiles == discoveredFiles, Set(manifest.fixtures.map(\.id)).count == manifest.fixtures.count else {
            throw ValidationError.fixtureInventoryMismatch
        }

        for fixture in manifest.fixtures {
            try validate(fixture, in: fixtureDirectory)
        }
        return MigrationValidationReport(fixtureCount: manifest.fixtures.count)
    }

    private static func validate(_ fixture: Fixture, in directory: URL) throws {
        guard ["usage-metrics", "quota-observations", "provider-refresh-history", "codex-explanations"].contains(fixture.store),
              fixture.origin == "synthetic" else {
            throw ValidationError.invalidManifest
        }
        let sqlData = try Data(contentsOf: directory.appendingPathComponent(fixture.file))
        try validatePrivacy(of: sqlData)
        guard let sql = String(data: sqlData, encoding: .utf8) else {
            throw ValidationError.invalidFixture(fixture.id)
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let databasePath = temporaryDirectory.appendingPathComponent("migration.sqlite").path

        try withDatabase(at: databasePath) { database in
            try execute(sql, in: database)
            guard try userVersion(in: database) == fixture.sqliteUserVersion else {
                throw ValidationError.invalidFixture(fixture.id)
            }
        }

        do {
            let store = try openProductionStore(fixture.store, at: databasePath)
            _ = store
            guard try recordCount(for: fixture.store, at: databasePath) == fixture.expected.rowCount else {
                throw ValidationError.recordCountMismatch(fixture.id)
            }
        }

        let canonicalPath = temporaryDirectory.appendingPathComponent("canonical.sqlite").path
        _ = try openProductionStore(fixture.store, at: canonicalPath)

        try withDatabase(at: databasePath) { database in
            guard try userVersion(in: database) == fixture.expected.resultUserVersion else {
                throw ValidationError.schemaVersionMismatch(fixture.id)
            }
            guard try integrityResult(in: database) == "ok" else {
                throw ValidationError.integrityCheckFailed(fixture.id)
            }
            try withDatabase(at: canonicalPath) { canonicalDatabase in
                try validateSchema(
                    for: fixture.store,
                    in: database,
                    canonicalDatabase: canonicalDatabase,
                    fixtureID: fixture.id
                )
            }
            let digest = try recordDigest(for: fixture.store, in: database)
            guard digest == fixture.expected.recordSHA256 else {
                throw ValidationError.recordDigestMismatch(fixture.id, actual: digest)
            }
        }
    }

    private static func openProductionStore(_ store: String, at path: String) throws -> Any {
        switch store {
        case "usage-metrics": try SQLiteUsageMetricStore(path: path)
        case "quota-observations": try SQLiteQuotaObservationStore(path: path)
        case "provider-refresh-history": try SQLiteProviderRefreshHistoryStore(path: path)
        case "codex-explanations": try SQLiteCodexExplanationStore(path: path)
        default: throw ValidationError.invalidManifest
        }
    }

    private static func recordCount(for store: String, at path: String) throws -> Int {
        let table = switch store {
        case "usage-metrics": "usage_metrics"
        case "quota-observations": "quota_observations"
        case "provider-refresh-history": "provider_refresh_history"
        case "codex-explanations": "codex_explanation_findings"
        default: throw ValidationError.invalidManifest
        }
        return try withDatabase(at: path) { database in
            let statement = try prepare("SELECT COUNT(*) FROM \(table);", in: database)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ValidationError.sqlite }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private static func validateSchema(
        for store: String,
        in database: OpaquePointer?,
        canonicalDatabase: OpaquePointer?,
        fixtureID: String
    ) throws {
        let expectedTables: [String]
        let expectedIndexes: [String: [String]]
        switch store {
        case "usage-metrics":
            expectedTables = ["usage_metrics", "app_metadata"]
            expectedIndexes = [
                "usage_metrics_current_windows": ["time_window", "window_start", "window_end", "window_basis"],
                "usage_metrics_replacement_scope": ["provider", "time_window", "source_kind", "source_identifier"]
            ]
        case "quota-observations":
            expectedTables = ["quota_observations"]
            expectedIndexes = ["quota_observations_retention": ["observed_at"]]
        case "provider-refresh-history":
            expectedTables = ["provider_refresh_history", "provider_refresh_windows"]
            expectedIndexes = ["provider_refresh_history_product_started": ["product", "started_at"]]
        case "codex-explanations":
            expectedTables = ["codex_explanation_findings"]
            expectedIndexes = ["codex_explanation_findings_recorded": ["recorded_at"]]
        default:
            throw ValidationError.invalidManifest
        }
        for (name, expectedColumns) in expectedIndexes {
            guard try indexColumns(name, in: database) == expectedColumns,
                  try normalizedSchemaObjectSQL(type: "index", name: name, in: database)
                    == normalizedSchemaObjectSQL(type: "index", name: name, in: canonicalDatabase) else {
                throw ValidationError.schemaFingerprintMismatch(fixtureID)
            }
        }

        let statement = try prepare(
            "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var objects = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            objects.insert("\(string(statement, 0)):\(string(statement, 1))")
            result = sqlite3_step(statement)
        }
        let expectedObjects = Set(
            expectedTables.map { "table:\($0)" } + expectedIndexes.keys.map { "index:\($0)" }
        )
        guard result == SQLITE_DONE, objects == expectedObjects else {
            throw ValidationError.schemaFingerprintMismatch(fixtureID)
        }
        for table in expectedTables {
            guard try normalizedSchemaObjectSQL(type: "table", name: table, in: database)
                    == normalizedSchemaObjectSQL(type: "table", name: table, in: canonicalDatabase) else {
                throw ValidationError.schemaFingerprintMismatch(fixtureID)
            }
        }
    }

    private static func recordDigest(for store: String, in database: OpaquePointer?) throws -> String {
        switch store {
        case "usage-metrics": try usageRecordDigest(in: database)
        case "quota-observations": try quotaObservationRecordDigest(in: database)
        case "provider-refresh-history": try providerRefreshHistoryRecordDigest(in: database)
        case "codex-explanations": try codexExplanationRecordDigest(in: database)
        default: throw ValidationError.invalidManifest
        }
    }

    private static func usageRecordDigest(in database: OpaquePointer?) throws -> String {
        let columns = """
        id, provider, account_label, project_label, model_label, deployment_label, time_window,
        source_kind, source_identifier, window_start, window_end, window_basis, aggregation_version,
        input_tokens, output_tokens, cost_amount, cost_currency_code, cost_source,
        limit_status, limit_used, limit_value, refreshed_at, freshness_status, missed_refreshes
        """
        let statement = try prepare("SELECT \(columns) FROM usage_metrics ORDER BY id;", in: database)
        defer { sqlite3_finalize(statement) }
        var data = Data()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            for index in 0..<sqlite3_column_count(statement) {
                appendColumn(statement, index: index, to: &data)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ValidationError.sqlite }
        data.append(contentsOf: "app_metadata".utf8)
        let metadata = try prepare("SELECT key, value FROM app_metadata ORDER BY key;", in: database)
        defer { sqlite3_finalize(metadata) }
        result = sqlite3_step(metadata)
        while result == SQLITE_ROW {
            appendColumn(metadata, index: 0, to: &data)
            appendColumn(metadata, index: 1, to: &data)
            result = sqlite3_step(metadata)
        }
        guard result == SQLITE_DONE else { throw ValidationError.sqlite }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func quotaObservationRecordDigest(in database: OpaquePointer?) throws -> String {
        var data = Data("quota_observations".utf8)
        try appendRows(
            """
            SELECT product, window_identifier, reset_boundary, observed_at, percentage_used, observation_source
            FROM quota_observations
            ORDER BY product, window_identifier, reset_boundary, observed_at, percentage_used, observation_source;
            """,
            in: database,
            to: &data
        )
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func providerRefreshHistoryRecordDigest(in database: OpaquePointer?) throws -> String {
        var data = Data("provider_refresh_history".utf8)
        try appendRows(
            """
            SELECT id, schema_version, product, operation, outcome, started_at, duration_bucket
            FROM provider_refresh_history ORDER BY id;
            """,
            in: database,
            to: &data
        )
        data.append(contentsOf: "provider_refresh_windows".utf8)
        try appendRows(
            """
            SELECT entry_id, ordinal, window_kind, window_start, window_end, calendar_basis, aggregation_version
            FROM provider_refresh_windows ORDER BY entry_id, ordinal;
            """,
            in: database,
            to: &data
        )
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func codexExplanationRecordDigest(in database: OpaquePointer?) throws -> String {
        var data = Data("codex_explanation_findings".utf8)
        try appendRows(
            """
            SELECT id, recorded_at, status, reason, adapter_version, interval_start, interval_end,
                   quota_reset_boundary, coverage_start, coverage_end, quota_movement_percent, input_tokens, cached_input_tokens,
                   output_tokens, reasoning_output_tokens, session_count, evidence_count, observation_count,
                   barrier_categories
            FROM codex_explanation_findings ORDER BY id;
            """,
            in: database,
            to: &data
        )
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendRows(
        _ sql: String,
        in database: OpaquePointer?,
        to data: inout Data
    ) throws {
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            for index in 0..<sqlite3_column_count(statement) {
                appendColumn(statement, index: index, to: &data)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ValidationError.sqlite }
    }

    private static func normalizedSchemaObjectSQL(
        type: String,
        name: String,
        in database: OpaquePointer?
    ) throws -> String {
        let statement = try prepare(
            "SELECT sql FROM sqlite_master WHERE type = '\(type)' AND name = '\(name)';",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ValidationError.sqlite }
        return string(statement, 0)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ";").union(.whitespacesAndNewlines))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    private static func appendColumn(_ statement: OpaquePointer?, index: Int32, to data: inout Data) {
        let type = sqlite3_column_type(statement, index)
        data.append(UInt8(type))
        switch type {
        case SQLITE_INTEGER:
            var value = sqlite3_column_int64(statement, index).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        case SQLITE_FLOAT:
            var value = sqlite3_column_double(statement, index).bitPattern.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        case SQLITE_TEXT, SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            var length = UInt64(count).littleEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            if let bytes = sqlite3_column_blob(statement, index), count > 0 {
                data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            }
        default:
            break
        }
    }

    private static func validatePrivacy(of data: Data) throws {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else {
            throw ValidationError.prohibitedFixtureContent
        }
        let prohibited = [
            "/users/", "bearer ", "sk-", "api_key", "credential", "prompt", "request_body",
            "response_body", "terminal_output"
        ]
        guard !prohibited.contains(where: text.contains) else {
            throw ValidationError.prohibitedFixtureContent
        }
    }

    private static func withDatabase<T>(at path: String, operation: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw ValidationError.sqlite }
        defer { sqlite3_close(database) }
        return try operation(database)
    }

    private static func execute(_ sql: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ValidationError.sqlite }
    }

    private static func prepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ValidationError.sqlite
        }
        return statement
    }

    private static func userVersion(in database: OpaquePointer?) throws -> Int {
        let statement = try prepare("PRAGMA user_version;", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ValidationError.sqlite }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func integrityResult(in database: OpaquePointer?) throws -> String {
        let statement = try prepare("PRAGMA integrity_check;", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ValidationError.sqlite }
        return string(statement, 0)
    }

    private static func indexColumns(_ name: String, in database: OpaquePointer?) throws -> [String] {
        let statement = try prepare("PRAGMA index_info(\(name));", in: database)
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            columns.append(string(statement, 2))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ValidationError.sqlite }
        return columns
    }

    private static func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }
}

private struct Manifest: Decodable {
    let formatVersion: Int
    let fixtures: [Fixture]
}

private struct Fixture: Decodable {
    let id: String
    let store: String
    let logicalSchema: String
    let sqliteUserVersion: Int
    let releaseRange: String
    let origin: String
    let file: String
    let expected: Expected
}

private struct Expected: Decodable {
    let resultUserVersion: Int
    let rowCount: Int
    let recordSHA256: String
}

private enum ValidationError: Error, CustomStringConvertible {
    case invalidManifest
    case fixtureInventoryMismatch
    case invalidFixture(String)
    case prohibitedFixtureContent
    case recordCountMismatch(String)
    case schemaVersionMismatch(String)
    case integrityCheckFailed(String)
    case schemaFingerprintMismatch(String)
    case recordDigestMismatch(String, actual: String)
    case sqlite

    var description: String {
        switch self {
        case .invalidManifest: "Invalid migration fixture manifest"
        case .fixtureInventoryMismatch: "Migration fixture manifest and directory differ"
        case let .invalidFixture(id): "Invalid migration fixture: \(id)"
        case .prohibitedFixtureContent: "Migration fixture contains prohibited private content"
        case let .recordCountMismatch(id): "Record count changed while validating \(id)"
        case let .schemaVersionMismatch(id): "Schema version mismatch while validating \(id)"
        case let .integrityCheckFailed(id): "Integrity check failed while validating \(id)"
        case let .schemaFingerprintMismatch(id): "Schema fingerprint mismatch while validating \(id)"
        case let .recordDigestMismatch(id, actual): "Record digest mismatch while validating \(id); actual \(actual)"
        case .sqlite: "SQLite migration validation failed"
        }
    }
}
