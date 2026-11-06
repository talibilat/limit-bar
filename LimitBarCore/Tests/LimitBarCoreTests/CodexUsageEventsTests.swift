import Foundation
import Testing
@testable import LimitBarCore

@Suite("Codex usage events")
struct CodexUsageEventsTests {
    private func line(_ stamp: String, total: (Int, Int), last: (Int, Int)) -> String {
        """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(total.0),"output_tokens":\(total.1)},"last_token_usage":{"input_tokens":\(last.0),"output_tokens":\(last.1)}}}}
        """
    }

    private let context = #"{"timestamp":"2026-11-02T09:00:00.000Z","type":"turn_context","payload":{"model":"gpt-test"}}"#

    @Test("each request is billed once: repeated ticks and zero markers are ignored")
    func requestsBilledOnce() {
        let text = [
            context,
            line("2026-11-02T09:00:01.000Z", total: (30, 10), last: (30, 10)),
            line("2026-11-02T09:00:02.000Z", total: (30, 10), last: (30, 10)),
            line("2026-11-02T09:00:03.000Z", total: (130, 60), last: (100, 50)),
            line("2026-11-02T09:00:04.000Z", total: (130, 60), last: (0, 0))
        ].joined(separator: "\n")
        let events = CodexUsageEventParser.events(from: Data(text.utf8))
        #expect(events.map(\.inputTokens) == [30, 100])
        #expect(events.map(\.outputTokens) == [10, 50])
        #expect(events.allSatisfy { $0.model == "gpt-test" })
    }

    @Test("history copied by a forked session is not counted again")
    func forkCopiesIgnored() {
        let meta = #"{"timestamp":"2026-11-02T09:00:00.000Z","type":"session_meta","payload":{"id":"a","forked_from_id":"b"}}"#
        let text = [
            meta, context,
            line("2026-11-02T09:00:00.100Z", total: (5_000, 400), last: (200, 20)),
            line("2026-11-02T09:00:00.200Z", total: (5_200, 420), last: (200, 20)),
            line("2026-11-02T09:00:10.000Z", total: (5_300, 450), last: (100, 30))
        ].joined(separator: "\n")
        let events = CodexUsageEventParser.events(from: Data(text.utf8))
        #expect(events.map(\.inputTokens) == [100])
        #expect(events.map(\.outputTokens) == [30])
    }

    @Test("a restarted counter bills the new request, and events without a model are skipped")
    func restartedCounters() {
        let text = [
            line("2026-11-02T08:59:00.000Z", total: (10, 1), last: (10, 1)),
            context,
            line("2026-11-02T09:00:01.000Z", total: (100, 10), last: (100, 10)),
            line("2026-11-02T09:05:00.000Z", total: (40, 4), last: (40, 4))
        ].joined(separator: "\n")
        let events = CodexUsageEventParser.events(from: Data(text.utf8))
        #expect(events.map(\.inputTokens) == [100, 40])
    }

    @Test("CODEX_HOME overrides the default folder and ~ expands to the home directory")
    func codexHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(LimitBarFileLocations.codexSessionsDirectory(homeDirectory: home).path == "/Users/someone/.codex/sessions")
        #expect(LimitBarFileLocations.codexSessionsDirectory(homeDirectory: home, environment: ["CODEX_HOME": "/data/codex"]).path == "/data/codex/sessions")
        #expect(LimitBarFileLocations.codexSessionsDirectory(homeDirectory: home, environment: ["CODEX_HOME": "~/alt"]).path == "/Users/someone/alt/sessions")
        #expect(LimitBarFileLocations.codexSessionsDirectory(homeDirectory: home, environment: ["CODEX_HOME": "  "]).path == "/Users/someone/.codex/sessions")
    }

    @Test("exporter writes importable events for recent files only")
    func exporter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-export-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions/2026/11/02")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        try [context, line(stamp, total: (10, 2), last: (10, 2))].joined(separator: "\n").write(to: sessions.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out/codex-usage-events.jsonl")
        let exporter = CodexUsageEventExporter()
        let wrote = await exporter.export(sessionsDirectory: root.appendingPathComponent("sessions"), to: output, now: now)
        #expect(wrote)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("\"inputTokens\":10"))
        #expect(text.contains("\"outputTokens\":2"))
    }
}
