import Foundation
import Testing
@testable import LimitBarCore

@Suite("Recovery Inbox")
struct RecoveryInboxTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    @Test("checkpoint decoder enforces the complete positive allow-list")
    func strictCheckpointContract() throws {
        let data = try RecoveryCheckpointCodec.encode(checkpoint())
        #expect(try RecoveryCheckpointCodec.decode(data) == checkpoint())

        for prohibited in ["prompt", "summary", "code", "command", "output", "path", "raw_error", "provider_payload", "metadata"] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object[prohibited] = "must-not-persist"
            #expect(throws: RecoveryCheckpointError.prohibitedField) {
                try RecoveryCheckpointCodec.decode(try JSONSerialization.data(withJSONObject: object))
            }
        }
        var missing = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        missing.removeValue(forKey: "client_version")
        #expect(throws: RecoveryCheckpointError.malformed) {
            try RecoveryCheckpointCodec.decode(try JSONSerialization.data(withJSONObject: missing))
        }
        var disguisedContent = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        disguisedContent["session_reference"] = "please-resume-my-secret-task"
        #expect(throws: RecoveryCheckpointError.invalidValue) {
            try RecoveryCheckpointCodec.decode(try JSONSerialization.data(withJSONObject: disguisedContent))
        }
    }

    @Test("duplicate retries are idempotent and changed retries conflict")
    func duplicatesAndConflicts() throws {
        let fixture = try storeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let value = checkpoint()

        #expect(try fixture.store.submit(value, now: now) == .accepted)
        #expect(try fixture.store.submit(value, now: now) == .duplicate)
        let conflict = RecoveryCheckpoint(
            product: value.product,
            sessionReference: value.sessionReference,
            workspaceFingerprint: "hmac-sha256-v1:" + String(repeating: "b", count: 64),
            clientVersion: value.clientVersion,
            failureClass: value.failureClass,
            windowKind: value.windowKind,
            resetBoundary: value.resetBoundary,
            createdAt: value.createdAt
        )
        #expect(try fixture.store.submit(conflict, now: now) == .conflict)
        #expect(try fixture.store.all(now: now).count == 1)
    }

    @Test("concurrent identical submissions produce one item")
    func concurrentDuplicates() async throws {
        let fixture = try storeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let value = checkpoint()
        let results = await withTaskGroup(of: RecoverySubmissionResult?.self) { group in
            for _ in 0..<32 {
                group.addTask { try? fixture.store.submit(value, now: self.now) }
            }
            var values: [RecoverySubmissionResult] = []
            for await result in group {
                if let result { values.append(result) }
            }
            return values
        }
        #expect(results.filter { $0 == .accepted }.count == 1)
        #expect(results.filter { $0 == .duplicate }.count == 31)
        #expect(try fixture.store.all(now: now).count == 1)
    }

    @Test("readiness requires fresh post-boundary Capacity Gate evidence")
    func freshCapacityOnly() {
        let value = checkpoint()
        let review = RecoveryReviewContext(workspace: .unchanged, session: .confirmed)
        let afterReset = value.resetBoundary.addingTimeInterval(10)

        #expect(evaluate(value, capacity: evidence(.missing), review: review, at: afterReset) == .unavailable(.missingCapacityEvidence))
        #expect(evaluate(value, capacity: evidence(.stale), review: review, at: afterReset) == .unavailable(.staleCapacityEvidence))
        #expect(evaluate(value, capacity: freshEvidence(observedAt: value.resetBoundary.addingTimeInterval(-1)), review: review, at: afterReset) == .unavailable(.changedResetBoundary))
        #expect(evaluate(value, capacity: freshEvidence(percentage: 95), review: review, at: afterReset) == .waiting)
        #expect(evaluate(value, capacity: freshEvidence(incident: true), review: review, at: afterReset) == .unavailable(.providerIncident))
        #expect(evaluate(value, capacity: freshEvidence(), review: review, at: afterReset) == .readyForReview)
    }

    @Test("clock crossing and changed boundaries never establish readiness")
    func timerAndBoundarySafety() {
        let value = checkpoint()
        let beforeReset = value.resetBoundary.addingTimeInterval(-10)
        let changed = RecoveryCapacityEvidence(
            availability: .fresh,
            product: .codex,
            windowKind: .session,
            percentageUsed: 10,
            observedAt: beforeReset,
            expiresAt: beforeReset.addingTimeInterval(60),
            resetBoundary: value.resetBoundary.addingTimeInterval(3_600)
        )
        #expect(evaluate(value, capacity: changed, review: .init(workspace: .unchanged, session: .confirmed), at: beforeReset) == .unavailable(.changedResetBoundary))
        #expect(evaluate(value, capacity: evidence(.missing), review: .init(workspace: .unchanged, session: .confirmed), at: value.resetBoundary) != .readyForReview)
    }

    @Test("readiness ignores a healthy successor from a different window kind")
    func exactWindowSuccessor() {
        let value = checkpoint()
        let afterReset = value.resetBoundary.addingTimeInterval(10)
        let publication = CapacityPublication(
            publishedAt: afterReset,
            observations: [
                CapacityPublication.Observation(
                    product: .codex,
                    windowKind: .weekly,
                    percentageUsed: 5,
                    observedAt: afterReset,
                    expiresAt: afterReset.addingTimeInterval(60),
                    resetBoundary: afterReset.addingTimeInterval(86_400)
                ),
                CapacityPublication.Observation(
                    product: .codex,
                    windowKind: .session,
                    percentageUsed: 95,
                    observedAt: afterReset,
                    expiresAt: afterReset.addingTimeInterval(60),
                    resetBoundary: afterReset.addingTimeInterval(3_600)
                ),
            ]
        )
        let sessionEvidence = RecoveryCapacityEvidence.from(
            publication,
            product: .codex,
            windowKind: .session,
            now: afterReset
        )
        #expect(evaluate(
            value,
            capacity: sessionEvidence,
            review: .init(workspace: .unchanged, session: .confirmed),
            at: afterReset
        ) == .waiting)
        let weeklyEvidence = RecoveryCapacityEvidence.from(
            publication,
            product: .codex,
            windowKind: .weekly,
            now: afterReset
        )
        #expect(evaluate(
            value,
            capacity: weeklyEvidence,
            review: .init(workspace: .unchanged, session: .confirmed),
            at: afterReset
        ) == .unavailable(.missingCapacityEvidence))
    }

    @Test("review distinguishes changed, deleted, expired session, unsupported client, and command")
    func reviewStates() {
        for product in RecoveryProduct.allCases {
            let value = checkpoint(product: product)
            let at = value.resetBoundary.addingTimeInterval(10)
            let capacity = freshEvidence(product: product)
            #expect(evaluate(value, capacity: capacity, review: .init(workspace: .unchanged, session: .confirmed), at: at) == .readyForReview)
            #expect(evaluate(value, capacity: capacity, review: .init(workspace: .changed, session: .confirmed), at: at) == .changedWorkspace)
            #expect(evaluate(value, capacity: capacity, review: .init(workspace: .deleted, session: .confirmed), at: at) == .unavailable(.workspaceUnavailable))
            #expect(evaluate(value, capacity: capacity, review: .init(workspace: .unchanged, session: .expired), at: at) == .unavailable(.sessionExpired))
            #expect(evaluate(value, capacity: capacity, review: .init(workspace: .unchanged, session: .confirmed, clientSupported: false), at: at) == .unavailable(.unsupportedClient))
            #expect(evaluate(value, capacity: capacity, review: .init(workspace: .unchanged, session: .confirmed, resumeCommandAvailable: false), at: at) == .unavailable(.resumeCommandUnavailable))
            #expect(evaluate(value, capacity: capacity, review: .init(workspace: .unchanged), at: at) == .unavailable(.sessionRevalidationRequired))
        }
    }

    @Test("terminal transitions survive reload and retention is bounded")
    func persistenceAndRetention() throws {
        let fixture = try storeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let value = checkpoint()
        #expect(try fixture.store.submit(value, now: now) == .accepted)
        let id = try #require(fixture.store.all(now: now).first?.id)
        #expect(!(try fixture.store.transition(id: id, to: .resumed, now: now)))
        #expect(try fixture.store.transition(id: id, to: .dismissed, now: now))
        let relaunchedStore = RecoveryInboxStore(destination: fixture.directory.appendingPathComponent("inbox.json"))
        #expect(try relaunchedStore.all(now: now).first?.state == .dismissed)
        #expect(!(try fixture.store.transition(id: id, to: .readyForReview, now: now)))
        #expect(try fixture.store.all(now: now.addingTimeInterval(RecoveryStateMachine.retentionAge + 1)).isEmpty)
    }

    @Test("old checkpoints expire before bounded deletion")
    func expiration() {
        let value = checkpoint()
        let later = now.addingTimeInterval(RecoveryStateMachine.expirationAge + 1)
        #expect(evaluate(value, capacity: evidence(.missing), review: .init(), at: later) == .expired)
    }

    @Test("persistence is count-bounded")
    func countBound() throws {
        let fixture = try storeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for index in 0...RecoveryInboxStore.maximumCount {
            let session = String(format: "123e4567-e89b-42d3-a456-%012x", index)
            let value = RecoveryCheckpoint(
                product: .codex,
                sessionReference: session,
                workspaceFingerprint: "hmac-sha256-v1:" + String(repeating: "a", count: 64),
                clientVersion: "1.2.3",
                failureClass: .quotaExhausted,
                windowKind: .session,
                resetBoundary: now.addingTimeInterval(3_600),
                createdAt: now.addingTimeInterval(Double(index))
            )
            #expect(try fixture.store.submit(value, now: now.addingTimeInterval(Double(index))) == .accepted)
        }
        #expect(try fixture.store.all(now: now.addingTimeInterval(200)).count == RecoveryInboxStore.maximumCount)
    }

    @Test("diagnostic export cannot accept or emit recovery secrets")
    func diagnosticsExcludeRecoveryData() throws {
        let fixture = try storeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.store.submit(checkpoint(), now: now)
        let version = try DiagnosticVersion(major: 1, minor: 0, patch: 0)
        let input = try DiagnosticExportInput(
            generatedAt: now,
            appVersion: version,
            appBuild: 1,
            operatingSystemVersion: version,
            providerStatuses: [],
            databaseState: .available,
            importCounts: DiagnosticImportCounts(accepted: 0, rejected: 0),
            resourceLimitReasons: []
        )
        let text = try #require(String(data: DiagnosticExport.make(from: input).bytes, encoding: .utf8))
        for prohibited in [sessionReference, "hmac-sha256-v1", "workspace_fingerprint", "session_reference", "recovery"] {
            #expect(!text.lowercased().contains(prohibited.lowercased()))
        }
    }

    @Test("fingerprint is keyed, content-free output and detects Git workspace changes")
    func privacySafeFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runGit(["init", "-q"], in: directory)
        try runGit(["config", "user.email", "fixture@example.invalid"], in: directory)
        try runGit(["config", "user.name", "Fixture"], in: directory)
        let file = directory.appendingPathComponent("private-project-name.txt")
        try Data("secret source content".utf8).write(to: file)
        try runGit(["add", "."], in: directory)
        try runGit(["commit", "-qm", "fixture"], in: directory)
        let key = Data(repeating: 7, count: 32)
        let original = try RecoveryWorkspaceFingerprint.make(workspace: directory, key: key)
        try Data("changed secret source content".utf8).write(to: file)
        let changed = try RecoveryWorkspaceFingerprint.make(workspace: directory, key: key)

        #expect(original != changed)
        #expect(original.hasPrefix(RecoveryWorkspaceFingerprint.prefix))
        for prohibited in ["private", "project", "name", "secret", directory.lastPathComponent] {
            #expect(!original.contains(prohibited))
            #expect(!changed.contains(prohibited))
        }
    }

    @Test("fingerprint distinguishes different unstaged and staged content with identical status")
    func dirtyContentFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-dirty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runGit(["init", "-q"], in: directory)
        try runGit(["config", "user.email", "fixture@example.invalid"], in: directory)
        try runGit(["config", "user.name", "Fixture"], in: directory)
        let file = directory.appendingPathComponent("work.swift")
        try Data("let value = 0\n".utf8).write(to: file)
        try runGit(["add", "."], in: directory)
        try runGit(["commit", "-qm", "fixture"], in: directory)
        let key = Data(repeating: 9, count: 32)

        try Data("let value = 1\n".utf8).write(to: file)
        let dirtyOne = try RecoveryWorkspaceFingerprint.make(workspace: directory, key: key)
        try Data("let value = 2\n".utf8).write(to: file)
        let dirtyTwo = try RecoveryWorkspaceFingerprint.make(workspace: directory, key: key)
        #expect(dirtyOne != dirtyTwo)

        try runGit(["add", "."], in: directory)
        let stagedTwo = try RecoveryWorkspaceFingerprint.make(workspace: directory, key: key)
        try Data("let value = 3\n".utf8).write(to: file)
        try runGit(["add", "."], in: directory)
        let stagedThree = try RecoveryWorkspaceFingerprint.make(workspace: directory, key: key)
        #expect(stagedTwo != stagedThree)
        for fingerprint in [dirtyOne, dirtyTwo, stagedTwo, stagedThree] {
            #expect(!fingerprint.contains("value"))
            #expect(!fingerprint.contains("work.swift"))
        }
    }

    @Test("only documented provider-owned resume commands are formed")
    func resumeCommands() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-executables-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claudeURL = try executable(named: "claude", in: directory)
        let codexURL = try executable(named: "codex", in: directory)
        let claude = try RecoveryResumeCommand.documented(for: checkpoint(product: .claudeCode), executableURL: claudeURL)
        let codex = try RecoveryResumeCommand.documented(for: checkpoint(product: .codex), executableURL: codexURL)
        #expect(claude.executableURL.path.hasPrefix("/"))
        #expect(claude.executableURL.lastPathComponent == "claude")
        #expect(claude.arguments == ["--resume", sessionReference])
        #expect(codex.executableURL.path.hasPrefix("/"))
        #expect(codex.executableURL.lastPathComponent == "codex")
        #expect(codex.arguments == ["resume", sessionReference])
        #expect(claude.display.hasPrefix(claude.executableURL.path))
    }

    @Test("validated resume command rejects executable substitution")
    func executableSubstitution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-substitution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try executable(named: "codex", in: directory)
        let command = try RecoveryResumeCommand.documented(for: checkpoint(), executableURL: url)
        #expect(command.isStillValid())
        try FileManager.default.removeItem(at: url)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #expect(!command.isStillValid())
    }

    @Test("multi-ready notifications have unique privacy-safe identifiers")
    func notificationIdentifiers() throws {
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        let firstID = try RecoveryNotificationIdentity.identifier(itemID: first)
        let secondID = try RecoveryNotificationIdentity.identifier(itemID: second)
        #expect(firstID != secondID)
        #expect(firstID == "limitbar.recovery.ready.\(first)")
        for identifier in [firstID, secondID] {
            #expect(!identifier.contains(sessionReference))
            #expect(!identifier.contains("hmac-sha256"))
        }
    }

    private func checkpoint(product: RecoveryProduct = .codex) -> RecoveryCheckpoint {
        RecoveryCheckpoint(
            product: product,
            sessionReference: sessionReference,
            workspaceFingerprint: "hmac-sha256-v1:" + String(repeating: "a", count: 64),
            clientVersion: "1.2.3",
            failureClass: .quotaExhausted,
            windowKind: .session,
            resetBoundary: now.addingTimeInterval(3_600),
            createdAt: now
        )
    }

    private var sessionReference: String { "123e4567-e89b-42d3-a456-426614174000" }

    private func evidence(_ availability: RecoveryCapacityEvidence.Availability) -> RecoveryCapacityEvidence {
        RecoveryCapacityEvidence(availability: availability, product: .codex, windowKind: .session)
    }

    private func freshEvidence(
        product: RecoveryProduct = .codex,
        percentage: Double = 10,
        observedAt: Date? = nil,
        incident: Bool = false
    ) -> RecoveryCapacityEvidence {
        RecoveryCapacityEvidence(
            availability: .fresh,
            product: product,
            windowKind: .session,
            percentageUsed: percentage,
            observedAt: observedAt ?? now.addingTimeInterval(3_601),
            expiresAt: now.addingTimeInterval(7_200),
            resetBoundary: now.addingTimeInterval(10_800),
            incidentActive: incident
        )
    }

    private func evaluate(
        _ checkpoint: RecoveryCheckpoint,
        capacity: RecoveryCapacityEvidence,
        review: RecoveryReviewContext,
        at now: Date
    ) -> RecoveryState {
        RecoveryStateMachine.evaluate(checkpoint: checkpoint, current: .waiting, capacity: capacity, review: review, now: now)
    }

    private func storeFixture() throws -> (directory: URL, store: RecoveryInboxStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, RecoveryInboxStore(destination: directory.appendingPathComponent("inbox.json")))
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func executable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
