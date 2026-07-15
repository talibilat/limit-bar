import Foundation
import LimitBarCore
import XCTest
@testable import LimitBar

@MainActor
final class DiagnosticExportPresentationTests: XCTestCase {
    func testQuotaInsightDisclosureStatesMethodQualificationAndLimitationConservatively() throws {
        let fixtures = try QuotaForecastFrozenCorpus.validatedFixtures()
        let qualifiedFixture = try XCTUnwrap(fixtures.first { $0.id == "heldout-codex-stable-01" })
        let unavailableFixture = try XCTUnwrap(fixtures.first { $0.id == "heldout-claude-stale-01" })
        let qualified = QuotaInsightAnalytics.analyze(qualifiedFixture.observations, now: qualifiedFixture.evaluationTime, maximumAge: qualifiedFixture.maximumEvidenceAge)
        let unavailable = QuotaInsightAnalytics.analyze(unavailableFixture.observations, now: unavailableFixture.evaluationTime, maximumAge: unavailableFixture.maximumEvidenceAge)

        XCTAssertEqual(PercentRateLimitPresentation.methodDisclosure(qualified), "Calculated pairwise_positive_slope_interquartile_v2 qualified; provider weighting is unknown.")
        XCTAssertEqual(PercentRateLimitPresentation.methodDisclosure(unavailable), "Calculated pairwise_positive_slope_interquartile_v2 unavailable: measured observations are stale.")
        XCTAssertEqual(PercentRateLimitPresentation.burnRange(QuotaInsightRange(lower: 0.04, upper: 0.16)), "0.04-0.16% per hour")
        XCTAssertEqual(PercentRateLimitPresentation.burnRange(QuotaInsightRange(lower: 0.004, upper: 0.16)), "<0.01-0.16% per hour")

        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let crossing = Date(timeIntervalSince1970: 1_798_761_000)...Date(timeIntervalSince1970: 1_798_762_200)
        XCTAssertEqual(
            PercentRateLimitPresentation.exhaustionRange(crossing, calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US_POSIX"), timeZone: utc),
            "2026-12-31 23:50 GMT-2027-01-01 00:10 GMT"
        )
    }

    func testAppBuilderProjectsOnlySafeLiveState() throws {
        let privatePath = "/Users/PRIVATE_USER/SECRET_PROJECT"
        let privateOrganization = "SECRET_ORGANIZATION"
        let settings = ProviderSettings(
            provider: .openAI,
            authMethod: .openAIOAuth,
            azureEndpoint: privatePath,
            openAIOrganizationID: privateOrganization,
            state: .failed,
            failureReason: .networkUnavailable,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_123)
        )
        let window = try ExactUsageWindow(
            timeWindow: .today,
            start: Date(timeIntervalSince1970: 1_699_920_000),
            end: Date(timeIntervalSince1970: 1_700_006_400),
            basis: .localCalendar,
            aggregationVersion: 99
        )
        let history = try ProviderRefreshHistoryEntry(
            product: .openAIAPI,
            outcome: .networkFailure,
            startedAt: Date(timeIntervalSince1970: 1_700_000_123),
            duration: 2,
            affectedWindows: [window]
        )
        let privateQuotaIdentifier = "session:SECRET_ACCOUNT_WINDOW"
        let quotaIdentity = try QuotaWindowIdentity(
            product: .claudeCode,
            identifier: privateQuotaIdentifier,
            resetBoundary: Date(timeIntervalSince1970: 1_700_007_200)
        )
        let explanationInterval = ClaudeQuotaExplanationInterval(id: "RAW_PAYLOAD_SENTINEL", identity: quotaIdentity, intervalStart: Date(timeIntervalSince1970: 1_700_000_000), intervalEnd: Date(timeIntervalSince1970: 1_700_000_100), lifecycle: .active)
        let explanation = ClaudeQuotaExplanation(
            providerProduct: .claudeCode,
            intervalStart: explanationInterval.intervalStart,
            intervalEnd: explanationInterval.intervalEnd,
            quotaResetBoundary: quotaIdentity.resetBoundary,
            reportedQuotaMovementPercent: 1,
            attribution: .partial(ClaudeObservedLocalBreakdown(inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0, modelCounts: ["CODE_SENTINEL": 1], sessionCount: 1, evidenceCount: 1)),
            unattributed: true,
            inferredAllocation: nil,
            observationIdentities: [],
            evidenceIdentities: ["CREDENTIAL_SENTINEL", "PRIVATE_PATH_SENTINEL", "ACCOUNT_LABEL_SENTINEL", "RESPONSE_SENTINEL", "TERMINAL_SENTINEL"],
            observationSpan: 100,
            evidenceAge: 0,
            methodVersion: ClaudeQuotaExplanationEngine.methodVersion,
            sourceAdapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion,
            sourceVersion: ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion
        )
        let explanationCatalog = ClaudeQuotaExplanationCatalog(
            selections: [ClaudeQuotaExplanationSelection(interval: explanationInterval, state: .movement(explanation), limitations: [])],
            defaultSelectionID: explanationInterval.id
        )

        let input = try DiagnosticExportInputBuilder.make(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_123),
            applicationVersion: "1.2.3",
            applicationBuild: "42",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0),
            providerSettings: ProviderSettings.defaultSettings.map { $0.provider == .openAI ? settings : $0 },
            customSourceCount: 1,
            databaseIsAvailable: false,
            acceptedImportCount: 7,
            rejectedImportCount: 2,
            customImportFailures: 0,
            customRejectedLines: 3,
            refreshHistory: [.openAIAPI: ProviderRefreshHistorySummary(latest: history, lastFullSuccess: nil)],
            quotaInsights: [quotaIdentity: unavailable(.insufficientObservations, identity: quotaIdentity, count: 3, span: 600)],
            claudeExplanations: explanationCatalog
        )
        let artifact = try DiagnosticExport.make(from: input)
        let preview = try artifact.preview

        XCTAssertTrue(preview.contains(#""state" : "networkUnavailable""#))
        XCTAssertEqual(input.providerStatuses.filter { $0.provider == .custom }, [
            DiagnosticProviderStatus(provider: .custom, state: .connected),
        ])
        XCTAssertTrue(preview.contains(#""rejected" : 5"#))
        XCTAssertFalse(preview.contains(privatePath))
        XCTAssertFalse(preview.contains(privateOrganization))
        XCTAssertFalse(preview.contains("updatedAt"))
        XCTAssertFalse(preview.contains("authMethod"))
        XCTAssertFalse(preview.contains("aggregationVersion"))
        XCTAssertFalse(preview.contains("localCalendar"))
        XCTAssertTrue(preview.contains(#""affectedWindowKinds""#))
        XCTAssertTrue(preview.contains(#""measuredObservationCount" : 3"#))
        XCTAssertTrue(preview.contains(#""status" : "insufficient_observations""#))
        XCTAssertTrue(preview.contains(#""forecastMethod" : "pairwise_positive_slope_interquartile_v2""#))
        XCTAssertTrue(preview.contains(#""qualification" : "unavailable""#))
        XCTAssertFalse(preview.contains(privateQuotaIdentifier))
        for prohibited in ["RAW_PAYLOAD_SENTINEL", "CODE_SENTINEL", "CREDENTIAL_SENTINEL", "PRIVATE_PATH_SENTINEL", "ACCOUNT_LABEL_SENTINEL", "RESPONSE_SENTINEL", "TERMINAL_SENTINEL"] {
            XCTAssertFalse(preview.contains(prohibited))
        }
        XCTAssertFalse(preview.contains("resetBoundary"))
    }

    func testPreviewArtifactIsSavedWithoutRegeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("chosen.json")
        var generation = 0
        let model = DiagnosticExportModel(
            makeArtifact: {
                generation += 1
                return try self.artifact(build: generation)
            },
            chooseDestination: { destination }
        )

        await model.prepare()
        let preview = model.preview
        model.save()

        XCTAssertEqual(generation, 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data(preview.utf8))
        XCTAssertEqual(model.message, "Diagnostic export saved.")
    }

    func testFailuresExposeOnlyFixedGenericMessages() async {
        let preparation = DiagnosticExportModel(
            makeArtifact: { throw NSError(domain: "/private/path", code: 1, userInfo: [NSLocalizedDescriptionKey: "TOKEN_SECRET"]) }
        )
        await preparation.prepare()
        XCTAssertEqual(preparation.message, DiagnosticExportModel.preparationError)

        let save = DiagnosticExportModel(
            makeArtifact: { try self.artifact() },
            chooseDestination: { URL(fileURLWithPath: "/directory-that-does-not-exist/private.json") }
        )
        await save.prepare()
        save.save()
        XCTAssertEqual(save.message, DiagnosticExportModel.saveError)
    }

    func testDiagnosticQuotaWindowKindsUseExactIdentityParsing() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = generatedAt.addingTimeInterval(3_600)
        let insights: [QuotaWindowIdentity: QuotaInsightState] = [
            try QuotaWindowIdentity(product: .codex, identifier: "primary:100800", resetBoundary: reset):
                unavailable(.insufficientObservations, identity: try QuotaWindowIdentity(product: .codex, identifier: "primary:100800", resetBoundary: reset), count: 1, span: 0),
            try QuotaWindowIdentity(product: .claudeCode, identifier: "other:session_weekly", resetBoundary: reset):
                unavailable(.insufficientObservations, identity: try QuotaWindowIdentity(product: .claudeCode, identifier: "other:session_weekly", resetBoundary: reset), count: 2, span: 60),
            try QuotaWindowIdentity(product: .claudeCode, identifier: "weekly:arbitrary_session_text", resetBoundary: reset):
                unavailable(.insufficientObservations, identity: try QuotaWindowIdentity(product: .claudeCode, identifier: "weekly:arbitrary_session_text", resetBoundary: reset), count: 3, span: 120),
        ]
        let input = try DiagnosticExportInputBuilder.make(
            generatedAt: generatedAt,
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
            quotaInsights: insights
        )

        let findings = try XCTUnwrap(DiagnosticExport.decode(DiagnosticExport.make(from: input).bytes).quotaFindings)
        XCTAssertEqual(findings.filter { $0.windowKind == .weekly }.map(\.measuredObservationCount), [3])
        XCTAssertEqual(Set(findings.filter { $0.windowKind == .other }.map(\.measuredObservationCount)), [1, 2])
    }

    func testLocalRefreshReevaluatesRetainedClaudeInsightAsStale() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = base.addingTimeInterval(4 * 3_600)
        let service = QuotaInsightsService(store: try SQLiteQuotaObservationStore.inMemory())
        var identity: QuotaWindowIdentity?
        for (minute, percent) in zip([0.0, 5, 10, 15], [70.0, 72, 74, 76]) {
            let observedAt = base.addingTimeInterval(minute * 60)
            let findings = try await service.recordClaude(
                ClaudeRateLimitSnapshot(limits: [
                    ClaudeRateLimit(kind: "session", group: .session, percentUsed: percent, severity: .normal, resetsAt: reset, scopeDisplayName: nil, isActive: true),
                ], fetchedAt: observedAt),
                now: observedAt
            )
            identity = findings.keys.first
        }
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
            codex: nil,
            refreshedAt: base.addingTimeInterval(30 * 60 + 1),
            codexRefreshed: false
        ))

        assertUnavailable(state.quotaInsights[try XCTUnwrap(identity)], reason: .staleEvidence, count: 4, span: 900)
    }

    func testFailedCodexScanReplacesQualifiedRetainedInsightWithStaleFinding() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = base.addingTimeInterval(10 * 3_600)
        let service = QuotaInsightsService(store: try SQLiteQuotaObservationStore.inMemory())
        let state = LimitBarState(
            providerSettings: ProviderSettings.defaultSettings,
            claudeModel: ClaudeRateLimitsModel(
                credentials: ClaudeCredentialBroker.shared,
                client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
            ),
            coordinator: LocalRefreshCoordinator(dependencies: LocalRefreshDependencies(
                refreshUsage: { _, _ in throw CancellationError() },
                scanCodex: { _ in throw CancellationError() }
            )),
            quotaInsightsService: service
        )

        var latestSnapshot: CodexRateLimitSnapshot?
        for (index, minute) in [0.0, 5, 10, 15].enumerated() {
            let observedAt = base.addingTimeInterval(minute * 60)
            let snapshot = CodexRateLimitSnapshot(
                planType: "plus",
                primary: CodexRateLimitWindow(percentUsed: 70 + Double(index) * 2, windowMinutes: 300, resetsAt: reset),
                secondary: nil,
                credits: nil,
                reportedAt: observedAt
            )
            latestSnapshot = snapshot
            await state.refreshQuotaInsights(for: LocalRefreshSnapshot(
                sequence: UInt64(index + 1),
                usage: nil,
                codex: snapshot,
                refreshedAt: observedAt,
                codexRefreshed: true
            ))
        }
        let identity = try XCTUnwrap(QuotaWindowIdentity.codex(slot: "primary", window: try XCTUnwrap(latestSnapshot?.primary)))
        guard case .qualified = state.quotaInsights[identity] else {
            return XCTFail("Expected a qualified Codex finding before the scan failure")
        }

        await state.refreshQuotaInsights(for: LocalRefreshSnapshot(
            sequence: 5,
            usage: nil,
            codex: latestSnapshot,
            refreshedAt: base.addingTimeInterval(6 * 3_600 + 15 * 60 + 1),
            codexRefreshed: false
        ))

        assertUnavailable(state.quotaInsights[identity], reason: .staleEvidence, count: 4, span: 900)

        await state.refreshQuotaInsights(for: LocalRefreshSnapshot(
            sequence: 6,
            usage: nil,
            codex: latestSnapshot,
            refreshedAt: reset,
            codexRefreshed: false
        ))

        assertUnavailable(state.quotaInsights[identity], reason: .resetOrExpired, count: 4, span: 900)
    }

    private func artifact(build: Int = 1) throws -> DiagnosticExportArtifact {
        try DiagnosticExport.make(from: DiagnosticExportInput(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: DiagnosticVersion(major: 1, minor: 0, patch: 0),
            appBuild: build,
            operatingSystemVersion: DiagnosticVersion(major: 15, minor: 0, patch: 0),
            providerStatuses: [],
            databaseState: .available,
            importCounts: DiagnosticImportCounts(accepted: 0, rejected: 0),
            resourceLimitReasons: []
        ))
    }

    private func unavailable(
        _ reason: QuotaInsightUnavailableReason,
        identity: QuotaWindowIdentity,
        count: Int,
        span: TimeInterval
    ) -> QuotaInsightState {
        precondition(reason == .insufficientObservations && count > 0)
        let source: QuotaObservationSource = identity.product == .claudeCode ? .claudeProviderReport : .codexLocalReport
        let latest = identity.resetBoundary.addingTimeInterval(-1_800)
        let observations = (0..<count).compactMap { index -> MeasuredQuotaObservation? in
            let fraction = count == 1 ? 0 : Double(index) / Double(count - 1)
            return try? MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: Double(index),
                observedAt: latest.addingTimeInterval(-span * (1 - fraction)),
                source: source
            )
        }
        return QuotaInsightAnalytics.analyze(observations, now: latest, maximumAge: 600)
    }

    private func assertUnavailable(
        _ state: QuotaInsightState?,
        reason: QuotaInsightUnavailableReason,
        count: Int,
        span: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(finding) = state else {
            return XCTFail("Expected an unavailable finding", file: file, line: line)
        }
        XCTAssertEqual(finding.reason, reason, file: file, line: line)
        XCTAssertEqual(finding.measuredObservationCount, count, file: file, line: line)
        XCTAssertEqual(finding.measuredSpan, span, file: file, line: line)
        XCTAssertEqual(finding.forecastMethod, .pairwisePositiveSlopeInterquartileV2, file: file, line: line)
        XCTAssertEqual(state?.qualificationStatus, .unavailable, file: file, line: line)
    }
}
