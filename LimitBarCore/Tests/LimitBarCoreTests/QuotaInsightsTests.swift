import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Quota insights")
struct QuotaInsightsTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("adapters retain only supported account-wide and individual-plan percentages")
    func adapters() throws {
        let reset = base.addingTimeInterval(7_200)
        let claude = ClaudeRateLimitSnapshot(limits: [
            ClaudeRateLimit(kind: "session", group: .session, percentUsed: 20, severity: .normal, resetsAt: reset, scopeDisplayName: nil, isActive: true),
            ClaudeRateLimit(kind: "model", group: .weekly, percentUsed: 30, severity: .normal, resetsAt: reset, scopeDisplayName: "Private model label", isActive: true),
        ], fetchedAt: base)
        #expect(MeasuredQuotaObservationAdapter.claude(claude).map(\.identity.identifier) == ["session:session"])

        let personal = CodexRateLimitSnapshot(planType: "plus", primary: CodexRateLimitWindow(percentUsed: 10, windowMinutes: 300, resetsAt: reset), secondary: nil, credits: nil, reportedAt: base)
        let business = CodexRateLimitSnapshot(planType: "business", primary: personal.primary, secondary: nil, credits: nil, reportedAt: base)
        #expect(MeasuredQuotaObservationAdapter.codex(personal).count == 1)
        #expect(MeasuredQuotaObservationAdapter.codex(business).isEmpty)
    }

    @Test("qualified analytics uses robust measured burn and bounded exhaustion ranges")
    func qualifiedAnalytics() throws {
        let identity = try window(reset: base.addingTimeInterval(4 * 3_600))
        let observations = try [
            observation(identity, minutes: 0, percent: 10),
            observation(identity, minutes: 10, percent: 12),
            observation(identity, minutes: 20, percent: 14),
            observation(identity, minutes: 30, percent: 50),
            observation(identity, minutes: 40, percent: 18),
        ]
        // A decrease is never converted into negative usage or hidden by robust statistics.
        #expect(QuotaInsightAnalytics.analyze(observations, now: base.addingTimeInterval(41 * 60), maximumAge: 600) ==
            .unavailable(.counterDecreased, measuredObservationCount: 5, measuredSpan: 2_400))

        let stable = try [0.0, 10, 20, 30].enumerated().map { index, minute in
            try observation(identity, minutes: minute, percent: 70 + Double(index) * 2)
        }
        guard case let .qualified(finding) = QuotaInsightAnalytics.analyze(stable, now: base.addingTimeInterval(31 * 60), maximumAge: 600) else {
            Issue.record("Expected a qualified finding")
            return
        }
        #expect(finding.measuredObservationCount == 4)
        #expect(finding.calculatedBurnPercentPerHour.lower == 12)
        #expect(finding.calculatedBurnPercentPerHour.upper == 12)
        #expect(finding.calculatedExhaustionRange != nil)

        let straddlingIdentity = try window(reset: base.addingTimeInterval(100 * 60))
        let straddling = try zip([0.0, 10, 20, 30], [70.0, 72, 75, 79]).map {
            try observation(straddlingIdentity, minutes: $0.0, percent: $0.1)
        }
        guard case let .qualified(straddlingFinding) = QuotaInsightAnalytics.analyze(
            straddling,
            now: base.addingTimeInterval(31 * 60),
            maximumAge: 600
        ) else {
            Issue.record("Expected burn to remain qualified")
            return
        }
        #expect(straddlingFinding.calculatedExhaustionRange == nil)
    }

    @Test("window kind classification parses only fixed identity structures")
    func windowKindClassification() throws {
        let reset = base.addingTimeInterval(3_600)
        #expect(try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: reset).insightWindowKind == .session)
        #expect(try QuotaWindowIdentity(product: .codex, identifier: "secondary:10080", resetBoundary: reset).insightWindowKind == .weekly)
        #expect(try QuotaWindowIdentity(product: .codex, identifier: "primary:100800", resetBoundary: reset).insightWindowKind == .other)
        #expect(try QuotaWindowIdentity(product: .codex, identifier: "primary:010080", resetBoundary: reset).insightWindowKind == .other)
        #expect(try QuotaWindowIdentity(product: .claudeCode, identifier: "session:weekly_claim", resetBoundary: reset).insightWindowKind == .session)
        #expect(try QuotaWindowIdentity(product: .claudeCode, identifier: "other:session_weekly", resetBoundary: reset).insightWindowKind == .other)
        #expect(try QuotaWindowIdentity(product: .claudeCode, identifier: "weekly:session_claim", resetBoundary: reset).insightWindowKind == .weekly)
    }

    @Test("service reevaluates retained Claude evidence as time advances")
    func claudeReevaluation() async throws {
        let service = QuotaInsightsService(store: try SQLiteQuotaObservationStore.inMemory())
        let reset = base.addingTimeInterval(4 * 3_600)
        var latest: [QuotaWindowIdentity: QuotaInsightState] = [:]
        for (minute, percent) in zip([0.0, 5, 10, 15], [70.0, 72, 74, 76]) {
            let observedAt = base.addingTimeInterval(minute * 60)
            latest = try await service.recordClaude(
                ClaudeRateLimitSnapshot(limits: [
                    ClaudeRateLimit(kind: "session", group: .session, percentUsed: percent, severity: .normal, resetsAt: reset, scopeDisplayName: nil, isActive: true),
                ], fetchedAt: observedAt),
                now: observedAt
            )
        }
        let identity = try #require(latest.keys.first)
        #expect(latest[identity]?.isQualified == true)

        let reevaluated = try await service.reevaluateClaude(now: base.addingTimeInterval(30 * 60 + 1))
        #expect(reevaluated[identity] == .unavailable(.staleEvidence, measuredObservationCount: 4, measuredSpan: 900))
    }

    @Test("analytics reports insufficient, stale, reset, and flat evidence explicitly")
    func unavailableStates() throws {
        let identity = try window(reset: base.addingTimeInterval(3_600))
        let short = try [observation(identity, minutes: 0, percent: 10)]
        #expect(QuotaInsightAnalytics.analyze(short, now: base.addingTimeInterval(60), maximumAge: 600) ==
            .unavailable(.insufficientObservations, measuredObservationCount: 1, measuredSpan: 0))

        let flat = try [0.0, 10, 20, 30].map { try observation(identity, minutes: $0, percent: 10) }
        #expect(QuotaInsightAnalytics.analyze(flat, now: base.addingTimeInterval(31 * 60), maximumAge: 600) ==
            .unavailable(.noPositiveBurn, measuredObservationCount: 4, measuredSpan: 1_800))
        #expect(QuotaInsightAnalytics.analyze(flat, now: base.addingTimeInterval(50 * 60), maximumAge: 600) ==
            .unavailable(.staleEvidence, measuredObservationCount: 4, measuredSpan: 1_800))
        #expect(QuotaInsightAnalytics.analyze(flat, now: base.addingTimeInterval(3_601), maximumAge: 600) ==
            .unavailable(.resetOrExpired, measuredObservationCount: 4, measuredSpan: 1_800))
    }

    @Test("same-time conflicting evidence is retained and unavailable")
    func conflictingEvidence() throws {
        let store = try SQLiteQuotaObservationStore.inMemory()
        let identity = try window(reset: base.addingTimeInterval(3_600))
        let original = try observation(identity, minutes: 0, percent: 10)
        let changedPercentage = try observation(identity, minutes: 0, percent: 11)

        #expect(try store.record([original, original, changedPercentage], now: base) == 2)
        let retained = try store.observations(for: identity, now: base)
        #expect(retained.count == 2)
        #expect(QuotaInsightAnalytics.analyze(retained, now: base, maximumAge: 600) ==
            .unavailable(.conflictingObservations, measuredObservationCount: 2, measuredSpan: 0))
    }

    @Test("SQLite deduplicates scans, bounds age and count, and deletes explicitly")
    func persistence() throws {
        let store = try SQLiteQuotaObservationStore.inMemory()
        let identity = try window(reset: base.addingTimeInterval(10 * 24 * 3_600))
        let repeated = try observation(identity, minutes: 0, percent: 10)
        #expect(try store.record([repeated], now: base) == 1)
        #expect(try store.record([repeated], now: base) == 0)

        let many = try (1...(SQLiteQuotaObservationStore.maximumObservationsPerWindow + 5)).map {
            try observation(identity, minutes: Double($0), percent: min(99, Double($0) / 10))
        }
        _ = try store.record(many, now: base.addingTimeInterval(600 * 60))
        #expect(try store.observations(for: identity, now: base.addingTimeInterval(600 * 60)).count == SQLiteQuotaObservationStore.maximumObservationsPerWindow)

        let future = base.addingTimeInterval(SQLiteQuotaObservationStore.retentionInterval + 601 * 60)
        #expect(try store.observations(for: identity, now: future).isEmpty)
        _ = try store.record([try observation(identity, minutes: 700, percent: 80)], now: base.addingTimeInterval(700 * 60))
        try store.deleteAll()
        #expect(try store.observations(for: identity, now: base.addingTimeInterval(700 * 60)).isEmpty)
    }

    @Test("SQLite rejects unknown and malformed schemas")
    func schemaValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let futurePath = directory.appendingPathComponent("future.sqlite").path
        try makeDatabase(path: futurePath, sql: "PRAGMA user_version = 2;")
        let futureBytes = try Data(contentsOf: URL(fileURLWithPath: futurePath))
        #expect(throws: QuotaObservationStoreError.schemaFailed) {
            try SQLiteQuotaObservationStore(path: futurePath)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: futurePath)) == futureBytes)

        let malformedPath = directory.appendingPathComponent("malformed.sqlite").path
        try makeDatabase(path: malformedPath, sql: "CREATE TABLE quota_observations (private_payload TEXT); PRAGMA user_version = 1;")
        let malformedBytes = try Data(contentsOf: URL(fileURLWithPath: malformedPath))
        #expect(throws: QuotaObservationStoreError.schemaFailed) {
            try SQLiteQuotaObservationStore(path: malformedPath)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: malformedPath)) == malformedBytes)

        let weakPath = directory.appendingPathComponent("weak.sqlite").path
        try makeDatabase(path: weakPath, sql: """
        CREATE TABLE quota_observations (
            product TEXT NOT NULL,
            window_identifier TEXT NOT NULL,
            reset_boundary REAL NOT NULL,
            observed_at REAL NOT NULL,
            percentage_used REAL NOT NULL,
            observation_source TEXT NOT NULL,
            PRIMARY KEY (product, window_identifier, reset_boundary, observed_at, percentage_used, observation_source)
        );
        CREATE INDEX quota_observations_retention ON quota_observations(observed_at);
        PRAGMA user_version = 1;
        """)
        let weakBytes = try Data(contentsOf: URL(fileURLWithPath: weakPath))
        #expect(throws: QuotaObservationStoreError.schemaFailed) {
            try SQLiteQuotaObservationStore(path: weakPath)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: weakPath)) == weakBytes)

        let wrongIndexPath = directory.appendingPathComponent("wrong-index.sqlite").path
        try makeDatabase(path: wrongIndexPath, sql: """
        CREATE TABLE quota_observations (
            product TEXT NOT NULL CHECK (product IN ('claudeCode', 'codex')),
            window_identifier TEXT NOT NULL CHECK (length(window_identifier) BETWEEN 1 AND 128),
            reset_boundary REAL NOT NULL,
            observed_at REAL NOT NULL,
            percentage_used REAL NOT NULL CHECK (percentage_used BETWEEN 0 AND 100),
            observation_source TEXT NOT NULL CHECK (observation_source IN ('claude_provider_report', 'codex_local_report')),
            PRIMARY KEY (product, window_identifier, reset_boundary, observed_at, percentage_used, observation_source)
        );
        CREATE INDEX quota_observations_retention ON quota_observations(reset_boundary);
        PRAGMA user_version = 1;
        """)
        #expect(throws: QuotaObservationStoreError.schemaFailed) {
            try SQLiteQuotaObservationStore(path: wrongIndexPath)
        }

        let priorCanonicalPath = directory.appendingPathComponent("prior-canonical.sqlite").path
        try makeDatabase(path: priorCanonicalPath, sql: """
        CREATE TABLE IF NOT EXISTS quota_observations (
            product TEXT NOT NULL CHECK (product IN ('claudeCode', 'codex')),
            window_identifier TEXT NOT NULL CHECK (length(window_identifier) BETWEEN 1 AND 128),
            reset_boundary REAL NOT NULL,
            observed_at REAL NOT NULL,
            percentage_used REAL NOT NULL CHECK (percentage_used BETWEEN 0 AND 100),
            observation_source TEXT NOT NULL CHECK (observation_source IN ('claude_provider_report', 'codex_local_report')),
            PRIMARY KEY (product, window_identifier, reset_boundary, observed_at, percentage_used, observation_source)
        );
        CREATE INDEX IF NOT EXISTS quota_observations_retention ON quota_observations(observed_at);
        PRAGMA user_version = 1;
        """)
        _ = try SQLiteQuotaObservationStore(path: priorCanonicalPath)
    }

    private func window(reset: Date) throws -> QuotaWindowIdentity {
        try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: reset)
    }

    private func observation(_ identity: QuotaWindowIdentity, minutes: Double, percent: Double) throws -> MeasuredQuotaObservation {
        try MeasuredQuotaObservation(
            identity: identity,
            percentageUsed: percent,
            observedAt: base.addingTimeInterval(minutes * 60),
            source: .codexLocalReport
        )
    }

    private func makeDatabase(path: String, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw QuotaObservationStoreError.openFailed
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw QuotaObservationStoreError.schemaFailed
        }
    }
}

private extension QuotaInsightState {
    var isQualified: Bool {
        if case .qualified = self { return true }
        return false
    }
}
