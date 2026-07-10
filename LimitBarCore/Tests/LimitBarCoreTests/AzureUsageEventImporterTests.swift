import Foundation
import SQLite3
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

    @Test("parses fractional second timestamps")
    func parsesFractionalSecondTimestamps() throws {
        let line = #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00.123Z","model":"gpt-4.1","inputTokens":120,"outputTokens":45}"#

        let event = try AzureUsageEventParser.parseLine(line)
        let expectedDate = try date("2026-07-10T10:30:00.123Z")

        #expect(event.timestamp == expectedDate)
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

    @Test("repeated import replaces the previous JSONL snapshot")
    func repeatedImportReplacesThePreviousJSONLSnapshot() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let fileURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","deployment":"team-tools","inputTokens":120,"outputTokens":45}"#)
        let now = try date("2026-07-10T18:00:00Z")
        let calendar = try utcCalendar()

        try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        try #"{"provider":"azureOpenAI","timestamp":"2026-07-10T13:30:00Z","model":"gpt-4.1-mini","deployment":"batch-review","inputTokens":20,"outputTokens":10}"#.write(to: fileURL, atomically: true, encoding: .utf8)

        try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)

        let imported = try store.allMetrics().filter { $0.provider == .azureOpenAI && $0.accountLabel == "Azure OpenAI" }
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.modelLabel == "gpt-4.1-mini" })
        #expect(imported.allSatisfy { $0.tokenUsage.totalTokens == 30 })
    }

    @Test("missing JSONL file clears the previous JSONL snapshot")
    func missingJSONLFileClearsThePreviousJSONLSnapshot() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let fileURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","deployment":"team-tools","inputTokens":120,"outputTokens":45}"#)
        let now = try date("2026-07-10T18:00:00Z")
        let calendar = try utcCalendar()

        try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        try FileManager.default.removeItem(at: fileURL)

        let result = try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)

        #expect(result.validEventCount == 0)
        let imported = try store.allMetrics().filter { $0.provider == .azureOpenAI && $0.accountLabel == "Azure OpenAI" }
        #expect(imported.isEmpty)
    }

    @Test("blank lines do not shift malformed line diagnostics")
    func blankLinesDoNotShiftMalformedLineDiagnostics() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let jsonl = [
            "",
            "bad-json",
            #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","inputTokens":1,"outputTokens":2}"#
        ].joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)

        let result = try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: try date("2026-07-10T18:00:00Z"), calendar: try utcCalendar())

        #expect(result.validEventCount == 1)
        #expect(result.malformedEvents.map(\.lineNumber) == [2])
    }

    @Test("file-level import failure preserves the previous JSONL snapshot")
    func fileLevelImportFailurePreservesThePreviousJSONLSnapshot() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let fileURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","inputTokens":120,"outputTokens":45}"#)
        let now = try date("2026-07-10T18:00:00Z")
        let calendar = try utcCalendar()

        try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

        #expect(throws: Error.self) {
            try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        }

        let imported = try store.allMetrics().filter { $0.provider == .azureOpenAI && $0.accountLabel == "Azure OpenAI" }
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.modelLabel == "gpt-4.1" })
    }

    @Test("insert failure rolls back JSONL snapshot replacement")
    func insertFailureRollsBackJSONLSnapshotReplacement() throws {
        let databasePath = temporaryDatabasePath()
        let store = try SQLiteUsageMetricStore(path: databasePath)
        let fileURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","inputTokens":120,"outputTokens":45}"#)
        let now = try date("2026-07-10T18:00:00Z")
        let calendar = try utcCalendar()

        try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        try executeSQLite(databasePath: databasePath, sql: """
        CREATE TRIGGER fail_jsonl_insert BEFORE INSERT ON usage_metrics
        WHEN NEW.provider = 'azureOpenAI' AND NEW.account_label = 'Azure OpenAI'
        BEGIN
            SELECT RAISE(ABORT, 'blocked imported metric insert');
        END;
        """)
        try #"{"provider":"azureOpenAI","timestamp":"2026-07-10T13:30:00Z","model":"gpt-4.1-mini","inputTokens":20,"outputTokens":10}"#.write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(throws: Error.self) {
            try AzureUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        }

        let imported = try store.allMetrics().filter { $0.provider == .azureOpenAI && $0.accountLabel == "Azure OpenAI" }
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.modelLabel == "gpt-4.1" })
    }

    private func temporaryFile(contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func temporaryDatabasePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).sqlite").path
    }

    private func executeSQLite(databasePath: String, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databasePath, &database) == SQLITE_OK else {
            throw UsageMetricStoreError.openFailed("Could not open test database")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageMetricStoreError.executeFailed("Could not execute test SQL")
        }
    }

    private func date(_ iso8601: String) throws -> Date {
        let standardFormatter = ISO8601DateFormatter()
        if let date = standardFormatter.date(from: iso8601) {
            return date
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(fractionalFormatter.date(from: iso8601))
    }

    private func utcCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        return calendar
    }
}
