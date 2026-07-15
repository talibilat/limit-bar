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

    @Test("measured observations enforce provider-product source interpretation")
    func observationProductSourceInvariant() throws {
        let reset = base.addingTimeInterval(3_600)
        let claude = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: reset)
        let codex = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: reset)
        let unsupported = try QuotaWindowIdentity(product: .openAIAPI, identifier: "quota", resetBoundary: reset)

        #expect(throws: QuotaInsightValidationError.invalidObservation) {
            try MeasuredQuotaObservation(identity: claude, percentageUsed: 10, observedAt: base, source: .codexLocalReport)
        }
        #expect(throws: QuotaInsightValidationError.invalidObservation) {
            try MeasuredQuotaObservation(identity: codex, percentageUsed: 10, observedAt: base, source: .claudeProviderReport)
        }
        #expect(throws: QuotaInsightValidationError.invalidObservation) {
            try MeasuredQuotaObservation(identity: unsupported, percentageUsed: 10, observedAt: base, source: .codexLocalReport)
        }
    }

    @Test("alert and insight adapters share canonical quota window identities")
    func canonicalAdapterIdentities() throws {
        let reset = base.addingTimeInterval(7_200)
        let claudeLimit = ClaudeRateLimit(kind: "session", group: .weekly, percentUsed: 20, severity: .normal, resetsAt: reset, scopeDisplayName: nil, isActive: true)
        let claudeSnapshot = ClaudeRateLimitSnapshot(limits: [claudeLimit], fetchedAt: base)
        let codexWindow = CodexRateLimitWindow(percentUsed: 10, windowMinutes: 300, resetsAt: reset)
        let codexSnapshot = CodexRateLimitSnapshot(planType: "plus", primary: codexWindow, secondary: nil, credits: nil, reportedAt: base)

        let canonicalClaude = try #require(QuotaWindowIdentity.claudeCode(claudeLimit))
        #expect(canonicalClaude.product == .claudeCode)
        #expect(canonicalClaude.identifier == "weekly:session")
        #expect(MeasuredQuotaObservationAdapter.claude(claudeSnapshot).map(\.identity) == [canonicalClaude])
        #expect(QuotaObservationAdapter.claude(claudeSnapshot, subscriptionType: nil, now: base).map(\.identity) == [canonicalClaude])

        let canonicalCodex = try #require(QuotaWindowIdentity.codex(slot: "primary", window: codexWindow))
        #expect(canonicalCodex.product == .codex)
        #expect(canonicalCodex.identifier == "codex:primary:300")
        #expect(MeasuredQuotaObservationAdapter.codex(codexSnapshot).map(\.identity) == [canonicalCodex])
        #expect(QuotaObservationAdapter.codex(codexSnapshot, now: base).map(\.identity) == [canonicalCodex])
        #expect(QuotaWindowIdentity.codex(slot: "unsupported", window: codexWindow) == nil)
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
        expectUnavailable(
            QuotaInsightAnalytics.analyze(observations, now: base.addingTimeInterval(41 * 60), maximumAge: 600),
            reason: .counterDecreased,
            count: 5,
            span: 2_400
        )

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
        #expect(finding.forecastMethod == .pairwisePositiveSlopeInterquartileV2)

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

    @Test("normalized observations have stable content identities and qualified findings retain the exact input trace")
    func observationIdentityAndQualifiedTrace() throws {
        let identity = try window(reset: base.addingTimeInterval(4 * 3_600))
        let observations = try zip([0.0, 10, 20, 30], [70.0, 72, 74, 76]).map {
            try observation(identity, minutes: $0.0, percent: $0.1)
        }
        let duplicate = try observation(identity, minutes: 10, percent: 72)
        let materiallyDifferent = try observation(identity, minutes: 10, percent: 73)
        let zero = try observation(identity, minutes: 10, percent: 0)
        let negativeZero = try observation(identity, minutes: 10, percent: -0.0)

        #expect(duplicate.stableIdentity == observations[1].stableIdentity)
        #expect(zero.stableIdentity == negativeZero.stableIdentity)
        #expect(materiallyDifferent.stableIdentity != observations[1].stableIdentity)
        #expect(observations[1].stableIdentity.version == .normalizedQuotaObservationV1)
        #expect(observations[1].normalizationVersion == .quotaObservationNormalizationV1)
        #expect(observations[1].interpretationVersion == .codexLocalReportV1)

        let now = base.addingTimeInterval(31 * 60)
        guard case let .qualified(finding) = QuotaInsightAnalytics.analyze(
            [duplicate] + observations.reversed(),
            now: now,
            maximumAge: 600
        ) else {
            Issue.record("Expected a qualified finding")
            return
        }
        #expect(finding.inputObservationIdentities == observations.map(\.stableIdentity))
        #expect(finding.createdAt == now)
        #expect(finding.evidenceAge == 60)
        #expect(QuotaInsightAnalytics.analyze(observations, now: now, maximumAge: 600).qualificationStatus == .qualified)
        #expect(finding.interpretationVersions == [.codexLocalReportV1])
        #expect(finding.identity == identity)
    }

    @Test("stable identities canonicalize Unicode and every signed-zero component with a fixed interpretation-aware digest")
    func canonicalStableIdentity() throws {
        let composed = try QuotaWindowIdentity(product: .codex, identifier: "prim\u{00E1}ry:300", resetBoundary: Date(timeIntervalSince1970: 0.0))
        let decomposed = try QuotaWindowIdentity(product: .codex, identifier: "prima\u{0301}ry:300", resetBoundary: Date(timeIntervalSince1970: -0.0))
        let first = try MeasuredQuotaObservation(identity: composed, percentageUsed: 0.0, observedAt: Date(timeIntervalSince1970: 0.0), source: .codexLocalReport)
        let second = try MeasuredQuotaObservation(identity: decomposed, percentageUsed: -0.0, observedAt: Date(timeIntervalSince1970: -0.0), source: .codexLocalReport)

        #expect(composed == decomposed)
        #expect(first.stableIdentity == second.stableIdentity)
        #expect(first.stableIdentity.digest == "056e380a62918a0bfb0f16c5a843c321aa41796224045ed973c6c0cedba723b1")
        let claudeIdentity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: Date(timeIntervalSince1970: 1))
        let claude = try MeasuredQuotaObservation(identity: claudeIdentity, percentageUsed: 1, observedAt: Date(timeIntervalSince1970: 0), source: .claudeProviderReport)
        #expect(claude.stableIdentity.digest == "5bc01f8f2d7ec8dc5e5fccdf3688e620f0a79466589eaf183c6167c62a416f0b")
        #expect(QuotaObservationInterpretationVersion(derivedFrom: .claudeProviderReport) == .claudeProviderReportV1)
        #expect(QuotaObservationInterpretationVersion(derivedFrom: .codexLocalReport) == .codexLocalReportV1)

        let store = try SQLiteQuotaObservationStore.inMemory()
        _ = try store.record([first], now: Date(timeIntervalSince1970: 0))
        #expect(try store.observations(for: decomposed, now: Date(timeIntervalSince1970: 0)).map(\.stableIdentity) == [first.stableIdentity])
    }

    @Test("unavailable analytics is versioned, traceable, and isolates exact quota windows")
    func unavailableTraceAndWindowIsolation() throws {
        let firstWindow = try window(reset: base.addingTimeInterval(4 * 3_600))
        let secondWindow = try window(reset: base.addingTimeInterval(5 * 3_600))
        let first = try observation(firstWindow, minutes: 0, percent: 10)
        let second = try observation(secondWindow, minutes: 1, percent: 11)
        let now = base.addingTimeInterval(2 * 60)

        let state = QuotaInsightAnalytics.analyze(
            [second, first, first],
            now: now,
            maximumAge: 600
        )
        guard case let .unavailable(finding) = state else {
            Issue.record("Expected incompatible evidence to be unavailable")
            return
        }
        #expect(finding.reason == .incompatibleEvidence)
        #expect(finding.forecastMethod == .pairwisePositiveSlopeInterquartileV2)
        #expect(finding.createdAt == now)
        #expect(state.qualificationStatus == .unavailable)
        #expect(finding.interpretationVersions == [.codexLocalReportV1])
        #expect(finding.implicatedIdentities == [firstWindow, secondWindow])
        #expect(finding.inputObservationIdentities == [first.stableIdentity, second.stableIdentity])
        #expect(finding.measuredObservationCount == 2)
        #expect(finding.measuredSpan == 60)
        #expect(finding.evidenceAge == 60)

        let reversed = QuotaInsightAnalytics.analyze([first, second], now: now, maximumAge: 600)
        #expect(reversed == .unavailable(finding))
    }

    @Test("unavailable findings retain deterministic implicated exact-window context")
    func unavailableIdentityShapes() throws {
        let identity = try window(reset: base.addingTimeInterval(4 * 3_600))
        let one = try observation(identity, minutes: 0, percent: 10)
        guard case let .unavailable(single) = QuotaInsightAnalytics.analyze([one], now: base.addingTimeInterval(60), maximumAge: 600),
              case let .unavailable(empty) = QuotaInsightAnalytics.analyze([], now: base, maximumAge: 600, expectedIdentity: identity) else {
            Issue.record("Expected unavailable findings")
            return
        }
        #expect(single.implicatedIdentities == [identity])
        #expect(empty.implicatedIdentities == [identity])
        #expect(empty.inputObservationIdentities.isEmpty)
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
        expectUnavailable(reevaluated[identity], reason: .staleEvidence, count: 4, span: 900)
    }

    @Test("service reevaluates retained Codex evidence as stale and expired")
    func codexReevaluation() async throws {
        let service = QuotaInsightsService(store: try SQLiteQuotaObservationStore.inMemory())
        let reset = base.addingTimeInterval(10 * 3_600)
        var latest: [QuotaWindowIdentity: QuotaInsightState] = [:]
        for (minute, percent) in zip([0.0, 5, 10, 15], [70.0, 72, 74, 76]) {
            let observedAt = base.addingTimeInterval(minute * 60)
            latest = try await service.recordCodex(
                CodexRateLimitSnapshot(
                    planType: "plus",
                    primary: CodexRateLimitWindow(percentUsed: percent, windowMinutes: 300, resetsAt: reset),
                    secondary: nil,
                    credits: nil,
                    reportedAt: observedAt
                ),
                now: observedAt
            )
        }
        let identity = try #require(latest.keys.first)
        #expect(latest[identity]?.isQualified == true)

        let stale = try await service.reevaluateCodex(now: base.addingTimeInterval(6 * 3_600 + 15 * 60 + 1))
        expectUnavailable(stale[identity], reason: .staleEvidence, count: 4, span: 900)

        let expired = try await service.reevaluateCodex(now: reset)
        expectUnavailable(expired[identity], reason: .resetOrExpired, count: 4, span: 900)
    }

    @Test("analytics reports insufficient, stale, reset, and flat evidence explicitly")
    func unavailableStates() throws {
        let identity = try window(reset: base.addingTimeInterval(3_600))
        let short = try [observation(identity, minutes: 0, percent: 10)]
        expectUnavailable(
            QuotaInsightAnalytics.analyze(short, now: base.addingTimeInterval(60), maximumAge: 600),
            reason: .insufficientObservations,
            count: 1,
            span: 0
        )

        let flat = try [0.0, 10, 20, 30].map { try observation(identity, minutes: $0, percent: 10) }
        expectUnavailable(QuotaInsightAnalytics.analyze(flat, now: base.addingTimeInterval(31 * 60), maximumAge: 600), reason: .noPositiveBurn, count: 4, span: 1_800)
        expectUnavailable(QuotaInsightAnalytics.analyze(flat, now: base.addingTimeInterval(50 * 60), maximumAge: 600), reason: .staleEvidence, count: 4, span: 1_800)
        expectUnavailable(QuotaInsightAnalytics.analyze(flat, now: base.addingTimeInterval(3_601), maximumAge: 600), reason: .resetOrExpired, count: 4, span: 1_800)
    }

    @Test("non-finite evaluation time fails safely without non-finite analytical metadata")
    func invalidEvaluationTime() throws {
        let identity = try window(reset: base.addingTimeInterval(3_600))
        let observations = try [observation(identity, minutes: 0, percent: 10)]

        guard case let .unavailable(finding) = QuotaInsightAnalytics.analyze(
            observations,
            now: Date(timeIntervalSince1970: .infinity),
            maximumAge: 600
        ) else {
            Issue.record("Expected invalid evaluation to be unavailable")
            return
        }
        #expect(finding.reason == .invalidEvaluation)
        #expect(finding.createdAt == nil)
        #expect(finding.evidenceAge == nil)
        #expect(finding.inputObservationIdentities == observations.map(\.stableIdentity))
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
        #expect(retained.map(\.stableIdentity) == [original, changedPercentage].map(\.stableIdentity))
        expectUnavailable(QuotaInsightAnalytics.analyze(retained, now: base, maximumAge: 600), reason: .conflictingObservations, count: 2, span: 0)
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

    @Test("SQLite reads pre-release decomposed identifiers through canonical identity without duplicate effective observations")
    func decomposedIdentifierReadCompatibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("quota.sqlite").path
        let store = try SQLiteQuotaObservationStore(path: path)
        let reset = base.addingTimeInterval(3_600)
        let composed = try QuotaWindowIdentity(product: .codex, identifier: "prim\u{00E1}ry:300", resetBoundary: reset)
        let decomposed = "prima\u{0301}ry:300"

        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let insert = "INSERT INTO quota_observations VALUES ('codex', '\(decomposed)', \(reset.timeIntervalSince1970), \(base.timeIntervalSince1970), 10, 'codex_local_report');"
        #expect(sqlite3_exec(database, insert, nil, nil, nil) == SQLITE_OK)

        let expected = try MeasuredQuotaObservation(identity: composed, percentageUsed: 10, observedAt: base, source: .codexLocalReport)
        #expect(try store.observations(for: composed, now: base).map(\.stableIdentity) == [expected.stableIdentity])
        _ = try store.record([expected], now: base)
        #expect(try store.observations(for: composed, now: base).map(\.stableIdentity) == [expected.stableIdentity])
        #expect(try store.observations(for: composed, now: base.addingTimeInterval(SQLiteQuotaObservationStore.retentionInterval + 1)).isEmpty)
    }

    @Test("SQLite physically caps canonically equivalent identifier forms without pruning a distinct identifier")
    func canonicalPhysicalCap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("quota.sqlite").path
        let store = try SQLiteQuotaObservationStore(path: path)
        let reset = base.addingTimeInterval(10 * 24 * 3_600)
        let composedText = "prim\u{00E1}ry:300"
        let decomposedText = "prima\u{0301}ry:300"
        let identity = try QuotaWindowIdentity(product: .codex, identifier: composedText, resetBoundary: reset)

        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        for index in 0..<600 {
            let identifier = index.isMultiple(of: 2) ? composedText : decomposedText
            let sql = "INSERT INTO quota_observations VALUES ('codex', '\(identifier)', \(reset.timeIntervalSince1970), \(base.addingTimeInterval(Double(index)).timeIntervalSince1970), \(Double(index % 100)), 'codex_local_report');"
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        #expect(sqlite3_exec(database, "INSERT INTO quota_observations VALUES ('codex', 'secondary:300', \(reset.timeIntervalSince1970), \(base.timeIntervalSince1970), 1, 'codex_local_report');", nil, nil, nil) == SQLITE_OK)

        let effective = try store.observations(for: identity, now: base.addingTimeInterval(600))
        #expect(effective.count <= SQLiteQuotaObservationStore.maximumObservationsPerWindow)
        #expect(try physicalCount(database, identifiers: [composedText, decomposedText], reset: reset) <= SQLiteQuotaObservationStore.maximumObservationsPerWindow)
        #expect(try physicalCount(database, identifiers: ["secondary:300"], reset: reset) == 1)
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

    private func physicalCount(_ database: OpaquePointer?, identifiers: [String], reset: Date) throws -> Int {
        let quoted = identifiers.map { "'\($0)'" }.joined(separator: ",")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM quota_observations WHERE reset_boundary = ? AND window_identifier IN (\(quoted));", -1, &statement, nil) == SQLITE_OK else {
            throw QuotaObservationStoreError.readFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, reset.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw QuotaObservationStoreError.readFailed }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func expectUnavailable(
        _ state: QuotaInsightState?,
        reason: QuotaInsightUnavailableReason,
        count: Int,
        span: TimeInterval
    ) {
        guard case let .unavailable(finding) = state else {
            Issue.record("Expected an unavailable finding")
            return
        }
        #expect(finding.reason == reason)
        #expect(finding.measuredObservationCount == count)
        #expect(finding.measuredSpan == span)
        #expect(finding.forecastMethod == .pairwisePositiveSlopeInterquartileV2)
        #expect(state?.qualificationStatus == .unavailable)
    }
}

private extension QuotaInsightState {
    var isQualified: Bool {
        if case .qualified = self { return true }
        return false
    }
}
