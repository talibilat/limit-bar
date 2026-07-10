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
}

public final class SQLiteUsageMetricStore {
    private var database: OpaquePointer?

    private let selectColumns = """
    id, provider, account_label, project_label, model_label, deployment_label, time_window,
    input_tokens, output_tokens, cost_amount, cost_currency_code, cost_source,
    limit_status, limit_used, limit_value, refreshed_at, freshness_status, missed_refreshes
    """

    public init(path: String) throws {
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw UsageMetricStoreError.openFailed(Self.message(from: database))
        }

        try createSchema()
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

    public func save(_ metrics: [UsageMetric]) throws {
        let sql = """
        INSERT OR REPLACE INTO usage_metrics (
            id, provider, account_label, project_label, model_label, deployment_label, time_window,
            input_tokens, output_tokens, cost_amount, cost_currency_code, cost_source,
            limit_status, limit_used, limit_value, refreshed_at, freshness_status, missed_refreshes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            sqlite3_bind_int64(statement, 8, Int64(metric.tokenUsage.inputTokens))
            sqlite3_bind_int64(statement, 9, Int64(metric.tokenUsage.outputTokens))
            bind(metric.cost.map { NSDecimalNumber(decimal: $0.amount).stringValue }, at: 10, in: statement)
            bind(metric.cost?.currencyCode, at: 11, in: statement)
            bind(metric.cost?.source.rawValue, at: 12, in: statement)

            let encodedLimit = encode(metric.limitStatus)
            bind(encodedLimit.status, at: 13, in: statement)
            bind(encodedLimit.used, at: 14, in: statement)
            bind(encodedLimit.limit, at: 15, in: statement)
            bind(metric.refreshedAt?.timeIntervalSince1970, at: 16, in: statement)

            let encodedFreshness = encode(metric.freshness)
            bind(encodedFreshness.status, at: 17, in: statement)
            sqlite3_bind_int64(statement, 18, Int64(encodedFreshness.missedRefreshes))

            try stepDone(statement)
        }
    }

    public func metrics(for timeWindow: TimeWindow) throws -> [UsageMetric] {
        try readMetrics(sql: "SELECT \(selectColumns) FROM usage_metrics WHERE time_window = ? ORDER BY rowid;", bindings: [timeWindow.rawValue])
    }

    public func allMetrics() throws -> [UsageMetric] {
        try readMetrics(sql: "SELECT \(selectColumns) FROM usage_metrics ORDER BY rowid;", bindings: [])
    }

    @discardableResult
    public func deleteMetrics(olderThan cutoff: Date) throws -> Int {
        let statement = try prepare("DELETE FROM usage_metrics WHERE refreshed_at IS NOT NULL AND refreshed_at < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        try stepDone(statement)
        return Int(sqlite3_changes(database))
    }

    public func markMetricsStale(timeWindow: TimeWindow, missedRefreshes: Int) throws {
        let statement = try prepare("UPDATE usage_metrics SET freshness_status = 'stale', missed_refreshes = ? WHERE time_window = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(missedRefreshes))
        bind(timeWindow.rawValue, at: 2, in: statement)
        try stepDone(statement)
    }

    func schemaColumnNames() throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(usage_metrics);")
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = stringColumn(statement, index: 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS usage_metrics (
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
        """)
    }

    private func readMetrics(sql: String, bindings: [String]) throws -> [UsageMetric] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            bind(value, at: Int32(index + 1), in: statement)
        }

        var metrics: [UsageMetric] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            metrics.append(try decodeMetric(from: statement))
        }
        return metrics
    }

    private func decodeMetric(from statement: OpaquePointer?) throws -> UsageMetric {
        guard let provider = ProviderKind(rawValue: requiredString(statement, index: 1)),
              let timeWindow = TimeWindow(rawValue: requiredString(statement, index: 6)) else {
            throw UsageMetricStoreError.decodeFailed("Invalid provider or time window")
        }

        let cost = try decodeCost(statement)
        let refreshedAt = sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 15))

        return UsageMetric(
            provider: provider,
            accountLabel: stringColumn(statement, index: 2),
            projectLabel: stringColumn(statement, index: 3),
            modelLabel: requiredString(statement, index: 4),
            deploymentLabel: stringColumn(statement, index: 5),
            timeWindow: timeWindow,
            tokenUsage: TokenUsage(inputTokens: Int(sqlite3_column_int64(statement, 7)), outputTokens: Int(sqlite3_column_int64(statement, 8))),
            cost: cost,
            limitStatus: try decodeLimit(statement),
            refreshedAt: refreshedAt,
            freshness: try decodeFreshness(statement)
        )
    }

    private func decodeCost(_ statement: OpaquePointer?) throws -> Cost? {
        guard let amountText = stringColumn(statement, index: 9),
              let amount = Decimal(string: amountText),
              let currencyCode = stringColumn(statement, index: 10),
              let sourceText = stringColumn(statement, index: 11),
              let source = CostSource(rawValue: sourceText) else {
            return nil
        }
        return Cost(amount: amount, currencyCode: currencyCode, source: source)
    }

    private func decodeLimit(_ statement: OpaquePointer?) throws -> LimitStatus {
        switch requiredString(statement, index: 12) {
        case "confirmed":
            return .confirmed(used: sqlite3_column_double(statement, 13), limit: sqlite3_column_double(statement, 14))
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
        switch requiredString(statement, index: 16) {
        case "fresh":
            return .fresh
        case "stale":
            return .stale(missedRefreshes: Int(sqlite3_column_int64(statement, 17)))
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
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func requiredString(_ statement: OpaquePointer?, index: Int32) -> String {
        stringColumn(statement, index: index) ?? ""
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func metricID(_ metric: UsageMetric) -> String {
        [
            metric.provider.rawValue,
            metric.timeWindow.rawValue,
            metric.accountLabel ?? "",
            metric.projectLabel ?? "",
            metric.modelLabel,
            metric.deploymentLabel ?? ""
        ].joined(separator: "|")
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
