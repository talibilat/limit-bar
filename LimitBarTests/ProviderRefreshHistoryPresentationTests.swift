import XCTest
import LimitBarCore
@testable import LimitBar

final class ProviderRefreshHistoryPresentationTests: XCTestCase {
    func testOutcomesUseDistinctSafeCopy() {
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.success), "Succeeded")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.partialFailure), "Partially failed")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.cancelled), "Cancelled")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.authenticationFailure), "Authentication failed")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.networkFailure), "Network failed")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.failed), "Failed")
    }

    func testMissingHistoryDoesNotImplySuccessOrZeroUsage() {
        XCTAssertEqual(ProviderRefreshHistoryStatusText.latest(nil), "No explicit refresh recorded")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.lastFullSuccess(nil), "No full success recorded")
    }

    func testDisplayedPercentageAlwaysHasMeasuredProvenance() {
        XCTAssertEqual(PercentRateLimitPresentation.percentageUsed(24.6), "Measured: 25% used")
    }

    func testClaudeLoginHelpUsesOfficialHTTPSDocumentation() {
        XCTAssertEqual(ClaudeLoginHelp.url.scheme, "https")
        XCTAssertEqual(ClaudeLoginHelp.url.host, "code.claude.com")
    }

    func testRefreshExecutionCarriesServiceWindowsAcrossBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let before = try CurrentUsageWindows.resolve(
            at: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-04T23:59:00Z")),
            calendar: calendar
        )
        let serviceWindows = try CurrentUsageWindows.resolve(
            at: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-05T00:01:00Z")),
            calendar: calendar
        )

        let execution = ProviderRefreshExecution(outcome: .success, windows: serviceWindows)

        XCTAssertEqual(execution.affectedWindows, [serviceWindows.today, serviceWindows.currentWeek, serviceWindows.utcBillingWeek])
        XCTAssertNotEqual(execution.affectedWindows, [before.today, before.currentWeek, before.utcBillingWeek])
    }

    func testPreFetchFailureHasNoAffectedWindows() {
        XCTAssertEqual(ProviderRefreshExecution(outcome: .failed).affectedWindows, [])
    }

    @MainActor
    func testDeletingQuotaEvidencePreservesUnrelatedApplicationState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "LimitBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usagePath = directory.appendingPathComponent("usage.sqlite").path
        let usageStore = try SQLiteUsageMetricStore(path: usagePath)
        let metric = UsageMetric(
            provider: .openAI,
            accountLabel: nil,
            projectLabel: nil,
            modelLabel: "integration-fixture",
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 5),
            cost: nil,
            limitStatus: .unavailable,
            refreshedAt: now,
            freshness: .fresh
        )
        try usageStore.save([metric])

        let rule = QuotaAlertRule(product: .codex, thresholds: try PercentageThresholds([50]))
        let alertPreferences = try AlertPreferences(quotaRules: [rule], costBudgetRules: [])
        let alertSettings = AlertSettingsStore(defaults: defaults, notificationCenter: NotificationCenter())
        XCTAssertTrue(alertSettings.replaceRules(with: alertPreferences))
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: now.addingTimeInterval(3_600))
        let occurrence = AlertOccurrence(ruleID: rule.id, window: .quota(identity), thresholds: [50])
        let deliveryStore = try SQLiteAlertDeliveryStore(path: usagePath)
        let reservation = try XCTUnwrap(deliveryStore.reserve(occurrence, now: now))
        try deliveryStore.markDelivered(reservation, at: now)

        let providerSettingsStore = ProviderSettingsStore(defaults: defaults)
        let providerSetting = try XCTUnwrap(ProviderSettings.defaultSettings.first)
        providerSettingsStore.update(providerSetting)
        let credentialStore = QuotaDeletionCredentialStore()
        let credentialService = CredentialService(store: credentialStore)
        let credentialKey = CredentialKey(provider: .openAI, kind: .apiKey)
        try credentialService.save("fixture-secret", for: credentialKey)

        let quotaStore = try SQLiteQuotaObservationStore(path: directory.appendingPathComponent("quota.sqlite").path)
        let observation = try MeasuredQuotaObservation(identity: identity, percentageUsed: 25, observedAt: now, source: .codexLocalReport)
        try quotaStore.record([observation], now: now)
        let service = QuotaInsightsService(store: quotaStore)
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
        await state.refreshQuotaInsights(for: LocalRefreshSnapshot(
            sequence: 1,
            usage: nil,
            codex: CodexRateLimitSnapshot(
                planType: "plus",
                primary: CodexRateLimitWindow(percentUsed: 25, windowMinutes: 300, resetsAt: identity.resetBoundary),
                secondary: nil,
                credits: nil,
                reportedAt: now
            ),
            refreshedAt: now,
            codexRefreshed: true
        ))
        XCTAssertFalse(state.quotaInsights.isEmpty)

        let deleted = await state.deleteQuotaObservations()
        XCTAssertTrue(deleted)

        XCTAssertTrue(state.quotaInsights.isEmpty)
        XCTAssertEqual(try quotaStore.observations(for: identity, now: now), [])
        XCTAssertEqual(try usageStore.allMetrics(), [metric])
        XCTAssertEqual(try deliveryStore.satisfactions(for: rule.id, window: .quota(identity)).map(\.threshold), [50])
        XCTAssertEqual(alertSettings.preferences, alertPreferences)
        XCTAssertEqual(providerSettingsStore.settings, ProviderSettingsPersistence.decode(try ProviderSettingsPersistence.encode([providerSetting])))
        XCTAssertEqual(try credentialService.credential(for: credentialKey), Data("fixture-secret".utf8))
    }
}

private final class QuotaDeletionCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [CredentialKey: Data] = [:]

    func save(_ data: Data, for key: CredentialKey) throws { values[key] = data }
    func data(for key: CredentialKey) throws -> Data? { values[key] }
    func contains(_ key: CredentialKey) throws -> Bool { values[key] != nil }
    func remove(_ key: CredentialKey) throws { values[key] = nil }
}
