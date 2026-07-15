import Foundation
@testable import LimitBarCore
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

    func testFailedAnalysisPreservesLastCoherentForecastAndAnomalyPair() async throws {
        let initial = try analysisSnapshot(identifier: "codex:primary:300", percentageOffset: 0)
        let attempted = try analysisSnapshot(identifier: "codex:primary:300", percentageOffset: 1)
        let service = FailingQuotaInsightsService(initial: initial, attempted: attempted)
        let state = LimitBarState(
            providerSettings: ProviderSettings.defaultSettings,
            claudeModel: ClaudeRateLimitsModel(
                credentials: ClaudeCredentialBroker.shared,
                client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
            ),
            coordinator: LocalRefreshCoordinator(dependencies: LocalRefreshDependencies(
                refreshUsage: { _, _ in throw CancellationError() },
                scanCodex: { _ in nil }
            )),
            quotaInsightsService: service
        )
        let snapshot = CodexRateLimitSnapshot(
            planType: "plus",
            primary: CodexRateLimitWindow(percentUsed: 75, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            secondary: nil,
            credits: nil,
            reportedAt: now
        )

        await state.recordCodexInsights(snapshot, now: now)
        XCTAssertEqual(state.quotaAnalysis, initial)

        await state.recordCodexInsights(snapshot, now: now.addingTimeInterval(60))
        XCTAssertEqual(state.quotaAnalysis, initial)
        XCTAssertFalse(state.quotaInsightsStorageAvailable)
        let attemptedAnalysis = await service.attemptedAnalysis
        XCTAssertEqual(attemptedAnalysis, attempted)
    }

    func testAnomalyCandidateFlowsThroughCoordinatorAndDurableLedger() async throws {
        let fixture = try makeFixture(status: .authorized)
        defer { fixture.cleanup() }
        let anomaly = try anomaly(identity: fixture.identity)

        await fixture.coordinator.evaluate(
            quota: [fixture.quota],
            costs: [],
            anomalies: [anomaly],
            now: now
        )

        XCTAssertEqual(fixture.center.added.map(\.title), ["Quota anomaly"])
        XCTAssertEqual(
            try fixture.deliveryStore.satisfactions(for: fixture.rule.id, window: .quota(fixture.identity)).map(\.threshold),
            [70]
        )
    }

    func testFailedReevaluationPreservesLastCoherentForecastAndAnomalyPair() async throws {
        let initial = try analysisSnapshot(identifier: "codex:primary:300", percentageOffset: 0)
        let attempted = try analysisSnapshot(identifier: "codex:primary:300", percentageOffset: 1)
        let service = FailingQuotaInsightsService(initial: initial, attempted: attempted)
        let state = LimitBarState(
            providerSettings: ProviderSettings.defaultSettings,
            claudeModel: ClaudeRateLimitsModel(
                credentials: ClaudeCredentialBroker.shared,
                client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
            ),
            coordinator: LocalRefreshCoordinator(dependencies: LocalRefreshDependencies(
                refreshUsage: { _, _ in throw CancellationError() },
                scanCodex: { _ in nil }
            )),
            quotaInsightsService: service
        )
        let snapshot = CodexRateLimitSnapshot(
            planType: "plus",
            primary: CodexRateLimitWindow(percentUsed: 75, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            secondary: nil,
            credits: nil,
            reportedAt: now
        )
        await state.recordCodexInsights(snapshot, now: now)

        await state.reevaluateCodexInsights(now: now.addingTimeInterval(60))

        XCTAssertEqual(state.quotaAnalysis, initial)
        XCTAssertFalse(state.quotaInsightsStorageAvailable)
    }

    func testRateLimitSurfaceExplainsQualifiedAnomalyMethodAndLimitations() throws {
        let identity = try QuotaWindowIdentity(
            product: .codex,
            identifier: "codex:primary:300",
            resetBoundary: now.addingTimeInterval(3_600)
        )
        let disclosure = PercentRateLimitPresentation.anomalyDisclosure(try anomaly(identity: identity))

        XCTAssertTrue(disclosure.contains("Calculated anomaly qualified"))
        XCTAssertTrue(disclosure.contains(QuotaAnomalyMethod.trailingMedianRatioV1.rawValue))
        XCTAssertTrue(disclosure.contains("No causal attribution"))
        XCTAssertTrue(disclosure.contains("Method validated with synthetic fixtures only"))
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

    private func analysisSnapshot(identifier: String, percentageOffset: Double) throws -> QuotaFindingAnalysisSnapshot {
        let identity = try QuotaWindowIdentity(
            product: .codex,
            identifier: identifier,
            resetBoundary: now.addingTimeInterval(3_600)
        )
        let observations = try zip([-1_800.0, -1_200, -600, -60], [70.0, 75, 80, 85]).map {
            try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: $0.1 + percentageOffset,
                observedAt: now.addingTimeInterval($0.0),
                source: .codexLocalReport
            )
        }
        return QuotaFindingAnalysisSnapshot(
            forecasts: [identity: QuotaInsightAnalytics.analyze(observations, now: now, maximumAge: 600)],
            anomalies: [identity: QuotaAnomalyAnalytics.analyze(observations, now: now, maximumAge: 600)]
        )
    }

    private func anomaly(identity: QuotaWindowIdentity) throws -> QuotaAnomalyState {
        var percentage = 10.0
        let observations = try [0.0, 2, 2, 2, 2, 2, 8].enumerated().map { index, movement in
            percentage += movement
            return try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: percentage,
                observedAt: now.addingTimeInterval(Double(index - 6) * 10 * 60),
                source: .codexLocalReport
            )
        }
        return QuotaAnomalyAnalytics.analyze(observations, now: now, maximumAge: 600)
    }
}

private actor FailingQuotaInsightsService: QuotaInsightsServing {
    private let initial: QuotaFindingAnalysisSnapshot
    private(set) var attemptedAnalysis: QuotaFindingAnalysisSnapshot
    private var callCount = 0

    init(initial: QuotaFindingAnalysisSnapshot, attempted: QuotaFindingAnalysisSnapshot) {
        self.initial = initial
        attemptedAnalysis = attempted
    }

    func recordCodexAnalysis(_ snapshot: CodexRateLimitSnapshot, now: Date) throws -> QuotaFindingAnalysisSnapshot {
        callCount += 1
        if callCount == 1 { return initial }
        throw FixtureError.analysisFailed
    }

    func recordClaudeAnalysis(_ snapshot: ClaudeRateLimitSnapshot, now: Date) throws -> QuotaFindingAnalysisSnapshot { initial }
    func reevaluateClaudeAnalysis(now: Date) throws -> QuotaFindingAnalysisSnapshot { initial }
    func reevaluateCodexAnalysis(now: Date) throws -> QuotaFindingAnalysisSnapshot { throw FixtureError.analysisFailed }
    func deleteAll() throws {}
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
    case analysisFailed
    case deliveryFailed
    case unqualifiedForecast
}
