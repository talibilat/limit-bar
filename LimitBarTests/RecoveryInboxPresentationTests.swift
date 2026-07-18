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

    func launch(_ command: RecoveryResumeCommand) throws {
        commands.append(command)
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
        fixture.model.recordWorkspaceReview(itemID: item.id, state: .unchanged)

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
        fixture.model.recordWorkspaceReview(itemID: item.id, state: .unchanged)
        fixture.model.confirmResume(item)
        let pending = try XCTUnwrap(fixture.model.pendingResume)

        XCTAssertTrue(pending.command.display.hasPrefix(pending.command.executableURL.path))
        fixture.model.launchConfirmedResume()

        XCTAssertEqual(fixture.launcher.commands, [pending.command])
        XCTAssertEqual(fixture.launcher.commands.first?.executableURL, pending.command.executableURL)
    }

    func testExecutableReplacementAfterConfirmationWithholdsLaunch() throws {
        let fixture = try makeModel()
        let item = try XCTUnwrap(fixture.model.items.first)
        fixture.model.recordWorkspaceReview(itemID: item.id, state: .unchanged)
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
        fixture.model.recordWorkspaceReview(itemID: item.id, state: .unchanged)
        fixture.model.confirmResume(item)
        current = current.addingTimeInterval(RecoveryInboxModel.sessionConfirmationLifetime + 1)

        fixture.model.launchConfirmedResume()

        XCTAssertTrue(fixture.launcher.commands.isEmpty)
        XCTAssertEqual(fixture.model.message, "Session confirmation expired. Revalidate before resuming.")
    }

    func testMultipleReadyItemsDeliverUniquePrivacySafeNotifications() async throws {
        let fixture = try makeModel(checkpointCount: 2)
        for item in fixture.model.items {
            fixture.model.recordWorkspaceReview(itemID: item.id, state: .unchanged)
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

    private func makeModel(now nowProvider: (() -> Date)? = nil, checkpointCount: Int = 1) throws -> (
        model: RecoveryInboxModel,
        launcher: RecoveryLauncherSpy,
        executable: URL,
        notifications: RecoveryNotificationSpy
    ) {
        let store = RecoveryInboxStore(destination: directory.appendingPathComponent("inbox.json"))
        for index in 0..<checkpointCount {
            let checkpoint = RecoveryCheckpoint(
                product: .codex,
                sessionReference: String(format: "123e4567-e89b-42d3-a456-%012x", index),
                workspaceFingerprint: "hmac-sha256-v1:" + String(repeating: "a", count: 64),
                clientVersion: "1.2.3",
                failureClass: .quotaExhausted,
                windowKind: .session,
                resetBoundary: now.addingTimeInterval(-10),
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
            fingerprintKeyURL: directory.appendingPathComponent("key"),
            notificationSender: notifications,
            launcher: launcher,
            executableCandidates: { _ in [executable] },
            now: nowProvider ?? { self.now }
        )
        return (model, launcher, executable, notifications)
    }
}
