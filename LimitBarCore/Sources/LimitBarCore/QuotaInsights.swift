import Foundation
import SQLite3

public enum QuotaObservationSource: String, Codable, CaseIterable, Sendable {
    case claudeProviderReport = "claude_provider_report"
    case codexLocalReport = "codex_local_report"
}

public enum QuotaInsightValidationError: Error, Equatable {
    case invalidObservation
}

public struct MeasuredQuotaObservation: Equatable, Sendable {
    public let identity: QuotaWindowIdentity
    public let percentageUsed: Double
    public let observedAt: Date
    public let source: QuotaObservationSource

    public init(
        identity: QuotaWindowIdentity,
        percentageUsed: Double,
        observedAt: Date,
        source: QuotaObservationSource
    ) throws {
        guard percentageUsed.isFinite, (0...100).contains(percentageUsed),
              observedAt.timeIntervalSince1970.isFinite,
              observedAt <= identity.resetBoundary,
              (identity.product == .claudeCode && source == .claudeProviderReport)
                || (identity.product == .codex && source == .codexLocalReport) else {
            throw QuotaInsightValidationError.invalidObservation
        }
        self.identity = identity
        self.percentageUsed = percentageUsed
        self.observedAt = observedAt
        self.source = source
    }
}

public enum MeasuredQuotaObservationAdapter {
    public static func claude(_ snapshot: ClaudeRateLimitSnapshot) -> [MeasuredQuotaObservation] {
        snapshot.limits.compactMap { limit in
            guard limit.scopeDisplayName == nil,
                  let reset = limit.resetsAt,
                  let identity = try? QuotaWindowIdentity(
                      product: .claudeCode,
                      identifier: "\(limit.group.rawValue):\(limit.kind)",
                      resetBoundary: reset
                  ) else { return nil }
            return try? MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: limit.percentUsed,
                observedAt: snapshot.fetchedAt,
                source: .claudeProviderReport
            )
        }
    }

    public static func codex(_ snapshot: CodexRateLimitSnapshot) -> [MeasuredQuotaObservation] {
        guard !snapshot.isBusinessPlan else { return [] }
        return [("primary", snapshot.primary), ("secondary", snapshot.secondary)].compactMap { slot, window in
            guard let window, let reset = window.resetsAt,
                  let identity = try? QuotaWindowIdentity(
                      product: .codex,
                      identifier: "\(slot):\(window.windowMinutes)",
                      resetBoundary: reset
                  ) else { return nil }
            return try? MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: window.percentUsed,
                observedAt: snapshot.reportedAt,
                source: .codexLocalReport
            )
        }
    }
}

public enum QuotaInsightUnavailableReason: String, Codable, Equatable, Sendable {
    case insufficientObservations = "insufficient_observations"
    case insufficientSpan = "insufficient_span"
    case staleEvidence = "stale_evidence"
    case resetOrExpired = "reset_or_expired"
    case counterDecreased = "counter_decreased"
    case noPositiveBurn = "no_positive_burn"

    public var displayText: String {
        switch self {
        case .insufficientObservations: "Collecting measured observations"
        case .insufficientSpan: "Collecting a longer measured span"
        case .staleEvidence: "Measured observations are stale"
        case .resetOrExpired: "Quota window reset or expired"
        case .counterDecreased: "Usage decreased; waiting for a stable window"
        case .noPositiveBurn: "No positive burn measured"
        }
    }
}

public enum QuotaInsightWindowKind: Equatable, Sendable {
    case session
    case weekly
    case other
}

public extension QuotaWindowIdentity {
    var insightWindowKind: QuotaInsightWindowKind {
        switch product {
        case .claudeCode:
            guard let separator = identifier.firstIndex(of: ":") else { return .other }
            let group = identifier[..<separator]
            let kind = identifier[identifier.index(after: separator)...]
            guard !kind.isEmpty else { return .other }
            return switch group {
            case ClaudeRateLimitGroup.session.rawValue: .session
            case ClaudeRateLimitGroup.weekly.rawValue: .weekly
            default: .other
            }
        case .codex:
            let components = identifier.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 2,
                  components[0] == "primary" || components[0] == "secondary",
                  let minutes = Int(components[1]), String(minutes) == components[1] else { return .other }
            return switch minutes {
            case 300: .session
            case 10_080: .weekly
            default: .other
            }
        default:
            return .other
        }
    }
}

public struct QuotaInsightRange: Equatable, Sendable {
    public let lower: Double
    public let upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }
}

public struct QualifiedQuotaInsight: Equatable, Sendable {
    public let identity: QuotaWindowIdentity
    public let measuredObservationCount: Int
    public let measuredSpan: TimeInterval
    public let calculatedBurnPercentPerHour: QuotaInsightRange
    public let calculatedExhaustionRange: ClosedRange<Date>?

    public init(
        identity: QuotaWindowIdentity,
        measuredObservationCount: Int,
        measuredSpan: TimeInterval,
        calculatedBurnPercentPerHour: QuotaInsightRange,
        calculatedExhaustionRange: ClosedRange<Date>?
    ) {
        self.identity = identity
        self.measuredObservationCount = measuredObservationCount
        self.measuredSpan = measuredSpan
        self.calculatedBurnPercentPerHour = calculatedBurnPercentPerHour
        self.calculatedExhaustionRange = calculatedExhaustionRange
    }
}

public enum QuotaInsightState: Equatable, Sendable {
    case qualified(QualifiedQuotaInsight)
    case unavailable(QuotaInsightUnavailableReason, measuredObservationCount: Int, measuredSpan: TimeInterval)
}

public enum QuotaInsightAnalytics {
    public static let minimumObservationCount = 4
    public static let minimumObservationSpan: TimeInterval = 15 * 60

    public static func analyze(
        _ observations: [MeasuredQuotaObservation],
        now: Date,
        maximumAge: TimeInterval
    ) -> QuotaInsightState {
        let ordered = observations.sorted { $0.observedAt < $1.observedAt }
        guard let identity = ordered.first?.identity else {
            return .unavailable(.insufficientObservations, measuredObservationCount: 0, measuredSpan: 0)
        }
        let sameWindow = ordered.filter { $0.identity == identity }
        let distinct = Dictionary(grouping: sameWindow, by: \.observedAt)
            .compactMap { $0.value.last }
            .sorted { $0.observedAt < $1.observedAt }
        let span = max(0, (distinct.last?.observedAt ?? now).timeIntervalSince(distinct.first?.observedAt ?? now))

        guard identity.resetBoundary > now else {
            return .unavailable(.resetOrExpired, measuredObservationCount: distinct.count, measuredSpan: span)
        }
        guard let latest = distinct.last,
              maximumAge.isFinite, maximumAge >= 0,
              now.timeIntervalSince(latest.observedAt) >= 0,
              now.timeIntervalSince(latest.observedAt) <= maximumAge else {
            return .unavailable(.staleEvidence, measuredObservationCount: distinct.count, measuredSpan: span)
        }
        guard distinct.count >= minimumObservationCount else {
            return .unavailable(.insufficientObservations, measuredObservationCount: distinct.count, measuredSpan: span)
        }
        guard span >= minimumObservationSpan else {
            return .unavailable(.insufficientSpan, measuredObservationCount: distinct.count, measuredSpan: span)
        }
        for pair in zip(distinct, distinct.dropFirst()) where pair.1.percentageUsed < pair.0.percentageUsed {
            return .unavailable(.counterDecreased, measuredObservationCount: distinct.count, measuredSpan: span)
        }

        var slopes: [Double] = []
        for lowerIndex in distinct.indices {
            for upperIndex in distinct.indices where upperIndex > lowerIndex {
                let elapsedHours = distinct[upperIndex].observedAt.timeIntervalSince(distinct[lowerIndex].observedAt) / 3_600
                let delta = distinct[upperIndex].percentageUsed - distinct[lowerIndex].percentageUsed
                if elapsedHours > 0, delta > 0 {
                    slopes.append(delta / elapsedHours)
                }
            }
        }
        slopes.sort()
        guard !slopes.isEmpty else {
            return .unavailable(.noPositiveBurn, measuredObservationCount: distinct.count, measuredSpan: span)
        }
        let lowerBurn = percentile(slopes, fraction: 0.25)
        let upperBurn = percentile(slopes, fraction: 0.75)
        let remaining = max(0, 100 - latest.percentageUsed)
        let earliest = latest.observedAt.addingTimeInterval(remaining / upperBurn * 3_600)
        let latestProjection = latest.observedAt.addingTimeInterval(remaining / lowerBurn * 3_600)
        let exhaustion = latestProjection < identity.resetBoundary
            ? earliest...latestProjection
            : nil
        return .qualified(QualifiedQuotaInsight(
            identity: identity,
            measuredObservationCount: distinct.count,
            measuredSpan: span,
            calculatedBurnPercentPerHour: QuotaInsightRange(lower: lowerBurn, upper: upperBurn),
            calculatedExhaustionRange: exhaustion
        ))
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}

public enum QuotaObservationStoreError: Error, Equatable {
    case openFailed
    case schemaFailed
    case writeFailed
    case readFailed
}

public final class SQLiteQuotaObservationStore {
    public static let schemaVersion = 1
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumObservationsPerWindow = 500

    private var database: OpaquePointer?

    private struct SchemaColumn: Equatable {
        let position: Int
        let name: String
        let type: String
        let isNotNull: Bool
        let primaryKeyPosition: Int
    }

    private static let createTableSQL = """
    CREATE TABLE quota_observations (
        product TEXT NOT NULL CHECK (product IN ('claudeCode', 'codex')),
        window_identifier TEXT NOT NULL CHECK (length(window_identifier) BETWEEN 1 AND 128),
        reset_boundary REAL NOT NULL,
        observed_at REAL NOT NULL,
        percentage_used REAL NOT NULL CHECK (percentage_used BETWEEN 0 AND 100),
        observation_source TEXT NOT NULL CHECK (observation_source IN ('claude_provider_report', 'codex_local_report')),
        PRIMARY KEY (product, window_identifier, reset_boundary, observed_at)
    )
    """
    private static let createRetentionIndexSQL = "CREATE INDEX quota_observations_retention ON quota_observations(observed_at)"
    private static let expectedColumns = [
        SchemaColumn(position: 0, name: "product", type: "TEXT", isNotNull: true, primaryKeyPosition: 1),
        SchemaColumn(position: 1, name: "window_identifier", type: "TEXT", isNotNull: true, primaryKeyPosition: 2),
        SchemaColumn(position: 2, name: "reset_boundary", type: "REAL", isNotNull: true, primaryKeyPosition: 3),
        SchemaColumn(position: 3, name: "observed_at", type: "REAL", isNotNull: true, primaryKeyPosition: 4),
        SchemaColumn(position: 4, name: "percentage_used", type: "REAL", isNotNull: true, primaryKeyPosition: 0),
        SchemaColumn(position: 5, name: "observation_source", type: "TEXT", isNotNull: true, primaryKeyPosition: 0),
    ]

    public init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw QuotaObservationStoreError.openFailed
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

    public static func inMemory() throws -> SQLiteQuotaObservationStore {
        try SQLiteQuotaObservationStore(path: ":memory:")
    }

    @discardableResult
    public func record(_ observations: [MeasuredQuotaObservation], now: Date = Date()) throws -> Int {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var inserted = 0
            for observation in observations {
                let statement = try prepare("""
                INSERT OR IGNORE INTO quota_observations
                    (product, window_identifier, reset_boundary, observed_at, percentage_used, observation_source)
                VALUES (?, ?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(statement) }
                bind(observation.identity.product.rawValue, at: 1, in: statement)
                bind(observation.identity.identifier, at: 2, in: statement)
                sqlite3_bind_double(statement, 3, observation.identity.resetBoundary.timeIntervalSince1970)
                sqlite3_bind_double(statement, 4, observation.observedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 5, observation.percentageUsed)
                bind(observation.source.rawValue, at: 6, in: statement)
                try stepDone(statement, error: .writeFailed)
                inserted += Int(sqlite3_changes(database))
            }
            try prune(now: now)
            try execute("COMMIT;")
            return inserted
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func observations(for identity: QuotaWindowIdentity, now: Date = Date()) throws -> [MeasuredQuotaObservation] {
        try pruneInTransaction(now: now)
        let statement = try prepare("""
        SELECT percentage_used, observed_at, observation_source
        FROM quota_observations
        WHERE product = ? AND window_identifier = ? AND reset_boundary = ?
        ORDER BY observed_at ASC;
        """)
        defer { sqlite3_finalize(statement) }
        bind(identity.product.rawValue, at: 1, in: statement)
        bind(identity.identifier, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, identity.resetBoundary.timeIntervalSince1970)
        var result: [MeasuredQuotaObservation] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let sourceRaw = stringColumn(statement, index: 2),
                  let source = QuotaObservationSource(rawValue: sourceRaw),
                  let observation = try? MeasuredQuotaObservation(
                      identity: identity,
                      percentageUsed: sqlite3_column_double(statement, 0),
                      observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                      source: source
                  ) else { throw QuotaObservationStoreError.readFailed }
            result.append(observation)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.readFailed }
        return result
    }

    public func identities(for product: ProviderProduct, now: Date = Date()) throws -> [QuotaWindowIdentity] {
        try pruneInTransaction(now: now)
        let statement = try prepare("""
        SELECT DISTINCT window_identifier, reset_boundary
        FROM quota_observations WHERE product = ?
        ORDER BY reset_boundary, window_identifier;
        """)
        defer { sqlite3_finalize(statement) }
        bind(product.rawValue, at: 1, in: statement)
        var result: [QuotaWindowIdentity] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let identifier = stringColumn(statement, index: 0),
                  let identity = try? QuotaWindowIdentity(
                      product: product,
                      identifier: identifier,
                      resetBoundary: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                  ) else { throw QuotaObservationStoreError.readFailed }
            result.append(identity)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.readFailed }
        return result
    }

    public func deleteAll() throws {
        try execute("DELETE FROM quota_observations;")
    }

    private func createSchema() throws {
        let existingVersion = try schemaVersion()
        guard existingVersion <= Self.schemaVersion else { throw QuotaObservationStoreError.schemaFailed }
        let objects = try schemaObjects()
        if !objects.isEmpty || existingVersion != 0 {
            guard existingVersion == Self.schemaVersion else { throw QuotaObservationStoreError.schemaFailed }
            try validateCanonicalSchema()
            return
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(Self.createTableSQL)
            try execute(Self.createRetentionIndexSQL)
            try validateCanonicalSchema()
            try execute("PRAGMA user_version = \(Self.schemaVersion);")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
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
        let age = try prepare("DELETE FROM quota_observations WHERE observed_at < ?;")
        defer { sqlite3_finalize(age) }
        sqlite3_bind_double(age, 1, now.addingTimeInterval(-Self.retentionInterval).timeIntervalSince1970)
        try stepDone(age, error: .writeFailed)

        let count = try prepare("""
        DELETE FROM quota_observations WHERE rowid IN (
            SELECT rowid FROM (
                SELECT rowid, ROW_NUMBER() OVER (
                    PARTITION BY product, window_identifier, reset_boundary
                    ORDER BY observed_at DESC
                ) AS position
                FROM quota_observations
            ) WHERE position > ?
        );
        """)
        defer { sqlite3_finalize(count) }
        sqlite3_bind_int64(count, 1, Int64(Self.maximumObservationsPerWindow))
        try stepDone(count, error: .writeFailed)
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw QuotaObservationStoreError.schemaFailed }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func schemaObjects() throws -> Set<String> {
        let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var objects = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let type = stringColumn(statement, index: 0),
                  let name = stringColumn(statement, index: 1) else { throw QuotaObservationStoreError.schemaFailed }
            objects.insert("\(type):\(name)")
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.schemaFailed }
        return objects
    }

    private func validateCanonicalSchema() throws {
        guard try schemaObjects() == ["table:quota_observations", "index:quota_observations_retention"],
              try schemaSQL(type: "table", name: "quota_observations") == normalizedSQL(Self.createTableSQL),
              try schemaSQL(type: "index", name: "quota_observations_retention") == normalizedSQL(Self.createRetentionIndexSQL),
              try columns() == Self.expectedColumns,
              try indexColumns() == ["observed_at"] else {
            throw QuotaObservationStoreError.schemaFailed
        }
    }

    private func columns() throws -> [SchemaColumn] {
        let statement = try prepare("PRAGMA table_info(quota_observations);")
        defer { sqlite3_finalize(statement) }
        var columns: [SchemaColumn] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let name = stringColumn(statement, index: 1),
                  let type = stringColumn(statement, index: 2),
                  sqlite3_column_type(statement, 4) == SQLITE_NULL else {
                throw QuotaObservationStoreError.schemaFailed
            }
            columns.append(SchemaColumn(
                position: Int(sqlite3_column_int(statement, 0)),
                name: name,
                type: type,
                isNotNull: sqlite3_column_int(statement, 3) == 1,
                primaryKeyPosition: Int(sqlite3_column_int(statement, 5))
            ))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.schemaFailed }
        return columns
    }

    private func schemaSQL(type: String, name: String) throws -> String {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(type, at: 1, in: statement)
        bind(name, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let sql = stringColumn(statement, index: 0),
              sqlite3_step(statement) == SQLITE_DONE else { throw QuotaObservationStoreError.schemaFailed }
        return normalizedSQL(sql)
    }

    private func indexColumns() throws -> [String] {
        let statement = try prepare("PRAGMA index_info(quota_observations_retention);")
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard Int(sqlite3_column_int(statement, 0)) == columns.count,
                  let name = stringColumn(statement, index: 2) else { throw QuotaObservationStoreError.schemaFailed }
            columns.append(name)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.schemaFailed }
        return columns
    }

    private func normalizedSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: " ;", with: ";")
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .lowercased()
            .replacingOccurrences(of: "create table if not exists ", with: "create table ")
            .replacingOccurrences(of: "create index if not exists ", with: "create index ")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw QuotaObservationStoreError.schemaFailed }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QuotaObservationStoreError.schemaFailed
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?, error: QuotaObservationStoreError) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}

public actor QuotaInsightsService {
    private let store: SQLiteQuotaObservationStore

    public init(store: SQLiteQuotaObservationStore) {
        self.store = store
    }

    public static func live(applicationSupportDirectory: URL) throws -> QuotaInsightsService {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        return try QuotaInsightsService(store: SQLiteQuotaObservationStore(
            path: applicationSupportDirectory.appendingPathComponent("quota-observations.sqlite").path
        ))
    }

    public func recordClaude(_ snapshot: ClaudeRateLimitSnapshot, now: Date) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try record(MeasuredQuotaObservationAdapter.claude(snapshot), now: now, maximumAge: QuotaObservationAdapter.claudeMaximumAge)
    }

    public func recordCodex(_ snapshot: CodexRateLimitSnapshot, now: Date) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try record(MeasuredQuotaObservationAdapter.codex(snapshot), now: now, maximumAge: QuotaObservationAdapter.codexMaximumAge)
    }

    public func reevaluateClaude(now: Date) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try reevaluate(product: .claudeCode, now: now, maximumAge: QuotaObservationAdapter.claudeMaximumAge)
    }

    public func deleteAll() throws {
        try store.deleteAll()
    }

    private func record(
        _ observations: [MeasuredQuotaObservation],
        now: Date,
        maximumAge: TimeInterval
    ) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try store.record(observations, now: now)
        return try findings(for: Set(observations.map(\.identity)), now: now, maximumAge: maximumAge)
    }

    private func reevaluate(
        product: ProviderProduct,
        now: Date,
        maximumAge: TimeInterval
    ) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try findings(for: Set(store.identities(for: product, now: now)), now: now, maximumAge: maximumAge)
    }

    private func findings(
        for identities: Set<QuotaWindowIdentity>,
        now: Date,
        maximumAge: TimeInterval
    ) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try Dictionary(uniqueKeysWithValues: identities.map { identity in
            let retained = try store.observations(for: identity, now: now)
            return (identity, QuotaInsightAnalytics.analyze(retained, now: now, maximumAge: maximumAge))
        })
    }
}
