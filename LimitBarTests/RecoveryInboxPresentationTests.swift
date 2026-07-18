import Foundation
import LimitBarCore
@testable import LimitBar
import XCTest

@MainActor
private final class RecoveryNotificationSpy: RecoveryNotificationSending {
    var identifiers: [String] = []
    var authorized = false

    func isAuthorized() async -> Bool { authorized }

    func add(identifier: String, title: String, body: String) async throws {
        identifiers.append(identifier)
    }
}

@MainActor
private final class RecoveryLauncherSpy: RecoveryCommandLaunching {
    var commands: [RecoveryResumeCommand] = []
    var currentDirectories: [URL] = []

    func launch(_ command: RecoveryResumeCommand, currentDirectoryURL: URL) throws {
        commands.append(command)
        currentDirectories.append(currentDirectoryURL)
    }
}

@MainActor
final class RecoveryInboxPresentationTests: XCTestCase {
    private var directory: URL!
    private var now: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        now = Date(timeIntervalSince1970: 1_900_003_610)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testRefreshAndConfirmationNeverLaunchAutomaticallyAndCancelLaunchesNothing() throws {
        let fixture = try makeModel()
        let item = try XCTUnwrap(fixture.model.items.first)
        recordReview(fixture, item: item)

        XCTAssertEqual(fixture.launcher.commands.count, 0)
        fixture.model.confirmResume(item)
        XCTAssertNotNil(fixture.model.pendingResume)
        XCTAssertEqual(fixture.launcher.commands.count, 0)

        fixture.model.cancelResume()
        fixture.model.launchConfirmedResume()
        XCTAssertEqual(fixture.launcher.commands.count, 0)
    }

    func testConfirmedLaunchUsesTheDisplayedValidatedAbsoluteExecutable() throws {
        let fixture = try makeModel()
        let item = try XCTUnwrap(fixture.model.items.first)
        recordReview(fixture, item: item)
        fixture.model.confirmResume(item)
        let pending = try XCTUnwrap(fixture.model.pendingResume)

        XCTAssertTrue(pending.command.display.hasPrefix(pending.command.executableURL.path))
        fixture.model.launchConfirmedResume()

        XCTAssertEqual(fixture.launcher.commands, [pending.command])
        XCTAssertEqual(fixture.launcher.commands.first?.executableURL, pending.command.executableURL)
        XCTAssertEqual(fixture.launcher.currentDirectories, [fixture.review.canonicalURL])
    }

    func testExecutableReplacementAfterConfirmationWithholdsLaunch() throws {
        let fixture = try makeModel()
        let item = try XCTUnwrap(fixture.model.items.first)
        recordReview(fixture, item: item)
        fixture.model.confirmResume(item)
        XCTAssertNotNil(fixture.model.pendingResume)

        try FileManager.default.removeItem(at: fixture.executable)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: fixture.executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
        fixture.model.launchConfirmedResume()

        XCTAssertTrue(fixture.launcher.commands.isEmpty)
        XCTAssertEqual(fixture.model.message, "The validated provider executable changed. Review it again before resuming.")
    }

    func testExpiredSessionConfirmationWithholdsLaunch() throws {
        var current = now!
        let fixture = try makeModel(now: { current })
        let item = try XCTUnwrap(fixture.model.items.first)
        recordReview(fixture, item: item)
        fixture.model.confirmResume(item)
        current = current.addingTimeInterval(RecoveryInboxModel.sessionConfirmationLifetime + 1)

        fixture.model.launchConfirmedResume()

        XCTAssertTrue(fixture.launcher.commands.isEmpty)
        XCTAssertEqual(fixture.model.message, "Session confirmation expired. Revalidate before resuming.")
    }

    func testMultipleReadyItemsDeliverUniquePrivacySafeNotifications() async throws {
        let fixture = try makeModel(checkpointCount: 2)
        for item in fixture.model.items {
            recordReview(fixture, item: item)
            fixture.model.confirmResume(item)
            fixture.model.cancelResume()
        }
        fixture.notifications.authorized = true

        await fixture.model.deliverReadyNotifications()

        XCTAssertEqual(fixture.notifications.identifiers.count, 2)
        XCTAssertEqual(Set(fixture.notifications.identifiers).count, 2)
        XCTAssertTrue(fixture.notifications.identifiers.allSatisfy { $0.hasPrefix("limitbar.recovery.ready.") })
        XCTAssertTrue(fixture.notifications.identifiers.allSatisfy { !$0.contains("123e4567") })
    }

    func testReviewedWorkspaceContentMutationWithholdsLaunch() throws {
        let fixture = try makeModel()
        let item = try XCTUnwrap(fixture.model.items.first)
        recordReview(fixture, item: item)
        fixture.model.confirmResume(item)
        try Data("changed\n".utf8).write(to: fixture.workspace.appendingPathComponent("work.txt"))

        fixture.model.launchConfirmedResume()

        XCTAssertTrue(fixture.launcher.commands.isEmpty)
        XCTAssertEqual(fixture.model.message, "The reviewed workspace changed or is no longer available. Review it again before resuming.")
    }

    func testReviewedWorkspaceDeletionWithholdsLaunch() throws {
        let fixture = try makeModel()
        let item = try XCTUnwrap(fixture.model.items.first)
        recordReview(fixture, item: item)
        fixture.model.confirmResume(item)
        try FileManager.default.removeItem(at: fixture.workspace)

        fixture.model.launchConfirmedResume()

        XCTAssertTrue(fixture.launcher.commands.isEmpty)
    }

    func testReviewedWorkspaceReplacementWithholdsLaunchEvenWhenContentMatches() throws {
        let fixture = try makeModel()
        let item = try XCTUnwrap(fixture.model.items.first)
        recordReview(fixture, item: item)
        fixture.model.confirmResume(item)
        let original = directory.appendingPathComponent("original-workspace")
        try FileManager.default.moveItem(at: fixture.workspace, to: original)
        try FileManager.default.copyItem(at: original, to: fixture.workspace)

        fixture.model.launchConfirmedResume()

        XCTAssertTrue(fixture.launcher.commands.isEmpty)
    }

    func testClaudeAndCodexChildProcessesUseReviewedWorkspaceAsCurrentDirectory() throws {
        for product in RecoveryProduct.allCases {
            let workspace = directory.appendingPathComponent("cwd-\(product.rawValue)")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try runGit(["init", "-q"], in: workspace)
            try runGit(["config", "user.email", "fixture@example.invalid"], in: workspace)
            try runGit(["config", "user.name", "Fixture"], in: workspace)
            try Data("cwd\n".utf8).write(to: workspace.appendingPathComponent("work.txt"))
            try runGit(["add", "."], in: workspace)
            try runGit(["commit", "-qm", "fixture"], in: workspace)
            let review = try RecoveryReviewedWorkspace.inspect(workspace: workspace, key: Data(repeating: 3, count: 32))
            let output = directory.appendingPathComponent("cwd-\(product.rawValue).txt")
            let executableName = product == .claudeCode ? "claude" : "codex"
            let executable = directory.appendingPathComponent(executableName)
            try Data("#!/bin/sh\n/bin/pwd > '\(output.path)'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let checkpoint = checkpoint(product: product, fingerprint: "hmac-sha256-v1:" + String(repeating: "a", count: 64))
            let command = try RecoveryResumeCommand.documented(for: checkpoint, executableURL: executable)

            try RecoveryDirectCommandLauncher().launch(command, currentDirectoryURL: review.canonicalURL)
            let deadline = Date().addingTimeInterval(2)
            while ((try? Data(contentsOf: output).isEmpty) ?? true), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }

            let childCWD = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(childCWD, review.canonicalURL.path)
        }
    }

    private func makeModel(now nowProvider: (() -> Date)? = nil, checkpointCount: Int = 1) throws -> (
        model: RecoveryInboxModel,
        launcher: RecoveryLauncherSpy,
        executable: URL,
        notifications: RecoveryNotificationSpy,
        workspace: URL,
        review: RecoveryReviewedWorkspace
    ) {
        let store = RecoveryInboxStore(destination: directory.appendingPathComponent("inbox.json"))
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: workspace)
        try runGit(["config", "user.email", "fixture@example.invalid"], in: workspace)
        try runGit(["config", "user.name", "Fixture"], in: workspace)
        try Data("original\n".utf8).write(to: workspace.appendingPathComponent("work.txt"))
        try runGit(["add", "."], in: workspace)
        try runGit(["commit", "-qm", "fixture"], in: workspace)
        let keyURL = directory.appendingPathComponent("key")
        let key = try RecoveryWorkspaceFingerprint.loadOrCreateKey(at: keyURL)
        let review = try RecoveryReviewedWorkspace.inspect(workspace: workspace, key: key)
        for index in 0..<checkpointCount {
            let checkpoint = checkpoint(
                sessionReference: String(format: "123e4567-e89b-42d3-a456-%012x", index),
                fingerprint: review.fingerprint,
                createdAt: now.addingTimeInterval(-3_610 + Double(index))
            )
            XCTAssertEqual(try store.submit(checkpoint, now: now), .accepted)
        }
        let capacityURL = directory.appendingPathComponent("capacity.json")
        let publication = CapacityPublication(
            publishedAt: now,
            observations: [CapacityPublication.Observation(
                product: .codex,
                windowKind: .session,
                percentageUsed: 10,
                observedAt: now.addingTimeInterval(-1),
                expiresAt: now.addingTimeInterval(60),
                resetBoundary: now.addingTimeInterval(3_600)
            )]
        )
        try CapacityPublicationCodec.encode(publication).write(to: capacityURL)
        let executable = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let launcher = RecoveryLauncherSpy()
        let notifications = RecoveryNotificationSpy()
        let model = RecoveryInboxModel(
            store: store,
            capacityURL: capacityURL,
            fingerprintKeyURL: keyURL,
            notificationSender: notifications,
            launcher: launcher,
            executableCandidates: { _ in [executable] },
            now: nowProvider ?? { self.now }
        )
        return (model, launcher, executable, notifications, workspace, review)
    }


    private func recordReview(
        _ fixture: (model: RecoveryInboxModel, launcher: RecoveryLauncherSpy, executable: URL, notifications: RecoveryNotificationSpy, workspace: URL, review: RecoveryReviewedWorkspace),
        item: RecoveryInboxItem
    ) {
        fixture.model.recordWorkspaceReview(
            itemID: item.id,
            review: fixture.review,
            expectedFingerprint: item.checkpoint.workspaceFingerprint
        )
    }

    private func checkpoint(
        product: RecoveryProduct = .codex,
        sessionReference: String = "123e4567-e89b-42d3-a456-426614174000",
        fingerprint: String,
        createdAt: Date? = nil
    ) -> RecoveryCheckpoint {
        RecoveryCheckpoint(
            product: product,
            sessionReference: sessionReference,
            workspaceFingerprint: fingerprint,
            clientVersion: "1.2.3",
            failureClass: .quotaExhausted,
            windowKind: .session,
            resetBoundary: now.addingTimeInterval(-10),
            createdAt: createdAt ?? now.addingTimeInterval(-3_610)
        )
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
