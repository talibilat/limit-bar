import Foundation
import Testing
@testable import LimitBarCore

@Suite("Capacity gate")
struct CapacityGateTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    @Test("fresh measured capacity maps to allow, warn, and pause")
    func decisions() {
        #expect(evaluate(percentage: 25).decision == .allow)
        #expect(evaluate(percentage: 80).decision == .warn)
        #expect(evaluate(percentage: 90).decision == .pause)
        #expect(evaluate(percentage: 25).reasons == [.measuredCapacityHealthy])
        #expect(evaluate(percentage: 80).reasons == [.measuredCapacityWarning])
        #expect(evaluate(percentage: 90).reasons == [.measuredCapacityExhausted])
    }

    @Test("unsafe evidence never allows")
    func unsafeEvidence() {
        let stale = publication(observations: [observation(
            percentage: 10,
            observedAt: now.addingTimeInterval(-QuotaObservationAdapter.codexMaximumAge - 1),
            expiresAt: now.addingTimeInterval(60)
        )])
        let expiredBoundary = publication(observations: [observation(
            percentage: 10,
            resetBoundary: now
        )])
        let missing = publication(observations: [])

        #expect(evaluate(stale).decision == .warn)
        #expect(evaluate(stale).reasons == [.staleEvidence])
        #expect(evaluate(expiredBoundary).decision == .warn)
        #expect(evaluate(missing).reasons == [.unavailableEvidence])
        #expect(evaluate(missing, mode: .failClosed).decision == .pause)
    }

    @Test("boundary rollover selects only the new exact window")
    func boundaryRollover() {
        let old = observation(percentage: 99, resetBoundary: now)
        let current = observation(percentage: 20, resetBoundary: now.addingTimeInterval(7_200))
        let result = evaluate(publication(observations: [old, current]))

        #expect(result.decision == .allow)
        #expect(result.evidence.resetBoundary == current.resetBoundary)
        #expect(result.evidence.percentageUsed == 20)
    }

    @Test("active provider incident overlaps measured capacity without claiming causation")
    func incidentOverlap() {
        let incident = CapacityPublication.Incident(
            product: .codex,
            observedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(60)
        )
        let result = evaluate(publication(
            observations: [observation(percentage: 20)],
            incidents: [incident]
        ))

        #expect(result.decision == .warn)
        #expect(result.reasons == [.measuredCapacityHealthy, .providerIncidentActive])
        #expect(result.evidence.incidentActive)
    }

    @Test("publication decoder is a positive allow-list")
    func strictContract() throws {
        let valid = try CapacityPublicationCodec.encode(publication(observations: [observation(percentage: 20)]))
        #expect(try CapacityPublicationCodec.decode(valid).schemaVersion == 2)

        var unknown = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        unknown["account_id"] = "prohibited"
        #expect(throws: CapacityPublicationReadError.unsupportedVersion) {
            try CapacityPublicationCodec.decode(try JSONSerialization.data(withJSONObject: unknown))
        }
        var boundaryless = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var observations = try #require(boundaryless["observations"] as? [[String: Any]])
        observations[0].removeValue(forKey: "reset_boundary")
        boundaryless["observations"] = observations
        #expect(throws: CapacityPublicationReadError.boundaryUnavailable) {
            try CapacityPublicationCodec.decode(try JSONSerialization.data(withJSONObject: boundaryless))
        }
    }

    @Test("atomic publication contains only normalized allow-listed evidence")
    func atomicPrivacySafePublication() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limitbar-capacity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capacity-v1.json")
        let identity = try QuotaWindowIdentity(
            product: .codex,
            identifier: "/private/project/account/prompt/token-cookie",
            resetBoundary: now.addingTimeInterval(3_600)
        )
        let quota = QuotaObservation(
            identity: identity,
            percentageUsed: 20,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        try CapacityPublicationWriter(destination: destination).publish(CapacityPublication(
            publishedAt: now,
            quotaObservations: [quota]
        ))

        let data = try Data(contentsOf: destination)
        let text = try #require(String(data: data, encoding: .utf8))
        _ = try CapacityPublicationCodec.decode(data)
        for prohibited in ["private", "project", "account", "prompt", "token", "cookie", "identifier"] {
            #expect(!text.lowercased().contains(prohibited))
        }
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("request contract round trips every supported operation")
    func requestContract() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for product in CapacityProviderProduct.allCases {
            for operation in CapacityOperationClass.allCases {
                for mode in [CapacityEvaluationMode.observation, .failClosed] {
                    let request = CapacityRequest(product: product, operationClass: operation, mode: mode)
                    #expect(try decoder.decode(CapacityRequest.self, from: encoder.encode(request)) == request)
                }
            }
        }
    }

    @Test("timeout bounds a stalled publication read")
    func timeout() {
        let result = CapacityCommand.run(
            ["capacity", "--product", "codex", "--operation", "prompt", "--timeout", "0.001"],
            now: now,
            defaultPublicationURL: URL(fileURLWithPath: "/unused"),
            fileManager: .default,
            publicationReader: { _ in
                Thread.sleep(forTimeInterval: 0.05)
                return Data()
            }
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains(#""timed_out""#))
    }

    @Test("atomic replacement remains readable during concurrent publication")
    func concurrentPublication() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limitbar-capacity-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capacity-v1.json")
        let writer = CapacityPublicationWriter(destination: destination)
        try writer.publish(publication(observations: [observation(percentage: 20)]))

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "capacity-writer")
        for index in 0..<50 {
            group.enter()
            queue.async {
                let percentage = index.isMultiple(of: 2) ? 20.0 : 95.0
                try? writer.publish(self.publication(observations: [self.observation(percentage: percentage)]))
                group.leave()
            }
            let result = CapacityCommand.run(
                ["capacity", "--product", "codex", "--operation", "prompt", "--state-file", destination.path],
                now: now
            )
            #expect(result.exitCode == 0)
            #expect(!result.output.contains("malformed_evidence"))
            #expect(!result.output.contains("unavailable_evidence"))
        }
        group.wait()
    }

    private func evaluate(
        _ publication: CapacityPublication? = nil,
        percentage: Double? = nil,
        mode: CapacityEvaluationMode = .observation
    ) -> CapacityResponse {
        let value = publication ?? self.publication(observations: [observation(percentage: percentage ?? 20)])
        return CapacityEvaluator.evaluate(
            request: CapacityRequest(product: .codex, operationClass: .queuedRun, mode: mode),
            publication: value,
            now: now
        )
    }

    private func publication(
        observations: [CapacityPublication.Observation],
        incidents: [CapacityPublication.Incident] = []
    ) -> CapacityPublication {
        CapacityPublication(publishedAt: now, observations: observations, incidents: incidents)
    }

    private func observation(
        percentage: Double,
        observedAt: Date? = nil,
        expiresAt: Date? = nil,
        resetBoundary: Date? = nil
    ) -> CapacityPublication.Observation {
        CapacityPublication.Observation(
            product: .codex,
            percentageUsed: percentage,
            observedAt: observedAt ?? now.addingTimeInterval(-60),
            expiresAt: expiresAt ?? now.addingTimeInterval(60),
            resetBoundary: resetBoundary ?? now.addingTimeInterval(3_600)
        )
    }
}

@Suite("Capacity command process", .serialized)
struct CapacityCommandProcessTests {
    @Test("distributed command has stable observation and fail-closed behavior")
    func processBehavior() throws {
        let now = Date()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limitbar-capacity-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        let publication = CapacityPublication(
            publishedAt: now,
            observations: [CapacityPublication.Observation(
                product: .codex,
                percentageUsed: 95,
                observedAt: now,
                expiresAt: now.addingTimeInterval(60),
                resetBoundary: now.addingTimeInterval(3_600)
            )]
        )
        try CapacityPublicationCodec.encode(publication).write(to: state)

        let observed = try run(["capacity", "--product", "codex", "--operation", "queued-run", "--state-file", state.path])
        #expect(observed.status == 0)
        #expect(observed.response.decision == .pause)
        let closed = try run(["capacity", "--product", "codex", "--operation", "queued-run", "--mode", "fail-closed", "--state-file", state.path])
        #expect(closed.status == CapacityCommand.pausedExitCode)
        #expect(closed.response.reasons == [.measuredCapacityExhausted])
    }

    @Test("distributed command evaluates fresh, stale, rollover, incident, and boundary-less fixtures")
    func processFixtureMatrix() throws {
        let now = Date()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limitbar-capacity-matrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        let arguments = ["capacity", "--product", "codex", "--operation", "subagent", "--state-file", state.path]

        try write(publication(now: now, observations: [observation(now: now, percentage: 20)]), to: state)
        var result = try run(arguments)
        #expect(result.response.decision == .allow)
        #expect(result.response.evidence.observationAgeSeconds != nil)
        #expect(result.response.evidence.resetBoundary != nil)

        try write(publication(now: now, observations: [observation(
            now: now,
            percentage: 20,
            observedAt: now.addingTimeInterval(-QuotaObservationAdapter.codexMaximumAge - 1),
            expiresAt: now.addingTimeInterval(60)
        )]), to: state)
        result = try run(arguments)
        #expect(result.response.decision == .warn)
        #expect(result.response.reasons == [.staleEvidence])

        let currentBoundary = now.addingTimeInterval(7_200)
        try write(publication(now: now, observations: [
            observation(now: now, percentage: 99, resetBoundary: now),
            observation(now: now, percentage: 20, resetBoundary: currentBoundary),
        ]), to: state)
        result = try run(arguments)
        #expect(result.response.decision == .allow)
        #expect(result.response.evidence.resetBoundary?.timeIntervalSince1970.rounded(.down) == currentBoundary.timeIntervalSince1970.rounded(.down))

        let incident = CapacityPublication.Incident(
            product: .codex,
            observedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(60)
        )
        try write(publication(
            now: now,
            observations: [observation(now: now, percentage: 20)],
            incidents: [incident]
        ), to: state)
        result = try run(arguments)
        #expect(result.response.decision == .warn)
        #expect(result.response.reasons.contains(.providerIncidentActive))

        let encoded = try CapacityPublicationCodec.encode(publication(
            now: now,
            observations: [observation(now: now, percentage: 20)]
        ))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var values = try #require(object["observations"] as? [[String: Any]])
        values[0].removeValue(forKey: "reset_boundary")
        object["observations"] = values
        try JSONSerialization.data(withJSONObject: object).write(to: state)
        result = try run(arguments)
        #expect(result.response.decision == .warn)
        #expect(result.response.reasons == [.boundaryUnavailable])
    }

    @Test("distributed command fails safely for absent, malformed, unsupported, and unsupported input")
    func processFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limitbar-capacity-failures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        let base = ["capacity", "--product", "codex", "--operation", "prompt", "--state-file", state.path]

        let missing = try run(base)
        #expect(missing.status == 0)
        #expect(missing.response.decision == .warn)
        #expect(missing.response.reasons == [.unavailableEvidence])

        try Data("not-json".utf8).write(to: state)
        #expect(try run(base).response.reasons == [.malformedEvidence])

        try Data(#"{"incidents":[],"observations":[],"published_at":"2030-01-01T00:00:00Z","schema_version":3}"#.utf8).write(to: state)
        #expect(try run(base).response.reasons == [.incompatibleEvidence])

        let unsupported = try run(["capacity", "--product", "openai-api", "--operation", "prompt"])
        #expect(unsupported.status == CapacityCommand.usageExitCode)
        #expect(unsupported.response.decision == .pause)
        #expect(unsupported.response.reasons == [.unsupportedProduct])

        let timeout = try run(["capacity", "--product", "codex", "--operation", "prompt", "--timeout", "0"])
        #expect(timeout.status == CapacityCommand.usageExitCode)
        #expect(timeout.response.reasons == [.timedOut])
    }

    @Test("Claude hook and Codex wrapper are observation-safe and explicitly fail closed")
    func integrationExamples() throws {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repository = packageDirectory.deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limitbar-capacity-wrappers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.json")
        let fakeCodex = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeCodex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)
        let environment = [
            "LIMITBAR_CLI": executableURL().path,
            "LIMITBAR_CAPACITY_STATE_FILE": missing.path,
            "PATH": directory.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
        ]
        let claude = repository.appendingPathComponent("examples/capacity/claude-user-prompt-submit.sh")
        let codex = repository.appendingPathComponent("examples/capacity/codex-pre-run.sh")

        #expect(try runScript(claude, environment: environment).status == 0)
        #expect(try runScript(codex, environment: environment).status == 0)
        var closedEnvironment = environment
        closedEnvironment["LIMITBAR_CAPACITY_MODE"] = "fail-closed"
        #expect(try runScript(claude, environment: closedEnvironment).status == 2)
        #expect(try runScript(codex, environment: closedEnvironment).status == CapacityCommand.pausedExitCode)

        var missingCLIEnvironment = environment
        missingCLIEnvironment["LIMITBAR_CLI"] = directory.appendingPathComponent("missing-limitbar").path
        #expect(try runScript(claude, environment: missingCLIEnvironment).status == 0)
        #expect(try runScript(codex, environment: missingCLIEnvironment).status == 0)

        missingCLIEnvironment["LIMITBAR_CAPACITY_MODE"] = "fail-closed"
        #expect(try runScript(claude, environment: missingCLIEnvironment).status != 0)
        #expect(try runScript(codex, environment: missingCLIEnvironment).status != 0)
    }

    @Test("distributed command reads a writer-produced publication")
    func writerAndCommandShareContract() throws {
        let now = Date()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limitbar-capacity-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        try CapacityPublicationWriter(destination: state).publish(publication(
            now: now,
            observations: [observation(now: now, percentage: 25)]
        ))

        let result = try run([
            "capacity", "--product", "codex", "--operation", "queued-run", "--state-file", state.path,
        ])
        #expect(result.status == 0)
        #expect(result.response.decision == .allow)
        #expect(result.response.reasons == [.measuredCapacityHealthy])
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, response: CapacityResponse) {
        let process = Process()
        process.executableURL = executableURL()
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (process.terminationStatus, try decoder.decode(CapacityResponse.self, from: data))
    }

    private func executableURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/limitbar")
    }

    private func runScript(_ url: URL, environment: [String: String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = url
        process.environment = environment
        process.standardOutput = Pipe()
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func publication(
        now: Date,
        observations: [CapacityPublication.Observation],
        incidents: [CapacityPublication.Incident] = []
    ) -> CapacityPublication {
        CapacityPublication(publishedAt: now, observations: observations, incidents: incidents)
    }

    private func observation(
        now: Date,
        percentage: Double,
        observedAt: Date? = nil,
        expiresAt: Date? = nil,
        resetBoundary: Date? = nil
    ) -> CapacityPublication.Observation {
        CapacityPublication.Observation(
            product: .codex,
            percentageUsed: percentage,
            observedAt: observedAt ?? now.addingTimeInterval(-1),
            expiresAt: expiresAt ?? now.addingTimeInterval(60),
            resetBoundary: resetBoundary ?? now.addingTimeInterval(3_600)
        )
    }

    private func write(_ publication: CapacityPublication, to url: URL) throws {
        try CapacityPublicationCodec.encode(publication).write(to: url)
    }
}
