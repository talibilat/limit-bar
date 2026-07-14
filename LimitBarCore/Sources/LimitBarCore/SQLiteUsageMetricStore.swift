import Foundation
import SQLite3

public struct UsageStoreHealth: Equatable, Sendable {
    public let isOpen: Bool
    public let message: String

    public init(isOpen: Bool, message: String) {
        self.isOpen = isOpen
        self.message = message
    }
}

public enum UsageMetricStoreError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case decodeFailed(String)
    case providerMismatch
    case replacementScopeMismatch
}

public final class SQLiteUsageMetricStore {
    private var database: OpaquePointer?

    private let selectColumns = """
    id, provider, account_label, project_label, model_label, deployment_label, time_window,
    source_kind, source_identifier, window_start, window_end, window_basis, aggregation_version,
    input_tokens, output_tokens, cost_amount, cost_currency_code, cost_source,
    limit_status, limit_used, limit_value, refreshed_at, freshness_status, missed_refreshes
    """

    public init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw UsageMetricStoreError.openFailed(Self.message(from: database))
        }
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)

        do {
            try migrateSchema()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    public static func inMemory() throws -> SQLiteUsageMetricStore {
        try SQLiteUsageMetricStore(path: ":memory:")
    }

    public static func applicationSupportStore(fileManager: FileManager = .default) throws -> SQLiteUsageMetricStore {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("LimitBar", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteUsageMetricStore(path: directory.appendingPathComponent("usage-metrics.sqlite").path)
    }

    public func health() -> UsageStoreHealth {
        UsageStoreHealth(isOpen: database != nil, message: database == nil ? "SQLite store closed" : "SQLite store opened")
    }

    public func hasInitializedMetrics() throws -> Bool {
        let statement = try prepare("SELECT value FROM app_metadata WHERE key = 'metrics_initialized';")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return false }
        guard result == SQLITE_ROW else { throw UsageMetricStoreError.executeFailed(Self.message(from: database)) }
        return stringColumn(statement, index: 0) == "true"
    }

    public func markMetricsInitialized() throws {
        try execute("INSERT OR REPLACE INTO app_metadata (key, value) VALUES ('metrics_initialized', 'true');")
    }

    public func save(_ metrics: [UsageMetric]) throws {
        let sql = """
        INSERT OR REPLACE INTO usage_metrics (
            id, provider, account_label, project_label, model_label, deployment_label, time_window,
            source_kind, source_identifier, window_start, window_end, window_basis, aggregation_version,
            input_tokens, output_tokens, cost_amount, cost_currency_code, cost_source,
            limit_status, limit_used, limit_value, refreshed_at, freshness_status, missed_refreshes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        for metric in metrics {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            bind(metricID(metric), at: 1, in: statement)
            bind(metric.provider.rawValue, at: 2, in: statement)
            bind(metric.accountLabel, at: 3, in: statement)
            bind(metric.projectLabel, at: 4, in: statement)
            bind(metric.modelLabel, at: 5, in: statement)
            bind(metric.deploymentLabel, at: 6, in: statement)
            bind(metric.timeWindow.rawValue, at: 7, in: statement)

            let encodedProvenance = encode(metric.provenance)
            bind(encodedProvenance.sourceKind, at: 8, in: statement)
            bind(encodedProvenance.sourceIdentifier, at: 9, in: statement)
            bind(encodedProvenance.windowStart, at: 10, in: statement)
            bind(encodedProvenance.windowEnd, at: 11, in: statement)
            bind(encodedProvenance.windowBasis, at: 12, in: statement)
            bind(encodedProvenance.aggregationVersion, at: 13, in: statement)

            sqlite3_bind_int64(statement, 14, Int64(metric.tokenUsage.inputTokens))
            sqlite3_bind_int64(statement, 15, Int64(metric.tokenUsage.outputTokens))
            bind(metric.cost.map { NSDecimalNumber(decimal: $0.amount).stringValue }, at: 16, in: statement)
            bind(metric.cost?.currencyCode, at: 17, in: statement)
            bind(metric.cost?.source.rawValue, at: 18, in: statement)

            let encodedLimit = encode(metric.limitStatus)
            bind(encodedLimit.status, at: 19, in: statement)
            bind(encodedLimit.used, at: 20, in: statement)
            bind(encodedLimit.limit, at: 21, in: statement)
            bind(metric.refreshedAt?.timeIntervalSince1970, at: 22, in: statement)

            let encodedFreshness = encode(metric.freshness)
            bind(encodedFreshness.status, at: 23, in: statement)
            sqlite3_bind_int64(statement, 24, Int64(encodedFreshness.missedRefreshes))

            try stepDone(statement)
        }
    }

    public func metrics(for timeWindow: TimeWindow) throws -> [UsageMetric] {
        try readMetrics(sql: "SELECT \(selectColumns) FROM usage_metrics WHERE time_window = ? ORDER BY rowid;", bindings: [timeWindow.rawValue])
    }

    public func allMetrics() throws -> [UsageMetric] {
        try readMetrics(sql: "SELECT \(selectColumns) FROM usage_metrics ORDER BY rowid;", bindings: [])
    }

    public func currentMetrics(at date: Date, calendar: Calendar) throws -> [UsageMetric] {
        let current = try CurrentUsageWindows.resolve(at: date, calendar: calendar)
        let windows = [current.today, current.currentWeek, current.utcBillingWeek]
        let predicate = windows.map { _ in exactWindowPredicate }.joined(separator: " OR ")
        let statement = try prepare("SELECT \(selectColumns) FROM usage_metrics WHERE source_kind != 'legacy' AND (\(predicate)) ORDER BY rowid;")
        defer { sqlite3_finalize(statement) }

        var bindingIndex: Int32 = 1
        for window in windows {
            bind(window, startingAt: &bindingIndex, in: statement)
        }
        return try readMetrics(from: statement)
    }

    @discardableResult
    public func deleteMetrics(olderThan cutoff: Date) throws -> Int {
        let statement = try prepare("DELETE FROM usage_metrics WHERE refreshed_at IS NOT NULL AND refreshed_at < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        try stepDone(statement)
        return Int(sqlite3_changes(database))
    }

    @discardableResult
    public func deleteMetrics(provider: ProviderKind, timeWindows: [TimeWindow]) throws -> Int {
        guard !timeWindows.isEmpty else {
            return 0
        }

        let placeholders = Array(repeating: "?", count: timeWindows.count).joined(separator: ", ")
        let statement = try prepare("DELETE FROM usage_metrics WHERE provider = ? AND source_kind = 'legacy' AND time_window IN (\(placeholders));")
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, at: 1, in: statement)
        for (index, window) in timeWindows.enumerated() {
            bind(window.rawValue, at: Int32(index + 2), in: statement)
        }
        try stepDone(statement)
        return Int(sqlite3_changes(database))
    }

    public func replaceMetrics(provider: ProviderKind, timeWindows: [TimeWindow], with metrics: [UsageMetric]) throws {
        let allowedWindows = Set(timeWindows)
        guard metrics.allSatisfy({
            $0.provider == provider
                && allowedWindows.contains($0.timeWindow)
                && $0.provenance == .legacy(timeWindow: $0.timeWindow)
        }) else {
            throw UsageMetricStoreError.providerMismatch
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try deleteMetrics(provider: provider, timeWindows: timeWindows)
            try save(metrics)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func replaceMetrics(in scope: UsageReplacementScope, with metrics: [UsageMetric]) throws {
        guard metrics.allSatisfy({ metric in
            guard metric.provider == scope.provider,
                  case let .bounded(source, window) = metric.provenance else {
                return false
            }
            return source == scope.source && scope.windows.contains(window)
        }) else {
            throw UsageMetricStoreError.replacementScopeMismatch
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try mutateMetrics(in: scope, sqlPrefix: "DELETE FROM usage_metrics WHERE")
            try save(metrics)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func replaceMetrics(_ replacements: [UsageScopedReplacement]) throws {
        guard replacements.allSatisfy({ replacement in
            replacement.metrics.allSatisfy { metric in
                guard metric.provider == replacement.scope.provider,
                      case let .bounded(source, window) = metric.provenance else {
                    return false
                }
                return source == replacement.scope.source && replacement.scope.windows.contains(window)
            }
        }) else {
            throw UsageMetricStoreError.replacementScopeMismatch
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for replacement in replacements {
                try mutateMetrics(in: replacement.scope, sqlPrefix: "DELETE FROM usage_metrics WHERE")
                try save(replacement.metrics)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    public func deleteCustomMetrics(excluding sourceIDs: Set<UUID>) throws -> Int {
        let sql: String
        if sourceIDs.isEmpty {
            sql = "DELETE FROM usage_metrics WHERE source_kind = 'custom';"
        } else {
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
            sql = "DELETE FROM usage_metrics WHERE source_kind = 'custom' AND source_identifier NOT IN (\(placeholders));"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, sourceID) in sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
            bind(sourceID.uuidString, at: Int32(index + 1), in: statement)
        }
        try stepDone(statement)
        return Int(sqlite3_changes(database))
    }

    @discardableResult
    public func deleteMetrics(provider: ProviderKind, timeWindows: [TimeWindow], accountLabel: String) throws -> Int {
        guard !timeWindows.isEmpty else {
            return 0
        }

        let placeholders = Array(repeating: "?", count: timeWindows.count).joined(separator: ", ")
        let statement = try prepare("DELETE FROM usage_metrics WHERE provider = ? AND source_kind = 'legacy' AND account_label = ? AND time_window IN (\(placeholders));")
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, at: 1, in: statement)
        bind(accountLabel, at: 2, in: statement)
        for (index, window) in timeWindows.enumerated() {
            bind(window.rawValue, at: Int32(index + 3), in: statement)
        }
        try stepDone(statement)
        return Int(sqlite3_changes(database))
    }

    public func replaceMetrics(provider: ProviderKind, timeWindows: [TimeWindow], accountLabel: String, with metrics: [UsageMetric]) throws {
        let allowedWindows = Set(timeWindows)
        guard metrics.allSatisfy({
            $0.provider == provider
                && $0.accountLabel == accountLabel
                && allowedWindows.contains($0.timeWindow)
                && $0.provenance == .legacy(timeWindow: $0.timeWindow)
        }) else {
            throw UsageMetricStoreError.providerMismatch
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try deleteMetrics(provider: provider, timeWindows: timeWindows, accountLabel: accountLabel)
            try save(metrics)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func markMetricsStale(timeWindow: TimeWindow, missedRefreshes: Int) throws {
        let statement = try prepare("UPDATE usage_metrics SET freshness_status = 'stale', missed_refreshes = ? WHERE source_kind = 'legacy' AND time_window = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(missedRefreshes))
        bind(timeWindow.rawValue, at: 2, in: statement)
        try stepDone(statement)
    }

    public func markMetricsStale(provider: ProviderKind, timeWindows: [TimeWindow], missedRefreshes: Int) throws {
        guard !timeWindows.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: timeWindows.count).joined(separator: ", ")
        let statement = try prepare("UPDATE usage_metrics SET freshness_status = 'stale', missed_refreshes = ? WHERE provider = ? AND source_kind = 'legacy' AND time_window IN (\(placeholders));")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(missedRefreshes))
        bind(provider.rawValue, at: 2, in: statement)
        for (index, window) in timeWindows.enumerated() {
            bind(window.rawValue, at: Int32(index + 3), in: statement)
        }
        try stepDone(statement)
    }

    public func markMetricsStale(in scope: UsageReplacementScope, missedRefreshes: Int) throws {
        try mutateMetrics(
            in: scope,
            sqlPrefix: "UPDATE usage_metrics SET freshness_status = 'stale', missed_refreshes = ? WHERE",
            missedRefreshes: missedRefreshes
        )
    }

    func schemaColumnNames() throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(usage_metrics);")
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = stringColumn(statement, index: 1) {
                columns.insert(name)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw UsageMetricStoreError.executeFailed(Self.message(from: database))
        }
        return columns
    }

    private func migrateSchema() throws {
        let version = try userVersion()
        guard version == 0 || version == 2 else {
            throw UsageMetricStoreError.executeFailed("Unsupported usage metric schema version \(version)")
        }

        if version == 0, try !tableExists("usage_metrics") {
            guard try schemaObjects().isEmpty else {
                throw UsageMetricStoreError.executeFailed("Unsupported usage metric schema fingerprint for version 0")
            }
            try createLatestSchema()
        } else if version == 0 {
            guard try tableFingerprint("usage_metrics") == Self.legacyUsageMetricFingerprint,
                  try schemaObjects() == ["table:usage_metrics"],
                  try normalizedTableSQL("usage_metrics") == Self.normalizedLegacyUsageMetricsTableSQL else {
                throw UsageMetricStoreError.executeFailed("Unsupported usage metric schema fingerprint for version \(version)")
            }
            try migrateLegacySchema()
        } else {
            let allowedObjects: Set<String> = [
                "table:usage_metrics", "table:app_metadata",
                "index:usage_metrics_current_windows", "index:usage_metrics_replacement_scope",
                "table:alert_store_metadata", "table:alert_deliveries",
                "index:alert_deliveries_boundary", "index:alert_deliveries_lease"
            ]
            let fingerprint = try tableFingerprint("usage_metrics")
            let normalizedSQL = try normalizedTableSQL("usage_metrics")
            let isCanonical = fingerprint == Self.currentUsageMetricFingerprint
                && normalizedSQL == Self.normalizedCurrentUsageMetricsTableSQL
            let isKnownWeakVariant = fingerprint == Self.legacyMigratedCurrentFingerprint
                && normalizedSQL == Self.normalizedLegacyMigratedUsageMetricsTableSQL
            guard try schemaObjects().isSubset(of: allowedObjects), isCanonical || isKnownWeakVariant else {
                throw UsageMetricStoreError.executeFailed("Unsupported usage metric schema fingerprint for version 2")
            }
            guard try tableFingerprint("app_metadata") == Self.metadataFingerprint,
                  try normalizedSchemaObjectSQL(type: "table", name: "app_metadata") == Self.normalizedMetadataTableSQL else {
                throw UsageMetricStoreError.executeFailed("Unsupported app metadata schema fingerprint for version 2")
            }
            if isKnownWeakVariant {
                try rebuildCurrentSchema()
            } else {
                try repairSupportingIndexes()
            }
        }
    }

    private func createLatestSchema() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try createUsageMetricsTable()
            try createSupportingSchema()
            try execute("PRAGMA user_version = 2;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func migrateLegacySchema() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("ALTER TABLE usage_metrics RENAME TO usage_metrics_legacy;")
            try createUsageMetricsTable()
            try execute("""
            INSERT INTO usage_metrics (
                id, provider, account_label, project_label, model_label, deployment_label, time_window,
                source_kind, source_identifier, window_start, window_end, window_basis, aggregation_version,
                input_tokens, output_tokens, cost_amount, cost_currency_code, cost_source,
                limit_status, limit_used, limit_value, refreshed_at, freshness_status, missed_refreshes
            )
            SELECT
                id, provider, account_label, project_label, model_label, deployment_label, time_window,
                'legacy', NULL, NULL, NULL, NULL, NULL,
                input_tokens, output_tokens, cost_amount, cost_currency_code, cost_source,
                limit_status, limit_used, limit_value, refreshed_at, freshness_status, missed_refreshes
            FROM usage_metrics_legacy;
            """)
            try execute("DROP TABLE usage_metrics_legacy;")
            try createSupportingSchema()
            try execute("PRAGMA user_version = 2;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func createSupportingSchema() throws {
        try execute("CREATE TABLE IF NOT EXISTS app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        try execute("CREATE INDEX IF NOT EXISTS usage_metrics_current_windows ON usage_metrics (time_window, window_start, window_end, window_basis);")
        try execute("CREATE INDEX IF NOT EXISTS usage_metrics_replacement_scope ON usage_metrics (provider, time_window, source_kind, source_identifier);")
    }

    private func rebuildCurrentSchema() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("ALTER TABLE usage_metrics RENAME TO usage_metrics_previous;")
            try createUsageMetricsTable()
            try execute("""
            INSERT INTO usage_metrics (\(selectColumns))
            SELECT \(selectColumns) FROM usage_metrics_previous;
            """)
            try execute("DROP TABLE usage_metrics_previous;")
            try createSupportingSchema()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func createUsageMetricsTable() throws {
        try execute(Self.currentUsageMetricsTableSQL)
    }

    private func repairSupportingIndexes() throws {
        let expected: [(String, [String], String)] = [
            (
                "usage_metrics_current_windows",
                ["time_window", "window_start", "window_end", "window_basis"],
                Self.normalizedCurrentWindowsIndexSQL
            ),
            (
                "usage_metrics_replacement_scope",
                ["provider", "time_window", "source_kind", "source_identifier"],
                Self.normalizedReplacementScopeIndexSQL
            )
        ]
        guard try expected.contains(where: {
            try indexColumns($0.0) != $0.1
                || normalizedSchemaObjectSQL(type: "index", name: $0.0) != $0.2
        }) else { return }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for (name, _, _) in expected {
                try execute("DROP INDEX IF EXISTS \(name);")
            }
            try createSupportingSchema()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func indexColumns(_ name: String) throws -> [String] {
        let statement = try prepare("PRAGMA index_info(\(name));")
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = stringColumn(statement, index: 2) { columns.append(name) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw UsageMetricStoreError.executeFailed(Self.message(from: database))
        }
        return columns
    }

    private func tableFingerprint(_ table: String) throws -> [ColumnFingerprint] {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var columns: [ColumnFingerprint] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            columns.append(ColumnFingerprint(
                name: requiredString(statement, index: 1),
                type: requiredString(statement, index: 2).uppercased(),
                isRequired: sqlite3_column_int(statement, 3) == 1,
                isPrimaryKey: sqlite3_column_int(statement, 5) == 1
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw UsageMetricStoreError.executeFailed(Self.message(from: database))
        }
        return columns
    }

    private func schemaObjects() throws -> Set<String> {
        let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var objects = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            objects.insert("\(requiredString(statement, index: 0)):\(requiredString(statement, index: 1))")
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw UsageMetricStoreError.executeFailed(Self.message(from: database))
        }
        return objects
    }

    private func normalizedTableSQL(_ table: String) throws -> String? {
        try normalizedSchemaObjectSQL(type: "table", name: table)
    }

    private func normalizedSchemaObjectSQL(type: String, name: String) throws -> String? {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(type, at: 1, in: statement)
        bind(name, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let sql = stringColumn(statement, index: 0) else { return nil }
        return Self.normalizeSchemaSQL(sql)
    }

    private struct ColumnFingerprint: Equatable {
        let name: String
        let type: String
        let isRequired: Bool
        let isPrimaryKey: Bool
    }

    private static let legacyUsageMetricFingerprint = fingerprints([
        ("id", "TEXT", false, true), ("provider", "TEXT", true, false),
        ("account_label", "TEXT", false, false), ("project_label", "TEXT", false, false),
        ("model_label", "TEXT", true, false), ("deployment_label", "TEXT", false, false),
        ("time_window", "TEXT", true, false), ("input_tokens", "INTEGER", true, false),
        ("output_tokens", "INTEGER", true, false), ("cost_amount", "TEXT", false, false),
        ("cost_currency_code", "TEXT", false, false), ("cost_source", "TEXT", false, false),
        ("limit_status", "TEXT", true, false), ("limit_used", "REAL", false, false),
        ("limit_value", "REAL", false, false), ("refreshed_at", "REAL", false, false),
        ("freshness_status", "TEXT", true, false), ("missed_refreshes", "INTEGER", true, false)
    ])

    private static let currentUsageMetricFingerprint = fingerprints([
        ("id", "TEXT", false, true), ("provider", "TEXT", true, false),
        ("account_label", "TEXT", false, false), ("project_label", "TEXT", false, false),
        ("model_label", "TEXT", true, false), ("deployment_label", "TEXT", false, false),
        ("time_window", "TEXT", true, false), ("source_kind", "TEXT", true, false),
        ("source_identifier", "TEXT", false, false), ("window_start", "INTEGER", false, false),
        ("window_end", "INTEGER", false, false), ("window_basis", "TEXT", false, false),
        ("aggregation_version", "INTEGER", false, false), ("input_tokens", "INTEGER", true, false),
        ("output_tokens", "INTEGER", true, false), ("cost_amount", "TEXT", false, false),
        ("cost_currency_code", "TEXT", false, false), ("cost_source", "TEXT", false, false),
        ("limit_status", "TEXT", true, false), ("limit_used", "REAL", false, false),
        ("limit_value", "REAL", false, false), ("refreshed_at", "REAL", false, false),
        ("freshness_status", "TEXT", true, false), ("missed_refreshes", "INTEGER", true, false)
    ])

    private static let legacyMigratedCurrentFingerprint = legacyUsageMetricFingerprint + fingerprints([
        ("source_kind", "TEXT", true, false), ("source_identifier", "TEXT", false, false),
        ("window_start", "INTEGER", false, false), ("window_end", "INTEGER", false, false),
        ("window_basis", "TEXT", false, false), ("aggregation_version", "INTEGER", false, false)
    ])

    private static let metadataFingerprint = fingerprints([
        ("key", "TEXT", false, true), ("value", "TEXT", true, false)
    ])

    private static func fingerprints(_ values: [(String, String, Bool, Bool)]) -> [ColumnFingerprint] {
        values.map { ColumnFingerprint(name: $0.0, type: $0.1, isRequired: $0.2, isPrimaryKey: $0.3) }
    }

    private static func normalizeSchemaSQL(_ sql: String) -> String {
        sql.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ";").union(.whitespacesAndNewlines))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    private static let legacyUsageMetricsTableSQL = """
    CREATE TABLE usage_metrics (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        account_label TEXT,
        project_label TEXT,
        model_label TEXT NOT NULL,
        deployment_label TEXT,
        time_window TEXT NOT NULL,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        cost_amount TEXT,
        cost_currency_code TEXT,
        cost_source TEXT,
        limit_status TEXT NOT NULL,
        limit_used REAL,
        limit_value REAL,
        refreshed_at REAL,
        freshness_status TEXT NOT NULL,
        missed_refreshes INTEGER NOT NULL
    );
    """

    private static let normalizedLegacyUsageMetricsTableSQL = normalizeSchemaSQL(legacyUsageMetricsTableSQL)
    private static let normalizedCurrentUsageMetricsTableSQL = normalizeSchemaSQL(currentUsageMetricsTableSQL)
    private static let normalizedMetadataTableSQL = normalizeSchemaSQL(
        "CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
    )
    private static let normalizedCurrentWindowsIndexSQL = normalizeSchemaSQL(
        "CREATE INDEX usage_metrics_current_windows ON usage_metrics (time_window, window_start, window_end, window_basis);"
    )
    private static let normalizedReplacementScopeIndexSQL = normalizeSchemaSQL(
        "CREATE INDEX usage_metrics_replacement_scope ON usage_metrics (provider, time_window, source_kind, source_identifier);"
    )
    private static let normalizedLegacyMigratedUsageMetricsTableSQL = normalizeSchemaSQL("""
    CREATE TABLE usage_metrics (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        account_label TEXT,
        project_label TEXT,
        model_label TEXT NOT NULL,
        deployment_label TEXT,
        time_window TEXT NOT NULL,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        cost_amount TEXT,
        cost_currency_code TEXT,
        cost_source TEXT,
        limit_status TEXT NOT NULL,
        limit_used REAL,
        limit_value REAL,
        refreshed_at REAL,
        freshness_status TEXT NOT NULL,
        missed_refreshes INTEGER NOT NULL,
        source_kind TEXT NOT NULL DEFAULT 'legacy' CHECK (source_kind IN ('legacy', 'providerAPI', 'builtInLocalLog', 'custom')),
        source_identifier TEXT,
        window_start INTEGER CHECK (window_start IS NULL OR typeof(window_start) = 'integer'),
        window_end INTEGER CHECK (window_end IS NULL OR typeof(window_end) = 'integer'),
        window_basis TEXT CHECK (window_basis IS NULL OR window_basis IN ('localCalendar', 'utcBilling')),
        aggregation_version INTEGER CHECK (aggregation_version IS NULL OR (typeof(aggregation_version) = 'integer' AND aggregation_version > 0))
    );
    """)

    private static let currentUsageMetricsTableSQL = """
    CREATE TABLE usage_metrics (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        account_label TEXT,
        project_label TEXT,
        model_label TEXT NOT NULL,
        deployment_label TEXT,
        time_window TEXT NOT NULL,
        source_kind TEXT NOT NULL CHECK (source_kind IN ('legacy', 'providerAPI', 'builtInLocalLog', 'custom')),
        source_identifier TEXT,
        window_start INTEGER,
        window_end INTEGER,
        window_basis TEXT CHECK (window_basis IS NULL OR window_basis IN ('localCalendar', 'utcBilling')),
        aggregation_version INTEGER CHECK (aggregation_version IS NULL OR (typeof(aggregation_version) = 'integer' AND aggregation_version > 0)),
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        cost_amount TEXT,
        cost_currency_code TEXT,
        cost_source TEXT,
        limit_status TEXT NOT NULL,
        limit_used REAL,
        limit_value REAL,
        refreshed_at REAL,
        freshness_status TEXT NOT NULL,
        missed_refreshes INTEGER NOT NULL,
        CHECK (
            (source_kind = 'legacy' AND source_identifier IS NULL AND window_start IS NULL AND window_end IS NULL AND window_basis IS NULL AND aggregation_version IS NULL)
            OR
            (source_kind IN ('providerAPI', 'builtInLocalLog', 'custom') AND window_start IS NOT NULL AND window_end IS NOT NULL AND typeof(window_start) = 'integer' AND typeof(window_end) = 'integer' AND window_end > window_start AND window_basis IS NOT NULL AND aggregation_version IS NOT NULL AND typeof(aggregation_version) = 'integer')
        ),
        CHECK (
            (source_kind = 'custom' AND source_identifier IS NOT NULL)
            OR
            (source_kind != 'custom' AND source_identifier IS NULL)
        )
    );
    """

    private func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageMetricStoreError.executeFailed(Self.message(from: database))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func tableExists(_ name: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(name, at: 1, in: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw UsageMetricStoreError.executeFailed(Self.message(from: database))
        }
        return result == SQLITE_ROW
    }

    private func readMetrics(sql: String, bindings: [String]) throws -> [UsageMetric] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            bind(value, at: Int32(index + 1), in: statement)
        }

        return try readMetrics(from: statement)
    }

    private func readMetrics(from statement: OpaquePointer?) throws -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            metrics.append(try decodeMetric(from: statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw UsageMetricStoreError.executeFailed(Self.message(from: database))
        }
        return metrics
    }

    private var exactWindowPredicate: String {
        "(time_window = ? AND window_start = ? AND window_end = ? AND window_basis = ? AND aggregation_version = ?)"
    }

    private func mutateMetrics(
        in scope: UsageReplacementScope,
        sqlPrefix: String,
        missedRefreshes: Int? = nil
    ) throws {
        guard !scope.windows.isEmpty else { return }
        let source = encode(scope.source)
        let windows = scope.windows.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            if lhs.timeWindow != rhs.timeWindow { return lhs.timeWindow.rawValue < rhs.timeWindow.rawValue }
            if lhs.basis != rhs.basis { return lhs.basis.rawValue < rhs.basis.rawValue }
            return lhs.aggregationVersion < rhs.aggregationVersion
        }
        let windowPredicate = windows.map { _ in exactWindowPredicate }.joined(separator: " OR ")
        let statement = try prepare("\(sqlPrefix) provider = ? AND source_kind = ? AND source_identifier IS ? AND (\(windowPredicate));")
        defer { sqlite3_finalize(statement) }

        var bindingIndex: Int32 = 1
        if let missedRefreshes {
            sqlite3_bind_int64(statement, bindingIndex, Int64(missedRefreshes))
            bindingIndex += 1
        }
        bind(scope.provider.rawValue, at: bindingIndex, in: statement)
        bind(source.kind, at: bindingIndex + 1, in: statement)
        bind(source.identifier, at: bindingIndex + 2, in: statement)
        bindingIndex += 3
        for window in windows {
            bind(window, startingAt: &bindingIndex, in: statement)
        }
        try stepDone(statement)
    }

    private func bind(_ window: ExactUsageWindow, startingAt index: inout Int32, in statement: OpaquePointer?) {
        bind(window.timeWindow.rawValue, at: index, in: statement)
        sqlite3_bind_int64(statement, index + 1, Int64(window.start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, index + 2, Int64(window.end.timeIntervalSince1970))
        bind(window.basis.rawValue, at: index + 3, in: statement)
        sqlite3_bind_int64(statement, index + 4, Int64(window.aggregationVersion))
        index += 5
    }

    private func decodeMetric(from statement: OpaquePointer?) throws -> UsageMetric {
        guard let provider = ProviderKind(rawValue: requiredString(statement, index: 1)),
              let timeWindow = TimeWindow(rawValue: requiredString(statement, index: 6)) else {
            throw UsageMetricStoreError.decodeFailed("Invalid provider or time window")
        }

        let cost = try decodeCost(statement)
        let refreshedAt = sqlite3_column_type(statement, 21) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 21))

        return UsageMetric(
            provider: provider,
            accountLabel: stringColumn(statement, index: 2),
            projectLabel: stringColumn(statement, index: 3),
            modelLabel: requiredString(statement, index: 4),
            deploymentLabel: stringColumn(statement, index: 5),
            provenance: try decodeProvenance(statement, timeWindow: timeWindow),
            tokenUsage: TokenUsage(inputTokens: Int(sqlite3_column_int64(statement, 13)), outputTokens: Int(sqlite3_column_int64(statement, 14))),
            cost: cost,
            limitStatus: try decodeLimit(statement),
            refreshedAt: refreshedAt,
            freshness: try decodeFreshness(statement)
        )
    }

    private func decodeProvenance(_ statement: OpaquePointer?, timeWindow: TimeWindow) throws -> UsageSnapshotProvenance {
        let sourceKind = requiredString(statement, index: 7)
        let sourceIdentifier = stringColumn(statement, index: 8)
        let boundedColumns: [Int32] = [9, 10, 11, 12]
        let hasNullBoundedColumn = boundedColumns.contains { sqlite3_column_type(statement, $0) == SQLITE_NULL }

        if sourceKind == "legacy" {
            guard sourceIdentifier == nil, boundedColumns.allSatisfy({ sqlite3_column_type(statement, $0) == SQLITE_NULL }) else {
                throw UsageMetricStoreError.decodeFailed("Legacy provenance contains bounded fields")
            }
            return .legacy(timeWindow: timeWindow)
        }

        guard !hasNullBoundedColumn,
              let basis = UsageWindowBasis(rawValue: requiredString(statement, index: 11)) else {
            throw UsageMetricStoreError.decodeFailed("Bounded provenance is missing window fields")
        }
        guard sqlite3_column_type(statement, 9) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 10) == SQLITE_INTEGER else {
            throw UsageMetricStoreError.decodeFailed("Bounded provenance boundaries must be integer seconds")
        }
        guard sqlite3_column_type(statement, 12) == SQLITE_INTEGER else {
            throw UsageMetricStoreError.decodeFailed("Bounded provenance aggregation version must be an integer")
        }

        let source: UsageMetricSource
        switch sourceKind {
        case "providerAPI":
            guard sourceIdentifier == nil else {
                throw UsageMetricStoreError.decodeFailed("Provider API provenance has an identifier")
            }
            source = .providerAPI
        case "builtInLocalLog":
            guard sourceIdentifier == nil else {
                throw UsageMetricStoreError.decodeFailed("Built-in local provenance has an identifier")
            }
            source = .builtInLocalLog
        case "custom":
            guard let sourceIdentifier, let identifier = UUID(uuidString: sourceIdentifier) else {
                throw UsageMetricStoreError.decodeFailed("Custom provenance has an invalid identifier")
            }
            source = .custom(identifier)
        default:
            throw UsageMetricStoreError.decodeFailed("Invalid provenance source")
        }

        do {
            let window = try ExactUsageWindow(
                timeWindow: timeWindow,
                start: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 9))),
                end: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 10))),
                basis: basis,
                aggregationVersion: Int(sqlite3_column_int64(statement, 12))
            )
            return .bounded(source: source, window: window)
        } catch {
            throw UsageMetricStoreError.decodeFailed("Invalid bounded provenance window")
        }
    }

    private func decodeCost(_ statement: OpaquePointer?) throws -> Cost? {
        guard let amountText = stringColumn(statement, index: 15),
              let amount = Decimal(string: amountText),
              let currencyCode = stringColumn(statement, index: 16),
              let sourceText = stringColumn(statement, index: 17),
              let source = CostSource(rawValue: sourceText) else {
            return nil
        }
        return Cost(amount: amount, currencyCode: currencyCode, source: source)
    }

    private func decodeLimit(_ statement: OpaquePointer?) throws -> LimitStatus {
        switch requiredString(statement, index: 18) {
        case "confirmed":
            return .confirmed(used: sqlite3_column_double(statement, 19), limit: sqlite3_column_double(statement, 20))
        case "unsupportedByProviderAPI":
            return .unsupportedByProviderAPI
        case "disconnected":
            return .disconnected
        case "unavailable":
            return .unavailable
        default:
            throw UsageMetricStoreError.decodeFailed("Invalid limit status")
        }
    }

    private func decodeFreshness(_ statement: OpaquePointer?) throws -> Freshness {
        switch requiredString(statement, index: 22) {
        case "fresh":
            return .fresh
        case "stale":
            return .stale(missedRefreshes: Int(sqlite3_column_int64(statement, 23)))
        default:
            throw UsageMetricStoreError.decodeFailed("Invalid freshness")
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.executeFailed(Self.message(from: database))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.prepareFailed(Self.message(from: database))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UsageMetricStoreError.executeFailed(Self.message(from: database))
        }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.utf8CString.withUnsafeBufferPointer { bytes in
            sqlite3_bind_text(statement, index, bytes.baseAddress, Int32(bytes.count - 1), SQLITE_TRANSIENT)
        }
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ value: Int64?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private func requiredString(_ statement: OpaquePointer?, index: Int32) -> String {
        stringColumn(statement, index: index) ?? ""
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
    }

    private func metricID(_ metric: UsageMetric) -> String {
        var components = [
            metric.provider.rawValue,
            metric.timeWindow.rawValue,
            metric.accountLabel ?? "",
            metric.projectLabel ?? "",
            metric.modelLabel,
            metric.deploymentLabel ?? ""
        ]

        if case .bounded = metric.provenance {
            let provenance = encode(metric.provenance)
            components += [
                provenance.sourceKind,
                provenance.sourceIdentifier ?? "",
                provenance.windowStart.map(String.init) ?? "",
                provenance.windowEnd.map(String.init) ?? "",
                provenance.windowBasis ?? "",
                provenance.aggregationVersion.map(String.init) ?? ""
            ]
            if let cost = metric.cost {
                components += [cost.currencyCode, cost.source.rawValue]
            }
            return "v4|" + components.map { "\($0.utf8.count):\($0)" }.joined()
        }

        if let cost = metric.cost {
            let costComponents = components + [cost.currencyCode, cost.source.rawValue]
            return "v3|" + costComponents.map { "\($0.utf8.count):\($0)" }.joined()
        }
        guard components.contains(where: { $0.contains("|") }) else {
            return components.joined(separator: "|")
        }
        return "v2|" + components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private func encode(_ provenance: UsageSnapshotProvenance) -> (
        sourceKind: String,
        sourceIdentifier: String?,
        windowStart: Int64?,
        windowEnd: Int64?,
        windowBasis: String?,
        aggregationVersion: Int64?
    ) {
        switch provenance {
        case .legacy:
            return ("legacy", nil, nil, nil, nil, nil)
        case let .bounded(source, window):
            let encodedSource = encode(source)
            return (
                encodedSource.kind,
                encodedSource.identifier,
                Int64(window.start.timeIntervalSince1970),
                Int64(window.end.timeIntervalSince1970),
                window.basis.rawValue,
                Int64(window.aggregationVersion)
            )
        }
    }

    private func encode(_ source: UsageMetricSource) -> (kind: String, identifier: String?) {
        switch source {
        case .providerAPI:
            return ("providerAPI", nil)
        case .builtInLocalLog:
            return ("builtInLocalLog", nil)
        case let .custom(identifier):
            return ("custom", identifier.uuidString)
        }
    }

    private func encode(_ limitStatus: LimitStatus) -> (status: String, used: Double?, limit: Double?) {
        switch limitStatus {
        case let .confirmed(used, limit):
            return ("confirmed", used, limit)
        case .unsupportedByProviderAPI:
            return ("unsupportedByProviderAPI", nil, nil)
        case .disconnected:
            return ("disconnected", nil, nil)
        case .unavailable:
            return ("unavailable", nil, nil)
        }
    }

    private func encode(_ freshness: Freshness) -> (status: String, missedRefreshes: Int) {
        switch freshness {
        case .fresh:
            return ("fresh", 0)
        case let .stale(missedRefreshes):
            return ("stale", missedRefreshes)
        }
    }

    private static func message(from database: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(database) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
