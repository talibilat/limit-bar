import Foundation
import Testing
@testable import LimitBarCore

@Suite("Codex rollout evidence")
struct CodexRolloutEvidenceTests {
    @Test("observed 0.144.4 rollout yields one validated local transition")
    func canonicalTransition() throws {
        let sentinel = "PROHIBITED-prompt-path-credential"
        let data = rollout([
            #"{"timestamp":"2026-07-15T10:00:00.000Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4","cwd":"\#(sentinel)","instructions":"\#(sentinel)"}}"#,
            tokenLine(at: "2026-07-15T10:01:00.000Z", total: usage(input: 10, cached: 2, output: 4, reasoning: 1), last: usage(input: 10, cached: 2, output: 4, reasoning: 1), extra: sentinel),
            tokenLine(at: "2026-07-15T10:02:00.000Z", total: usage(input: 17, cached: 5, output: 9, reasoning: 3), last: usage(input: 7, cached: 3, output: 5, reasoning: 2), extra: sentinel)
        ])

        let result = CodexRolloutEvidenceAdapter.scan(data: data, identityKey: Data("local-test-key".utf8))

        #expect(result.adapterVersion == "codex-rollout-observed-0.144.4")
        #expect(result.confidence == .observedCompatible)
        #expect(result.creatorVersion == "0.144.4")
        #expect(result.evidence.count == 1)
        #expect(result.evidence[0].lineOrdinal == 3)
        #expect(result.evidence[0].tokens == CodexMeasuredTokens(input: 7, cachedInput: 3, output: 5, reasoningOutput: 2))
        #expect(result.evidence[0].lineSHA256.count == 64)
        #expect(result.evidence[0].sessionIdentity.count == 64)
        #expect(result.barriers.isEmpty)
        #expect(!String(describing: result).contains(sentinel))
    }

    @Test("explicit null token info interrupts coverage before later activity")
    func explicitNullTokenInfoIsCoverageBarrier() {
        let data = rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", total: usage(input: 1, output: 1), last: usage(input: 1, output: 1)),
            #"{"timestamp":"2026-07-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#,
            tokenLine(at: "2026-07-15T10:03:00Z", total: usage(input: 2, output: 2), last: usage(input: 1, output: 1))
        ])

        let result = CodexRolloutEvidenceAdapter.scan(data: data, identityKey: Data("key".utf8))

        #expect(result.evidence.isEmpty)
        #expect(result.barriers == [.unsupportedVariant])
        #expect(result.coverageStart != nil)
        #expect(result.coverageEnd != nil)
    }

    @Test("unsupported creator version fails closed")
    func unsupportedVersion() {
        let data = rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.145.0"}}"#
        ])

        let result = CodexRolloutEvidenceAdapter.scan(data: data, identityKey: Data("key".utf8))

        #expect(result.evidence.isEmpty)
        #expect(result.barriers == [.unsupportedVersionOrMixedAuthorship])
    }

    @Test("empty rollout fails closed")
    func emptyRolloutFailsClosed() {
        let result = CodexRolloutEvidenceAdapter.scan(data: Data(), identityKey: Data("key".utf8))

        #expect(result.evidence.isEmpty)
        #expect(result.barriers == [.malformedRecord])
    }

    @Test("unterminated final record is ignored until LF arrives")
    func partialFinalRecord() {
        let metadata = #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#
        let baseline = tokenLine(at: "2026-07-15T10:01:00Z", total: usage(input: 1, output: 1), last: usage(input: 1, output: 1))
        let transition = tokenLine(at: "2026-07-15T10:02:00Z", total: usage(input: 2, output: 3), last: usage(input: 1, output: 2))

        let partial = CodexRolloutEvidenceAdapter.scan(data: Data((metadata + "\n" + baseline + "\n" + transition).utf8), identityKey: Data("key".utf8))
        let complete = CodexRolloutEvidenceAdapter.scan(data: Data((metadata + "\n" + baseline + "\n" + transition + "\n").utf8), identityKey: Data("key".utf8))

        #expect(partial.evidence.isEmpty)
        #expect(complete.evidence.count == 1)
    }

    @Test("all documented info and rate-limit nullability variants are accepted without private field retention")
    func nullabilityVariants() {
        let sentinel = "PROHIBITED-response-path-git"
        let data = rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4","cwd":"\#(sentinel)"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", info: "null", rateLimits: "null", extra: sentinel),
            tokenLine(at: "2026-07-15T10:02:00Z", info: "null", rateLimits: rateLimits(percent: 5, reset: 1_783_716_600), extra: sentinel),
            tokenLine(at: "2026-07-15T10:03:00Z", info: info(total: usage(input: 1, cached: 1, output: 2, reasoning: 1), last: usage(input: 1, cached: 1, output: 2, reasoning: 1)), rateLimits: "null", extra: sentinel),
            tokenLine(at: "2026-07-15T10:04:00Z", info: info(total: usage(input: 1, cached: 1, output: 2, reasoning: 1), last: usage(input: 0, output: 0)), rateLimits: rateLimits(percent: 6, reset: 1_783_716_600), extra: sentinel)
        ])

        let result = CodexRolloutEvidenceAdapter.scan(data: data, identityKey: Data("key".utf8))

        #expect(result.quotaSnapshots.count == 2)
        #expect(result.evidence.map(\.tokens) == [CodexMeasuredTokens(input: 0, cachedInput: 0, output: 0, reasoningOutput: 0)])
        #expect(result.barriers.isEmpty)
        #expect(!String(describing: result).contains(sentinel))
    }

    @Test("missing token_count keys are incompatible while explicit null remains supported")
    func missingTokenCountKeysAreBarriers() {
        let metadata = #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#
        let missingInfo = rollout([
            metadata,
            #"{"timestamp":"2026-07-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#
        ])
        let missingRateLimits = rollout([
            metadata,
            #"{"timestamp":"2026-07-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#
        ])
        let missingTotal = rollout([
            metadata,
            #"{"timestamp":"2026-07-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":null},"rate_limits":null}}"#
        ])
        let missingLast = rollout([
            metadata,
            #"{"timestamp":"2026-07-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":null},"rate_limits":null}}"#
        ])
        let explicitNullNested = rollout([
            metadata,
            #"{"timestamp":"2026-07-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":null,"last_token_usage":null,"model_context_window":null},"rate_limits":null}}"#
        ])

        for data in [missingInfo, missingRateLimits, missingTotal, missingLast, explicitNullNested] {
            let result = CodexRolloutEvidenceAdapter.scan(data: data, identityKey: Data("key".utf8))
            #expect(result.barriers == [.unsupportedVariant])
            #expect(result.coverageStart == nil)
            #expect(result.coverageEnd == nil)
        }
    }

    @Test("rate-limit limit_id participates in exact quota identity")
    func rateLimitIDParticipatesInIdentity() throws {
        let data = rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", info: "null", rateLimits: rateLimits(limitID: "codex", percent: 5, reset: 1_783_716_600)),
            tokenLine(at: "2026-07-15T10:02:00Z", info: "null", rateLimits: rateLimits(limitID: "team", percent: 6, reset: 1_783_716_600))
        ])

        let result = CodexRolloutEvidenceAdapter.scan(data: data, identityKey: Data("key".utf8))
        let codexWindow = try #require(result.quotaSnapshots.first?.primary)
        let teamWindow = try #require(result.quotaSnapshots.last?.primary)

        #expect(QuotaWindowIdentity.codex(slot: "primary", window: codexWindow)?.identifier == "codex:primary:300")
        #expect(QuotaWindowIdentity.codex(slot: "primary", window: teamWindow)?.identifier == "team:primary:300")
    }

    @Test("malformed and unsupported records are barriers and token deltas are not bridged across them")
    func barriersDoNotBridge() {
        let data = rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", total: usage(input: 10, output: 1), last: usage(input: 10, output: 1)),
            #"{"timestamp":"2026-07-15T10:01:30Z","type":"event_msg","payload":{"type":"agent_message","message":"PROHIBITED-prompt"}}"#,
            tokenLine(at: "2026-07-15T10:02:00Z", total: usage(input: 15, output: 3), last: usage(input: 5, output: 2))
        ])

        let result = CodexRolloutEvidenceAdapter.scan(data: data, identityKey: Data("key".utf8))

        #expect(result.evidence.isEmpty)
        #expect(result.barriers == [.unsupportedVariant])
        #expect(!String(describing: result).contains("PROHIBITED-prompt"))
    }

    @Test("synthetic and inconsistent token shapes become typed barriers")
    func unsafeTokenShapes() {
        let estimated = rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", total: usage(input: 10, output: 1), last: usage(input: 10, output: 1)),
            tokenLine(at: "2026-07-15T10:02:00Z", total: rawUsage(input: 10, cached: 0, output: 1, reasoning: 0, total: 100), last: rawUsage(input: 0, cached: 0, output: 0, reasoning: 0, total: 89))
        ])
        let mismatch = rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", total: usage(input: 10, output: 1), last: usage(input: 10, output: 1)),
            tokenLine(at: "2026-07-15T10:02:00Z", total: usage(input: 12, output: 2), last: usage(input: 1, output: 1))
        ])
        let decrease = rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", total: usage(input: 10, output: 1), last: usage(input: 10, output: 1)),
            tokenLine(at: "2026-07-15T10:02:00Z", total: usage(input: 9, output: 1), last: usage(input: 0, output: 0))
        ])

        #expect(CodexRolloutEvidenceAdapter.scan(data: estimated, identityKey: Data("key".utf8)).barriers == [.invalidTokenState])
        #expect(CodexRolloutEvidenceAdapter.scan(data: mismatch, identityKey: Data("key".utf8)).barriers == [.mismatchedTokenDelta])
        #expect(CodexRolloutEvidenceAdapter.scan(data: decrease, identityKey: Data("key".utf8)).barriers == [.tokenCounterDecreased])
    }

    @Test("reader exposes unsupported compression as a coverage gap")
    func compressedRolloutIsCoverageGap() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try Data("compressed".utf8).write(to: root.appendingPathComponent("rollout.jsonl.zst"))

        let publication = try CodexSessionEvidenceReader.scan(sessionsDirectory: root, now: Date(), identityKey: Data("key".utf8), fileManager: fileManager)

        #expect(publication.snapshot == nil)
        #expect(publication.evidence.isEmpty)
        #expect(publication.barriers == [.unsupportedCompression])
    }

    @Test("old and future quota records from recent files do not drive explanation")
    func staleAndFutureQuotaRecordsDoNotDriveExplanation() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-01T10:01:00Z", info: "null", rateLimits: rateLimits(percent: 5, reset: 1_783_716_600)),
            tokenLine(at: "2026-07-15T10:10:01Z", info: "null", rateLimits: rateLimits(percent: 6, reset: 1_783_716_600))
        ]).write(to: root.appendingPathComponent("rollout.jsonl"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T10:00:00Z"))

        let publication = try CodexSessionEvidenceReader.scan(sessionsDirectory: root, now: now, identityKey: Data("key".utf8), fileManager: fileManager)

        #expect(publication.snapshot == nil)
        #expect(publication.explanation == .unavailable(.insufficientObservations))
    }

    @Test("recent expired quota windows do not become available explanations")
    func expiredQuotaWindowDoesNotExplain() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try rollout([
            #"{"timestamp":"2026-07-15T09:59:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:00:00Z", info: "null", rateLimits: rateLimits(percent: 5, reset: 1_784_109_690)),
            tokenLine(at: "2026-07-15T10:01:00Z", info: "null", rateLimits: rateLimits(percent: 6, reset: 1_784_109_690))
        ]).write(to: root.appendingPathComponent("rollout.jsonl"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T10:02:00Z"))

        let publication = try CodexSessionEvidenceReader.scan(sessionsDirectory: root, now: now, identityKey: Data("key".utf8), fileManager: fileManager)

        #expect(publication.snapshot?.primary?.percentUsed == 6)
        #expect(publication.explanation == .unavailable(.expiredQuotaWindow))
    }

    @Test("reader rejects a sessions directory reached through a symbolic-link parent")
    func rejectsSymlinkedSessionsParent() throws {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = parent.appendingPathComponent("target", isDirectory: true)
        let sessions = target.appendingPathComponent("sessions", isDirectory: true)
        let linkedParent = parent.appendingPathComponent("linked", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: parent) }
        try rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", info: "null", rateLimits: rateLimits(percent: 5, reset: 1_783_716_600))
        ]).write(to: sessions.appendingPathComponent("rollout.jsonl"))
        try fileManager.createSymbolicLink(at: linkedParent, withDestinationURL: target)

        #expect(throws: CodexRateLimitFailure.notFound) {
            try CodexSessionEvidenceReader.scan(
                sessionsDirectory: linkedParent.appendingPathComponent("sessions", isDirectory: true),
                now: Date(),
                identityKey: Data("key".utf8),
                fileManager: fileManager
            )
        }
    }

    @Test("reader never follows a file symlink outside the configured sessions boundary")
    func rejectsFileSymlinkOutsideBoundary() throws {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = parent.appendingPathComponent("sessions", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.jsonl")
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: parent) }
        try rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", info: "null", rateLimits: rateLimits(percent: 5, reset: 1_783_716_600))
        ]).write(to: outside)
        try fileManager.createSymbolicLink(at: sessions.appendingPathComponent("linked.jsonl"), withDestinationURL: outside)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T10:02:00Z"))

        #expect(throws: CodexRateLimitFailure.notFound) {
            try CodexSessionEvidenceReader.scan(
                sessionsDirectory: sessions,
                now: now,
                identityKey: Data("key".utf8),
                fileManager: fileManager
            )
        }
    }

    @Test("reader recursively consumes a regular JSONL file in any in-boundary subdirectory")
    func consumesNestedInBoundaryFileWithoutArchiveSemantics() throws {
        let fileManager = FileManager.default
        let sessions = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = sessions.appendingPathComponent("archived_sessions", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sessions) }
        try rollout([
            #"{"timestamp":"2026-07-15T10:00:00Z","type":"session_meta","payload":{"session_id":"11111111-1111-4111-8111-111111111111","id":"22222222-2222-4222-8222-222222222222","cli_version":"0.144.4"}}"#,
            tokenLine(at: "2026-07-15T10:01:00Z", info: "null", rateLimits: rateLimits(percent: 5, reset: 1_784_109_600))
        ]).write(to: nested.appendingPathComponent("rollout.jsonl"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T10:02:00Z"))

        let publication = try CodexSessionEvidenceReader.scan(
            sessionsDirectory: sessions,
            now: now,
            identityKey: Data("key".utf8),
            fileManager: fileManager
        )

        #expect(publication.snapshot?.primary?.percentUsed == 5)
    }
}

private func rollout(_ lines: [String]) -> Data {
    Data((lines.joined(separator: "\n") + "\n").utf8)
}

private func usage(input: Int64, cached: Int64 = 0, output: Int64, reasoning: Int64 = 0) -> String {
    #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)}"#
}

private func rawUsage(input: Int64, cached: Int64, output: Int64, reasoning: Int64, total: Int64) -> String {
    #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)}"#
}

private func info(total: String, last: String) -> String {
    #"{"total_token_usage":\#(total),"last_token_usage":\#(last),"model_context_window":null}"#
}

private func rateLimits(limitID: String = "codex", percent: Double, reset: Int) -> String {
    #"{"limit_id":"\#(limitID)","limit_name":null,"primary":{"used_percent":\#(percent),"window_minutes":300,"resets_at":\#(reset)},"secondary":null,"credits":null,"individual_limit":null,"plan_type":"plus","rate_limit_reached_type":null}"#
}

private func tokenLine(at timestamp: String, total: String, last: String, extra: String = "") -> String {
    tokenLine(at: timestamp, info: info(total: total, last: last), rateLimits: "null", extra: extra)
}

private func tokenLine(at timestamp: String, info: String, rateLimits: String, extra: String = "") -> String {
    #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":\#(info),"rate_limits":\#(rateLimits),"response":"\#(extra)"}}"#
}
