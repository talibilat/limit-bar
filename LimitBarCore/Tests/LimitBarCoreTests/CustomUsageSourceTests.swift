import Foundation
import Testing
@testable import LimitBarCore

@Suite("Custom usage source")
struct CustomUsageSourceTests {
    @Test("parses a minimal event with only timestamp, model, and tokens")
    func parsesMinimalEvent() throws {
        let line = #"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}"#

        let event = try CustomUsageEventParser.parseLine(line)

        #expect(event.model == "gpt-4o")
        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 20)
    }

    @Test("rejects missing fields and negative tokens")
    func rejectsInvalidEvents() {
        #expect(throws: CustomUsageEventError.self) {
            try CustomUsageEventParser.parseLine("not json")
        }
        #expect(throws: CustomUsageEventError.self) {
            try CustomUsageEventParser.parseLine(#"{"timestamp":"2026-07-12T10:00:00Z","inputTokens":1,"outputTokens":2}"#)
        }
        #expect(throws: CustomUsageEventError.self) {
            try CustomUsageEventParser.parseLine(#"{"timestamp":"2026-07-12T10:00:00Z","model":"x","inputTokens":-1,"outputTokens":2}"#)
        }
    }

    @Test("aggregates events per model and time window under the source's name")
    func aggregatesEventsUnderSourceName() throws {
        let jsonl = [
            #"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}"#,
            #"{"timestamp":"2026-07-12T11:00:00Z","model":"gpt-4o","inputTokens":50,"outputTokens":5}"#,
            #"{"timestamp":"2026-07-12T12:00:00Z","model":"claude-fable-5","inputTokens":10,"outputTokens":1}"#
        ].joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)
        let now = try date("2026-07-12T18:00:00Z")

        let metrics = CustomUsageAggregator.metrics(from: fileURL, sourceName: "Aider", now: now, calendar: utcCalendar())

        let today = metrics.filter { $0.timeWindow == .today }
        #expect(today.allSatisfy { $0.provider == .custom && $0.accountLabel == "Aider" })
        let gpt4o = try #require(today.first { $0.modelLabel == "gpt-4o" })
        #expect(gpt4o.tokenUsage == TokenUsage(inputTokens: 150, outputTokens: 25))
        let claude = try #require(today.first { $0.modelLabel == "claude-fable-5" })
        #expect(claude.tokenUsage == TokenUsage(inputTokens: 10, outputTokens: 1))
    }

    @Test("a missing file produces no metrics instead of an error")
    func missingFileProducesNoMetrics() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

        let metrics = CustomUsageAggregator.metrics(from: missing, sourceName: "Aider", now: Date(), calendar: .current)

        #expect(metrics.isEmpty)
    }

    @Test("malformed lines are skipped without failing the whole source")
    func malformedLinesAreSkipped() throws {
        let jsonl = [
            #"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}"#,
            "not json at all"
        ].joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)
        let now = try date("2026-07-12T18:00:00Z")

        let metrics = CustomUsageAggregator.metrics(from: fileURL, sourceName: "Aider", now: now, calendar: utcCalendar())

        // One valid event, aggregated into both the Today and Current Week windows it falls in.
        #expect(metrics.count == 2)
        #expect(metrics.allSatisfy { $0.modelLabel == "gpt-4o" })
    }

    private func temporaryFile(contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func date(_ iso8601: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso8601))
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
