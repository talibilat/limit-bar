import CryptoKit
import Foundation
import Testing
@testable import LimitBarCore

@Suite("Custom usage source")
struct CustomUsageSourceTests {
    @Test("a nonempty source with no valid events fails instead of replacing last-good usage")
    func whollyInvalidSourceFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("invalid.jsonl")
        try "not-json\n{".write(to: file, atomically: true, encoding: .utf8)
        let source = CustomUsageSource(name: "Invalid", filePath: file.path)

        await #expect(throws: CustomUsageLoadError.self) {
            try await CustomUsageAggregator.loadMetrics(from: file, source: source, now: Date(), calendar: .current)
        }
    }

    @Test("a symbolic-link custom file is rejected")
    func symbolicLinkSourceFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.jsonl")
        let link = root.appendingPathComponent("linked.jsonl")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let source = CustomUsageSource(name: "Linked", filePath: link.path)

        await #expect(throws: CustomUsageLoadError.notRegularFile) {
            try await CustomUsageAggregator.loadMetrics(from: link, source: source, now: Date(), calendar: .current)
        }
    }

    @Test("decoding preserves the originally authorized canonical path")
    func decodingDoesNotReauthorizeRedirectedParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authorized = root.appendingPathComponent("authorized", isDirectory: true)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = authorized.appendingPathComponent("usage.jsonl")
        try Data().write(to: file)
        let source = CustomUsageSource(name: "Canonical", filePath: file.path)
        let encoded = try JSONEncoder().encode(source)
        try FileManager.default.moveItem(at: authorized, to: moved)
        try FileManager.default.createSymbolicLink(at: authorized, withDestinationURL: replacement)

        let decoded = try JSONDecoder().decode(CustomUsageSource.self, from: encoded)

        #expect(decoded.filePath == source.filePath)
        #expect(decoded.filePath != replacement.appendingPathComponent("usage.jsonl").path)
    }

    @Test("parses a minimal event with only timestamp, model, and tokens")
    func parsesMinimalEvent() throws {
        let line = #"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}"#

        let event = try CustomUsageEventParser.parseLine(line)

        #expect(event.model == "gpt-4o")
        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 20)
    }

    @Test("legacy custom parser ignores arbitrary schemaVersion and unknown field types")
    func legacyCustomParserRemainsPermissive() throws {
        for fields in [
            #""schemaVersion":"2","unknown":{"private":"sentinel"},"#,
            #""schemaVersion":true,"unknown":[1,2,3],"#,
            #""schemaVersion":{"future":2},"unknown":null,"#,
            #""schemaVersion":2.5,"unknown":false,"#
        ] {
            let event = try CustomUsageEventParser.parseLine("{\(fields)\"timestamp\":\"2026-07-12T10:00:00Z\",\"model\":\"local\",\"inputTokens\":1,\"outputTokens\":2}")
            #expect(event.model == "local")
            #expect(event.project == nil && event.agent == nil)
        }
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
    func aggregatesEventsUnderSourceName() async throws {
        let jsonl = [
            #"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}"#,
            #"{"timestamp":"2026-07-12T11:00:00Z","model":"gpt-4o","inputTokens":50,"outputTokens":5}"#,
            #"{"timestamp":"2026-07-12T12:00:00Z","model":"claude-fable-5","inputTokens":10,"outputTokens":1}"#
        ].joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)
        let now = try date("2026-07-12T18:00:00Z")

        let source = CustomUsageSource(name: "Aider", filePath: fileURL.path)
        let metrics = await CustomUsageAggregator.metrics(from: fileURL, source: source, now: now, calendar: utcCalendar())

        let today = metrics.filter { $0.timeWindow == .today }
        #expect(today.allSatisfy { $0.provider == .custom && $0.accountLabel == "Aider" })
        let gpt4o = try #require(today.first { $0.modelLabel == "gpt-4o" })
        #expect(gpt4o.tokenUsage == TokenUsage(inputTokens: 150, outputTokens: 25))
        let claude = try #require(today.first { $0.modelLabel == "claude-fable-5" })
        #expect(claude.tokenUsage == TokenUsage(inputTokens: 10, outputTokens: 1))
    }

    @Test("a missing file produces no metrics instead of an error")
    func missingFileProducesNoMetrics() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

        let metrics = await CustomUsageAggregator.metrics(from: missing, source: CustomUsageSource(name: "Aider", filePath: missing.path), now: Date(), calendar: .current)

        #expect(metrics.isEmpty)
    }

    @Test("malformed lines are skipped without failing the whole source")
    func malformedLinesAreSkipped() async throws {
        let jsonl = [
            #"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}"#,
            "not json at all"
        ].joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)
        let now = try date("2026-07-12T18:00:00Z")

        let metrics = await CustomUsageAggregator.metrics(from: fileURL, source: CustomUsageSource(name: "Aider", filePath: fileURL.path), now: now, calendar: utcCalendar())

        // One valid event, aggregated into both the Today and Current Week windows it falls in.
        #expect(metrics.count == 2)
        #expect(metrics.allSatisfy { $0.modelLabel == "gpt-4o" })
    }

    @Test("custom metrics use stable source identity across rename")
    func customMetricsUseStableIdentityAcrossRename() async throws {
        let fileURL = try temporaryFile(contents: #"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":1,"outputTokens":2}"#)
        let id = UUID()
        let now = try date("2026-07-12T18:00:00Z")
        let before = await CustomUsageAggregator.metrics(from: fileURL, source: CustomUsageSource(id: id, name: "Aider", filePath: fileURL.path), now: now, calendar: utcCalendar())
        let after = await CustomUsageAggregator.metrics(from: fileURL, source: CustomUsageSource(id: id, name: "Renamed", filePath: fileURL.path), now: now, calendar: utcCalendar())

        #expect(before.allSatisfy { $0.provenance.source == .custom(id) })
        #expect(after.allSatisfy { $0.provenance.source == .custom(id) })
        #expect(before.map(\.provenance) == after.map(\.provenance))
        #expect(after.allSatisfy { $0.accountLabel == "Renamed" })
    }

    @Test("streaming load recovers after invalid UTF-8 and overlong lines with bounded diagnostics")
    func streamingLoadRecoversWithBoundedDiagnostics() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var data = Data([0xFF, 0x0A])
        data.append(Data(repeating: 0x61, count: 1_048_577))
        data.append(0x0A)
        for _ in 0..<25 { data.append(Data("bad json\n".utf8)) }
        data.append(Data(#"{"timestamp":"2026-07-12T10:00:00Z","model":"valid","inputTokens":3,"outputTokens":2}"#.utf8))
        try data.write(to: fileURL)

        let result = try await CustomUsageAggregator.loadMetrics(
            from: fileURL,
            source: CustomUsageSource(name: "Tool", filePath: fileURL.path),
            now: try date("2026-07-12T18:00:00Z"),
            calendar: utcCalendar()
        )

        #expect(result.metrics.count == 2)
        #expect(result.metrics.allSatisfy { $0.modelLabel == "valid" })
        #expect(result.rejectedLineCount == 27)
        #expect(result.diagnostics.count == 20)
    }

    @Test("custom-source v2 attribution retains its source identity")
    func customV2Attribution() async throws {
        let sourceID = try #require(UUID(uuidString: "9598575e-259b-47df-9f34-f161c9015e65"))
        let fileURL = try temporaryFile(contents: #"{"schemaVersion":2,"eventID":"00000000-0000-0000-0000-000000000001","customSourceID":"9598575e-259b-47df-9f34-f161c9015e65","timestamp":"2026-07-12T10:00:00Z","model":"local","inputTokens":3,"outputTokens":2,"projectID":"alpha","agentID":"builder"}"#)
        let source = CustomUsageSource(id: sourceID, name: "Tool", filePath: fileURL.path)

        let result = try await CustomUsageAggregator.loadMetrics(
            from: fileURL, source: source, now: try date("2026-07-12T18:00:00Z"), calendar: utcCalendar()
        )

        #expect(result.attributionBreakdowns.count == 2)
        #expect(result.attributionBreakdowns.allSatisfy { $0.source == .custom(sourceID) && $0.provider == .custom })
        #expect(result.attributionBreakdowns.allSatisfy { $0.project?.id == "alpha" && $0.agent?.id == "builder" })
    }

    @Test("load rejects sparse oversized files, directories, and special files without leaking paths")
    func rejectsUnsafeFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oversized = root.appendingPathComponent("private-name.jsonl")
        #expect(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 100 * 1_024 * 1_024 + 1)
        try handle.close()
        let source = CustomUsageSource(name: "Tool", filePath: oversized.path)

        await #expect(throws: CustomUsageLoadError.fileTooLarge) {
            try await CustomUsageAggregator.loadMetrics(from: oversized, source: source, now: Date(), calendar: .current)
        }
        await #expect(throws: CustomUsageLoadError.notRegularFile) {
            try await CustomUsageAggregator.loadMetrics(from: root, source: source, now: Date(), calendar: .current)
        }

        let fifo = root.appendingPathComponent("private-fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        do {
            _ = try await CustomUsageAggregator.loadMetrics(from: fifo, source: source, now: Date(), calendar: .current)
            Issue.record("Expected special file rejection")
        } catch let error as CustomUsageLoadError {
            #expect(error == .notRegularFile)
            #expect(!String(describing: error).contains(root.path))
        }
    }

    @Test("load rejects events over five minutes in the future but accepts the boundary")
    func rejectsFutureEventsPastBoundary() async throws {
        let jsonl = [
            #"{"timestamp":"2026-07-12T18:05:00Z","model":"boundary","inputTokens":1,"outputTokens":1}"#,
            #"{"timestamp":"2026-07-12T18:05:01Z","model":"future","inputTokens":2,"outputTokens":2}"#
        ].joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)

        let result = try await CustomUsageAggregator.loadMetrics(
            from: fileURL,
            source: CustomUsageSource(name: "Tool", filePath: fileURL.path),
            now: try date("2026-07-12T18:00:00Z"),
            calendar: utcCalendar()
        )

        #expect(Set(result.metrics.map(\.modelLabel)) == ["boundary"])
        #expect(result.rejectedLineCount == 1)
        #expect(result.diagnostics.first?.reason == .futureTimestamp)
        #expect(result.hasFutureTimestampRejection)
    }

    @Test("token overflow fails the typed load")
    func tokenOverflowFails() async throws {
        let jsonl = [
            #"{"timestamp":"2026-07-12T10:00:00Z","model":"x","inputTokens":9223372036854775807,"outputTokens":0}"#,
            #"{"timestamp":"2026-07-12T11:00:00Z","model":"x","inputTokens":1,"outputTokens":0}"#
        ].joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)

        await #expect(throws: CustomUsageLoadError.tokenOverflow) {
            try await CustomUsageAggregator.loadMetrics(
                from: fileURL,
                source: CustomUsageSource(name: "Tool", filePath: fileURL.path),
                now: try date("2026-07-12T18:00:00Z"),
                calendar: utcCalendar()
            )
        }
    }

    @Test("more than ten thousand distinct model-window aggregates fails the typed load")
    func aggregateCardinalityIsBounded() async throws {
        let jsonl = (0...5_000).map { index in
            "{\"timestamp\":\"2026-07-12T10:00:00Z\",\"model\":\"model-\(index)\",\"inputTokens\":1,\"outputTokens\":1}"
        }.joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)

        await #expect(throws: CustomUsageLoadError.tooManyAggregates) {
            try await CustomUsageAggregator.loadMetrics(
                from: fileURL,
                source: CustomUsageSource(name: "Tool", filePath: fileURL.path),
                now: try date("2026-07-12T18:00:00Z"),
                calendar: utcCalendar()
            )
        }
    }

    @Test("custom parent and attribution aggregates share one ten-thousand-key bound")
    func customCombinedAggregateLimit() async throws {
        let sourceID = UUID(uuidString: "9598575e-259b-47df-9f34-f161c9015e65")!
        let jsonl = (0...2_500).map { index in
            "{\"schemaVersion\":2,\"eventID\":\"\(String(format: "00000000-0000-0000-0000-%012d", index + 1))\",\"customSourceID\":\"\(sourceID.uuidString)\",\"timestamp\":\"2026-07-12T10:00:00Z\",\"model\":\"model-\(index)\",\"inputTokens\":1,\"outputTokens\":1,\"agentID\":\"agent-\(index)\"}"
        }.joined(separator: "\n")
        let fileURL = try temporaryFile(contents: jsonl)
        let source = CustomUsageSource(id: sourceID, name: "Tool", filePath: fileURL.path)

        await #expect(throws: CustomUsageLoadError.tooManyAggregates) {
            try await CustomUsageAggregator.loadMetrics(from: fileURL, source: source, now: try date("2026-07-12T18:00:00Z"), calendar: utcCalendar())
        }
    }

    @Test("custom source revision hashes the exact bytes read across atomic path replacement")
    func customRevisionMatchesImportedBytesDuringReplacement() async throws {
        let sourceID = UUID(uuidString: "9598575e-259b-47df-9f34-f161c9015e65")!
        let eventA = #"{"schemaVersion":2,"eventID":"00000000-0000-0000-0000-000000000001","customSourceID":"9598575e-259b-47df-9f34-f161c9015e65","timestamp":"2026-07-12T10:00:00Z","model":"model-a","inputTokens":1,"outputTokens":1,"projectID":"alpha"}"#
        let eventB = #"{"schemaVersion":2,"eventID":"00000000-0000-0000-0000-000000000002","customSourceID":"9598575e-259b-47df-9f34-f161c9015e65","timestamp":"2026-07-12T10:00:00Z","model":"model-b","inputTokens":2,"outputTokens":2,"projectID":"beta"}"#
        let bytesA = Data((eventA + String(repeating: "\n", count: 70_000)).utf8)
        let bytesB = Data(eventB.utf8)
        let fileURL = try temporaryFile(contents: "")
        try bytesA.write(to: fileURL)
        let source = CustomUsageSource(id: sourceID, name: "Tool", filePath: fileURL.path)
        var replaced = false

        let result = try await CustomUsageAggregator.loadMetrics(
            from: fileURL,
            source: source,
            now: try date("2026-07-12T18:00:00Z"),
            calendar: utcCalendar(),
            onChunkRead: { _ in
                guard !replaced else { return }
                replaced = true
                try bytesB.write(to: fileURL, options: .atomic)
            }
        )

        #expect(result.sourceRevision == SHA256.hash(data: bytesA).map { String(format: "%02x", $0) }.joined())
        #expect(result.attributionBreakdowns.allSatisfy { $0.project?.id == "alpha" })
        #expect(try Data(contentsOf: fileURL) == bytesB)
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
