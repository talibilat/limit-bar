import Foundation
import Testing
@testable import LimitBarCore

@Suite("Collector CLI integration", .serialized)
struct CollectorCLIIntegrationTests {
    @Test("schema v2 CLI persists imports retries conflicts and independently deleted attribution")
    func schemaV2EndToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activeFile = directory.appendingPathComponent("usage-events.jsonl")
        let databasePath = directory.appendingPathComponent("usage-metrics.sqlite").path
        let unrelatedFiles = ["settings.json", "credentials.marker", "alert-rules.json"].map { directory.appendingPathComponent($0) }
        for (index, file) in unrelatedFiles.enumerated() {
            try Data("unrelated-\(index)".utf8).write(to: file)
        }
        let unrelatedBytes = try unrelatedFiles.map { try Data(contentsOf: $0) }
        let arguments = [
            "--schema-version", "2",
            "--event-id", "00000000-0000-0000-0000-000000000001",
            "--provider", "openAI",
            "--timestamp", "2026-07-15T10:00:00Z",
            "--model", "gpt-5",
            "--input-tokens", "10",
            "--output-tokens", "2",
            "--project-id", "limitbar",
            "--project-label", "LimitBar",
            "--agent-id", "reviewer-1",
            "--agent-label", "Reviewer 1",
            "--output", activeFile.path
        ]

        let accepted = try runCLI(arguments)
        #expect(accepted.status == 0)
        #expect(accepted.stdout == "accepted\n")
        let duplicate = try runCLI(arguments)
        #expect(duplicate.status == 0)
        #expect(duplicate.stdout == "duplicate\n")
        let conflict = try runCLI(arguments.replacing("limitbar", after: "--project-id", with: "other-project"))
        #expect(conflict.status == 65)
        #expect(conflict.stderr.contains("eventIDConflict"))
        #expect(!conflict.stderr.contains("limitbar"))
        #expect(!conflict.stderr.contains("other-project"))

        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T18:00:00Z"))
        let database = UsageDatabase(pathFactory: { databasePath }, localEventsURL: activeFile)
        let imported = await database.snapshot(now: now, calendar: utcCalendar())
        #expect(imported.localImport.validEventCount == 1)
        #expect(imported.attributionBreakdowns.count == 2)
        #expect(imported.attributionBreakdowns.allSatisfy { $0.project?.id == "limitbar" && $0.agent?.id == "reviewer-1" })
        let parentMetrics = imported.metrics
        let activeBytes = try Data(contentsOf: activeFile)
        let deliveryStore = try SQLiteAlertDeliveryStore(path: databasePath)
        let ruleID = UUID(uuidString: "8AB1442A-F507-483A-9D92-756898B8190D")!
        let window = try QuotaWindowIdentity(product: .codex, identifier: "primary", resetBoundary: now.addingTimeInterval(3_600))
        let occurrence = AlertOccurrence(ruleID: ruleID, window: .quota(window), thresholds: [75])
        let reservation = try #require(try deliveryStore.reserve(occurrence, now: now))
        try deliveryStore.markDelivered(reservation, at: now)

        try await database.deleteAllAttributionEvidence(now: now)
        let deleted = await database.snapshot(now: now.addingTimeInterval(1), calendar: utcCalendar())
        #expect(deleted.attributionBreakdowns.isEmpty)
        #expect(deleted.metrics == parentMetrics)
        #expect(try Data(contentsOf: activeFile) == activeBytes)
        for (index, file) in unrelatedFiles.enumerated() {
            #expect(try Data(contentsOf: file) == unrelatedBytes[index])
        }
        #expect(try SQLiteAlertDeliveryStore(path: databasePath).satisfactions(for: ruleID, window: .quota(window)).map(\.threshold) == [75])

        let restarted = UsageDatabase(pathFactory: { databasePath }, localEventsURL: activeFile)
        let afterRestart = await restarted.snapshot(now: now.addingTimeInterval(2), calendar: utcCalendar())
        #expect(afterRestart.attributionBreakdowns.isEmpty)
        #expect(afterRestart.metrics == parentMetrics)
    }

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = packageDirectory.appendingPathComponent(".build/debug/limitbar-collect")
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private extension Array where Element == String {
    func replacing(_ expected: String, after option: String, with replacement: String) -> [String] {
        var result = self
        guard let optionIndex = result.firstIndex(of: option), result.indices.contains(optionIndex + 1), result[optionIndex + 1] == expected else {
            return result
        }
        result[optionIndex + 1] = replacement
        return result
    }
}
