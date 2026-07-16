import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Historical usage trend store")
struct HistoricalUsageTrendStoreTests {
    @Test("exact local periods preserve DST boundaries and timezone identity")
    func exactPeriodsPreserveDSTAndTimeZone() throws {
        let calendar = try calendar(timeZone: "America/Los_Angeles")
        let spring = try period(2026, 3, 8, calendar: calendar)
        let fall = try period(2026, 11, 1, calendar: calendar)

        #expect(spring.window.end.timeIntervalSince(spring.window.start) == 23 * 60 * 60)
        #expect(fall.window.end.timeIntervalSince(fall.window.start) == 25 * 60 * 60)
        #expect(spring.timeZoneIdentifier == "America/Los_Angeles")
        #expect(throws: HistoricalUsageTrendPeriod.ValidationError.periodDoesNotMatchTimeZone) {
            try HistoricalUsageTrendPeriod(window: spring.window, timeZoneIdentifier: "America/New_York")
        }
    }

    @Test("an observed zero is distinct from a missing period")
    func observedZeroIsNotAGap() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let calendar = try calendar(timeZone: "UTC")
        let observed = try period(2026, 7, 1, calendar: calendar)
        let missing = try period(2026, 7, 2, calendar: calendar)
        try store.record([try sample(period: observed, input: 0, output: 0)], now: observed.window.end)

        let buckets = try store.buckets(for: [observed, missing])

        #expect(observations(in: buckets[0]).first?.sample.tokenUsage == TokenUsage(inputTokens: 0, outputTokens: 0))
        #expect(buckets[1].value == .gap)
    }

    @Test("corrections append revisions and supersede rather than overwrite")
    func correctionsAreImmutableRevisions() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let day = try period(2026, 7, 10, calendar: calendar(timeZone: "UTC"))
        let first = try #require(try store.record([try sample(period: day, input: 10)], now: day.window.start).first)
        let correction = try #require(try store.record([try sample(period: day, input: 12)], now: day.window.end).first)

        let current = observations(in: try #require(store.buckets(for: [day]).first))
        let revisions = try store.revisions(for: day)

        #expect(first.revision == 1)
        #expect(first.lifecycle == .provisional)
        #expect(correction.revision == 2)
        #expect(correction.supersedesID == first.id)
        #expect(correction.lifecycle == .final)
        #expect(current.map(\.id) == [correction.id])
        #expect(revisions.map(\.lifecycle) == [.superseded, .final])
        #expect(revisions.map(\.sample.tokenUsage.inputTokens) == [10, 12])
    }

    @Test("recording an identical observation is idempotent")
    func identicalObservationIsIdempotent() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let day = try period(2026, 7, 10, calendar: calendar(timeZone: "UTC"))
        let value = try sample(period: day, input: 10)

        let first = try #require(try store.record([value], now: day.window.start).first)
        let repeated = try #require(try store.record([value], now: day.window.start.addingTimeInterval(60)).first)

        #expect(repeated.id == first.id)
        #expect(try store.revisions(for: day).count == 1)
    }

    @Test("closing a period finalizes an unchanged provisional observation as a new revision")
    func unchangedObservationIsFinalized() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let day = try period(2026, 7, 10, calendar: calendar(timeZone: "UTC"))
        let value = try sample(period: day, input: 10)

        let provisional = try #require(try store.record([value], now: day.window.start).first)
        let final = try #require(try store.record([value], now: day.window.end).first)

        #expect(final.id != provisional.id)
        #expect(final.supersedesID == provisional.id)
        #expect(final.lifecycle == .final)
        #expect(try store.revisions(for: day).map(\.lifecycle) == [.superseded, .final])
    }

    @Test("recording a new period finalizes ended provisional observations")
    func rolloverFinalizesPreviousPeriod() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let utc = try calendar(timeZone: "UTC")
        let firstDay = try period(2026, 7, 10, calendar: utc)
        let nextDay = try period(2026, 7, 11, calendar: utc)
        try store.record([try sample(period: firstDay, input: 10)], now: firstDay.window.start)

        try store.record([try sample(period: nextDay, input: 2)], now: nextDay.window.start)

        let bucket = try #require(store.buckets(for: [firstDay]).first)
        let current = try #require(observations(in: bucket).first)
        #expect(current.lifecycle == .final)
        #expect(current.sample.tokenUsage.inputTokens == 10)
        #expect(try store.revisions(for: firstDay).map(\.lifecycle) == [.superseded, .final])
    }

    @Test("a model missing from a successful replacement becomes observed zero")
    func missingModelBecomesObservedZero() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let day = try period(2026, 7, 10, calendar: calendar(timeZone: "UTC"))
        try store.record([
            try sample(period: day, coverage: .model("retained"), input: 10),
            try sample(period: day, coverage: .model("removed"), input: 5)
        ], now: day.window.start)

        try store.record([
            try sample(period: day, coverage: .model("retained"), input: 12)
        ], now: day.window.start.addingTimeInterval(60))

        let current = observations(in: try #require(store.buckets(for: [day]).first))
        let removed = try #require(current.first { $0.sample.coverage == .model("removed") })
        #expect(removed.sample.tokenUsage.totalTokens == 0)
        #expect(removed.revision == 2)
    }

    @Test("a completely empty successful scope replaces prior usage with observed zero")
    func emptyScopeBecomesObservedZero() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let day = try period(2026, 7, 10, calendar: calendar(timeZone: "UTC"))
        let value = try sample(period: day, coverage: .model("removed"), input: 5)
        try store.record([value], now: day.window.start)
        let scope = HistoricalUsageObservedScope(
            provider: value.provider,
            source: value.source,
            period: day
        )

        try store.record([], observedScopes: [scope], now: day.window.start.addingTimeInterval(60))

        let current = observations(in: try #require(store.buckets(for: [day]).first))
        #expect(current.count == 1)
        #expect(current.first?.sample.tokenUsage.totalTokens == 0)
        #expect(current.first?.revision == 2)
    }

    @Test("provider API totals are authoritative without deleting model attribution")
    func authorityDoesNotDiscardAttribution() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let day = try period(2026, 7, 10, calendar: calendar(timeZone: "UTC"))
        try store.record([
            try sample(period: day, source: .builtInLocalLog, coverage: .providerTotal, input: 11),
            try sample(period: day, source: .providerAPI, coverage: .providerTotal, input: 12),
            try sample(period: day, source: .builtInLocalLog, coverage: .model("claude-sonnet"), input: 7),
            try sample(period: day, source: .builtInLocalLog, coverage: .model("claude-opus"), input: 4)
        ], now: day.window.end)

        let bucket = try #require(store.buckets(for: [day]).first)
        let all = observations(in: bucket)

        #expect(all.count == 4)
        #expect(bucket.authoritativeTotals.count == 1)
        #expect(bucket.authoritativeTotals.first?.sample.source == .providerAPI)
        #expect(bucket.authoritativeTotals.first?.sample.tokenUsage.inputTokens == 12)
        #expect(bucket.modelAttributions.map(\.sample.tokenUsage.inputTokens).sorted() == [4, 7])
    }

    @Test("provider-reported and atomically revisioned calculated costs remain distinct")
    func costSemanticsRemainDistinct() throws {
        let day = try period(2026, 7, 10, calendar: calendar(timeZone: "UTC"))
        let calculated = try HistoricalUsageCalculatedCost(
            cost: Cost(amount: Decimal(string: "3.10")!, currencyCode: "USD", source: .calculatedEstimate),
            pricingRevision: "prices-2026-07",
            pricingEffectiveAt: try date(2026, 7, 1, calendar: calendar(timeZone: "UTC"))
        )
        let value = try sample(
            period: day,
            providerCost: Cost(amount: Decimal(string: "3.25")!, currencyCode: "USD", source: .providerReported),
            calculatedCost: calculated
        )
        let store = try HistoricalUsageTrendStore.inMemory()
        try store.record([value], now: day.window.end)

        let bucket = try #require(store.buckets(for: [day]).first)
        let stored = try #require(observations(in: bucket).first)

        #expect(stored.sample.providerReportedCost?.amount == Decimal(string: "3.25"))
        #expect(stored.sample.calculatedCost == calculated)
        #expect(throws: HistoricalUsageCalculatedCost.ValidationError.missingPricingRevision) {
            try HistoricalUsageCalculatedCost(
                cost: calculated.cost,
                pricingRevision: "",
                pricingEffectiveAt: calculated.pricingEffectiveAt
            )
        }
    }

    @Test("bounded current metrics derive timezone per window and lifecycle from period end")
    func currentMetricIntegration() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let localCalendar = try calendar(timeZone: "America/Los_Angeles")
        let now = try date(2026, 7, 8, hour: 12, calendar: localCalendar)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: localCalendar)
        let localMetric = metric(window: windows.today, source: .builtInLocalLog, input: 5)
        let utcMetric = metric(window: windows.utcBillingWeek, source: .providerAPI, input: 20)
        let samples = [
            try HistoricalUsageTrendSample(
                metric: localMetric,
                coverage: .model("claude-sonnet"),
                localTimeZoneIdentifier: localCalendar.timeZone.identifier
            ),
            try HistoricalUsageTrendSample(
                metric: utcMetric,
                coverage: .providerTotal,
                localTimeZoneIdentifier: localCalendar.timeZone.identifier
            )
        ]

        let recorded = try store.record(samples, now: now)

        #expect(recorded.map(\.sample.period.timeZoneIdentifier) == ["America/Los_Angeles", "UTC"])
        #expect(recorded.allSatisfy { $0.lifecycle == .provisional })
    }

    @Test("legacy metrics cannot be assigned invented historical dates")
    func legacyMetricsAreRejected() throws {
        let legacy = UsageMetric(
            provider: .anthropic,
            accountLabel: "not persisted",
            projectLabel: "not persisted",
            modelLabel: "claude-sonnet",
            deploymentLabel: "not persisted",
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: nil,
            freshness: .fresh
        )

        #expect(throws: HistoricalUsageTrendSample.ValidationError.legacyMetric) {
            try HistoricalUsageTrendSample(metric: legacy, coverage: .providerTotal, localTimeZoneIdentifier: "UTC")
        }
    }

    @Test("range discovery returns stored periods across timezone changes")
    func rangeDiscoveryPreservesTimeZoneChanges() throws {
        let store = try HistoricalUsageTrendStore.inMemory()
        let west = try period(2026, 7, 10, calendar: calendar(timeZone: "America/Los_Angeles"))
        let east = try period(2026, 7, 11, calendar: calendar(timeZone: "America/New_York"))
        try store.record([try sample(period: west), try sample(period: east)], now: east.window.end)

        let discovered = try store.periods(
            from: west.window.start,
            through: east.window.end,
            provider: .anthropic,
            window: .today
        )
        let buckets = try store.buckets(
            from: west.window.start,
            through: east.window.end,
            provider: .anthropic,
            window: .today
        )

        #expect(discovered.map(\.timeZoneIdentifier) == ["America/Los_Angeles", "America/New_York"])
        #expect(buckets.count == 2)
    }

    @Test("retention presets persist and changing them prunes immediately")
    func retentionPersistsAndPrunesImmediately() throws {
        let path = temporaryDatabasePath()
        defer { removeDatabase(at: path) }
        let utc = try calendar(timeZone: "UTC")
        let now = try date(2026, 7, 15, hour: 12, calendar: utc)
        let old = try period(2026, 6, 14, calendar: utc)
        let recent = try period(2026, 6, 16, calendar: utc)
        do {
            let store = try HistoricalUsageTrendStore(path: path)
            #expect(try store.retention() == .days365)
            try store.record([try sample(period: old), try sample(period: recent)], now: now)
            #expect(try store.setRetention(.days30, now: now) == 1)
            let buckets = try store.buckets(for: [old, recent])
            #expect(buckets[0].value == .gap)
            #expect(buckets[1].value != .gap)
        }

        let reopened = try HistoricalUsageTrendStore(path: path)
        #expect(try reopened.retention() == .days30)
        #expect(try reopened.buckets(for: [old]).first?.value == .gap)
    }

    @Test("file-backed deletion survives reopen")
    func deletionSurvivesReopen() throws {
        let path = temporaryDatabasePath()
        defer { removeDatabase(at: path) }
        let day = try period(2026, 7, 10, calendar: calendar(timeZone: "UTC"))
        do {
            let store = try HistoricalUsageTrendStore(path: path)
            try store.record([try sample(period: day)], now: day.window.end)
            #expect(try store.deleteAll() == 1)
        }

        let reopened = try HistoricalUsageTrendStore(path: path)
        #expect(try reopened.buckets(for: [day]).first?.value == .gap)
    }

    @Test("schema has an exact privacy-safe allowlist")
    func schemaHasExactAllowlist() throws {
        let store = try HistoricalUsageTrendStore.inMemory()

        #expect(try store.schemaColumnNames() == HistoricalUsageTrendStore.observationColumnNames)
        #expect(try store.schemaColumnNames().isDisjoint(with: [
            "account", "account_label", "project", "project_label", "deployment", "deployment_label",
            "prompt", "response", "raw_content", "raw_provider_response", "api_key", "access_token"
        ]))
    }

    @Test("an unshipped draft schema resets transactionally and remains recoverable")
    func draftSchemaResetIsRecoverable() throws {
        let path = temporaryDatabasePath()
        defer { removeDatabase(at: path) }
        try withDatabase(at: path) { database in
            try execute("""
            CREATE TABLE historical_usage_trends (sentinel TEXT);
            INSERT INTO historical_usage_trends VALUES ('preserved-on-rollback');
            CREATE VIEW historical_usage_observations AS SELECT sentinel FROM historical_usage_trends;
            PRAGMA user_version = 2;
            """, in: database)
        }

        #expect(throws: HistoricalUsageTrendStoreError.self) {
            _ = try HistoricalUsageTrendStore(path: path)
        }
        #expect(try scalarText("SELECT sentinel FROM historical_usage_trends;", at: path) == "preserved-on-rollback")

        try withDatabase(at: path) { database in
            try execute("DROP VIEW historical_usage_observations;", in: database)
        }
        let recovered = try HistoricalUsageTrendStore(path: path)
        #expect(try recovered.schemaColumnNames() == HistoricalUsageTrendStore.observationColumnNames)
        #expect(try databaseVersion(at: path) == HistoricalUsageTrendStore.schemaVersion)
    }

    private func sample(
        period: HistoricalUsageTrendPeriod,
        source: UsageMetricSource = .builtInLocalLog,
        coverage: HistoricalUsageCoverageScope = .model("claude-sonnet"),
        input: Int = 10,
        output: Int = 5,
        providerCost: Cost? = nil,
        calculatedCost: HistoricalUsageCalculatedCost? = nil
    ) throws -> HistoricalUsageTrendSample {
        try HistoricalUsageTrendSample(
            provider: .anthropic,
            source: source,
            coverage: coverage,
            period: period,
            tokenUsage: TokenUsage(inputTokens: input, outputTokens: output),
            providerReportedCost: providerCost,
            calculatedCost: calculatedCost
        )
    }

    private func metric(window: ExactUsageWindow, source: UsageMetricSource, input: Int) -> UsageMetric {
        UsageMetric(
            provider: .anthropic,
            accountLabel: "not persisted",
            projectLabel: "not persisted",
            modelLabel: "claude-sonnet",
            deploymentLabel: "not persisted",
            provenance: .bounded(source: source, window: window),
            tokenUsage: TokenUsage(inputTokens: input, outputTokens: 1),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: window.start,
            freshness: .fresh
        )
    }

    private func observations(in bucket: HistoricalUsageTrendBucket) -> [HistoricalUsageTrendObservation] {
        guard case let .observed(observations) = bucket.value else {
            Issue.record("Expected an observed bucket")
            return []
        }
        return observations
    }

    private func period(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        window: TimeWindow = .today,
        calendar: Calendar
    ) throws -> HistoricalUsageTrendPeriod {
        let reference = try date(year, month, day, hour: 12, calendar: calendar)
        let windows = try CurrentUsageWindows.resolve(at: reference, calendar: calendar)
        let exact = window == .today ? windows.today : windows.currentWeek
        return try HistoricalUsageTrendPeriod(window: exact, timeZoneIdentifier: calendar.timeZone.identifier)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    private func calendar(timeZone identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: identifier))
        return calendar
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).sqlite").path
    }

    private func removeDatabase(at path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func databaseVersion(at path: String) throws -> Int {
        try withDatabase(at: path) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
                throw HistoricalUsageTrendStoreError.prepareFailed("Unable to inspect version")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw HistoricalUsageTrendStoreError.executeFailed("Unable to inspect version")
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func scalarText(_ sql: String, at path: String) throws -> String? {
        try withDatabase(at: path) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw HistoricalUsageTrendStoreError.prepareFailed("Unable to inspect database")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
    }

    private func withDatabase<T>(at path: String, operation: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw HistoricalUsageTrendStoreError.openFailed("Unable to open test database")
        }
        defer { sqlite3_close(database) }
        return try operation(database)
    }

    private func execute(_ sql: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoricalUsageTrendStoreError.executeFailed(String(cString: sqlite3_errmsg(database)))
        }
    }
}
