import Foundation
import LimitBarCore
import UserNotifications
import XCTest
@testable import LimitBar

@MainActor
final class QuotaFindingAlertCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private var databasePaths: [String] = []

    override func tearDown() {
        for path in databasePaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        databasePaths = []
        super.tearDown()
    }

    func testDeniedAuthorizationDoesNotConsumeDeliveryOpportunity() async throws {
        let fixture = try makeFixture(status: .denied)
        defer { fixture.cleanup() }

        await fixture.coordinator.evaluate(
            quota: [fixture.quota],
            costs: [],
            forecasts: [fixture.forecast],
            now: now
        )

        XCTAssertTrue(fixture.center.added.isEmpty)
        XCTAssertTrue(try fixture.deliveryStore.satisfactions(for: fixture.rule.id, window: .quota(fixture.identity)).isEmpty)
        XCTAssertEqual(fixture.coordinator.authorizationStatus, .denied)
    }

    func testDeliveryFailureReleasesReservationForRetry() async throws {
        let fixture = try makeFixture(status: .authorized)
        defer { fixture.cleanup() }
        fixture.center.shouldFailDelivery = true

        await fixture.coordinator.evaluate(
            quota: [fixture.quota],
            costs: [],
            forecasts: [fixture.forecast],
            now: now
        )
        XCTAssertTrue(try fixture.deliveryStore.satisfactions(for: fixture.rule.id, window: .quota(fixture.identity)).isEmpty)
        XCTAssertEqual(fixture.coordinator.lastErrorMessage, "A notification could not be delivered and will be retried.")

        fixture.center.shouldFailDelivery = false
        await fixture.coordinator.evaluate(
            quota: [fixture.quota],
            costs: [],
            forecasts: [fixture.forecast],
            now: now
        )

        XCTAssertEqual(fixture.center.added.map(\.title), ["Quota forecast"])
        XCTAssertEqual(try fixture.deliveryStore.satisfactions(for: fixture.rule.id, window: .quota(fixture.identity)).map(\.threshold), [70])
    }

    private func makeFixture(status: UNAuthorizationStatus) throws -> Fixture {
        let suite = "QuotaFindingAlertCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = AlertSettingsStore(defaults: defaults, notificationCenter: NotificationCenter())
        let rule = QuotaAlertRule(
            id: UUID(uuidString: "E4633E94-0687-467F-9779-E1C2B0FD4847")!,
            product: .codex,
            thresholds: try PercentageThresholds([70])
        )
        XCTAssertTrue(settings.replaceQuotaRules([rule]))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        databasePaths.append(path)
        let deliveryStore = try SQLiteAlertDeliveryStore(path: path)
        let center = RecordingAlertNotificationCenter(status: status)
        let coordinator = AlertCoordinator(
            settingsStore: settings,
            notificationCenter: center,
            deliveryStore: deliveryStore
        )
        let identity = try QuotaWindowIdentity(
            product: .codex,
            identifier: "codex:primary:300",
            resetBoundary: now.addingTimeInterval(3_600)
        )
        let measured = try zip([-1_800.0, -1_200, -600, -60], [70.0, 75, 80, 85]).map {
            try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: $0.1,
                observedAt: now.addingTimeInterval($0.0),
                source: .codexLocalReport
            )
        }
        let forecast = QuotaInsightAnalytics.analyze(measured, now: now, maximumAge: 600)
        guard case .qualified = forecast else {
            XCTFail("Expected a qualified forecast fixture")
            throw FixtureError.unqualifiedForecast
        }
        let quota = QuotaObservation(
            identity: identity,
            percentageUsed: 75,
            observedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(60)
        )
        return Fixture(
            coordinator: coordinator,
            center: center,
            deliveryStore: deliveryStore,
            rule: rule,
            identity: identity,
            forecast: forecast,
            quota: quota,
            defaults: defaults,
            suite: suite
        )
    }
}

@MainActor
private final class RecordingAlertNotificationCenter: AlertNotificationCenter {
    struct Added {
        let identifier: String
        let title: String
        let body: String
    }

    var status: UNAuthorizationStatus
    var shouldFailDelivery = false
    private(set) var added: [Added] = []

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool { status == .authorized }

    func add(identifier: String, title: String, body: String) async throws {
        if shouldFailDelivery { throw FixtureError.deliveryFailed }
        added.append(Added(identifier: identifier, title: title, body: body))
    }

    func pendingIdentifiers() async -> [String] { added.map(\.identifier) }
    func deliveredIdentifiers() async -> [String] { [] }
    func removePending(identifiers: [String]) {}
    func removeDelivered(identifiers: [String]) {}
}

@MainActor
private struct Fixture {
    let coordinator: AlertCoordinator
    let center: RecordingAlertNotificationCenter
    let deliveryStore: SQLiteAlertDeliveryStore
    let rule: QuotaAlertRule
    let identity: QuotaWindowIdentity
    let forecast: QuotaInsightState
    let quota: QuotaObservation
    let defaults: UserDefaults
    let suite: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private enum FixtureError: Error {
    case deliveryFailed
    case unqualifiedForecast
}
