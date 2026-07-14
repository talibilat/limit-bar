import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("SQLite usage metric store")
struct SQLiteUsageMetricStoreTests {
    @Test("saves and queries normalized metrics by time window")
    func savesAndQueriesNormalizedMetricsByTimeWindow() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let today = metric(provider: .anthropic, timeWindow: .today, modelLabel: "Claude Sonnet")
        let week = metric(provider: .openAI, timeWindow: .currentWeek, modelLabel: "gpt-5.1-codex")

        try store.save([today, week])

        #expect(try store.metrics(for: .today) == [today])
        #expect(try store.metrics(for: .currentWeek) == [week])
    }

    @Test("queries metrics across all providers")
    func queriesMetricsAcrossAllProviders() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let metrics = [
            metric(provider: .anthropic, timeWindow: .today, modelLabel: "Claude Sonnet"),
            metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "gpt-4.1"),
            metric(provider: .openAI, timeWindow: .today, modelLabel: "gpt-5.1-codex")
        ]

        try store.save(metrics)

        #expect(try store.allMetrics() == metrics)
    }

    @Test("saving same logical metric updates the retained row")
    func savingSameLogicalMetricUpdatesTheRetainedRow() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let first = metric(provider: .anthropic, timeWindow: .today, modelLabel: "Claude Sonnet", refreshedAt: Date(timeIntervalSince1970: 100))
        let updated = metric(provider: .anthropic, timeWindow: .today, modelLabel: "Claude Sonnet", refreshedAt: Date(timeIntervalSince1970: 200), inputTokens: 42, outputTokens: 12)

        try store.save([first])
        try store.save([updated])

        #expect(try store.allMetrics() == [updated])
    }

    @Test("round trip preserves cost and confirmed limit fields")
    func roundTripPreservesCostAndConfirmedLimitFields() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let stored = metric(
            provider: .openAI,
            timeWindow: .today,
            modelLabel: "gpt-5.1-codex",
            cost: Cost(amount: Decimal(string: "12.34")!, currencyCode: "USD", source: .providerReported),
            limitStatus: .confirmed(used: 72, limit: 100)
        )

        try store.save([stored])

        #expect(try store.metrics(for: .today) == [stored])
    }

    @Test("round trip preserves bounded sources and window bases")
    func roundTripPreservesBoundedSourcesAndWindowBases() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let customID = try #require(UUID(uuidString: "4A613A87-9D4D-4208-80D5-7F6D94A6DBE7"))
        let localWindow = try exactWindow(
            timeWindow: .today,
            start: 1_783_728_000,
            end: 1_783_814_400,
            basis: .localCalendar
        )
        let billingWindow = try exactWindow(
            timeWindow: .currentWeek,
            start: 1_783_641_600,
            end: 1_784_246_400,
            basis: .utcBilling,
            aggregationVersion: 2
        )
        let metrics = [
            metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: localWindow), modelLabel: "api"),
            metric(provider: .openAI, provenance: .bounded(source: .builtInLocalLog, window: billingWindow), modelLabel: "local"),
            metric(provider: .custom, provenance: .bounded(source: .custom(customID), window: localWindow), modelLabel: "custom")
        ]

        try store.save(metrics)

        #expect(try store.allMetrics() == metrics)
    }

    @Test("metric identity distinguishes source and exact windows")
    func metricIdentityDistinguishesSourceAndExactWindows() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let firstWindow = try exactWindow(timeWindow: .today, start: 100, end: 200, basis: .localCalendar)
        let secondWindow = try exactWindow(timeWindow: .today, start: 200, end: 300, basis: .localCalendar)
        let commonSourceWindow = metric(
            provider: .anthropic,
            provenance: .bounded(source: .providerAPI, window: firstWindow),
            modelLabel: "same"
        )
        let differentSource = metric(
            provider: .anthropic,
            provenance: .bounded(source: .builtInLocalLog, window: firstWindow),
            modelLabel: "same"
        )
        let differentWindow = metric(
            provider: .anthropic,
            provenance: .bounded(source: .providerAPI, window: secondWindow),
            modelLabel: "same"
        )

        try store.save([commonSourceWindow, differentSource, differentWindow])

        #expect(try store.allMetrics() == [commonSourceWindow, differentSource, differentWindow])
    }

    @Test("schema rejects bounded metrics with REAL window boundaries")
    func schemaRejectsRealWindowBoundaries() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteUsageMetricStore(path: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }

        #expect(throws: UsageMetricStoreError.self) {
            try insertMalformedBoundedMetric(in: database)
        }
        #expect(try store.allMetrics().isEmpty)
    }

    @Test("reading rejects REAL window boundaries when constraints are bypassed")
    func readingRejectsRealWindowBoundariesWhenConstraintsAreBypassed() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteUsageMetricStore(path: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        try execute("PRAGMA ignore_check_constraints = ON;", in: database)
        try insertMalformedBoundedMetric(in: database)

        #expect(throws: UsageMetricStoreError.decodeFailed("Bounded provenance boundaries must be integer seconds")) {
            try store.allMetrics()
        }
    }

    @Test("schema rejects bounded metrics with REAL aggregation versions")
    func schemaRejectsRealAggregationVersions() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteUsageMetricStore(path: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }

        #expect(throws: UsageMetricStoreError.self) {
            try insertMalformedAggregationVersion(in: database)
        }
        #expect(try store.allMetrics().isEmpty)
    }

    @Test("reading rejects REAL aggregation versions when constraints are bypassed")
    func readingRejectsRealAggregationVersionsWhenConstraintsAreBypassed() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteUsageMetricStore(path: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        try execute("PRAGMA ignore_check_constraints = ON;", in: database)
        try insertMalformedAggregationVersion(in: database)

        #expect(throws: UsageMetricStoreError.decodeFailed("Bounded provenance aggregation version must be an integer")) {
            try store.allMetrics()
        }
    }

    @Test("physical v1 rows migrate as legacy without invented bounds")
    func physicalV1RowsMigrateAsLegacyWithoutInventedBounds() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try createV1Database(at: path)

        let store = try SQLiteUsageMetricStore(path: path)
        let migrated = try #require(try store.allMetrics().first)

        #expect(migrated.provenance == .legacy(timeWindow: .today))
        #expect(try databaseUserVersion(at: path) == 2)
        #expect(try provenanceColumns(at: path) == ["legacy", nil, nil, nil, nil, nil])
    }

    @Test("legacy migration rebuilds the canonical constrained schema")
    func legacyMigrationRebuildsCanonicalSchema() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try createV1Database(at: path)

        _ = try SQLiteUsageMetricStore(path: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }

        #expect(throws: UsageMetricStoreError.self) {
            try execute("UPDATE usage_metrics SET source_kind = 'providerAPI' WHERE id = 'old';", in: database)
        }
        #expect(try tableColumns(in: database) == canonicalColumns)
    }

    @Test("unknown version zero schema is rejected without mutation")
    func unknownVersionZeroSchemaIsRejectedWithoutMutation() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        try execute("CREATE TABLE usage_metrics (id TEXT PRIMARY KEY, time_window TEXT NOT NULL);", in: database)
        sqlite3_close(database)
        database = nil

        #expect(throws: UsageMetricStoreError.executeFailed("Unsupported usage metric schema fingerprint for version 0")) {
            _ = try SQLiteUsageMetricStore(path: path)
        }

        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        #expect(try databaseUserVersion(in: database) == 0)
        #expect(try tableColumns(in: database) == ["id", "time_window"])
    }

    @Test("version zero database with unrelated objects is not treated as empty")
    func versionZeroDatabaseWithUnrelatedObjectsIsRejected() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        try execute("CREATE TABLE unrelated (value TEXT);", in: database)
        sqlite3_close(database)
        database = nil

        #expect(throws: UsageMetricStoreError.executeFailed("Unsupported usage metric schema fingerprint for version 0")) {
            _ = try SQLiteUsageMetricStore(path: path)
        }

        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        #expect(try databaseUserVersion(in: database) == 0)
    }

    @Test("unlisted schema version is rejected without mutation")
    func unlistedSchemaVersionIsRejected() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try createV1Database(at: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        try execute("PRAGMA user_version = 1;", in: database)
        sqlite3_close(database)
        database = nil

        #expect(throws: UsageMetricStoreError.executeFailed("Unsupported usage metric schema version 1")) {
            _ = try SQLiteUsageMetricStore(path: path)
        }

        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        #expect(try databaseUserVersion(in: database) == 1)
    }

    @Test("legacy schema with unknown objects is rejected without mutation")
    func legacySchemaWithUnknownObjectsIsRejected() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try createV1Database(at: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        try execute("CREATE TABLE unexpected_data (value TEXT);", in: database)
        sqlite3_close(database)
        database = nil

        #expect(throws: UsageMetricStoreError.executeFailed("Unsupported usage metric schema fingerprint for version 0")) {
            _ = try SQLiteUsageMetricStore(path: path)
        }

        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        #expect(try databaseUserVersion(in: database) == 0)
        #expect(try tableColumns(in: database) == Array(canonicalColumns.prefix(7)) + Array(canonicalColumns.suffix(11)))
    }

    @Test("corrupt database is rejected without changing its bytes")
    func corruptDatabaseIsRejectedWithoutMutation() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = Data("not a sqlite database".utf8)
        try original.write(to: URL(fileURLWithPath: path))

        #expect(throws: UsageMetricStoreError.self) {
            _ = try SQLiteUsageMetricStore(path: path)
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
    }

    @Test("current schema repairs missing supporting indexes")
    func currentSchemaRepairsMissingSupportingIndexes() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try SQLiteUsageMetricStore(path: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        try execute("DROP INDEX usage_metrics_current_windows;", in: database)
        sqlite3_close(database)
        database = nil

        _ = try SQLiteUsageMetricStore(path: path)

        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        #expect(try indexNames(in: database).contains("usage_metrics_current_windows"))
    }

    @Test("current schema repairs a unique supporting index")
    func currentSchemaRepairsUniqueSupportingIndex() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try SQLiteUsageMetricStore(path: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        try execute("""
        DROP INDEX usage_metrics_current_windows;
        CREATE UNIQUE INDEX usage_metrics_current_windows
        ON usage_metrics (time_window, window_start, window_end, window_basis);
        """, in: database)
        sqlite3_close(database)
        database = nil

        _ = try SQLiteUsageMetricStore(path: path)

        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        #expect(try indexIsUnique("usage_metrics_current_windows", in: database) == false)
    }

    @Test("current schema rejects noncanonical metadata constraints")
    func currentSchemaRejectsNoncanonicalMetadataConstraints() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try SQLiteUsageMetricStore(path: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        try execute("""
        DROP TABLE app_metadata;
        CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL CHECK (length(value) > 0));
        """, in: database)
        sqlite3_close(database)
        database = nil

        #expect(throws: UsageMetricStoreError.executeFailed("Unsupported app metadata schema fingerprint for version 2")) {
            _ = try SQLiteUsageMetricStore(path: path)
        }
    }

    @Test("current schema with weakened constraints is rebuilt canonically")
    func currentSchemaWithWeakenedConstraintsIsRebuilt() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try createWeakV2Database(at: path)

        _ = try SQLiteUsageMetricStore(path: path)

        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        let sql = try tableSQL(in: database)
        #expect(sql.contains("source_kind IN ('legacy', 'providerAPI', 'builtInLocalLog', 'custom')"))
    }

    @Test("malformed current schema is rejected without repair")
    func malformedCurrentSchemaIsRejectedWithoutRepair() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        try execute("CREATE TABLE usage_metrics (id TEXT PRIMARY KEY); PRAGMA user_version = 2;", in: database)
        sqlite3_close(database)
        database = nil

        #expect(throws: UsageMetricStoreError.executeFailed("Unsupported usage metric schema fingerprint for version 2")) {
            _ = try SQLiteUsageMetricStore(path: path)
        }

        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        #expect(try tableColumns(in: database) == ["id"])
        #expect(try databaseUserVersion(in: database) == 2)
    }

    @Test("future schema is rejected without mutation")
    func futureSchemaIsRejectedWithoutMutation() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try SQLiteUsageMetricStore(path: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        try execute("PRAGMA user_version = 99;", in: database)
        sqlite3_close(database)
        database = nil

        #expect(throws: UsageMetricStoreError.executeFailed("Unsupported usage metric schema version 99")) {
            _ = try SQLiteUsageMetricStore(path: path)
        }

        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        #expect(try databaseUserVersion(in: database) == 99)
        #expect(try tableColumns(in: database) == canonicalColumns)
    }

    @Test("migration rolls back schema changes when a later step fails")
    func migrationRollsBackSchemaChangesWhenLaterStepFails() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        try execute("CREATE TABLE usage_metrics (id TEXT PRIMARY KEY, time_window TEXT NOT NULL);", in: database)

        #expect(throws: UsageMetricStoreError.self) {
            _ = try SQLiteUsageMetricStore(path: path)
        }

        #expect(try databaseUserVersion(in: database) == 0)
        #expect(try tableColumns(in: database) == ["id", "time_window"])
    }

    @Test("deletes metrics older than retention cutoff")
    func deletesMetricsOlderThanRetentionCutoff() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let old = metric(provider: .anthropic, timeWindow: .today, modelLabel: "old", refreshedAt: Date(timeIntervalSince1970: 100))
        let current = metric(provider: .anthropic, timeWindow: .today, modelLabel: "current", refreshedAt: Date(timeIntervalSince1970: 1_000))

        try store.save([old, current])
        let deleted = try store.deleteMetrics(olderThan: Date(timeIntervalSince1970: 500))

        #expect(deleted == 1)
        #expect(try store.allMetrics() == [current])
    }

    @Test("refresh failure retains values and marks metrics stale")
    func refreshFailureRetainsValuesAndMarksMetricsStale() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let fresh = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "gpt-4.1", freshness: .fresh)

        try store.save([fresh])
        try store.markMetricsStale(timeWindow: .today, missedRefreshes: 2)

        let retained = try #require(try store.metrics(for: .today).first)
        #expect(retained.tokenUsage == fresh.tokenUsage)
        #expect(retained.limitStatus == fresh.limitStatus)
        #expect(retained.freshness == .stale(missedRefreshes: 2))
    }

    @Test("provider replacement rejects mismatched metrics before deletion")
    func providerReplacementRejectsMismatchedMetricsBeforeDeletion() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let existing = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "existing")
        let mismatched = metric(provider: .openAI, timeWindow: .today, modelLabel: "wrong-provider")
        try store.save([existing])

        #expect(throws: UsageMetricStoreError.self) {
            try store.replaceMetrics(provider: .azureOpenAI, timeWindows: [.today], with: [mismatched])
        }

        #expect(try store.allMetrics() == [existing])
    }

    @Test("provider replacement rejects metrics outside replacement windows")
    func providerReplacementRejectsMetricsOutsideReplacementWindows() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let existing = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "existing")
        let wrongWindow = metric(provider: .azureOpenAI, timeWindow: .currentWeek, modelLabel: "wrong-window")
        try store.save([existing])

        #expect(throws: UsageMetricStoreError.self) {
            try store.replaceMetrics(provider: .azureOpenAI, timeWindows: [.today], with: [wrongWindow])
        }

        #expect(try store.allMetrics() == [existing])
    }

    @Test("provider replacement preserves other providers")
    func providerReplacementPreservesOtherProviders() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let anthropic = metric(provider: .anthropic, timeWindow: .today, modelLabel: "claude")
        let oldAzure = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "old")
        let openAI = metric(provider: .openAI, timeWindow: .today, modelLabel: "gpt")
        let newAzure = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "new")
        try store.save([anthropic, oldAzure, openAI])

        try store.replaceMetrics(provider: .azureOpenAI, timeWindows: [.today], with: [newAzure])

        #expect(try store.allMetrics() == [anthropic, openAI, newAzure])
    }

    @Test("legacy provider delete preserves adjacent bounded sources")
    func legacyProviderDeletePreservesAdjacentBoundedSources() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let legacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "legacy")
        let bounded = try boundedSourceMetrics(provider: .anthropic, timeWindow: .today)
        try store.save([legacy] + bounded)

        try store.deleteMetrics(provider: .anthropic, timeWindows: [.today])

        #expect(try store.allMetrics() == bounded)
    }

    @Test("legacy provider replacement preserves adjacent bounded sources")
    func legacyProviderReplacementPreservesAdjacentBoundedSources() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let oldLegacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "old-legacy")
        let newLegacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "new-legacy")
        let bounded = try boundedSourceMetrics(provider: .anthropic, timeWindow: .today)
        try store.save([oldLegacy] + bounded)

        try store.replaceMetrics(provider: .anthropic, timeWindows: [.today], with: [newLegacy])

        #expect(try store.allMetrics() == bounded + [newLegacy])
    }

    @Test("legacy account delete preserves adjacent bounded sources")
    func legacyAccountDeletePreservesAdjacentBoundedSources() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let legacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "legacy")
        let bounded = try boundedSourceMetrics(provider: .anthropic, timeWindow: .today)
        try store.save([legacy] + bounded)

        try store.deleteMetrics(provider: .anthropic, timeWindows: [.today], accountLabel: "Account")

        #expect(try store.allMetrics() == bounded)
    }

    @Test("legacy account replacement preserves adjacent bounded sources")
    func legacyAccountReplacementPreservesAdjacentBoundedSources() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let oldLegacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "old-legacy")
        let newLegacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "new-legacy")
        let bounded = try boundedSourceMetrics(provider: .anthropic, timeWindow: .today)
        try store.save([oldLegacy] + bounded)

        try store.replaceMetrics(
            provider: .anthropic,
            timeWindows: [.today],
            accountLabel: "Account",
            with: [newLegacy]
        )

        #expect(try store.allMetrics() == bounded + [newLegacy])
    }

    @Test("legacy window staleness preserves adjacent bounded sources")
    func legacyWindowStalenessPreservesAdjacentBoundedSources() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let legacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "legacy")
        let bounded = try boundedSourceMetrics(provider: .anthropic, timeWindow: .today)
        try store.save([legacy] + bounded)

        try store.markMetricsStale(timeWindow: .today, missedRefreshes: 2)

        let retained = try store.allMetrics()
        #expect(retained[0].freshness == .stale(missedRefreshes: 2))
        #expect(retained.dropFirst().allSatisfy { $0.freshness == .fresh })
    }

    @Test("legacy provider staleness preserves adjacent bounded sources")
    func legacyProviderStalenessPreservesAdjacentBoundedSources() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let legacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "legacy")
        let bounded = try boundedSourceMetrics(provider: .anthropic, timeWindow: .today)
        try store.save([legacy] + bounded)

        try store.markMetricsStale(provider: .anthropic, timeWindows: [.today], missedRefreshes: 2)

        let retained = try store.allMetrics()
        #expect(retained[0].freshness == .stale(missedRefreshes: 2))
        #expect(retained.dropFirst().allSatisfy { $0.freshness == .fresh })
    }

    @Test("API replacement preserves local and custom metrics")
    func apiReplacementPreservesLocalAndCustomMetrics() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let window = try exactWindow(timeWindow: .today, start: 1_783_728_000, end: 1_783_814_400, basis: .localCalendar)
        let customID = try #require(UUID(uuidString: "4A613A87-9D4D-4208-80D5-7F6D94A6DBE7"))
        let oldAPI = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: window), modelLabel: "old-api")
        let local = metric(provider: .anthropic, provenance: .bounded(source: .builtInLocalLog, window: window), modelLabel: "local")
        let custom = metric(provider: .anthropic, provenance: .bounded(source: .custom(customID), window: window), modelLabel: "custom")
        let newAPI = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: window), modelLabel: "new-api")
        try store.save([oldAPI, local, custom])

        try store.replaceMetrics(
            in: UsageReplacementScope(provider: .anthropic, source: .providerAPI, windows: [window]),
            with: [newAPI]
        )

        #expect(try store.allMetrics() == [local, custom, newAPI])
    }

    @Test("local replacement preserves API metrics")
    func localReplacementPreservesAPIMetrics() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let window = try exactWindow(timeWindow: .currentWeek, start: 1_783_641_600, end: 1_784_246_400, basis: .localCalendar)
        let api = metric(provider: .openAI, provenance: .bounded(source: .providerAPI, window: window), modelLabel: "api")
        let oldLocal = metric(provider: .openAI, provenance: .bounded(source: .builtInLocalLog, window: window), modelLabel: "old-local")
        let newLocal = metric(provider: .openAI, provenance: .bounded(source: .builtInLocalLog, window: window), modelLabel: "new-local")
        try store.save([api, oldLocal])

        try store.replaceMetrics(
            in: UsageReplacementScope(provider: .openAI, source: .builtInLocalLog, windows: [window]),
            with: [newLocal]
        )

        #expect(try store.allMetrics() == [api, newLocal])
    }

    @Test("custom replacement preserves a different custom source")
    func customReplacementPreservesDifferentCustomSource() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let window = try exactWindow(timeWindow: .today, start: 1_783_728_000, end: 1_783_814_400, basis: .localCalendar)
        let firstID = try #require(UUID(uuidString: "4A613A87-9D4D-4208-80D5-7F6D94A6DBE7"))
        let secondID = try #require(UUID(uuidString: "D90E7234-E6EF-4378-8C43-65DB8ED195EA"))
        let oldFirst = metric(provider: .custom, provenance: .bounded(source: .custom(firstID), window: window), modelLabel: "old-first")
        let second = metric(provider: .custom, provenance: .bounded(source: .custom(secondID), window: window), modelLabel: "second")
        let newFirst = metric(provider: .custom, provenance: .bounded(source: .custom(firstID), window: window), modelLabel: "new-first")
        try store.save([oldFirst, second])

        try store.replaceMetrics(
            in: UsageReplacementScope(provider: .custom, source: .custom(firstID), windows: [window]),
            with: [newFirst]
        )

        #expect(try store.allMetrics() == [second, newFirst])
    }

    @Test("empty scoped replacement clears only its exact bounded scope")
    func emptyScopedReplacementClearsOnlyItsExactBoundedScope() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let today = try exactWindow(timeWindow: .today, start: 1_783_728_000, end: 1_783_814_400, basis: .localCalendar)
        let tomorrow = try exactWindow(timeWindow: .today, start: 1_783_814_400, end: 1_783_900_800, basis: .localCalendar)
        let targeted = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: today), modelLabel: "targeted")
        let otherWindow = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: tomorrow), modelLabel: "other-window")
        let legacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "legacy")
        try store.save([targeted, otherWindow, legacy])

        try store.replaceMetrics(
            in: UsageReplacementScope(provider: .anthropic, source: .providerAPI, windows: [today]),
            with: []
        )

        #expect(try store.allMetrics() == [otherWindow, legacy])
    }

    @Test("scoped replacement validates every metric before deleting")
    func scopedReplacementValidatesEveryMetricBeforeDeleting() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let window = try exactWindow(timeWindow: .today, start: 1_783_728_000, end: 1_783_814_400, basis: .localCalendar)
        let otherWindow = try exactWindow(timeWindow: .today, start: 1_783_814_400, end: 1_783_900_800, basis: .localCalendar)
        let scope = UsageReplacementScope(provider: .anthropic, source: .providerAPI, windows: [window])
        let existing = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: window), modelLabel: "existing")
        let mismatches = [
            metric(provider: .openAI, provenance: .bounded(source: .providerAPI, window: window), modelLabel: "provider"),
            metric(provider: .anthropic, provenance: .bounded(source: .builtInLocalLog, window: window), modelLabel: "source"),
            metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: otherWindow), modelLabel: "window"),
            metric(provider: .anthropic, timeWindow: .today, modelLabel: "legacy")
        ]
        try store.save([existing])

        for mismatch in mismatches {
            #expect(throws: UsageMetricStoreError.self) {
                try store.replaceMetrics(in: scope, with: [mismatch])
            }
            #expect(try store.allMetrics() == [existing])
        }
    }

    @Test("scoped staleness affects only matching API rows and preserves legacy")
    func scopedStalenessAffectsOnlyMatchingAPIRowsAndPreservesLegacy() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let window = try exactWindow(timeWindow: .today, start: 1_783_728_000, end: 1_783_814_400, basis: .localCalendar)
        let api = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: window), modelLabel: "api")
        let local = metric(provider: .anthropic, provenance: .bounded(source: .builtInLocalLog, window: window), modelLabel: "local")
        let legacy = metric(provider: .anthropic, timeWindow: .today, modelLabel: "legacy")
        try store.save([api, local, legacy])

        try store.markMetricsStale(
            in: UsageReplacementScope(provider: .anthropic, source: .providerAPI, windows: [window]),
            missedRefreshes: 3
        )

        let retained = try store.allMetrics()
        #expect(retained[0].freshness == .stale(missedRefreshes: 3))
        #expect(retained[1].freshness == .fresh)
        #expect(retained[2].freshness == .fresh)
    }

    @Test("scoped replacement and staleness preserve every exact window discriminator")
    func scopedMutationsPreserveEveryExactWindowDiscriminator() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let targetWindow = try exactWindow(timeWindow: .today, start: 1_783_728_000, end: 1_783_814_400, basis: .localCalendar)
        let differentBasis = try exactWindow(timeWindow: .today, start: 1_783_728_000, end: 1_783_814_400, basis: .utcBilling)
        let differentVersion = try exactWindow(
            timeWindow: .today,
            start: 1_783_728_000,
            end: 1_783_814_400,
            basis: .localCalendar,
            aggregationVersion: targetWindow.aggregationVersion + 1
        )
        let differentTimeWindow = try exactWindow(
            timeWindow: .currentWeek,
            start: 1_783_728_000,
            end: 1_783_814_400,
            basis: .localCalendar
        )
        let scope = UsageReplacementScope(provider: .anthropic, source: .providerAPI, windows: [targetWindow])
        let oldTarget = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: targetWindow), modelLabel: "old-target")
        let basisRow = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: differentBasis), modelLabel: "basis")
        let versionRow = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: differentVersion), modelLabel: "version")
        let timeWindowRow = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: differentTimeWindow), modelLabel: "time-window")
        let newTarget = metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: targetWindow), modelLabel: "new-target")
        try store.save([oldTarget, basisRow, versionRow, timeWindowRow])

        try store.replaceMetrics(in: scope, with: [newTarget])
        try store.markMetricsStale(in: scope, missedRefreshes: 4)

        let retained = try store.allMetrics()
        #expect(retained.map(\.modelLabel) == ["basis", "version", "time-window", "new-target"])
        #expect(retained.dropLast().allSatisfy { $0.freshness == .fresh })
        #expect(retained.last?.freshness == .stale(missedRefreshes: 4))
    }

    @Test("current metrics returns only exact current bounded windows while history remains available")
    func currentMetricsFiltersExpiredTimezoneVersionAndLegacyRows() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-08T18:00:00Z"))
        let current = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let previousDay = try shifted(current.today, by: -86_400)
        let previousWeek = try shifted(current.currentWeek, by: -604_800)
        let oldVersion = try exactWindow(
            timeWindow: current.today.timeWindow,
            start: current.today.start.timeIntervalSince1970,
            end: current.today.end.timeIntervalSince1970,
            basis: current.today.basis,
            aggregationVersion: ExactUsageWindow.currentAggregationVersion + 1
        )
        var otherCalendar = calendar
        otherCalendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let timezoneDifferentToday = try CurrentUsageWindows.resolve(at: now, calendar: otherCalendar).today
        let included = [
            metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: current.today), modelLabel: "today"),
            metric(provider: .anthropic, provenance: .bounded(source: .builtInLocalLog, window: current.currentWeek), modelLabel: "local-week"),
            metric(provider: .openAI, provenance: .bounded(source: .providerAPI, window: current.utcBillingWeek), modelLabel: "billing-week")
        ]
        let excluded = [
            metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: previousDay), modelLabel: "expired-day"),
            metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: previousWeek), modelLabel: "previous-week"),
            metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: timezoneDifferentToday), modelLabel: "other-timezone"),
            metric(provider: .anthropic, provenance: .bounded(source: .providerAPI, window: oldVersion), modelLabel: "old-version"),
            metric(provider: .anthropic, timeWindow: .today, modelLabel: "legacy")
        ]
        try store.save(included + excluded)

        #expect(try store.currentMetrics(at: now, calendar: calendar) == included)
        #expect(try store.allMetrics() == included + excluded)
    }

    @Test("metric identity distinguishes separator characters in labels")
    func metricIdentityDistinguishesSeparatorCharactersInLabels() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let first = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "a|", deploymentLabel: "b")
        let second = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "a", deploymentLabel: "|b")

        try store.save([first, second])

        #expect(try store.allMetrics() == [first, second])
    }

    @Test("metric identity and labels preserve embedded NUL characters")
    func metricIdentityAndLabelsPreserveEmbeddedNULCharacters() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let first = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "model\0a", deploymentLabel: "deployment")
        let second = metric(provider: .azureOpenAI, timeWindow: .today, modelLabel: "model\0b", deploymentLabel: "deployment")

        try store.save([first, second])

        #expect(try store.allMetrics() == [first, second])
    }

    @Test("schema stores normalized fields and excludes sensitive fields")
    func schemaStoresNormalizedFieldsAndExcludesSensitiveFields() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let columns = try store.schemaColumnNames()

        #expect(columns.isSuperset(of: ["provider", "time_window", "model_label", "input_tokens", "output_tokens", "limit_status", "freshness_status", "source_kind", "source_identifier", "window_start", "window_end", "window_basis", "aggregation_version"]))
        #expect(!columns.contains("prompt"))
        #expect(!columns.contains("response"))
        #expect(!columns.contains("raw_provider_response"))
        #expect(!columns.contains("request_body"))
        #expect(!columns.contains("terminal_output"))
        #expect(!columns.contains("source_code"))
        #expect(!columns.contains("api_key"))
        #expect(!columns.contains("access_token"))
        #expect(!columns.contains("refresh_token"))
    }

    @Test("health reports open database")
    func healthReportsOpenDatabase() throws {
        let store = try SQLiteUsageMetricStore.inMemory()

        #expect(store.health().isOpen)
        #expect(store.health().message == "SQLite store opened")
    }

    @Test("read throws when SQLite cannot complete the query")
    func readThrowsWhenSQLiteCannotCompleteQuery() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).sqlite").path
        let store = try SQLiteUsageMetricStore(path: path, busyTimeoutMilliseconds: 1)
        var lockingDatabase: OpaquePointer?
        #expect(sqlite3_open(path, &lockingDatabase) == SQLITE_OK)
        defer { sqlite3_close(lockingDatabase) }
        #expect(sqlite3_exec(lockingDatabase, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockingDatabase, "ROLLBACK;", nil, nil, nil) }

        #expect(throws: UsageMetricStoreError.self) {
            try store.allMetrics()
        }
    }

    private func metric(
        provider: ProviderKind,
        timeWindow: TimeWindow = .today,
        provenance: UsageSnapshotProvenance? = nil,
        modelLabel: String,
        deploymentLabel: String? = nil,
        refreshedAt: Date = Date(timeIntervalSince1970: 1_783_728_000),
        inputTokens: Int = 10,
        outputTokens: Int = 5,
        freshness: Freshness = .fresh,
        cost: Cost? = nil,
        limitStatus: LimitStatus = .unsupportedByProviderAPI
    ) -> UsageMetric {
        let common = (
            accountLabel: "Account",
            projectLabel: "Project",
            deploymentLabel: deploymentLabel ?? (provider == .azureOpenAI ? "deployment" : nil),
            tokenUsage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
        )
        if let provenance {
            return UsageMetric(
                provider: provider,
                accountLabel: common.accountLabel,
                projectLabel: common.projectLabel,
                modelLabel: modelLabel,
                deploymentLabel: common.deploymentLabel,
                provenance: provenance,
                tokenUsage: common.tokenUsage,
                cost: cost,
                limitStatus: limitStatus,
                refreshedAt: refreshedAt,
                freshness: freshness
            )
        }
        return UsageMetric(
            provider: provider,
            accountLabel: common.accountLabel,
            projectLabel: common.projectLabel,
            modelLabel: modelLabel,
            deploymentLabel: common.deploymentLabel,
            timeWindow: timeWindow,
            tokenUsage: common.tokenUsage,
            cost: cost,
            limitStatus: limitStatus,
            refreshedAt: refreshedAt,
            freshness: freshness
        )
    }

    private func exactWindow(
        timeWindow: TimeWindow,
        start: TimeInterval,
        end: TimeInterval,
        basis: UsageWindowBasis,
        aggregationVersion: Int = ExactUsageWindow.currentAggregationVersion
    ) throws -> ExactUsageWindow {
        try ExactUsageWindow(
            timeWindow: timeWindow,
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end),
            basis: basis,
            aggregationVersion: aggregationVersion
        )
    }

    private func boundedSourceMetrics(provider: ProviderKind, timeWindow: TimeWindow) throws -> [UsageMetric] {
        let window = try exactWindow(
            timeWindow: timeWindow,
            start: 1_783_728_000,
            end: 1_783_814_400,
            basis: .localCalendar
        )
        let customID = try #require(UUID(uuidString: "4A613A87-9D4D-4208-80D5-7F6D94A6DBE7"))
        return [
            metric(provider: provider, provenance: .bounded(source: .providerAPI, window: window), modelLabel: "api"),
            metric(provider: provider, provenance: .bounded(source: .builtInLocalLog, window: window), modelLabel: "local"),
            metric(provider: provider, provenance: .bounded(source: .custom(customID), window: window), modelLabel: "custom")
        ]
    }

    private func shifted(_ window: ExactUsageWindow, by seconds: TimeInterval) throws -> ExactUsageWindow {
        try ExactUsageWindow(
            timeWindow: window.timeWindow,
            start: window.start.addingTimeInterval(seconds),
            end: window.end.addingTimeInterval(seconds),
            basis: window.basis,
            aggregationVersion: window.aggregationVersion
        )
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).sqlite").path
    }

    private func createV1Database(at path: String) throws {
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        try execute("""
        CREATE TABLE usage_metrics (
            id TEXT PRIMARY KEY, provider TEXT NOT NULL, account_label TEXT, project_label TEXT,
            model_label TEXT NOT NULL, deployment_label TEXT, time_window TEXT NOT NULL,
            input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, cost_amount TEXT,
            cost_currency_code TEXT, cost_source TEXT, limit_status TEXT NOT NULL,
            limit_used REAL, limit_value REAL, refreshed_at REAL, freshness_status TEXT NOT NULL,
            missed_refreshes INTEGER NOT NULL
        );
        INSERT INTO usage_metrics VALUES (
            'old', 'anthropic', 'Account', 'Project', 'Claude', NULL, 'today',
            10, 5, NULL, NULL, NULL, 'unsupportedByProviderAPI', NULL, NULL,
            1783728000, 'fresh', 0
        );
        """, in: database)
    }

    private func createWeakV2Database(at path: String) throws {
        try createV1Database(at: path)
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        try execute("""
        ALTER TABLE usage_metrics ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'legacy' CHECK (source_kind IN ('legacy', 'providerAPI', 'builtInLocalLog', 'custom'));
        ALTER TABLE usage_metrics ADD COLUMN source_identifier TEXT;
        ALTER TABLE usage_metrics ADD COLUMN window_start INTEGER CHECK (window_start IS NULL OR typeof(window_start) = 'integer');
        ALTER TABLE usage_metrics ADD COLUMN window_end INTEGER CHECK (window_end IS NULL OR typeof(window_end) = 'integer');
        ALTER TABLE usage_metrics ADD COLUMN window_basis TEXT CHECK (window_basis IS NULL OR window_basis IN ('localCalendar', 'utcBilling'));
        ALTER TABLE usage_metrics ADD COLUMN aggregation_version INTEGER CHECK (aggregation_version IS NULL OR (typeof(aggregation_version) = 'integer' AND aggregation_version > 0));
        CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE INDEX usage_metrics_current_windows ON usage_metrics (time_window, window_start, window_end, window_basis);
        CREATE INDEX usage_metrics_replacement_scope ON usage_metrics (provider, time_window, source_kind, source_identifier);
        PRAGMA user_version = 2;
        """, in: database)
    }

    private func openDatabase(at path: String, into database: inout OpaquePointer?) throws {
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw UsageMetricStoreError.openFailed("Unable to create test database")
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.executeFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func insertMalformedBoundedMetric(in database: OpaquePointer?) throws {
        try execute("""
        INSERT INTO usage_metrics (
            id, provider, model_label, time_window, source_kind, source_identifier,
            window_start, window_end, window_basis, aggregation_version,
            input_tokens, output_tokens, limit_status, freshness_status, missed_refreshes
        ) VALUES (
            'malformed', 'anthropic', 'Claude', 'today', 'providerAPI', NULL,
            100.5, 200.5, 'localCalendar', 1,
            10, 5, 'unsupportedByProviderAPI', 'fresh', 0
        );
        """, in: database)
    }

    private func insertMalformedAggregationVersion(in database: OpaquePointer?) throws {
        try execute("""
        INSERT INTO usage_metrics (
            id, provider, model_label, time_window, source_kind, source_identifier,
            window_start, window_end, window_basis, aggregation_version,
            input_tokens, output_tokens, limit_status, freshness_status, missed_refreshes
        ) VALUES (
            'malformed-aggregation', 'anthropic', 'Claude', 'today', 'providerAPI', NULL,
            100, 200, 'localCalendar', 1.5,
            10, 5, 'unsupportedByProviderAPI', 'fresh', 0
        );
        """, in: database)
    }

    private func databaseUserVersion(at path: String) throws -> Int {
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        return try databaseUserVersion(in: database)
    }

    private func databaseUserVersion(in database: OpaquePointer?) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.prepareFailed("Unable to inspect test database")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageMetricStoreError.executeFailed("Unable to inspect test database")
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func tableColumns(in database: OpaquePointer?) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(usage_metrics);", -1, &statement, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.prepareFailed("Unable to inspect test database")
        }
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.append(String(cString: sqlite3_column_text(statement, 1)))
        }
        return columns
    }

    private func indexNames(in database: OpaquePointer?) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA index_list(usage_metrics);", -1, &statement, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.prepareFailed("Unable to inspect test indexes")
        }
        defer { sqlite3_finalize(statement) }
        var indexes = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            indexes.insert(String(cString: sqlite3_column_text(statement, 1)))
        }
        return indexes
    }

    private func indexIsUnique(_ name: String, in database: OpaquePointer?) throws -> Bool? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA index_list(usage_metrics);", -1, &statement, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.prepareFailed("Unable to inspect test indexes")
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard String(cString: sqlite3_column_text(statement, 1)) == name else { continue }
            return sqlite3_column_int(statement, 2) == 1
        }
        return nil
    }

    private func tableSQL(in database: OpaquePointer?) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'usage_metrics';", -1, &statement, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.prepareFailed("Unable to inspect test table SQL")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageMetricStoreError.executeFailed("Unable to inspect test table SQL")
        }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    private var canonicalColumns: [String] {
        [
            "id", "provider", "account_label", "project_label", "model_label", "deployment_label",
            "time_window", "source_kind", "source_identifier", "window_start", "window_end", "window_basis",
            "aggregation_version", "input_tokens", "output_tokens", "cost_amount", "cost_currency_code",
            "cost_source", "limit_status", "limit_used", "limit_value", "refreshed_at", "freshness_status",
            "missed_refreshes"
        ]
    }

    private func provenanceColumns(at path: String) throws -> [String?] {
        var database: OpaquePointer?
        try openDatabase(at: path, into: &database)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT source_kind, source_identifier, window_start, window_end, window_basis, aggregation_version FROM usage_metrics;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.prepareFailed("Unable to inspect provenance")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageMetricStoreError.executeFailed("Unable to inspect provenance")
        }
        return (0..<6).map { index in
            guard let text = sqlite3_column_text(statement, Int32(index)) else { return nil }
            return String(cString: text)
        }
    }
}
