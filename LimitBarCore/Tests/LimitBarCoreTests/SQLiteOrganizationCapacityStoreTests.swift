import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Organization capacity storage")
struct SQLiteOrganizationCapacityStoreTests {
    private let now = Date(timeIntervalSince1970: 1_783_468_800)
    private let aliaser = try! OrganizationTeamAliasKey(keyData: Data(repeating: 9, count: 32))

    @Test func persistsOnlyAliasedThresholdQualifiedRecordsInSeparateSchema() throws {
        let store = try SQLiteOrganizationCapacityStore.inMemory()
        let batch = try OrganizationDailyAggregateImporter.importData(file(), aliaser: aliaser, now: now)
        try store.record(batch, now: now)
        let records = try store.aggregates(now: now)
        #expect(records.count == 1)
        #expect(records[0].teamAlias.hasPrefix("team-"))
        #expect(try store.diagnostics(now: now).aggregateCount == 1)
        #expect(try store.retentionDays() == 90)
    }

    @Test func duplicateFileAndAggregateFailWithoutPartialWrites() throws {
        let store = try SQLiteOrganizationCapacityStore.inMemory()
        let batch = try OrganizationDailyAggregateImporter.importData(file(), aliaser: aliaser, now: now)
        try store.record(batch, now: now)
        #expect(throws: OrganizationCapacityError.duplicateImport) { try store.record(batch, now: now) }
        #expect(try store.aggregates(now: now).count == 1)
    }

    @Test func storeRejectsMismatchedPrivacyThresholdEvenForValidatedAggregates() throws {
        let store = try SQLiteOrganizationCapacityStore.inMemory()
        let accepted = try OrganizationDailyAggregateImporter.importData(file(), aliaser: aliaser, now: now)
        let unsafeProvenance = OrganizationImportProvenance(
            schemaVersion: accepted.provenance.schemaVersion,
            providerProducts: accepted.provenance.providerProducts,
            period: accepted.provenance.period,
            timezone: accepted.provenance.timezone,
            importedAt: accepted.provenance.importedAt,
            fileDigest: accepted.provenance.fileDigest,
            acceptedRecordCount: accepted.provenance.acceptedRecordCount,
            suppressedRecordCount: accepted.provenance.suppressedRecordCount,
            privacyThreshold: 4
        )
        let batch = OrganizationImportBatch(aggregates: accepted.aggregates, provenance: unsafeProvenance)
        #expect(throws: OrganizationCapacityError.storageUnavailable) { try store.record(batch, now: now) }
        #expect(try store.aggregates(now: now).isEmpty)
    }

    @Test func fullySuppressedImportsRetainOnlyProvenanceAndRemainIdempotent() throws {
        let store = try SQLiteOrganizationCapacityStore.inMemory()
        var root = try #require(JSONSerialization.jsonObject(with: file()) as? [String: Any])
        var rows = try #require(root["records"] as? [[String: Any]])
        rows[0]["cohort_size"] = 4
        rows[0]["peak_concurrency"] = 2
        root["records"] = rows
        let batch = try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: aliaser, now: now)
        try store.record(batch, now: now)
        #expect(try store.aggregates(now: now).isEmpty)
        #expect(try store.provenances(now: now).first?.suppressedRecordCount == 1)
        #expect(throws: OrganizationCapacityError.duplicateImport) { try store.record(batch, now: now) }
    }

    @Test func retentionIsIndependent() throws {
        let store = try SQLiteOrganizationCapacityStore.inMemory()
        let batch = try OrganizationDailyAggregateImporter.importData(file(), aliaser: aliaser, now: now)
        try store.record(batch, now: now)
        try store.setRetentionDays(30, now: now.addingTimeInterval(40 * 86_400))
        #expect(try store.aggregates(now: now.addingTimeInterval(40 * 86_400)).isEmpty)
        #expect(try store.retentionDays() == 30)
    }

    @Test func corruptedBelowThresholdPayloadFailsClosedOnRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteOrganizationCapacityStore(path: url.path)
        let batch = try OrganizationDailyAggregateImporter.importData(file(), aliaser: aliaser, now: now)
        try store.record(batch, now: now)
        var object = try #require(JSONSerialization.jsonObject(with: encoded(batch.aggregates[0])) as? [String: Any])
        object["cohortSize"] = 4
        let payload = try JSONSerialization.data(withJSONObject: object)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "UPDATE daily_aggregates SET payload = ?;", -1, &statement, nil) == SQLITE_OK)
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
        sqlite3_close(database)
        #expect(throws: OrganizationCapacityError.storageUnavailable) { try store.aggregates(now: now) }
    }

    @Test func unknownDatabaseVersionFailsClosed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 99;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(throws: OrganizationCapacityError.unknownDatabaseSchema) { try SQLiteOrganizationCapacityStore(path: url.path) }
    }

    private func file() -> Data {
        Data(#"{"schema_version":"limitbar.organization.daily.v1","administrator_reviewed":true,"aggregation_period":"daily","timezone":"UTC","records":[{"day":"2026-07-05","provider_product":"codex","team_identity":"11111111-1111-4111-8111-111111111111","cohort_size":5,"complete_day":true,"usage_units":50,"blocked_capacity_user_days":1,"peak_concurrency":2}]}"#.utf8)
    }

    private func encoded(_ aggregate: OrganizationDailyAggregate) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(aggregate)
    }
}
