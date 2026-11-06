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

    @Test("deltas come from running totals, repeated ticks are ignored, first counter uses the per-call value")
    func deltas() {
        let text = [
            #"{"timestamp":"2026-11-02T09:00:00.000Z","type":"turn_context","payload":{"model":"gpt-test"}}"#,
            line("2026-11-02T09:00:01.000Z", total: (5_000, 100), last: (30, 10)),
            line("2026-11-02T09:00:02.000Z", total: (5_000, 100), last: (30, 10)),
            line("2026-11-02T09:00:03.000Z", total: (5_100, 150), last: (100, 50)),
            line("2026-11-02T09:00:04.000Z", total: (50, 5), last: (50, 5)),
            line("2026-11-02T09:00:05.000Z", total: (80, 9), last: (30, 4))
        ].joined(separator: "\n")
        let events = CodexUsageEventParser.events(from: Data(text.utf8))
        #expect(events.map(\.inputTokens) == [30, 100, 30])
        #expect(events.map(\.outputTokens) == [10, 50, 4])
        #expect(events.allSatisfy { $0.model == "gpt-test" })
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
        try line(stamp, total: (10, 2), last: (10, 2)).write(to: sessions.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out/codex-usage-events.jsonl")
        let exporter = CodexUsageEventExporter()
        let wrote = await exporter.export(sessionsDirectory: root.appendingPathComponent("sessions"), to: output, now: now)
        #expect(wrote)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("\"inputTokens\":10"))
        #expect(text.contains("\"outputTokens\":2"))
    }
}
