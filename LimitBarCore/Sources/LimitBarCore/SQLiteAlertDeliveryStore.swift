import Foundation
import SQLite3

public enum AlertDeliveryStoreError: Error, Equatable {
    case openFailed(String)
    case executeFailed(String)
    case invalidReservation
    case unsupportedSchemaVersion(Int)
}

public struct AlertDeliveryReservation: Equatable, Sendable {
    public let token: UUID
    public let occurrence: AlertOccurrence

    public init(token: UUID, occurrence: AlertOccurrence) {
        self.token = token
        self.occurrence = occurrence
    }
}

public final class SQLiteAlertDeliveryStore {
    private var database: OpaquePointer?

    public init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw AlertDeliveryStoreError.openFailed(Self.message(from: database))
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

    public static func inMemory() throws -> SQLiteAlertDeliveryStore {
        try SQLiteAlertDeliveryStore(path: ":memory:")
    }

    public static func applicationSupportStore(fileManager: FileManager = .default) throws -> SQLiteAlertDeliveryStore {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("LimitBar", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteAlertDeliveryStore(path: directory.appendingPathComponent("usage-metrics.sqlite").path)
    }

    public func reserve(
        _ occurrence: AlertOccurrence,
        now: Date,
        leaseDuration: TimeInterval = 5 * 60
    ) throws -> AlertDeliveryReservation? {
        guard !occurrence.thresholds.isEmpty,
              now.timeIntervalSince1970.isFinite,
              leaseDuration.isFinite,
              leaseDuration > 0 else { return nil }
        let windowKey = try encode(occurrence.window)
        let token = UUID()
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try deleteExpiredReservations(now: now)
            let available = try occurrence.thresholds.filter { threshold in
                try !contains(ruleID: occurrence.ruleID, windowKey: windowKey, threshold: threshold)
            }
            guard !available.isEmpty else {
                try execute("COMMIT;")
                return nil
            }
            for threshold in available {
                let statement = try prepare("""
                INSERT INTO alert_deliveries
                    (rule_id, window_key, threshold, boundary, state, reservation_token, lease_expires_at, delivered_at)
                VALUES (?, ?, ?, ?, 'reserved', ?, ?, NULL);
                """)
                defer { sqlite3_finalize(statement) }
                bind(occurrence.ruleID.uuidString, at: 1, in: statement)
                bind(windowKey, at: 2, in: statement)
                sqlite3_bind_int64(statement, 3, Int64(threshold))
                sqlite3_bind_double(statement, 4, occurrence.window.boundary.timeIntervalSince1970)
                bind(token.uuidString, at: 5, in: statement)
                sqlite3_bind_double(statement, 6, now.addingTimeInterval(leaseDuration).timeIntervalSince1970)
                try stepDone(statement)
            }
            try execute("COMMIT;")
            return AlertDeliveryReservation(
                token: token,
                occurrence: AlertOccurrence(ruleID: occurrence.ruleID, window: occurrence.window, thresholds: available)
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func markDelivered(_ reservation: AlertDeliveryReservation, at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw AlertDeliveryStoreError.invalidReservation }
        try mutateReservation(reservation, sql: """
        UPDATE alert_deliveries
        SET state = 'delivered', reservation_token = NULL, lease_expires_at = NULL, delivered_at = ?
        WHERE reservation_token = ? AND state = 'reserved';
        """) { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            bind(reservation.token.uuidString, at: 2, in: statement)
        }
    }

    public func markFailed(_ reservation: AlertDeliveryReservation) throws {
        try mutateReservation(
            reservation,
            sql: "DELETE FROM alert_deliveries WHERE reservation_token = ? AND state = 'reserved';"
        ) { statement in
            bind(reservation.token.uuidString, at: 1, in: statement)
        }
    }

    public func retainAcceptedReservation(_ reservation: AlertDeliveryReservation) throws {
        try mutateReservation(
            reservation,
            sql: "UPDATE alert_deliveries SET lease_expires_at = ? WHERE reservation_token = ? AND state = 'reserved';"
        ) { statement in
            sqlite3_bind_double(statement, 1, reservation.occurrence.window.boundary.timeIntervalSince1970)
            bind(reservation.token.uuidString, at: 2, in: statement)
        }
    }

    public func satisfactions(for ruleID: UUID, window: AlertWindowIdentity) throws -> [AlertThresholdSatisfaction] {
        let statement = try prepare("""
        SELECT threshold FROM alert_deliveries
        WHERE rule_id = ? AND window_key = ? AND state = 'delivered'
        ORDER BY threshold;
        """)
        defer { sqlite3_finalize(statement) }
        bind(ruleID.uuidString, at: 1, in: statement)
        bind(try encode(window), at: 2, in: statement)
        var values: [AlertThresholdSatisfaction] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            values.append(AlertThresholdSatisfaction(ruleID: ruleID, window: window, threshold: Int(sqlite3_column_int64(statement, 0))))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw executeError() }
        return values
    }

    @discardableResult
    public func prune(through boundary: Date) throws -> Int {
        let statement = try prepare("DELETE FROM alert_deliveries WHERE boundary <= ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, boundary.timeIntervalSince1970)
        try stepDone(statement)
        return Int(sqlite3_changes(database))
    }

    public func reset(ruleID: UUID? = nil) throws {
        guard let ruleID else {
            try execute("DELETE FROM alert_deliveries;")
            return
        }
        let statement = try prepare("DELETE FROM alert_deliveries WHERE rule_id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(ruleID.uuidString, at: 1, in: statement)
        try stepDone(statement)
    }

    private func migrateSchema() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("CREATE TABLE IF NOT EXISTS alert_store_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            let version = try schemaVersion()
            guard version <= 1 else { throw AlertDeliveryStoreError.unsupportedSchemaVersion(version) }
            if version == 0 {
                try execute("""
                CREATE TABLE IF NOT EXISTS alert_deliveries (
                    rule_id TEXT NOT NULL,
                    window_key TEXT NOT NULL,
                    threshold INTEGER NOT NULL CHECK (threshold BETWEEN 1 AND 100),
                    boundary REAL NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('reserved', 'delivered')),
                    reservation_token TEXT,
                    lease_expires_at REAL,
                    delivered_at REAL,
                    PRIMARY KEY (rule_id, window_key, threshold),
                    CHECK (
                        (state = 'reserved' AND reservation_token IS NOT NULL AND lease_expires_at IS NOT NULL AND delivered_at IS NULL)
                        OR
                        (state = 'delivered' AND reservation_token IS NULL AND lease_expires_at IS NULL AND delivered_at IS NOT NULL)
                    )
                );
                """)
                try execute("CREATE INDEX IF NOT EXISTS alert_deliveries_boundary ON alert_deliveries (boundary);")
                try execute("CREATE INDEX IF NOT EXISTS alert_deliveries_lease ON alert_deliveries (state, lease_expires_at);")
                try execute("INSERT OR REPLACE INTO alert_store_metadata (key, value) VALUES ('schema_version', '1');")
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("SELECT value FROM alert_store_metadata WHERE key = 'schema_version';")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return 0 }
        guard result == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              let version = Int(String(cString: text)) else { throw executeError() }
        return version
    }

    private func deleteExpiredReservations(now: Date) throws {
        let statement = try prepare("DELETE FROM alert_deliveries WHERE state = 'reserved' AND lease_expires_at <= ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func contains(ruleID: UUID, windowKey: String, threshold: Int) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM alert_deliveries WHERE rule_id = ? AND window_key = ? AND threshold = ?;")
        defer { sqlite3_finalize(statement) }
        bind(ruleID.uuidString, at: 1, in: statement)
        bind(windowKey, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, Int64(threshold))
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw executeError() }
        return result == SQLITE_ROW
    }

    private func mutateReservation(
        _ reservation: AlertDeliveryReservation,
        sql: String,
        bindValues: (OpaquePointer?) -> Void
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bindValues(statement)
            try stepDone(statement)
            guard sqlite3_changes(database) == reservation.occurrence.thresholds.count else {
                throw AlertDeliveryStoreError.invalidReservation
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func encode(_ window: AlertWindowIdentity) throws -> String {
        window.canonicalIdentifier
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw executeError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw executeError() }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw executeError() }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        _ = value.utf8CString.withUnsafeBufferPointer { bytes in
            sqlite3_bind_text(statement, index, bytes.baseAddress, Int32(bytes.count - 1), alertSQLiteTransient)
        }
    }

    private func executeError() -> AlertDeliveryStoreError {
        .executeFailed(Self.message(from: database))
    }

    private static func message(from database: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(database) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}

private let alertSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
