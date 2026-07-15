import XCTest
import LimitBarCore
@testable import LimitBar

final class ProviderRefreshHistoryPresentationTests: XCTestCase {
    @MainActor
    func testPlanningEvidenceSelectsClaudeWhenBothProductsArePresent() throws {
        let fixture = try PlanningCurrentEvidenceFixture()

        let selected = LiveWorkloadPlanningData.currentEvidence(
            for: fixture.support(.claudeCode),
            codexSnapshot: fixture.codexSnapshot,
            claudeSnapshot: fixture.claudeSnapshot,
            forecasts: fixture.forecasts
        )

        XCTAssertEqual(selected?.latestObservation.identity.product, .claudeCode)
        XCTAssertEqual(selected?.latestObservation.stableIdentity, fixture.claudeObservation.stableIdentity)
    }

    @MainActor
    func testPlanningEvidenceReturnsNilWhenOnlyWrongProductIsPresent() throws {
        let fixture = try PlanningCurrentEvidenceFixture()

        let selected = LiveWorkloadPlanningData.currentEvidence(
            for: fixture.support(.claudeCode),
            codexSnapshot: fixture.codexSnapshot,
            claudeSnapshot: nil,
            forecasts: [fixture.codexObservation.identity: fixture.codexForecast]
        )

        XCTAssertNil(selected)
    }

    @MainActor
    func testPlanningEvidenceSelectsMatchingCodexProduct() throws {
        let fixture = try PlanningCurrentEvidenceFixture()

        let selected = LiveWorkloadPlanningData.currentEvidence(
            for: fixture.support(.codex),
            codexSnapshot: fixture.codexSnapshot,
            claudeSnapshot: fixture.claudeSnapshot,
            forecasts: fixture.forecasts
        )

        XCTAssertEqual(selected?.latestObservation.identity.product, .codex)
        XCTAssertEqual(selected?.latestObservation.stableIdentity, fixture.codexObservation.stableIdentity)
    }

    @MainActor
    func testUnsupportedPlanningSelectsNoProductEvidenceOrReset() throws {
        let fixture = try PlanningCurrentEvidenceFixture()
        let selected = LiveWorkloadPlanningData.currentEvidence(
            for: nil,
            codexSnapshot: fixture.codexSnapshot,
            claudeSnapshot: fixture.claudeSnapshot,
            forecasts: fixture.forecasts
        )
        let result = WorkloadPlanningSurfaceResult(WorkloadPlanning.unavailableForUnsupportedAdapter(
            currentEvidence: selected,
            now: fixture.now
        ))

        XCTAssertNil(selected)
        XCTAssertTrue(result.evidence.contains("No compatible current quota evidence"))
        XCTAssertFalse(result.evidence.contains("exact reset"))
        XCTAssertFalse(result.evidence.contains("Claude"))
        XCTAssertFalse(result.evidence.contains("Codex"))
    }

    @MainActor
    func testPlannedWorkloadViewRendersInjectedAvailableIndeterminateAndUnavailableStates() {
        let cases: [(WorkloadPlanningSurfaceStatus, String)] = [
            (.available, "Assessment available"),
            (.indeterminate, "Assessment indeterminate"),
            (.unavailable, "Assessment unavailable"),
        ]

        for (status, title) in cases {
            let expected = WorkloadPlanningSurfaceResult(
                status: status,
                title: title,
                summary: "Fixture summary",
                evidence: "Fixture evidence"
            )
            let provider = InjectedWorkloadPlanningData(expected: expected)
            let view = PlannedWorkloadView(data: provider)

            XCTAssertEqual(view.renderedResult, expected)
        }
    }

    @MainActor
    func testUnsupportedProductionBoundaryHidesNoOpPlanningControls() {
        let state = LimitBarState(
            providerSettings: [],
            claudeModel: ClaudeRateLimitsModel(
                credentials: ClaudeCredentialBroker.shared,
                client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
            ),
            coordinator: LocalRefreshCoordinator(dependencies: LocalRefreshDependencies(
                refreshUsage: { _, _ in throw CancellationError() },
                scanCodex: { _ in nil }
            ))
        )
        let provider = LiveWorkloadPlanningData(state: state)

        XCTAssertNil(provider.inputSupport)
        XCTAssertEqual(provider.result(workUnits: 10, concurrency: 1, now: Date()).status, .unavailable)
    }

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
        let codexExplanationStore = try SQLiteCodexExplanationStore(path: directory.appendingPathComponent("codex-explanations.sqlite").path)
        try codexExplanationStore.record(.unavailable(.gap), now: now)
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
            quotaInsightsService: service,
            codexExplanationStore: codexExplanationStore
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

        let deletedExplanations = await state.deleteCodexExplanations()
        XCTAssertTrue(deletedExplanations)
        XCTAssertNil(try codexExplanationStore.latest(now: now))
        XCTAssertEqual(try usageStore.allMetrics(), [metric])
        XCTAssertEqual(try quotaStore.observations(for: identity, now: now), [])
        XCTAssertEqual(try deliveryStore.satisfactions(for: rule.id, window: .quota(identity)).map(\.threshold), [50])
        XCTAssertEqual(alertSettings.preferences, alertPreferences)
        XCTAssertEqual(providerSettingsStore.settings, ProviderSettingsPersistence.decode(try ProviderSettingsPersistence.encode([providerSetting])))
        XCTAssertEqual(try credentialService.credential(for: credentialKey), Data("fixture-secret".utf8))
    }

    @MainActor
    func testRetainedCodexExplanationRestoresIntoStateAndDiagnosticsAndDeletesImmediately() async throws {
        let store = try SQLiteCodexExplanationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let explanation = CodexQuotaExplanation(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            quotaResetBoundary: now.addingTimeInterval(3_600),
            coverageStart: now.addingTimeInterval(-130),
            coverageEnd: now.addingTimeInterval(-50),
            calculatedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(
                tokens: CodexMeasuredTokens(input: 3, cachedInput: 1, output: 2, reasoningOutput: 1),
                sessionCount: 1
            ),
            unattributed: true,
            inferredAllocation: nil,
            observationIdentities: [],
            evidenceIdentities: ["retained-private-digest"],
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            barriers: []
        )
        try store.record(.available(explanation), now: now)

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
            codexExplanationStore: store
        )

        guard case .available = state.local.codexExplanation else {
            return XCTFail("Expected retained explanation to be restored")
        }
        let restoredRetained = state.local.codexExplanationRetained
        XCTAssertTrue(restoredRetained)

        let input = try DiagnosticExportInputBuilder.make(
            generatedAt: now,
            applicationVersion: "1.0.0",
            applicationBuild: "1",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0),
            providerSettings: ProviderSettings.defaultSettings,
            customSourceCount: 0,
            databaseIsAvailable: true,
            acceptedImportCount: 0,
            rejectedImportCount: 0,
            customImportFailures: 0,
            customRejectedLines: 0,
            refreshHistory: [:],
            quotaInsights: [:],
            codexExplanation: state.local.codexExplanation,
            codexExplanationRetained: restoredRetained
        )
        let artifact = try DiagnosticExport.make(from: input)
        let preview = try artifact.preview
        XCTAssertTrue(preview.contains(#""retention" : "retained""#))
        XCTAssertFalse(preview.contains("retained-private-digest"))

        let deleted = await state.deleteCodexExplanations()
        let clearedExplanation = state.local.codexExplanation
        let clearedRetained = state.local.codexExplanationRetained
        XCTAssertTrue(deleted)
        XCTAssertEqual(clearedExplanation, .unavailable(.insufficientObservations))
        XCTAssertFalse(clearedRetained)
        XCTAssertNil(try store.latest(now: now))
    }

    @MainActor
    func testProjectAgentAttributionDeletionReportsCommittedSuccessAndFailure() async throws {
        let successfulStore = AttributionDeletionStub(shouldFail: false)
        let successfulState = makeState(attributionStore: successfulStore)

        let succeeded = await successfulState.deleteProjectAgentAttribution()
        let successfulCalls = await successfulStore.callCount()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(successfulCalls, 1)
        XCTAssertEqual(
            AttributionEvidenceDeletionPresentation.message(succeeded: true),
            "Project and agent attribution deleted. Parent usage, source files, settings, credentials, alert rules, and delivery history were not changed."
        )

        let failingStore = AttributionDeletionStub(shouldFail: true)
        let failingState = makeState(attributionStore: failingStore)
        let failed = await failingState.deleteProjectAgentAttribution()
        let failingCalls = await failingStore.callCount()
        XCTAssertFalse(failed)
        XCTAssertEqual(failingCalls, 1)
        XCTAssertEqual(
            AttributionEvidenceDeletionPresentation.message(succeeded: false),
            "Could not delete project and agent attribution. Existing attribution was left available."
        )
    }

    @MainActor
    private func makeState(attributionStore: any AttributionEvidenceDeleting) -> LimitBarState {
        LimitBarState(
            providerSettings: ProviderSettings.defaultSettings,
            claudeModel: ClaudeRateLimitsModel(
                credentials: ClaudeCredentialBroker.shared,
                client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
            ),
            coordinator: LocalRefreshCoordinator(dependencies: LocalRefreshDependencies(
                refreshUsage: { _, _ in throw CancellationError() },
                scanCodex: { _ in nil }
            )),
            attributionEvidenceStore: attributionStore
        )
    }
}

@MainActor
private struct InjectedWorkloadPlanningData: WorkloadPlanningDataProviding {
    let expected: WorkloadPlanningSurfaceResult
    var inputSupport: WorkloadPlanningInputSupport? { nil }

    func result(workUnits: Int, concurrency: Int, now: Date) -> WorkloadPlanningSurfaceResult {
        expected
    }
}

private struct PlanningCurrentEvidenceFixture {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let codexSnapshot: CodexRateLimitSnapshot
    let claudeSnapshot: ClaudeRateLimitSnapshot
    let codexObservation: MeasuredQuotaObservation
    let claudeObservation: MeasuredQuotaObservation
    let codexForecast: QuotaInsightState
    let claudeForecast: QuotaInsightState

    var forecasts: [QuotaWindowIdentity: QuotaInsightState] {
        [codexObservation.identity: codexForecast, claudeObservation.identity: claudeForecast]
    }

    init() throws {
        codexSnapshot = CodexRateLimitSnapshot(
            planType: "plus",
            primary: CodexRateLimitWindow(
                percentUsed: 25,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3_600)
            ),
            secondary: nil,
            credits: nil,
            reportedAt: now
        )
        claudeSnapshot = ClaudeRateLimitSnapshot(
            limits: [ClaudeRateLimit(
                kind: "session",
                group: .session,
                percentUsed: 35,
                severity: .normal,
                resetsAt: now.addingTimeInterval(3_600),
                scopeDisplayName: nil,
                isActive: true
            )],
            fetchedAt: now
        )
        codexObservation = try XCTUnwrap(MeasuredQuotaObservationAdapter.codex(codexSnapshot).first)
        claudeObservation = try XCTUnwrap(MeasuredQuotaObservationAdapter.claude(claudeSnapshot).first)
        codexForecast = QuotaInsightAnalytics.analyze(
            [], now: now, maximumAge: QuotaObservationAdapter.codexMaximumAge,
            expectedIdentity: codexObservation.identity
        )
        claudeForecast = QuotaInsightAnalytics.analyze(
            [], now: now, maximumAge: QuotaObservationAdapter.claudeMaximumAge,
            expectedIdentity: claudeObservation.identity
        )
    }

    func support(_ product: ProviderProduct) -> CompletedWorkloadRunSupport {
        CompletedWorkloadRunSupport(
            product: product,
            kind: .codingAgentOperations,
            quotaWindowKind: .session,
            executionMode: .interactive,
            source: .normalizedCompletedRunAdapter,
            adapterVersion: WorkloadAdapterVersion(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            clientVersion: WorkloadClientVersion(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            providerFormatVersion: WorkloadProviderFormatVersion(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        )
    }
}

private actor AttributionDeletionStub: AttributionEvidenceDeleting {
    private let shouldFail: Bool
    private var calls = 0

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func deleteAllAttributionEvidence(now: Date) async throws {
        calls += 1
        if shouldFail { throw AttributionDeletionTestError.failed }
    }

    func callCount() -> Int { calls }
}

private enum AttributionDeletionTestError: Error {
    case failed
}

private final class QuotaDeletionCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [CredentialKey: Data] = [:]

    func save(_ data: Data, for key: CredentialKey) throws { values[key] = data }
    func data(for key: CredentialKey) throws -> Data? { values[key] }
    func contains(_ key: CredentialKey) throws -> Bool { values[key] != nil }
    func remove(_ key: CredentialKey) throws { values[key] = nil }
}
