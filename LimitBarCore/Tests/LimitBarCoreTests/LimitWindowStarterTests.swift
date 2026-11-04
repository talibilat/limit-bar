import XCTest
@testable import LimitBarCore

final class LimitWindowStarterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSendsNowWhenNoSessionWindowHasStarted() {
        let resets = LimitWindowResets(hasSessionWindow: true, sessionResetsAt: nil, weeklyResetsAt: now.addingTimeInterval(86_400))
        XCTAssertEqual(WindowStartPlan.plan(resets: resets, lastSentAt: nil, now: now), .sendNow)
    }

    func testWaitsUntilOneMinuteAfterTheEarliestReset() {
        let session = now.addingTimeInterval(3_600)
        let resets = LimitWindowResets(hasSessionWindow: true, sessionResetsAt: session, weeklyResetsAt: now.addingTimeInterval(86_400))
        XCTAssertEqual(WindowStartPlan.plan(resets: resets, lastSentAt: nil, now: now), .wait(until: session.addingTimeInterval(60)))
    }

    func testWeeklyResetAlsoTriggersASend() {
        let resets = LimitWindowResets(hasSessionWindow: false, sessionResetsAt: nil, weeklyResetsAt: now.addingTimeInterval(-120))
        XCTAssertEqual(WindowStartPlan.plan(resets: resets, lastSentAt: now.addingTimeInterval(-86_400), now: now), .sendNow)
    }

    func testDoesNotResendForAResetAlreadyHandled() {
        let reset = now.addingTimeInterval(-15 * 60)
        let resets = LimitWindowResets(hasSessionWindow: true, sessionResetsAt: reset, weeklyResetsAt: nil)
        let plan = WindowStartPlan.plan(resets: resets, lastSentAt: reset.addingTimeInterval(90), now: now)
        XCTAssertEqual(plan, .wait(until: now.addingTimeInterval(WindowStartPlan.recheckInterval)))
    }

    func testThrottlesSendsCloserThanTenMinutes() {
        let resets = LimitWindowResets(hasSessionWindow: true, sessionResetsAt: nil, weeklyResetsAt: nil)
        let lastSent = now.addingTimeInterval(-60)
        XCTAssertEqual(WindowStartPlan.plan(resets: resets, lastSentAt: lastSent, now: now), .wait(until: lastSent.addingTimeInterval(600)))
    }

    func testKeepsDueResetWhenProviderReportsNextWindow() {
        let due = now.addingTimeInterval(-60)
        let resets = LimitWindowResets(hasSessionWindow: true, sessionResetsAt: now.addingTimeInterval(18_000), weeklyResetsAt: nil)
        XCTAssertEqual(WindowStartPlan.pendingSendAt(resets: resets, previous: due, lastSentAt: nil), due)
    }

    func testKeepsDueResetWhenLimitsCannotBeRead() {
        let due = now.addingTimeInterval(-60)
        XCTAssertEqual(WindowStartPlan.pendingSendAt(resets: nil, previous: due, lastSentAt: nil), due)
    }

    func testSuccessfulSendClearsOldResetAndKeepsNextOne() {
        let next = now.addingTimeInterval(18_000)
        let resets = LimitWindowResets(hasSessionWindow: true, sessionResetsAt: next, weeklyResetsAt: nil)
        XCTAssertEqual(WindowStartPlan.pendingSendAt(resets: resets, previous: now.addingTimeInterval(-60), lastSentAt: now), next.addingTimeInterval(60))
    }

    @MainActor
    func testFailedSendRemainsPendingAcrossRestart() async {
        let suite = "LimitWindowStarterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let due = Date().addingTimeInterval(-120)
        let starter = LimitWindowStarter(defaults: defaults)
        starter.setEnabled(true, for: .codex)
        starter.start(readResets: { _ in
            LimitWindowResets(hasSessionWindow: true, sessionResetsAt: due, weeklyResetsAt: nil)
        }, send: { _ in false })
        for _ in 0..<100 where starter.status(.codex).lastSucceeded == nil {
            await Task.yield()
        }
        XCTAssertEqual(starter.status(.codex).lastSucceeded, false)
        XCTAssertNil(starter.status(.codex).lastSentAt)
        XCTAssertNotNil(defaults.object(forKey: "limitbar.windowStarter.codex.pendingSendAt"))
        starter.setEnabled(false, for: .codex)

        let restarted = LimitWindowStarter(defaults: defaults)
        restarted.setEnabled(true, for: .codex)
        restarted.start(readResets: { _ in nil }, send: { _ in true })
        for _ in 0..<100 where restarted.status(.codex).lastSucceeded == nil {
            await Task.yield()
        }
        XCTAssertEqual(restarted.status(.codex).lastSucceeded, true)
        XCTAssertNotNil(restarted.status(.codex).lastSentAt)
        XCTAssertNil(defaults.object(forKey: "limitbar.windowStarter.codex.pendingSendAt"))
        restarted.setEnabled(false, for: .codex)
    }

    func testMessagesUseTheSmallestPrompt() {
        XCTAssertEqual(LimitWindowMessenger.message, ".")
        XCTAssertEqual(LimitWindowMessenger.arguments(for: .claudeCode).prefix(2), ["-p", "."])
        XCTAssertEqual(LimitWindowMessenger.arguments(for: .codex).last, ".")
    }
}
