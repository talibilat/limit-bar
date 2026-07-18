import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Activity receipts")
struct ActivityReceiptTests {
    private let runID = "11111111-1111-4111-8111-111111111111"
    private let now = ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z")!
    private var claudeMetadata: ActivityImportMetadata { .init(mode: "interactive", concurrency: 2) }
    private var codexMetadata: ActivityImportMetadata { .init(clientVersion: ActivityReceiptParser.codexClientVersion, mode: "exec", concurrency: 1) }

    @Test("sources remain disabled and Codex requires explicit trusted metadata")
    func sourceAndMetadataQualification() {
        #expect(ActivityReceiptParser.parseClaude(data: claudeFixture(), preferences: .init(), now: now) == .unavailable(.sourceDisabled))
        #expect(ActivityReceiptParser.parseCodexJSONL(data: codexFixture(), preferences: .init(codexExecEnabled: true), now: now) == .unavailable(.missingImportMetadata))
        let wrong = ActivitySourcePreferences(codexExecEnabled: true, codexImportMetadata: .init(clientVersion: "newer", mode: "exec", concurrency: 1))
        #expect(ActivityReceiptParser.parseCodexJSONL(data: codexFixture(), preferences: wrong, now: now) == .unavailable(.missingImportMetadata))
    }

    @Test("documented Claude attributes derive facts without invented OTLP requirements")
    func providerClaudeFixture() {
        let preferences = ActivitySourcePreferences(claudeCodeEnabled: true, claudeImportMetadata: claudeMetadata)
        guard case let .imported(receipts) = ActivityReceiptParser.parseClaude(data: claudeFixture(), preferences: preferences, now: now) else { Issue.record("Expected documented Claude events"); return }
        #expect(receipts.count == 4)
        #expect(receipts[0].lifecycle == .modelAttempt)
        #expect(receipts[0].attempt == .unknown)
        #expect(receipts[0].role == .primary)
        #expect(receipts[0].outcome == .unknown)
        #expect(receipts[0].tokens.input == 50)
        #expect(receipts[1].lifecycle == .modelAttempt)
        #expect(receipts[1].attempt == .retry)
        #expect(receipts[1].role == .subagent)
        #expect(receipts[1].outcome == .failed)
        #expect(receipts[2].lifecycle == .compaction)
        #expect(receipts[2].outcome == .succeeded)
        #expect(receipts[3].lifecycle == .unknown)
        #expect(receipts[3].attempt == .unknown)
        #expect(receipts[3].role == .unknown)
        #expect(receipts[3].outcome == .unknown)
        #expect(receipts.map(\.operationIdentity) == ["event-1", "event-2", "event-3", "event-4"])
    }

    @Test("api_request never manufactures retry or success from undocumented fields")
    func claudeDoesNotTrustUndocumentedClassifications() {
        let preferences = ActivitySourcePreferences(claudeCodeEnabled: true, claudeImportMetadata: claudeMetadata)
        guard case let .imported(receipts) = ActivityReceiptParser.parseClaude(data: claudeFixture(addUndocumentedFields: true), preferences: preferences, now: now) else { Issue.record("Expected import"); return }
        #expect(receipts[0].attempt == .unknown)
        #expect(receipts[0].outcome == .unknown)
        #expect(receipts[0].role == .primary)
    }

    @Test("Claude mode and concurrency are distinct optional import metadata")
    func claudeOptionalMetadata() {
        let preferences = ActivitySourcePreferences(claudeCodeEnabled: true)
        guard case let .imported(receipts) = ActivityReceiptParser.parseClaude(data: claudeFixture(), preferences: preferences, now: now) else { Issue.record("Expected import without comparison metadata"); return }
        #expect(receipts.first?.compatibility.mode == "unknown")
        #expect(receipts.first?.compatibility.concurrency == 0)
        let other = receipts.map { clone($0, run: UUID()) }
        #expect(ActivityReceiptDebugger.compare(receipts, other) == .unavailable(.incompatibleRuns))
    }

    @Test("documented Codex shapes preserve unsupported lifecycle attempt and role")
    func providerCodexFixture() {
        let preferences = ActivitySourcePreferences(codexExecEnabled: true, codexImportMetadata: codexMetadata)
        guard case let .imported(receipts) = ActivityReceiptParser.parseCodexJSONL(data: codexFixture(), preferences: preferences, now: now) else { Issue.record("Expected documented Codex events"); return }
        #expect(receipts.count == 2)
        #expect(receipts[0].operationIdentity == "item-item_3")
        #expect(receipts[0].lifecycle == .unknown)
        #expect(receipts[0].attempt == .unknown)
        #expect(receipts[0].role == .unknown)
        #expect(receipts[0].outcome == .unknown)
        #expect(receipts[1].operationIdentity == "turn-terminal-1")
        #expect(receipts[1].lifecycle == .unknown)
        #expect(receipts[1].attempt == .unknown)
        #expect(receipts[1].role == .unknown)
        #expect(receipts[1].outcome == .succeeded)
        #expect(receipts[1].compatibility.clientVersion == ActivityReceiptParser.codexClientVersion)
    }

    @Test("findings emit only observable dimensions and never unknown as zero")
    func observableFindingsOnly() {
        let claudePreferences = ActivitySourcePreferences(claudeCodeEnabled: true, claudeImportMetadata: claudeMetadata)
        guard case let .imported(claude) = ActivityReceiptParser.parseClaude(data: claudeFixture(), preferences: claudePreferences, now: now),
              case let .available(claudeFindings) = ActivityReceiptDebugger.findings(for: claude) else { Issue.record("Expected Claude findings"); return }
        #expect(claudeFindings.contains { $0.kind == .retryEvidence(count: 1) })
        #expect(claudeFindings.contains { $0.kind == .compactionAssociated(count: 1) })
        #expect(claudeFindings.contains { $0.kind == .failedOperations(count: 1) })
        #expect(!claudeFindings.contains { if case .normalAttempts = $0.kind { true } else { false } })
        #expect(!claudeFindings.contains { if case .recoveryReplayAssociated = $0.kind { true } else { false } })

        let codexPreferences = ActivitySourcePreferences(codexExecEnabled: true, codexImportMetadata: codexMetadata)
        guard case let .imported(codex) = ActivityReceiptParser.parseCodexJSONL(data: codexFixture(), preferences: codexPreferences, now: now),
              case let .available(codexFindings) = ActivityReceiptDebugger.findings(for: codex) else { Issue.record("Expected Codex findings"); return }
        #expect(codexFindings.contains { $0.kind == .successfulCompletions(count: 1) })
        #expect(codexFindings.contains { $0.kind == .unknownActivity(count: 2) })
        #expect(!codexFindings.contains { if case .normalAttempts = $0.kind { true } else { false } })
        #expect(!codexFindings.contains { if case .subagentAssociated = $0.kind { true } else { false } })
        #expect(!codexFindings.contains { if case .compactionAssociated = $0.kind { true } else { false } })
    }

    @Test("all-unclassified coverage cannot qualify")
    func allUnknownUnavailable() {
        let value = receipt(lifecycle: .unknown, attempt: .unknown, role: .unknown, outcome: .unknown, tokens: .zero)
        #expect(ActivityReceiptDebugger.findings(for: [value]) == .unavailable(.insufficientLifecycleSemantics))
    }

    @Test("unknown event schemas make coverage unavailable instead of being skipped")
    func unknownEventsFailCoverageClosed() {
        let claudePreferences = ActivitySourcePreferences(claudeCodeEnabled: true, claudeImportMetadata: claudeMetadata)
        #expect(ActivityReceiptParser.parseClaude(data: claudeFixture(includeUnsupportedEvent: true), preferences: claudePreferences, now: now) == .unavailable(.insufficientLifecycleSemantics))
        let codexPreferences = ActivitySourcePreferences(codexExecEnabled: true, codexImportMetadata: codexMetadata)
        let codex = Data("""
        {"type":"thread.started","thread_id":"\(runID)"}
        {"type":"future.event"}

        """.utf8)
        #expect(ActivityReceiptParser.parseCodexJSONL(data: codex, preferences: codexPreferences, now: now) == .unavailable(.insufficientLifecycleSemantics))
    }

    @Test("compatible comparison includes observable normalized operation shares")
    func comparisonShares() {
        let firstRun = UUID()
        let secondRun = UUID()
        let earlier = [
            receipt(run: firstRun, operation: "a", attempt: .normal, role: .primary, outcome: .failed, tokens: .zero),
            receipt(run: firstRun, operation: "b", lifecycle: .compaction, attempt: .unknown, role: .unknown, outcome: .succeeded, tokens: .zero),
        ]
        let later = [
            receipt(run: secondRun, operation: "c", attempt: .retry, role: .subagent, outcome: .failed, tokens: .zero),
            receipt(run: secondRun, operation: "d", attempt: .retry, role: .subagent, outcome: .failed, tokens: .zero),
        ]
        guard case let .available(comparison) = ActivityReceiptDebugger.compare(earlier, later) else { Issue.record("Expected compatible comparison"); return }
        #expect(comparison.findings.contains { $0.kind == .compatibleRunShareDelta(metric: "retry-evidence attempt share", earlierPercent: 0, laterPercent: 100) })
        #expect(comparison.findings.contains { $0.kind == .compatibleRunShareDelta(metric: "subagent-associated role share", earlierPercent: 0, laterPercent: 100) })
        #expect(comparison.findings.allSatisfy { !$0.statement.localizedCaseInsensitiveContains("caused") })
    }

    @Test("latest findings surface incompatible configuration without comparing values")
    func incompatibleConfigurationNotice() {
        let earlier = receipt(run: UUID(), operation: "a", compatibility: compatibility(mode: "interactive", concurrency: 1))
        let later = receipt(run: UUID(), operation: "b", at: now.addingTimeInterval(1), compatibility: compatibility(mode: "headless", concurrency: 4))
        guard case let .available(findings) = ActivityReceiptDebugger.latestRunFindings(for: [earlier, later]) else { Issue.record("Expected findings"); return }
        #expect(findings.contains { $0.kind == .incompatibleConfigurationChange(dimensions: ["mode", "concurrency"]) })
        #expect(findings.contains { $0.statement.contains("Values were not compared") })
        #expect(!findings.contains { if case .compatibleRunDelta = $0.kind { true } else { false } })
    }

    @Test("checked aggregation rejects unsafe totals")
    func checkedAggregation() {
        let run = UUID()
        let first = receipt(run: run, operation: "a", tokens: .init(input: ActivityTokenCounts.maximumValue, cachedInput: 0, cacheCreationInput: 0, output: 0, reasoningOutput: 0))
        let second = receipt(run: run, operation: "b", at: now.addingTimeInterval(1), tokens: .init(input: 1, cachedInput: 0, cacheCreationInput: 0, output: 0, reasoningOutput: 0))
        #expect(ActivityReceiptDebugger.findings(for: [first, second]) == .unavailable(.tokenOverflow))
    }

    @Test("privacy allow list excludes provider content from receipts and SQLite")
    func privacy() throws {
        let preferences = ActivitySourcePreferences(claudeCodeEnabled: true, claudeImportMetadata: claudeMetadata)
        guard case let .imported(receipts) = ActivityReceiptParser.parseClaude(data: claudeFixture(includePrivateContent: true), preferences: preferences, now: now) else { Issue.record("Expected import"); return }
        let encoded = String(decoding: try JSONEncoder().encode(receipts), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE"))
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteActivityReceiptStore(path: url.path)
        try store.record(receipts, now: now)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("PRIVATE"))
    }

    @Test("cross-import enforcement remains typed and transactional")
    func crossImport() throws {
        let store = try SQLiteActivityReceiptStore.inMemory()
        let first = receipt(run: UUID(uuidString: runID)!, operation: "a")
        try store.record([first], now: now)
        #expect(throws: ActivityReceiptStoreError.duplicateRecord) { try store.record([first], now: now) }
        #expect(throws: ActivityReceiptStoreError.conflictingRecord) { try store.record([receipt(run: first.runIdentity, operation: "a", tokens: .zero)], now: now) }
        #expect(throws: ActivityReceiptStoreError.outOfOrder) { try store.record([receipt(run: first.runIdentity, operation: "b", at: now.addingTimeInterval(-1))], now: now) }
        #expect(throws: ActivityReceiptStoreError.incompatibleRuns) { try store.record([receipt(run: first.runIdentity, operation: "c", at: now.addingTimeInterval(1), compatibility: compatibility(mode: "headless"))], now: now) }
        #expect(try store.all(now: now) == [first])
    }

    @Test("store restart deletion and decoded validation remain safe")
    func storeSafety() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do { try SQLiteActivityReceiptStore(path: url.path).record([receipt()], now: now) }
        #expect(try SQLiteActivityReceiptStore(path: url.path).all(now: now).count == 1)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "UPDATE activity_receipts SET lifecycle = 'recoveryReplay';", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(throws: ActivityReceiptStoreError.readFailed) { try SQLiteActivityReceiptStore(path: url.path).all(now: now) }
    }

    private func claudeFixture(addUndocumentedFields: Bool = false, includePrivateContent: Bool = false, includeUnsupportedEvent: Bool = false) -> Data {
        var records = [
            claudeRecord(event: "api_request", sequence: 1, extra: ["model": string("claude-sonnet-4"), "query_source": string("repl_main_thread"), "input_tokens": int(50), "output_tokens": int(8), "cache_read_tokens": int(10), "cache_creation_tokens": int(5)]),
            claudeRecord(event: "api_error", sequence: 2, extra: ["model": string("claude-sonnet-4"), "query_source": string("subagent"), "agent.name": string("Explore"), "attempt": int(3), "status_code": int(429), "error": string("PRIVATE raw error")]),
            claudeRecord(event: "compaction", sequence: 3, extra: ["success": string("true"), "trigger": string("auto")]),
            claudeRecord(event: "tool_result", sequence: 4, extra: ["success": string("true"), "tool_name": string("Bash"), "tool_input": string("PRIVATE command")]),
        ]
        if includeUnsupportedEvent { records.append(claudeRecord(event: "future_event", sequence: 5, extra: [:])) }
        if addUndocumentedFields, var attributes = records[0]["attributes"] as? [[String: Any]] {
            attributes.append(attribute("attempt", int(9)))
            attributes.append(attribute("success", bool(true)))
            attributes.append(attribute("lifecycle", string("recoveryReplay")))
            records[0]["attributes"] = attributes
        }
        var request: [String: Any] = ["resourceLogs": [["resource": ["attributes": [["key": "department", "value": string("PRIVATE-team")]]], "scopeLogs": [["scope": ["name": "arbitrary-provider-scope"], "logRecords": records]]]]]
        if includePrivateContent { request["prompt"] = "PRIVATE prompt"; request["response"] = "PRIVATE response" }
        return try! JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    }

    private func claudeRecord(event: String, sequence: Int64, extra: [String: [String: Any]]) -> [String: Any] {
        var values = [attribute("event.name", string(event)), attribute("event.timestamp", string("2026-07-18T10:0\(sequence - 1):00Z")), attribute("event.sequence", int(sequence)), attribute("session.id", string(runID)), attribute("app.version", string(ActivityReceiptParser.claudeClientVersion))]
        values += extra.sorted { $0.key < $1.key }.map { attribute($0.key, $0.value) }
        return ["attributes": values]
    }

    private func codexFixture(input: Int64 = 24_763) -> Data {
        Data("""
        {"type":"thread.started","thread_id":"\(runID)"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"PRIVATE response"}}
        {"type":"turn.completed","usage":{"input_tokens":\(input),"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}

        """.utf8)
    }

    private func receipt(run: UUID = UUID(), operation: String = "operation", at: Date? = nil, compatibility: ActivityReceiptCompatibility? = nil, lifecycle: ActivityLifecycle = .modelAttempt, attempt: ActivityAttempt = .unknown, role: ActivityRole = .primary, outcome: ActivityOutcome = .unknown, tokens: ActivityTokenCounts = .init(input: 1, cachedInput: 0, cacheCreationInput: 0, output: 0, reasoningOutput: 0)) -> ActivityReceipt {
        .init(runIdentity: run, operationIdentity: operation, occurredAt: at ?? now, compatibility: compatibility ?? self.compatibility(), lifecycle: lifecycle, attempt: attempt, role: role, outcome: outcome, tokens: tokens, evidenceLimitations: ActivityEvidenceLimitation.allCases)
    }

    private func clone(_ value: ActivityReceipt, run: UUID) -> ActivityReceipt {
        .init(runIdentity: run, operationIdentity: value.operationIdentity, occurredAt: value.occurredAt, compatibility: value.compatibility, lifecycle: value.lifecycle, attempt: value.attempt, role: value.role, outcome: value.outcome, tokens: value.tokens, evidenceLimitations: value.evidenceLimitations)
    }

    private func compatibility(mode: String = "interactive", concurrency: Int = 2) -> ActivityReceiptCompatibility {
        .init(source: .claudeCode, adapterSchema: ActivityReceiptParser.claudeSchema, clientVersion: ActivityReceiptParser.claudeClientVersion, model: "claude-sonnet-4", mode: mode, concurrency: concurrency, tokenSemantics: ActivityReceiptParser.claudeTokenSemantics)
    }

    private func attribute(_ key: String, _ value: [String: Any]) -> [String: Any] { ["key": key, "value": value] }
    private func string(_ value: String) -> [String: Any] { ["stringValue": value] }
    private func int(_ value: Int64) -> [String: Any] { ["intValue": String(value)] }
    private func bool(_ value: Bool) -> [String: Any] { ["boolValue": value] }
    private func temporaryDatabaseURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite") }
}
