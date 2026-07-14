import Foundation
import SQLite3

public enum ProviderRefreshProduct: String, CaseIterable, Equatable, Hashable, Sendable {
    case anthropicAPI = "anthropic_api"
    case openAIAPI = "openai_api"

    public var displayName: String {
        switch self {
        case .anthropicAPI: "Anthropic API"
        case .openAIAPI: "OpenAI API"
        }
    }
}

public enum ProviderRefreshOperation: String, CaseIterable, Equatable, Sendable {
    case usageAndCost = "usage_and_cost"
}

public enum ProviderRefreshOutcome: String, CaseIterable, Equatable, Sendable {
    case success
    case partialFailure = "partial_failure"
    case cancelled
    case authenticationFailure = "authentication_failure"
    case networkFailure = "network_failure"
    case failed

    public init(usage: AnthropicRefreshResult, cost: AnthropicRefreshResult) {
        self = Self.classify(components: [Self.component(usage), Self.component(cost)])
    }

    public init(usage: OpenAIRefreshResult, cost: OpenAIRefreshResult) {
        self = Self.classify(components: [Self.component(usage), Self.component(cost)])
    }

    public init(failureReason: ProviderFailureReason) {
        switch failureReason {
        case .authenticationRejected, .insufficientPermissions, .expiredCredential:
            self = .authenticationFailure
        case .networkUnavailable:
            self = .networkFailure
        case .invalidConfiguration, .refreshFailed:
            self = .failed
        }
    }

    private enum Component {
        case success
        case cancelled
        case failure(ProviderFailureReason)
    }

    private static func component(_ result: AnthropicRefreshResult) -> Component {
        switch result {
        case .success: .success
        case .cancelled: .cancelled
        case let .failure(reason): .failure(reason)
        }
    }

    private static func component(_ result: OpenAIRefreshResult) -> Component {
        switch result {
        case .success: .success
        case .cancelled: .cancelled
        case let .failure(reason): .failure(reason)
        }
    }

    private static func classify(components: [Component]) -> Self {
        if components.allSatisfy({ if case .success = $0 { true } else { false } }) {
            return .success
        }
        if components.contains(where: { if case .success = $0 { true } else { false } }) {
            return .partialFailure
        }
        if components.allSatisfy({ if case .cancelled = $0 { true } else { false } }) {
            return .cancelled
        }
        let reasons = components.compactMap { component -> ProviderFailureReason? in
            if case let .failure(reason) = component { return reason }
            return nil
        }
        if reasons.contains(where: { $0 == .authenticationRejected || $0 == .insufficientPermissions || $0 == .expiredCredential }) {
            return .authenticationFailure
        }
        if reasons.contains(.networkUnavailable) {
            return .networkFailure
        }
        return reasons.isEmpty ? .cancelled : .failed
    }
}

public enum ProviderRefreshDurationBucket: String, CaseIterable, Equatable, Sendable {
    case underOneSecond = "under_1_second"
    case oneToFiveSeconds = "1_to_5_seconds"
    case fiveToThirtySeconds = "5_to_30_seconds"
    case overThirtySeconds = "over_30_seconds"

    public init(duration: TimeInterval) throws {
        guard duration.isFinite, duration >= 0 else { throw ProviderRefreshHistoryError.invalidDuration }
        switch duration {
        case ..<1: self = .underOneSecond
        case ..<5: self = .oneToFiveSeconds
        case ..<30: self = .fiveToThirtySeconds
        default: self = .overThirtySeconds
        }
    }
}

public struct ProviderRefreshHistoryEntry: Equatable, Sendable {
    public static let schemaVersion = 1

    public let product: ProviderRefreshProduct
    public let operation: ProviderRefreshOperation
    public let outcome: ProviderRefreshOutcome
    public let startedAt: Date
    public let duration: ProviderRefreshDurationBucket
    public let affectedWindows: [ExactUsageWindow]

    public init(
        product: ProviderRefreshProduct,
        operation: ProviderRefreshOperation = .usageAndCost,
        outcome: ProviderRefreshOutcome,
        startedAt: Date,
        duration: TimeInterval,
        affectedWindows: [ExactUsageWindow]
    ) throws {
        guard startedAt.timeIntervalSince1970.isFinite else { throw ProviderRefreshHistoryError.invalidStartTime }
        guard affectedWindows.count <= 3, Set(affectedWindows).count == affectedWindows.count else {
            throw ProviderRefreshHistoryError.invalidWindows
        }
        self.product = product
        self.operation = operation
        self.outcome = outcome
        self.startedAt = startedAt
        self.duration = try ProviderRefreshDurationBucket(duration: duration)
        self.affectedWindows = affectedWindows.sorted(by: Self.windowSort)
    }

    private static func windowSort(_ lhs: ExactUsageWindow, _ rhs: ExactUsageWindow) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        if lhs.timeWindow != rhs.timeWindow { return lhs.timeWindow.rawValue < rhs.timeWindow.rawValue }
        return lhs.basis.rawValue < rhs.basis.rawValue
    }
}

public struct ProviderRefreshHistorySummary: Equatable, Sendable {
    public let latest: ProviderRefreshHistoryEntry?
    public let lastFullSuccess: ProviderRefreshHistoryEntry?

    public init(latest: ProviderRefreshHistoryEntry?, lastFullSuccess: ProviderRefreshHistoryEntry?) {
        self.latest = latest
        self.lastFullSuccess = lastFullSuccess
    }
}

public enum ProviderRefreshHistoryError: Error, Equatable {
    case invalidDuration
    case invalidStartTime
    case invalidWindows
    case openFailed
    case schemaFailed
    case writeFailed
    case readFailed
}

public final class SQLiteProviderRefreshHistoryStore {
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumEntriesPerProduct = 200

    private var database: OpaquePointer?

    private struct SchemaColumn: Equatable {
        let position: Int
        let name: String
        let type: String
        let isNotNull: Bool
        let primaryKeyPosition: Int
    }

    private static let createHistoryTableSQL = """
    CREATE TABLE provider_refresh_history (
        id INTEGER PRIMARY KEY,
        schema_version INTEGER NOT NULL CHECK (schema_version = 1),
        product TEXT NOT NULL CHECK (product IN ('anthropic_api', 'openai_api')),
        operation TEXT NOT NULL CHECK (operation = 'usage_and_cost'),
        outcome TEXT NOT NULL CHECK (outcome IN ('success', 'partial_failure', 'cancelled', 'authentication_failure', 'network_failure', 'failed')),
        started_at REAL NOT NULL,
        duration_bucket TEXT NOT NULL CHECK (duration_bucket IN ('under_1_second', '1_to_5_seconds', '5_to_30_seconds', 'over_30_seconds'))
    )
    """
    private static let createWindowsTableSQL = """
    CREATE TABLE provider_refresh_windows (
        entry_id INTEGER NOT NULL REFERENCES provider_refresh_history(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL CHECK (ordinal >= 0 AND ordinal < 3),
        window_kind TEXT NOT NULL CHECK (window_kind IN ('today', 'currentWeek')),
        window_start REAL NOT NULL,
        window_end REAL NOT NULL CHECK (window_end > window_start),
        calendar_basis TEXT NOT NULL CHECK (calendar_basis IN ('localCalendar', 'utcBilling')),
        aggregation_version INTEGER NOT NULL CHECK (aggregation_version > 0),
        PRIMARY KEY (entry_id, ordinal)
    )
    """
    private static let createHistoryIndexSQL = "CREATE INDEX provider_refresh_history_product_started ON provider_refresh_history(product, started_at DESC)"
    private static let expectedHistoryColumns = [
        SchemaColumn(position: 0, name: "id", type: "INTEGER", isNotNull: false, primaryKeyPosition: 1),
        SchemaColumn(position: 1, name: "schema_version", type: "INTEGER", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 2, name: "product", type: "TEXT", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 3, name: "operation", type: "TEXT", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 4, name: "outcome", type: "TEXT", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 5, name: "started_at", type: "REAL", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 6, name: "duration_bucket", type: "TEXT", isNotNull: true, primaryKeyPosition: 0),
    ]
    private static let expectedWindowColumns = [
        SchemaColumn(position: 0, name: "entry_id", type: "INTEGER", isNotNull: true, primaryKeyPosition: 1),
        SchemaColumn(position: 1, name: "ordinal", type: "INTEGER", isNotNull: true, primaryKeyPosition: 2),
        SchemaColumn(position: 2, name: "window_kind", type: "TEXT", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 3, name: "window_start", type: "REAL", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 4, name: "window_end", type: "REAL", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 5, name: "calendar_basis", type: "TEXT", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 6, name: "aggregation_version", type: "INTEGER", isNotNull: true, primaryKeyPosition: 0),
    ]

    public init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw ProviderRefreshHistoryError.openFailed
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

    public static func inMemory() throws -> SQLiteProviderRefreshHistoryStore {
        try SQLiteProviderRefreshHistoryStore(path: ":memory:")
    }

    public func record(_ entry: ProviderRefreshHistoryEntry, now: Date = Date()) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let entryStatement = try prepare("""
            INSERT INTO provider_refresh_history
                (schema_version, product, operation, outcome, started_at, duration_bucket)
            VALUES (?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(entryStatement) }
            sqlite3_bind_int(entryStatement, 1, Int32(ProviderRefreshHistoryEntry.schemaVersion))
            bind(entry.product.rawValue, at: 2, in: entryStatement)
            bind(entry.operation.rawValue, at: 3, in: entryStatement)
            bind(entry.outcome.rawValue, at: 4, in: entryStatement)
            sqlite3_bind_double(entryStatement, 5, entry.startedAt.timeIntervalSince1970)
            bind(entry.duration.rawValue, at: 6, in: entryStatement)
            try stepDone(entryStatement, error: .writeFailed)
            let entryID = sqlite3_last_insert_rowid(database)

            for (ordinal, window) in entry.affectedWindows.enumerated() {
                let windowStatement = try prepare("""
                INSERT INTO provider_refresh_windows
                    (entry_id, ordinal, window_kind, window_start, window_end, calendar_basis, aggregation_version)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(windowStatement) }
                sqlite3_bind_int64(windowStatement, 1, entryID)
                sqlite3_bind_int64(windowStatement, 2, Int64(ordinal))
                bind(window.timeWindow.rawValue, at: 3, in: windowStatement)
                sqlite3_bind_double(windowStatement, 4, window.start.timeIntervalSince1970)
                sqlite3_bind_double(windowStatement, 5, window.end.timeIntervalSince1970)
                bind(window.basis.rawValue, at: 6, in: windowStatement)
                sqlite3_bind_int64(windowStatement, 7, Int64(window.aggregationVersion))
                try stepDone(windowStatement, error: .writeFailed)
            }

            try prune(now: now)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func entries(for product: ProviderRefreshProduct, now: Date = Date()) throws -> [ProviderRefreshHistoryEntry] {
        try pruneInTransaction(now: now)
        let statement = try prepare("""
        SELECT id, product, operation, outcome, started_at, duration_bucket
        FROM provider_refresh_history WHERE product = ? ORDER BY started_at DESC, id DESC;
        """)
        defer { sqlite3_finalize(statement) }
        bind(product.rawValue, at: 1, in: statement)
        return try readEntries(statement)
    }

    public func summary(for product: ProviderRefreshProduct, now: Date = Date()) throws -> ProviderRefreshHistorySummary {
        let retained = try entries(for: product, now: now)
        return ProviderRefreshHistorySummary(
            latest: retained.first,
            lastFullSuccess: retained.first(where: { $0.outcome == .success })
        )
    }

    public func deleteAll() throws {
        try execute("DELETE FROM provider_refresh_history;")
    }

    func schemaObjects() throws -> Set<String> {
        let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var objects = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let type = stringColumn(statement, index: 0), let name = stringColumn(statement, index: 1) else {
                throw ProviderRefreshHistoryError.readFailed
            }
            objects.insert("\(type):\(name)")
        }
        return objects
    }

    func columnNames(table: String) throws -> Set<String> {
        guard ["provider_refresh_history", "provider_refresh_windows"].contains(table) else {
            throw ProviderRefreshHistoryError.readFailed
        }
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = stringColumn(statement, index: 1) else { throw ProviderRefreshHistoryError.readFailed }
            columns.insert(name)
        }
        return columns
    }

    private func createSchema() throws {
        try execute("PRAGMA foreign_keys = ON;")
        guard try foreignKeysEnabled() else { throw ProviderRefreshHistoryError.schemaFailed }
        let version = try schemaVersion()
        guard version <= ProviderRefreshHistoryEntry.schemaVersion else { throw ProviderRefreshHistoryError.schemaFailed }
        let objects = try schemaObjects()
        if !objects.isEmpty || version != 0 {
            guard version == ProviderRefreshHistoryEntry.schemaVersion else { throw ProviderRefreshHistoryError.schemaFailed }
            try validateCanonicalSchema()
            return
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(Self.createHistoryTableSQL)
            try execute(Self.createWindowsTableSQL)
            try execute(Self.createHistoryIndexSQL)
            try validateCanonicalSchema()
            try execute("PRAGMA user_version = \(ProviderRefreshHistoryEntry.schemaVersion);")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func validateCanonicalSchema() throws {
        guard try schemaObjects() == [
            "table:provider_refresh_history", "table:provider_refresh_windows",
            "index:provider_refresh_history_product_started",
        ], try schemaSQL(type: "table", name: "provider_refresh_history") == normalizedSQL(Self.createHistoryTableSQL),
           try schemaSQL(type: "table", name: "provider_refresh_windows") == normalizedSQL(Self.createWindowsTableSQL),
           try schemaSQL(type: "index", name: "provider_refresh_history_product_started") == normalizedSQL(Self.createHistoryIndexSQL),
           try columns(table: "provider_refresh_history") == Self.expectedHistoryColumns,
           try columns(table: "provider_refresh_windows") == Self.expectedWindowColumns,
           try indexColumns() == ["product", "started_at"],
           try windowForeignKey() == ("provider_refresh_history", "entry_id", "id", "CASCADE") else {
            throw ProviderRefreshHistoryError.schemaFailed
        }
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ProviderRefreshHistoryError.schemaFailed }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func foreignKeysEnabled() throws -> Bool {
        let statement = try prepare("PRAGMA foreign_keys;")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
    }

    private func schemaSQL(type: String, name: String) throws -> String {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(type, at: 1, in: statement)
        bind(name, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let sql = stringColumn(statement, index: 0),
              sqlite3_step(statement) == SQLITE_DONE else { throw ProviderRefreshHistoryError.schemaFailed }
        return normalizedSQL(sql)
    }

    private func columns(table: String) throws -> [SchemaColumn] {
        guard ["provider_refresh_history", "provider_refresh_windows"].contains(table) else { throw ProviderRefreshHistoryError.schemaFailed }
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var result: [SchemaColumn] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let name = stringColumn(statement, index: 1), let type = stringColumn(statement, index: 2),
                  sqlite3_column_type(statement, 4) == SQLITE_NULL else { throw ProviderRefreshHistoryError.schemaFailed }
            result.append(SchemaColumn(position: Int(sqlite3_column_int(statement, 0)), name: name, type: type,
                                       isNotNull: sqlite3_column_int(statement, 3) == 1,
                                       primaryKeyPosition: Int(sqlite3_column_int(statement, 5))))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ProviderRefreshHistoryError.schemaFailed }
        return result
    }

    private func indexColumns() throws -> [String] {
        let statement = try prepare("PRAGMA index_info(provider_refresh_history_product_started);")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = stringColumn(statement, index: 2) else { throw ProviderRefreshHistoryError.schemaFailed }
            result.append(name)
        }
        return result
    }

    private func windowForeignKey() throws -> (String, String, String, String) {
        let statement = try prepare("PRAGMA foreign_key_list(provider_refresh_windows);")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let table = stringColumn(statement, index: 2), let from = stringColumn(statement, index: 3),
              let to = stringColumn(statement, index: 4), let onDelete = stringColumn(statement, index: 6),
              sqlite3_step(statement) == SQLITE_DONE else { throw ProviderRefreshHistoryError.schemaFailed }
        return (table, from, to, onDelete)
    }

    private func normalizedSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: " ;", with: ";")
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .lowercased()
    }

    private func pruneInTransaction(now: Date) throws {
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
        let ageStatement = try prepare("DELETE FROM provider_refresh_history WHERE started_at < ?;")
        defer { sqlite3_finalize(ageStatement) }
        sqlite3_bind_double(ageStatement, 1, now.addingTimeInterval(-Self.retentionInterval).timeIntervalSince1970)
        try stepDone(ageStatement, error: .writeFailed)

        for product in ProviderRefreshProduct.allCases {
            let countStatement = try prepare("""
            DELETE FROM provider_refresh_history WHERE id IN (
                SELECT id FROM provider_refresh_history WHERE product = ?
                ORDER BY started_at DESC, id DESC LIMIT -1 OFFSET ?
            );
            """)
            defer { sqlite3_finalize(countStatement) }
            bind(product.rawValue, at: 1, in: countStatement)
            sqlite3_bind_int64(countStatement, 2, Int64(Self.maximumEntriesPerProduct))
            try stepDone(countStatement, error: .writeFailed)
        }
    }

    private func readEntries(_ statement: OpaquePointer?) throws -> [ProviderRefreshHistoryEntry] {
        var entries: [ProviderRefreshHistoryEntry] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let entryID = sqlite3_column_int64(statement, 0)
            guard let productRaw = stringColumn(statement, index: 1),
                  let product = ProviderRefreshProduct(rawValue: productRaw),
                  let operationRaw = stringColumn(statement, index: 2),
                  let operation = ProviderRefreshOperation(rawValue: operationRaw),
                  let outcomeRaw = stringColumn(statement, index: 3),
                  let outcome = ProviderRefreshOutcome(rawValue: outcomeRaw),
                  let durationRaw = stringColumn(statement, index: 5),
                  let duration = ProviderRefreshDurationBucket(rawValue: durationRaw) else {
                throw ProviderRefreshHistoryError.readFailed
            }
            let windows = try windows(entryID: entryID)
            let encodedDuration: TimeInterval = switch duration {
            case .underOneSecond: 0
            case .oneToFiveSeconds: 1
            case .fiveToThirtySeconds: 5
            case .overThirtySeconds: 30
            }
            entries.append(try ProviderRefreshHistoryEntry(
                product: product,
                operation: operation,
                outcome: outcome,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                duration: encodedDuration,
                affectedWindows: windows
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ProviderRefreshHistoryError.readFailed }
        return entries
    }

    private func windows(entryID: Int64) throws -> [ExactUsageWindow] {
        let statement = try prepare("""
        SELECT window_kind, window_start, window_end, calendar_basis, aggregation_version
        FROM provider_refresh_windows WHERE entry_id = ? ORDER BY ordinal;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, entryID)
        var windows: [ExactUsageWindow] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let kindRaw = stringColumn(statement, index: 0),
                  let kind = TimeWindow(rawValue: kindRaw),
                  let basisRaw = stringColumn(statement, index: 3),
                  let basis = UsageWindowBasis(rawValue: basisRaw) else {
                throw ProviderRefreshHistoryError.readFailed
            }
            windows.append(try ExactUsageWindow(
                timeWindow: kind,
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                basis: basis,
                aggregationVersion: Int(sqlite3_column_int64(statement, 4))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ProviderRefreshHistoryError.readFailed }
        return windows
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderRefreshHistoryError.schemaFailed
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ProviderRefreshHistoryError.writeFailed
        }
    }

    private func stepDone(_ statement: OpaquePointer?, error: ProviderRefreshHistoryError) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, providerRefreshSQLiteTransient) }
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }
}

public actor ProviderRefreshHistoryRepository {
    public static let shared = ProviderRefreshHistoryRepository.applicationSupport()

    private let pathFactory: @Sendable () throws -> String
    private var store: SQLiteProviderRefreshHistoryStore?

    public init(pathFactory: @escaping @Sendable () throws -> String) {
        self.pathFactory = pathFactory
    }

    public static func applicationSupport(fileManager: FileManager = .default) -> ProviderRefreshHistoryRepository {
        let fileManager = ProviderRefreshSendableFileManager(fileManager)
        return ProviderRefreshHistoryRepository {
            let applicationSupport = try fileManager.value.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport.appendingPathComponent("LimitBar", isDirectory: true)
            try fileManager.value.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("provider-refresh-history.sqlite").path
        }
    }

    @discardableResult
    public func record(_ entry: ProviderRefreshHistoryEntry, now: Date = Date()) -> Bool {
        do {
            try openStore().record(entry, now: now)
            return true
        } catch {
            return false
        }
    }

    public func summaries(now: Date = Date()) -> [ProviderRefreshProduct: ProviderRefreshHistorySummary] {
        do {
            let store = try openStore()
            return try Dictionary(uniqueKeysWithValues: ProviderRefreshProduct.allCases.map {
                ($0, try store.summary(for: $0, now: now))
            })
        } catch {
            return [:]
        }
    }

    @discardableResult
    public func deleteAll() -> Bool {
        do {
            try openStore().deleteAll()
            return true
        } catch {
            return false
        }
    }

    private func openStore() throws -> SQLiteProviderRefreshHistoryStore {
        if let store { return store }
        let opened = try SQLiteProviderRefreshHistoryStore(path: pathFactory())
        store = opened
        return opened
    }
}

private final class ProviderRefreshSendableFileManager: @unchecked Sendable {
    let value: FileManager
    init(_ value: FileManager) { self.value = value }
}

private let providerRefreshSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
