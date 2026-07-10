import Foundation
import Testing
@testable import LimitBarCore

@Suite("Azure usage event importer")
struct AzureUsageEventImporterTests {
    @Test("resolves JSONL path under Application Support")
    func resolvesJSONLPathUnderApplicationSupport() throws {
        let base = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)

        let path = AzureUsageEventImporter.usageEventsURL(applicationSupportDirectory: base)

        #expect(path.path == "/tmp/app-support/LimitBar/usage-events.jsonl")
    }

    @Test("parses valid Azure OpenAI event")
    func parsesValidAzureOpenAIEvent() throws {
        let line = #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","deployment":"team-tools","inputTokens":120,"outputTokens":45}"#

        let event = try AzureUsageEventParser.parseLine(line)

        #expect(event.provider == .azureOpenAI)
        #expect(event.model == "gpt-4.1")
        #expect(event.deployment == "team-tools")
        #expect(event.inputTokens == 120)
        #expect(event.outputTokens == 45)
    }

    @Test("rejects malformed events")
    func rejectsMalformedEvents() {
        #expect(throws: AzureUsageEventError.self) {
            try AzureUsageEventParser.parseLine("not json")
        }
        #expect(throws: AzureUsageEventError.self) {
            try AzureUsageEventParser.parseLine(#"{"provider":"openAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","inputTokens":1,"outputTokens":2}"#)
        }
        #expect(throws: AzureUsageEventError.self) {
            try AzureUsageEventParser.parseLine(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","inputTokens":-1,"outputTokens":2}"#)
        }
        #expect(throws: AzureUsageEventError.self) {
            try AzureUsageEventParser.parseLine(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","inputTokens":1,"outputTokens":2}"#)
        }
    }

    @Test("imports valid events and reports malformed lines")
    func importsValidEventsAndReportsMalformedLines() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let jsonl = [
            #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","deployment":"team-tools","inputTokens":120,"outputTokens":45}"#,
            #"{"provider":"azureOpenAI","timestamp":"2026-07-10T12:30:00Z","model":"gpt-4.1","deployment":"team-tools","inputTokens":80,"outputTokens":5}"#,
            #"{"provider":"azureOpenAI","timestamp":"2026-07-10T13:30:00Z","model":"gpt-4.1","deployment":"batch-review","inputTokens":20,"outputTokens":10}"#,
            "bad-json"
        ].joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)
        let now = try date("2026-07-10T18:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2

        let result = try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)

        #expect(result.validEventCount == 3)
        #expect(result.malformedEvents.count == 1)

        let today = try #require(try store.metrics(for: .today).first { $0.provider == .azureOpenAI })
        #expect(today.modelLabel == "gpt-4.1")
        #expect(today.deploymentLabel == "batch-review, team-tools")
        #expect(today.tokenUsage.inputTokens == 220)
        #expect(today.tokenUsage.outputTokens == 60)
        #expect(today.limitStatus == .unsupportedByProviderAPI)

        let week = try #require(try store.metrics(for: .currentWeek).first { $0.provider == .azureOpenAI })
        #expect(week.tokenUsage.totalTokens == 280)
    }

    @Test("missing JSONL file is a successful empty import")
    func missingJSONLFileIsSuccessfulEmptyImport() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

        let result = try AzureUsageEventImporter.importEvents(from: missing, to: store, now: Date(), calendar: .current)

        #expect(result.validEventCount == 0)
        #expect(result.malformedEvents.isEmpty)
    }

    private func temporaryFile(contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func date(_ iso8601: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso8601))
    }
}
