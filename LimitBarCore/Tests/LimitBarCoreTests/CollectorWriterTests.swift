import Foundation
import Testing
@testable import LimitBarCore

@Suite("Collector writer")
struct CollectorWriterTests {
    private let now = Date(timeIntervalSince1970: 1_783_857_600)

    @Test("identical UUID and payload is idempotent and consumes capacity once")
    func duplicateIsIdempotent() throws {
        let output = try temporaryOutput()
        let writer = CollectorWriter(policy: CollectorPolicy(maximumEventsPerMinute: 1))
        let event = try makeEvent(id: 1)

        #expect(try writer.append(event, to: output, now: now) == .appended)
        #expect(try writer.append(event, to: output, now: now) == .duplicate)
        #expect(try Data(contentsOf: output).split(separator: 0x0A).count == 1)
        for path in [output.path, output.path + ".collector.lock", output.path + ".collector-rate-v1.json"] {
            let permissions = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o600)
        }
        #expect(throws: CollectorWriterError.rateLimited) {
            try writer.append(try makeEvent(id: 2), to: output, now: now)
        }
    }

    @Test("reused UUID with different content is rejected")
    func reusedIDConflicts() throws {
        let output = try temporaryOutput()
        let writer = CollectorWriter()
        try writer.append(try makeEvent(id: 1), to: output, now: now)

        #expect(throws: CollectorWriterError.eventIDConflict) {
            try writer.append(try makeEvent(id: 1, inputTokens: 99), to: output, now: now)
        }
    }

    @Test("v2 retries are idempotent and attribution changes conflict")
    func v2RetriesAndConflicts() throws {
        let output = try temporaryOutput()
        let writer = CollectorWriter()
        let event = try makeV2Event(id: 1)

        #expect(try writer.append(event, to: output, now: now) == .appended)
        #expect(try writer.append(event, to: output, now: now) == .duplicate)
        #expect(throws: CollectorWriterError.eventIDConflict) {
            try writer.append(try makeV2Event(id: 1, projectID: "other-project"), to: output, now: now)
        }
    }

    @Test("schema version is material to Event ID identity")
    func schemaVersionChangeConflicts() throws {
        let output = try temporaryOutput()
        let writer = CollectorWriter()
        try writer.append(try makeEvent(id: 1), to: output, now: now)

        #expect(throws: CollectorWriterError.eventIDConflict) {
            try writer.append(try makeV2Event(id: 1, projectID: nil), to: output, now: now)
        }
    }

    @Test("adds a separator when an existing JSONL file has no trailing newline")
    func appendsAfterUnterminatedLine() throws {
        let output = try temporaryOutput()
        try CollectorSchemaV1.encode(makeEvent(id: 1)).write(to: output)

        try CollectorWriter().append(try makeEvent(id: 2), to: output, now: now)

        let lines = try Data(contentsOf: output).split(separator: 0x0A)
        #expect(lines.count == 2)
        #expect(try lines.map { try CollectorSchemaV1.decode(Data($0)).eventID } == [uuid(1), uuid(2)])
    }

    @Test("rolling shared rate limit rejects excess accepted events")
    func enforcesRateLimit() throws {
        let output = try temporaryOutput()
        let writer = CollectorWriter(policy: CollectorPolicy(maximumEventsPerMinute: 2))
        try writer.append(try makeEvent(id: 1), to: output, now: now)
        try writer.append(try makeEvent(id: 2), to: output, now: now.addingTimeInterval(30))

        #expect(throws: CollectorWriterError.rateLimited) {
            try writer.append(try makeEvent(id: 3), to: output, now: now.addingTimeInterval(59))
        }
        #expect(try writer.append(try makeEvent(id: 3), to: output, now: now.addingTimeInterval(61)) == .appended)
    }

    @Test("concurrent producers leave one coherent line per event")
    func concurrentProducers() async throws {
        let output = try temporaryOutput()
        let writer = CollectorWriter(policy: CollectorPolicy(maximumEventsPerMinute: 100))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 1...40 {
                group.addTask { _ = try writer.append(try makeEvent(id: id), to: output, now: now) }
            }
            try await group.waitForAll()
        }

        let lines = try Data(contentsOf: output).split(separator: 0x0A)
        let events = try lines.map { try CollectorSchemaV1.decode(Data($0)) }
        #expect(events.count == 40)
        #expect(Set(events.map(\.eventID)).count == 40)
    }

    @Test("rotation archives all data and retains only recent active events")
    func rotatesWithoutLosingRecentUsage() throws {
        let output = try temporaryOutput()
        let oldEvents = try (1...4).map { try makeEvent(id: $0, timestamp: now.addingTimeInterval(-9 * 24 * 60 * 60)) }
        var oldData = Data()
        for event in oldEvents {
            oldData.append(try CollectorSchemaV1.encode(event))
            oldData.append(0x0A)
        }
        try oldData.write(to: output)
        let writer = CollectorWriter(policy: CollectorPolicy(maximumEventsPerMinute: 10, maximumActiveFileBytes: oldData.count, activeRetention: 8 * 24 * 60 * 60))

        let result = try writer.append(try makeEvent(id: 9), to: output, now: now)
        guard case let .appendedAfterRotation(archiveURL) = result else {
            Issue.record("Expected rotation")
            return
        }

        #expect(try Data(contentsOf: archiveURL) == oldData)
        let activeLines = try Data(contentsOf: output).split(separator: 0x0A)
        #expect(activeLines.count == 1)
        #expect(try CollectorSchemaV1.decode(Data(activeLines[0])).eventID == makeEvent(id: 9).eventID)
    }

    @Test("schema v2 attribution follows the same active retention and rotation policy")
    func v2RetentionAndRotation() throws {
        let output = try temporaryOutput()
        let old = CollectorEventV2(
            eventID: try uuid(1), identity: .provider(.openAI), timestamp: now.addingTimeInterval(-9 * 24 * 60 * 60),
            model: "old", inputTokens: 1, outputTokens: 1,
            project: CollectorAttribution(id: "old-project")
        )
        let recent = try makeV2Event(id: 2)
        let new = try makeV2Event(id: 3)
        var existing = try CollectorSchemaV2.encode(old) + Data([0x0A])
        existing.append(try CollectorSchemaV2.encode(recent))
        existing.append(0x0A)
        try existing.write(to: output)
        let retainedCandidate = try CollectorSchemaV2.encode(recent) + Data([0x0A]) + CollectorSchemaV2.encode(new) + Data([0x0A])
        let writer = CollectorWriter(policy: CollectorPolicy(maximumActiveFileBytes: retainedCandidate.count))

        guard case .appendedAfterRotation = try writer.append(new, to: output, now: now) else {
            Issue.record("Expected schema v2 rotation")
            return
        }

        let active = try Data(contentsOf: output).split(separator: 0x0A).map { try CollectorSchemaV2.decode(Data($0)) }
        #expect(active.map(\.eventID) == [try uuid(2), try uuid(3)])
        #expect(active.first?.project?.id == "project-one")
    }

    @Test("fails rotation rather than dropping retained or malformed lines")
    func refusesLossyRotation() throws {
        let output = try temporaryOutput()
        try Data("\nunrecognized-existing-line\n\n".utf8).write(to: output)
        let writer = CollectorWriter(policy: CollectorPolicy(maximumActiveFileBytes: 32))

        #expect(throws: CollectorWriterError.activeFileTooLargeAfterRetention) {
            try writer.append(try makeEvent(id: 1), to: output, now: now)
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "\nunrecognized-existing-line\n\n")
    }

    @Test("prunes archives by age and total bytes before rotation")
    func boundsArchives() throws {
        let output = try temporaryOutput()
        let directory = output.deletingLastPathComponent()
        let expired = directory.appendingPathComponent("usage-events.jsonl.archive-v1.1.00000000-0000-0000-0000-000000000101.jsonl")
        let recent = directory.appendingPathComponent("usage-events.jsonl.archive-v1.2.00000000-0000-0000-0000-000000000102.jsonl")
        let unrelated = directory.appendingPathComponent("usage-events.jsonl.archive-v1.notes.jsonl")
        try Data(repeating: 1, count: 20).write(to: expired)
        try Data(repeating: 2, count: 20).write(to: recent)
        try Data(repeating: 3, count: 20).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 24 * 60 * 60)], ofItemAtPath: expired.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: recent.path)
        let existing = try CollectorSchemaV1.encode(makeEvent(id: 1, timestamp: now.addingTimeInterval(-9 * 24 * 60 * 60))) + Data([0x0A])
        try existing.write(to: output)
        let writer = CollectorWriter(policy: CollectorPolicy(maximumActiveFileBytes: existing.count, maximumArchiveBytes: existing.count + 10, archiveRetention: 30 * 24 * 60 * 60))

        _ = try writer.append(try makeEvent(id: 2), to: output, now: now)

        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(!FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        let archives = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.contains(".archive-v1.") && $0.lastPathComponent != unrelated.lastPathComponent
        }
        #expect(archives.count == 1)
    }

    @Test("extensionless and JSONL outputs have separate archive namespaces")
    func isolatesArchiveNamespaces() throws {
        let directory = try temporaryOutput().deletingLastPathComponent()
        let extensionless = directory.appendingPathComponent("usage-events")
        let jsonl = directory.appendingPathComponent("usage-events.jsonl")
        let old = try makeEvent(id: 1, timestamp: now.addingTimeInterval(-9 * 24 * 60 * 60))
        let oldData = try CollectorSchemaV1.encode(old) + Data([0x0A])
        try oldData.write(to: extensionless)
        try oldData.write(to: jsonl)
        let writer = CollectorWriter(policy: CollectorPolicy(maximumActiveFileBytes: oldData.count))

        guard case let .appendedAfterRotation(firstArchive) = try writer.append(try makeEvent(id: 2), to: extensionless, now: now),
              case let .appendedAfterRotation(secondArchive) = try writer.append(try makeEvent(id: 3), to: jsonl, now: now) else {
            Issue.record("Expected both outputs to rotate")
            return
        }
        #expect(firstArchive != secondArchive)
        #expect(FileManager.default.fileExists(atPath: firstArchive.path))
        #expect(FileManager.default.fileExists(atPath: secondArchive.path))
    }

    @Test("collector output remains compatible with built-in and custom importers")
    func remainsCompatibleWithLimitBarIngestion() throws {
        let builtInData = try CollectorSchemaV1.encode(makeEvent(id: 1))
        let builtIn = try LocalUsageEventParser.parseLine(String(decoding: builtInData, as: UTF8.self))
        #expect(builtIn.provider == .openAI)
        #expect(builtIn.inputTokens == 1)

        let custom = CollectorEventV1(eventID: try uuid(2), identity: .customSource(try uuid(99)), timestamp: now, model: "local-model", inputTokens: 3, outputTokens: 4)
        let customData = try CollectorSchemaV1.encode(custom)
        let importedCustom = try CustomUsageEventParser.parseLine(String(decoding: customData, as: UTF8.self))
        #expect(importedCustom.model == "local-model")
        #expect(importedCustom.outputTokens == 4)
    }

    @Test("rejects future events, symlink outputs, and invalid policies")
    func rejectsResourceAbuse() throws {
        let output = try temporaryOutput()
        #expect(throws: CollectorWriterError.futureTimestamp) {
            try CollectorWriter().append(try makeEvent(id: 1, timestamp: now.addingTimeInterval(301)), to: output, now: now)
        }
        try Data().write(to: output)
        let link = output.deletingLastPathComponent().appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        #expect(throws: CollectorWriterError.outputIsNotRegularFile) {
            try CollectorWriter().append(try makeEvent(id: 2), to: link, now: now)
        }
        let dangling = output.deletingLastPathComponent().appendingPathComponent("dangling.jsonl")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: output.deletingLastPathComponent().appendingPathComponent("missing.jsonl"))
        #expect(throws: CollectorWriterError.outputIsNotRegularFile) {
            try CollectorWriter().append(try makeEvent(id: 3), to: dangling, now: now)
        }
        let writer = CollectorWriter()
        try writer.append(try makeEvent(id: 4), to: output, now: now)
        let rateState = URL(fileURLWithPath: output.path + ".collector-rate-v1.json")
        try FileManager.default.removeItem(at: rateState)
        try FileManager.default.createSymbolicLink(at: rateState, withDestinationURL: output.deletingLastPathComponent().appendingPathComponent("missing-rate.json"))
        #expect(throws: CollectorWriterError.outputIsNotRegularFile) {
            try writer.append(try makeEvent(id: 4), to: output, now: now)
        }
        #expect(throws: CollectorWriterError.invalidPolicy) {
            try CollectorWriter(policy: CollectorPolicy(maximumEventsPerMinute: 0)).append(try makeEvent(id: 5), to: output, now: now)
        }
    }

    private func makeEvent(id: Int, timestamp: Date? = nil, inputTokens: Int = 1) throws -> CollectorEventV1 {
        CollectorEventV1(eventID: try uuid(id), identity: .provider(.openAI), timestamp: timestamp ?? now, model: "model-\(id)", inputTokens: inputTokens, outputTokens: 2)
    }

    private func makeV2Event(id: Int, projectID: String? = "project-one") throws -> CollectorEventV2 {
        CollectorEventV2(
            eventID: try uuid(id), identity: .provider(.openAI), timestamp: now, model: "model-\(id)",
            inputTokens: 1, outputTokens: 2,
            project: projectID.map { CollectorAttribution(id: $0, label: "Project One") },
            agent: CollectorAttribution(id: "agent-one", label: "Agent One")
        )
    }

    private func temporaryOutput() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage-events.jsonl")
    }
}
