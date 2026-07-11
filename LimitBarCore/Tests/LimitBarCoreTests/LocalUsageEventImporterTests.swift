import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Local usage event importer")
struct LocalUsageEventImporterTests {
    @Test("resolves JSONL path under Application Support")
    func resolvesJSONLPathUnderApplicationSupport() throws {
        let base = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)

        let path = LocalUsageEventImporter.usageEventsURL(applicationSupportDirectory: base)

        #expect(path.path == "/tmp/app-support/LimitBar/usage-events.jsonl")
    }

    @Test("parses valid Azure OpenAI event")
    func parsesValidAzureOpenAIEvent() throws {
        let line = #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","deployment":"team-tools","inputTokens":120,"outputTokens":45}"#

        let event = try LocalUsageEventParser.parseLine(line)

        #expect(event.provider == .azureOpenAI)
        #expect(event.model == "gpt-4.1")
        #expect(event.deployment == "team-tools")
        #expect(event.inputTokens == 120)
        #expect(event.outputTokens == 45)
    }

    @Test("parses fractional second timestamps")
    func parsesFractionalSecondTimestamps() throws {
        let line = #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00.123Z","model":"gpt-4.1","inputTokens":120,"outputTokens":45}"#

        let event = try LocalUsageEventParser.parseLine(line)
        let expectedDate = try date("2026-07-10T10:30:00.123Z")

        #expect(event.timestamp == expectedDate)
    }

    @Test("rejects malformed events")
    func rejectsMalformedEvents() {
        #expect(throws: LocalUsageEventError.self) {
            try LocalUsageEventParser.parseLine("not json")
        }
        #expect(throws: LocalUsageEventError.self) {
            try LocalUsageEventParser.parseLine(#"{"provider":"google","timestamp":"2026-07-10T10:30:00Z","model":"gemini-2.5-pro","inputTokens":1,"outputTokens":2}"#)
        }
        #expect(throws: LocalUsageEventError.self) {
            try LocalUsageEventParser.parseLine(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","inputTokens":-1,"outputTokens":2}"#)
        }
        #expect(throws: LocalUsageEventError.self) {
            try LocalUsageEventParser.parseLine(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","inputTokens":1,"outputTokens":2}"#)
        }
        #expect(throws: LocalUsageEventError.self) {
            try LocalUsageEventParser.parseLine(#"{"provider":"azureOpenAI","timestamp":"not-a-date","model":"gpt-4.1","inputTokens":1,"outputTokens":2}"#)
        }
        #expect(throws: LocalUsageEventError.self) {
            try LocalUsageEventParser.parseLine(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"   ","inputTokens":1,"outputTokens":2}"#)
        }
        #expect(throws: LocalUsageEventError.self) {
            try LocalUsageEventParser.parseLine(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","deployment":"   ","inputTokens":1,"outputTokens":2}"#)
        }
        #expect(throws: LocalUsageEventError.self) {
            try LocalUsageEventParser.parseLine(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","inputTokens":1,"outputTokens":-2}"#)
        }
    }

    @Test("trims labels and ignores unknown fields")
    func trimsLabelsAndIgnoresUnknownFields() throws {
        let event = try LocalUsageEventParser.parseLine(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":" gpt-4.1 ","deployment":" team-tools ","inputTokens":1,"outputTokens":2,"requestID":"ignored"}"#)

        #expect(event.model == "gpt-4.1")
        #expect(event.deployment == "team-tools")
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

        let result = try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)

        #expect(result.validEventCount == 3)
        #expect(result.malformedEvents.count == 1)

        let today = try store.metrics(for: .today).filter { $0.provider == .azureOpenAI }
        #expect(today.count == 2)
        let teamTools = try #require(today.first { $0.deploymentLabel == "team-tools" })
        #expect(teamTools.modelLabel == "gpt-4.1")
        #expect(teamTools.tokenUsage == TokenUsage(inputTokens: 200, outputTokens: 50))
        #expect(teamTools.limitStatus == .unsupportedByProviderAPI)
        let batchReview = try #require(today.first { $0.deploymentLabel == "batch-review" })
        #expect(batchReview.tokenUsage == TokenUsage(inputTokens: 20, outputTokens: 10))

        let week = try store.metrics(for: .currentWeek).filter { $0.provider == .azureOpenAI }
        #expect(week.count == 2)
    }

    @Test("missing JSONL file is a successful empty import")
    func missingJSONLFileIsSuccessfulEmptyImport() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

        let result = try LocalUsageEventImporter.importEvents(from: missing, to: store, now: Date(), calendar: .current)

        #expect(result.validEventCount == 0)
        #expect(result.malformedEvents.isEmpty)
    }

    @Test("repeated import replaces the previous JSONL snapshot")
    func repeatedImportReplacesThePreviousJSONLSnapshot() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let fileURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","deployment":"team-tools","inputTokens":120,"outputTokens":45}"#)
        let now = try date("2026-07-10T18:00:00Z")
        let calendar = try utcCalendar()

        try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        try #"{"provider":"azureOpenAI","timestamp":"2026-07-10T13:30:00Z","model":"gpt-4.1-mini","deployment":"batch-review","inputTokens":20,"outputTokens":10}"#.write(to: fileURL, atomically: true, encoding: .utf8)

        try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)

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

        try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        try FileManager.default.removeItem(at: fileURL)

        let result = try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)

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

        let result = try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: try date("2026-07-10T18:00:00Z"), calendar: try utcCalendar())

        #expect(result.validEventCount == 1)
        #expect(result.malformedEvents.map(\.lineNumber) == [2])
    }

    @Test("invalid UTF-8 line does not prevent later events from importing")
    func invalidUTF8LineDoesNotPreventLaterEventsFromImporting() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let first = Data(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"first","inputTokens":1,"outputTokens":2}"#.utf8)
        let second = Data(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T11:30:00Z","model":"second","inputTokens":3,"outputTokens":4}"#.utf8)
        var data = first
        data.append(0x0A)
        data.append(0xFF)
        data.append(0x0A)
        data.append(second)
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try data.write(to: fileURL)

        let result = try LocalUsageEventImporter.importEvents(
            from: fileURL,
            to: store,
            now: try date("2026-07-10T18:00:00Z"),
            calendar: try utcCalendar()
        )

        #expect(result.validEventCount == 2)
        #expect(result.malformedEvents.map(\.lineNumber) == [2])
        let models = Set(try store.metrics(for: .today).map(\.modelLabel))
        #expect(models == ["first", "second"])
    }

    @Test("malformed diagnostics are bounded without losing the rejected count")
    func malformedDiagnosticsAreBoundedWithoutLosingRejectedCount() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let fileURL = try temporaryFile(contents: Array(repeating: "bad-json", count: 25).joined(separator: "\n"))

        let result = try LocalUsageEventImporter.importEvents(
            from: fileURL,
            to: store,
            now: try date("2026-07-10T18:00:00Z"),
            calendar: try utcCalendar()
        )

        #expect(result.malformedEventCount == 25)
        #expect(result.malformedEvents.count == 20)
        #expect(result.malformedEvents.map(\.lineNumber) == Array(1...20))
    }

    @Test("overlong line is discarded without preventing the next event")
    func overlongLineIsDiscardedWithoutPreventingNextEvent() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let oversizedModel = String(repeating: "a", count: 1_048_576)
        let oversized = #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"\#(oversizedModel)","inputTokens":1,"outputTokens":2}"#
        let valid = #"{"provider":"azureOpenAI","timestamp":"2026-07-10T11:30:00Z","model":"valid","inputTokens":3,"outputTokens":4}"#
        let fileURL = try temporaryFile(contents: oversized + "\n" + valid)

        let result = try LocalUsageEventImporter.importEvents(
            from: fileURL,
            to: store,
            now: try date("2026-07-10T18:00:00Z"),
            calendar: try utcCalendar()
        )

        #expect(result.validEventCount == 1)
        #expect(result.malformedEventCount == 1)
        #expect(result.malformedEvents == [MalformedLocalUsageEvent(lineNumber: 1, reason: String(describing: LocalUsageEventError.lineTooLong))])
        #expect(try store.metrics(for: .today).map(\.modelLabel) == ["valid"])
    }

    @Test("event at the end of today is excluded from today")
    func eventAtEndOfTodayIsExcludedFromToday() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let fileURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-11T00:00:00Z","model":"next-day","inputTokens":1,"outputTokens":2}"#)

        try LocalUsageEventImporter.importEvents(
            from: fileURL,
            to: store,
            now: try date("2026-07-10T18:00:00Z"),
            calendar: try utcCalendar()
        )

        #expect(try store.metrics(for: .today).isEmpty)
        #expect(try store.metrics(for: .currentWeek).map(\.modelLabel) == ["next-day"])
    }

    @Test("file-level import failure preserves the previous JSONL snapshot")
    func fileLevelImportFailurePreservesThePreviousJSONLSnapshot() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let fileURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","inputTokens":120,"outputTokens":45}"#)
        let now = try date("2026-07-10T18:00:00Z")
        let calendar = try utcCalendar()

        try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

        #expect(throws: Error.self) {
            try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        }

        let imported = try store.allMetrics().filter { $0.provider == .azureOpenAI && $0.accountLabel == "Azure OpenAI" }
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.modelLabel == "gpt-4.1" })
    }

    @Test("inaccessible JSONL path preserves the previous snapshot")
    func inaccessibleJSONLPathPreservesPreviousSnapshot() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let initialURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"existing","inputTokens":1,"outputTokens":2}"#)
        let now = try date("2026-07-10T18:00:00Z")
        let calendar = try utcCalendar()
        try LocalUsageEventImporter.importEvents(from: initialURL, to: store, now: now, calendar: calendar)

        let protectedDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: true)
        let protectedFile = protectedDirectory.appendingPathComponent("usage-events.jsonl")
        try Data("valid contents are irrelevant".utf8).write(to: protectedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: protectedDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDirectory.path) }

        #expect(throws: Error.self) {
            try LocalUsageEventImporter.importEvents(from: protectedFile, to: store, now: now, calendar: calendar)
        }

        let imported = try store.allMetrics().filter { $0.provider == .azureOpenAI }
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.modelLabel == "existing" })
    }

    @Test("insert failure rolls back JSONL snapshot replacement")
    func insertFailureRollsBackJSONLSnapshotReplacement() throws {
        let databasePath = temporaryDatabasePath()
        let store = try SQLiteUsageMetricStore(path: databasePath)
        let fileURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"gpt-4.1","inputTokens":120,"outputTokens":45}"#)
        let now = try date("2026-07-10T18:00:00Z")
        let calendar = try utcCalendar()

        try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        try executeSQLite(databasePath: databasePath, sql: """
        CREATE TRIGGER fail_jsonl_insert BEFORE INSERT ON usage_metrics
        WHEN NEW.provider = 'azureOpenAI' AND NEW.account_label = 'Azure OpenAI'
        BEGIN
            SELECT RAISE(ABORT, 'blocked imported metric insert');
        END;
        """)
        try #"{"provider":"azureOpenAI","timestamp":"2026-07-10T13:30:00Z","model":"gpt-4.1-mini","inputTokens":20,"outputTokens":10}"#.write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(throws: Error.self) {
            try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        }

        let imported = try store.allMetrics().filter { $0.provider == .azureOpenAI && $0.accountLabel == "Azure OpenAI" }
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.modelLabel == "gpt-4.1" })
    }

    @Test("token aggregation overflow fails without replacing the previous snapshot")
    func tokenAggregationOverflowFailsWithoutReplacingPreviousSnapshot() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let now = try date("2026-07-10T18:00:00Z")
        let calendar = try utcCalendar()
        let fileURL = try temporaryFile(contents: #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:30:00Z","model":"existing","inputTokens":1,"outputTokens":1}"#)
        try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        let overflowing = [
            #"{"provider":"azureOpenAI","timestamp":"2026-07-10T11:30:00Z","model":"overflow","inputTokens":\#(Int.max),"outputTokens":0}"#,
            #"{"provider":"azureOpenAI","timestamp":"2026-07-10T12:30:00Z","model":"overflow","inputTokens":1,"outputTokens":0}"#
        ].joined(separator: "\n")
        try overflowing.write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(throws: LocalUsageEventError.self) {
            try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: calendar)
        }

        let imported = try store.allMetrics().filter { $0.provider == .azureOpenAI }
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.modelLabel == "existing" })
    }

    @Test("parses Anthropic and OpenAI events")
    func parsesAnthropicAndOpenAIEvents() throws {
        let anthropic = try LocalUsageEventParser.parseLine(#"{"provider":"anthropic","timestamp":"2026-07-10T10:30:00Z","model":"claude-fable-5","inputTokens":300,"outputTokens":40}"#)
        #expect(anthropic.provider == .anthropic)
        #expect(anthropic.model == "claude-fable-5")

        let openAI = try LocalUsageEventParser.parseLine(#"{"provider":"openAI","timestamp":"2026-07-10T10:31:00Z","model":"gpt-5.5","inputTokens":100,"outputTokens":20}"#)
        #expect(openAI.provider == .openAI)
        #expect(openAI.model == "gpt-5.5")
    }

    @Test("aggregates events per provider and model")
    func aggregatesEventsPerProviderAndModel() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let jsonl = [
            #"{"provider":"anthropic","timestamp":"2026-07-10T10:30:00Z","model":"claude-fable-5","inputTokens":300,"outputTokens":40}"#,
            #"{"provider":"anthropic","timestamp":"2026-07-10T11:30:00Z","model":"claude-fable-5","inputTokens":100,"outputTokens":10}"#,
            #"{"provider":"openAI","timestamp":"2026-07-10T10:31:00Z","model":"gpt-5.5","inputTokens":100,"outputTokens":20}"#,
            #"{"provider":"openAI","timestamp":"2026-07-10T10:32:00Z","model":"gpt-5.6","inputTokens":50,"outputTokens":5}"#,
            #"{"provider":"azureOpenAI","timestamp":"2026-07-10T10:33:00Z","model":"gpt-4.1","inputTokens":20,"outputTokens":2}"#
        ].joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)
        let now = try date("2026-07-10T18:00:00Z")

        let result = try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: utcCalendar())

        #expect(result.validEventCount == 5)
        #expect(result.malformedEventCount == 0)

        let today = try store.metrics(for: .today)
        let anthropic = try #require(today.first { $0.provider == .anthropic })
        #expect(anthropic.modelLabel == "claude-fable-5")
        #expect(anthropic.accountLabel == "Local logs")
        #expect(anthropic.tokenUsage == TokenUsage(inputTokens: 400, outputTokens: 50))

        let openAIModels = today.filter { $0.provider == .openAI }.map(\.modelLabel).sorted()
        #expect(openAIModels == ["gpt-5.5", "gpt-5.6"])

        let azure = try #require(today.first { $0.provider == .azureOpenAI })
        #expect(azure.accountLabel == "Azure OpenAI")
    }

    @Test("local metrics coexist with provider API metrics")
    func localMetricsCoexistWithProviderAPIMetrics() throws {
        let store = try SQLiteUsageMetricStore.inMemory()
        let now = try date("2026-07-10T18:00:00Z")
        let apiMetric = UsageMetric(
            provider: .anthropic,
            accountLabel: nil,
            projectLabel: nil,
            modelLabel: "claude-fable-5",
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 999, outputTokens: 99),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: now,
            freshness: .fresh
        )
        try store.save([apiMetric])
        let fileURL = try temporaryFile(contents: #"{"provider":"anthropic","timestamp":"2026-07-10T10:30:00Z","model":"claude-fable-5","inputTokens":300,"outputTokens":40}"#)

        try LocalUsageEventImporter.importEvents(from: fileURL, to: store, now: now, calendar: utcCalendar())

        let anthropicToday = try store.metrics(for: .today).filter { $0.provider == .anthropic }
        #expect(anthropicToday.count == 2)
        #expect(anthropicToday.contains { $0.accountLabel == nil && $0.tokenUsage.inputTokens == 999 })
        #expect(anthropicToday.contains { $0.accountLabel == "Local logs" && $0.tokenUsage.inputTokens == 300 })

        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try LocalUsageEventImporter.importEvents(from: missing, to: store, now: now, calendar: utcCalendar())

        let afterClear = try store.metrics(for: .today).filter { $0.provider == .anthropic }
        #expect(afterClear.count == 1)
        #expect(afterClear.first?.accountLabel == nil)
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
