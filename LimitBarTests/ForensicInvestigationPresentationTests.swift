import XCTest
import LimitBarCore
@testable import LimitBar

final class ForensicInvestigationPresentationTests: XCTestCase {
    func testUnavailableForecastPreservesReasonMethodAndEvidenceMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: now.addingTimeInterval(3_600))
        let state = QuotaInsightAnalytics.analyze([], now: now, maximumAge: 300, expectedIdentity: identity)

        let presentation = ForensicInvestigationPresentation.forecast(state)

        XCTAssertTrue(presentation.summary.contains("Unavailable"))
        XCTAssertTrue(presentation.details.contains("insufficient_observations"))
        XCTAssertTrue(presentation.details.contains("pairwise_positive_slope_interquartile_v2"))
        XCTAssertTrue(presentation.details.contains("0 Measured observations"))
        XCTAssertTrue(presentation.details.contains("provider capacity and weighting are unknown"))
        XCTAssertTrue(presentation.details.contains("synthetic replay"))
        XCTAssertFalse(presentation.summary.contains("exhaust"))
    }

    func testAnomalyObservedZeroIsDistinctFromGapAndNoFinding() throws {
        let fixture = try anomalyFixture(values: [0, 0, 0, 0, 0, 0, 0])
        let observedZero = QuotaAnomalyAnalytics.analyze(fixture.observations, now: fixture.now, maximumAge: 300)
        let gap = QuotaAnomalyAnalytics.analyze(fixture.observations, now: fixture.now, maximumAge: 300, gaps: [fixture.gap])

        XCTAssertEqual(ForensicInvestigationPresentation.anomaly(observedZero).status, "Observed Zero")
        XCTAssertEqual(ForensicInvestigationPresentation.anomaly(gap).status, "Unavailable - Gap")
        XCTAssertNotEqual(ForensicInvestigationPresentation.anomaly(observedZero).status, "No finding")
    }

    func testAPIProductsAreFactualUnavailableDecisionsNotSupportedSelections() {
        let snapshot = ForensicInvestigationSnapshot.empty(publishedAt: Date(timeIntervalSince1970: 1_900_000_000))

        XCTAssertEqual(snapshot.supportedProducts, [])
        XCTAssertEqual(snapshot.apiEvidenceNotice, APIProviderQuotaPathAvailability.fixedUnavailableSummary)
        XCTAssertFalse(snapshot.apiEvidenceNotice.contains("zero"))
    }

    func testHalfOpenRangeIntersectionExcludesTouchingBoundaries() {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let end = start.addingTimeInterval(60)

        XCTAssertFalse(ForensicInvestigationPresentation.intersects(start: start.addingTimeInterval(-60), end: start, rangeStart: start, rangeEnd: end))
        XCTAssertFalse(ForensicInvestigationPresentation.intersects(start: end, end: end.addingTimeInterval(60), rangeStart: start, rangeEnd: end))
        XCTAssertTrue(ForensicInvestigationPresentation.intersects(start: start, end: end, rangeStart: start, rangeEnd: end))
    }

    func testTraceDetailsRevealTruncatedStableIdentitiesWithoutFullDigest() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "limit:primary:300", resetBoundary: now.addingTimeInterval(3_600))
        let observations = try [10.0, 12, 14, 16].enumerated().map { index, value in
            try MeasuredQuotaObservation(identity: identity, percentageUsed: value, observedAt: now.addingTimeInterval(Double(index - 3) * 600), source: .codexLocalReport)
        }
        let state = QuotaInsightAnalytics.analyze(observations, now: now, maximumAge: 60)

        let details = ForensicInvestigationPresentation.forecast(state).details

        XCTAssertTrue(details.contains(String(observations[0].stableIdentity.digest.prefix(12))))
        XCTAssertFalse(details.contains(observations[0].stableIdentity.digest))
    }

    func testCodexExplanationUsesCanonicalLimitIdentityAndDoesNotDuplicateAnalyticsRecord() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = now.addingTimeInterval(3_600)
        let snapshot = CodexRateLimitSnapshot(
            planType: "plus",
            primary: CodexRateLimitWindow(limitID: "Team-A", percentUsed: 20, windowMinutes: 300, resetsAt: reset),
            secondary: CodexRateLimitWindow(limitID: "Team-B", percentUsed: 40, windowMinutes: 10_080, resetsAt: reset),
            credits: nil,
            reportedAt: now
        )
        let observations = MeasuredQuotaObservationAdapter.codex(snapshot)
        let identity = try XCTUnwrap(observations.last?.identity)
        let explanation = CodexQuotaExplanation(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            quotaResetBoundary: reset,
            coverageStart: now.addingTimeInterval(-120),
            coverageEnd: now.addingTimeInterval(-60),
            calculatedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(tokens: CodexMeasuredTokens(input: 2, cachedInput: 0, output: 1, reasoningOutput: 0), sessionCount: 1),
            unattributed: true,
            inferredAllocation: nil,
            observationIdentities: [],
            evidenceIdentities: [],
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            barriers: [],
            quotaWindowIdentity: identity
        )
        let forecast = QuotaInsightAnalytics.analyze([], now: now, maximumAge: 60, expectedIdentity: identity)

        let publication = ForensicInvestigationAssembler.make(input(
            now: now,
            snapshot: snapshot,
            explanation: .available(explanation),
            forecasts: [identity: forecast]
        ))

        let records = try XCTUnwrap(publication.products.first { $0.product == .codex }?.records)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identity?.identifier, "team-b:secondary:10080")
    }

    func testRetainedCodexObservedZeroPreservesExactIntervalAndIsNeverGap() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let zero = CodexQuotaObservedZero(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            calculatedQuotaMovementPercent: 0,
            quotaResetBoundary: now.addingTimeInterval(3_600),
            observationIdentities: [],
            evidenceIdentities: []
        )

        let sameResetSnapshot = CodexRateLimitSnapshot(
            planType: "plus",
            primary: CodexRateLimitWindow(limitID: "a", percentUsed: 10, windowMinutes: 300, resetsAt: zero.quotaResetBoundary),
            secondary: CodexRateLimitWindow(limitID: "b", percentUsed: 20, windowMinutes: 10_080, resetsAt: zero.quotaResetBoundary),
            credits: nil,
            reportedAt: now
        )
        let publication = ForensicInvestigationAssembler.make(input(
            now: now,
            snapshot: sameResetSnapshot,
            explanation: .observedZero(zero),
            retained: true
        ))

        let record = try XCTUnwrap(publication.products.first?.records.first)
        XCTAssertEqual(record.start, zero.intervalStart)
        XCTAssertEqual(record.end, zero.intervalEnd)
        XCTAssertTrue(record.isObservedZero)
        XCTAssertFalse(record.isGap)
        XCTAssertNil(record.identity)
        XCTAssertTrue(record.freshness.contains("Retained/stale"))
    }

    func testTypedInferredAllocationRequiresMethodAndLimitationsForClaudeAndCodex() throws {
        XCTAssertThrowsError(try InferredQuotaAllocation(percent: 25, method: .temporalProportionalV1, limitations: []))
        let allocation = try InferredQuotaAllocation(
            percent: 25,
            method: .temporalProportionalV1,
            limitations: [.temporalCorrelationOnly, .providerWeightingUnknown, .noCausalAttribution]
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = now.addingTimeInterval(3_600)
        let codexIdentity = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: reset)
        let codex = CodexQuotaExplanation(
            intervalStart: now.addingTimeInterval(-120), intervalEnd: now.addingTimeInterval(-60), quotaResetBoundary: reset,
            coverageStart: now.addingTimeInterval(-120), coverageEnd: now.addingTimeInterval(-60), calculatedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(tokens: CodexMeasuredTokens(input: 2, cachedInput: 0, output: 1, reasoningOutput: 0), sessionCount: 2),
            unattributed: true, inferredAllocation: allocation, observationIdentities: [], evidenceIdentities: [],
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion, barriers: [], quotaWindowIdentity: codexIdentity
        )
        let codexPublication = ForensicInvestigationAssembler.make(input(now: now, explanation: .available(codex)))
        let codexText = try XCTUnwrap(codexPublication.products.first?.records.first?.unattributed)
        XCTAssertTrue(codexText.contains("25%"))
        XCTAssertTrue(codexText.contains("temporal_proportional_v1"))
        XCTAssertTrue(codexText.contains("temporal_correlation_only"))
        XCTAssertTrue(codexText.contains("no causal claim"))
        let codexReport = try QuotaEvidenceReportBuilder.make(snapshot: codexPublication, product: .codex, rangeStart: codex.intervalStart, rangeEnd: codex.intervalEnd)
        let exported = try XCTUnwrap(codexReport.records.first)
        XCTAssertEqual(exported.inferredAllocation?.percent, 25)
        XCTAssertEqual(exported.inferredAllocation?.provenance, .inferred)
        XCTAssertEqual(exported.unattributedRemainder.value, 1.5)
        XCTAssertEqual(exported.unattributedRemainder.provenance, .inferred)
        XCTAssertEqual(exported.unattributedRemainder.method, .temporalProportionalV1)

        let claudeIdentity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: reset)
        let claudeValue = ClaudeQuotaExplanation(
            providerProduct: .claudeCode, intervalStart: now.addingTimeInterval(-120), intervalEnd: now.addingTimeInterval(-60),
            quotaResetBoundary: reset, reportedQuotaMovementPercent: 2,
            attribution: .unavailable(.gap), unattributed: true, inferredAllocation: allocation,
            observationIdentities: [], observationSpan: 60, evidenceAge: 60,
            methodVersion: ClaudeQuotaExplanationEngine.methodVersion,
            sourceAdapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion, sourceVersion: nil
        )
        let interval = ClaudeQuotaExplanationInterval(id: "claude-inferred", identity: claudeIdentity, intervalStart: claudeValue.intervalStart, intervalEnd: claudeValue.intervalEnd, lifecycle: .active)
        let catalog = ClaudeQuotaExplanationCatalog(selections: [ClaudeQuotaExplanationSelection(interval: interval, state: .movement(claudeValue), limitations: [.partialCoverage])], defaultSelectionID: interval.id)
        let claudePublication = ForensicInvestigationAssembler.make(ForensicInvestigationInput(
            generation: 1, publishedAt: now, codexSnapshot: nil, codexExplanation: .unavailable(.insufficientObservations),
            codexExplanationRetained: false, claudeExplanationCatalog: catalog, forecasts: [:], anomalies: [:],
            storageAvailable: true, storeOpen: true
        ))
        let claudeText = try XCTUnwrap(claudePublication.products.first?.records.first?.unattributed)
        XCTAssertTrue(claudeText.contains("temporal_proportional_v1"))
        XCTAssertTrue(claudeText.contains("provider_weighting_unknown"))
    }

    func testAdverseForecastEvidenceStatesRemainTraceableAndDeterministic() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: now.addingTimeInterval(7_200))
        let ordered = try observations(identity: identity, now: now, values: [10, 12, 14, 16])

        let stale = QuotaInsightAnalytics.analyze(ordered, now: now.addingTimeInterval(3_600), maximumAge: 60)
        XCTAssertTrue(ForensicInvestigationPresentation.forecast(stale).details.contains("stale_evidence"))

        let decreased = try observations(identity: identity, now: now, values: [10, 12, 11, 14])
        XCTAssertTrue(ForensicInvestigationPresentation.forecast(QuotaInsightAnalytics.analyze(decreased, now: now, maximumAge: 60)).details.contains("counter_decreased"))

        let forward = QuotaInsightAnalytics.analyze(ordered, now: now, maximumAge: 60)
        let reversed = QuotaInsightAnalytics.analyze(ordered.reversed(), now: now, maximumAge: 60)
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(ForensicInvestigationPresentation.forecast(forward), ForensicInvestigationPresentation.forecast(reversed))

        let otherIdentity = try QuotaWindowIdentity(product: .codex, identifier: "codex:secondary:10080", resetBoundary: identity.resetBoundary)
        let claudeIdentity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: identity.resetBoundary)
        let incompatible = QuotaInsightAnalytics.analyze(ordered + [
            try MeasuredQuotaObservation(identity: otherIdentity, percentageUsed: 20, observedAt: now, source: .codexLocalReport),
            try MeasuredQuotaObservation(identity: claudeIdentity, percentageUsed: 21, observedAt: now, source: .claudeProviderReport),
        ], now: now, maximumAge: 60)
        let incompatibleText = ForensicInvestigationPresentation.forecast(incompatible).details
        XCTAssertTrue(incompatibleText.contains("incompatible_evidence"))
        XCTAssertTrue(incompatibleText.contains("codex_local_report_v1"))
        XCTAssertTrue(incompatibleText.contains("claude_provider_report_v1"))
        let stalePublication = ForensicInvestigationAssembler.make(input(now: now, explanation: .unavailable(.gap), forecasts: [identity: stale]))
        let staleRecord = try XCTUnwrap(stalePublication.products.first?.records.first)
        let staleReport = try QuotaEvidenceReportBuilder.make(snapshot: stalePublication, product: .codex, rangeStart: staleRecord.start, rangeEnd: staleRecord.end)
        XCTAssertEqual(staleReport.records.first?.forecast.unavailableReason, .staleEvidence)
    }

    func testIncompatibleEvidenceVersionsAndSectionLocalFailurePreserveIndependentAnalysis() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: now.addingTimeInterval(7_200))
        let values = try observations(identity: identity, now: now, values: [10, 11, 12, 13, 14, 15, 20], spacing: 600)
        let v1 = try QuotaAnomalyEvidenceVersion(adapter: .quotaObservationV1, client: .codex0144, providerFormat: .codexLocalReportV1)
        let v2 = try QuotaAnomalyEvidenceVersion(adapter: .quotaObservationV2, client: .codex0145, providerFormat: .codexLocalReportV2)
        var versions = Dictionary(uniqueKeysWithValues: values.map { ($0.stableIdentity, v1) })
        versions[values.last!.stableIdentity] = v2
        let incompatible = QuotaAnomalyAnalytics.analyze(values, now: now, maximumAge: 60, evidenceVersions: versions)
        let versionText = ForensicInvestigationPresentation.anomaly(incompatible)
        XCTAssertEqual(versionText.status, "Unavailable")
        XCTAssertTrue(versionText.details.contains("incompatible"))

        let forecastError = QuotaInsightAnalytics.analyze(values, now: Date(timeIntervalSince1970: .nan), maximumAge: 60)
        let anomaly = QuotaAnomalyAnalytics.analyze(values, now: now, maximumAge: 60)
        let publication = ForensicInvestigationAssembler.make(ForensicInvestigationInput(
            generation: 1, publishedAt: now, codexSnapshot: nil, codexExplanation: .unavailable(.gap), codexExplanationRetained: false,
            claudeExplanationCatalog: .empty, forecasts: [identity: forecastError], anomalies: [identity: anomaly], storageAvailable: true, storeOpen: true
        ))
        let record = try XCTUnwrap(publication.products.first?.records.first)
        XCTAssertEqual(record.forecast.status, "Unavailable")
        XCTAssertNotEqual(record.anomaly.status, "Unavailable")
        XCTAssertTrue(record.anomaly.details.contains("no_causal_attribution"))
        let report = try QuotaEvidenceReportBuilder.make(snapshot: publication, product: .codex, rangeStart: record.start, rangeEnd: record.end)
        XCTAssertEqual(report.records.first?.forecast.unavailableReason, .invalidEvaluation)

        let intervalForecast = QuotaInsightAnalytics.analyze(values, now: now, maximumAge: 60)
        let incompatiblePublication = ForensicInvestigationAssembler.make(ForensicInvestigationInput(
            generation: 2, publishedAt: now, codexSnapshot: nil, codexExplanation: .unavailable(.gap), codexExplanationRetained: false,
            claudeExplanationCatalog: .empty, forecasts: [identity: intervalForecast], anomalies: [identity: incompatible], storageAvailable: true, storeOpen: true
        ))
        let incompatibleRecord = try XCTUnwrap(incompatiblePublication.products.first?.records.first)
        let incompatibleReport = try QuotaEvidenceReportBuilder.make(snapshot: incompatiblePublication, product: .codex, rangeStart: incompatibleRecord.start, rangeEnd: incompatibleRecord.end)
        XCTAssertEqual(incompatibleReport.records.first?.anomaly.unavailableReason, .incompatibleEvidence)
    }

    func testGenericAPIAttributionSentinelCannotEnterInvestigationOrDiagnostics() throws {
        let sentinel = "PRIVATE_SENTINEL_PROMPT_PATH_COOKIE"
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let window = try ExactUsageWindow(timeWindow: .today, start: now, end: now.addingTimeInterval(86_400), basis: .localCalendar)
        let upstream = ObservedLocalAttributionBreakdown(
            source: .builtInLocalLog, provider: .anthropic, window: window, model: sentinel, deployment: sentinel,
            project: CollectorAttribution(id: "generic", label: sentinel), agent: nil,
            tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1), eventIDs: [UUID()], observedAt: now
        )
        XCTAssertEqual(upstream.model, sentinel) // The sentinel exists before the product-explicit publication seam.

        let publication = ForensicInvestigationAssembler.make(input(now: now, explanation: .unavailable(.gap)))
        let visible = String(describing: publication)
        let diagnostic = try DiagnosticExport.make(from: DiagnosticExportInput(
            generatedAt: now,
            appVersion: DiagnosticVersion(major: 1, minor: 0, patch: 0),
            appBuild: 1,
            operatingSystemVersion: DiagnosticVersion(major: 15, minor: 0, patch: 0),
            providerStatuses: [],
            databaseState: .available,
            importCounts: DiagnosticImportCounts(accepted: 1, rejected: 0),
            resourceLimitReasons: []
        )).preview
        XCTAssertFalse(visible.contains(sentinel))
        XCTAssertFalse(diagnostic.contains(sentinel))
    }

    func testQuotaEvidenceProjectionUsesStructuredCoherentPublicationAndExcludesSourceText() throws {
        let sentinels = [
            "PROMPT_SENTINEL", "SOURCE_CODE_SENTINEL", "MODEL_RESPONSE_SENTINEL", "TERMINAL_OUTPUT_SENTINEL",
            "REQUEST_BODY_SENTINEL", "CREDENTIAL_SENTINEL", "/Users/private/source", "ACCOUNT_LABEL_SENTINEL",
            "RAW_PAYLOAD_SENTINEL",
        ]
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = now.addingTimeInterval(3_600)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: reset)
        let analyticalInputs = try observations(identity: identity, now: now, values: [10, 11, 12, 13, 14, 15, 20], spacing: 600)
        let forecast = QuotaInsightAnalytics.analyze(Array(analyticalInputs.prefix(4)), now: analyticalInputs[3].observedAt, maximumAge: 60)
        let anomaly = QuotaAnomalyAnalytics.analyze(analyticalInputs, now: now, maximumAge: 60)
        let explanation = CodexQuotaExplanation(
            intervalStart: now.addingTimeInterval(-120),
            intervalEnd: now.addingTimeInterval(-60),
            quotaResetBoundary: reset,
            coverageStart: now.addingTimeInterval(-120),
            coverageEnd: now.addingTimeInterval(-60),
            calculatedQuotaMovementPercent: 2,
            observedLocalBreakdown: CodexObservedLocalBreakdown(tokens: CodexMeasuredTokens(input: 2, cachedInput: 0, output: 1, reasoningOutput: 0), sessionCount: 1),
            unattributed: true,
            inferredAllocation: nil,
            observationIdentities: [],
            evidenceIdentities: sentinels,
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            barriers: [],
            quotaWindowIdentity: identity
        )
        let publication = ForensicInvestigationAssembler.make(input(now: now, explanation: .available(explanation), forecasts: [identity: forecast], anomalies: [identity: anomaly]))
        let evidence = try QuotaEvidenceReportBuilder.make(
            snapshot: publication,
            product: .codex,
            rangeStart: explanation.intervalStart,
            rangeEnd: explanation.intervalEnd
        )
        let diagnosticInput = try DiagnosticExportInputBuilder.make(
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
            quotaEvidence: evidence
        )
        let artifact = try DiagnosticExport.make(from: diagnosticInput)
        let decoded = try XCTUnwrap(DiagnosticExport.decode(artifact.bytes).quotaEvidence)

        XCTAssertEqual(decoded.selectedRange.basis, .gregorianUTC)
        XCTAssertEqual(decoded.records.first?.movement?.value, 2)
        XCTAssertEqual(decoded.records.first?.movement?.provenance, .calculated)
        XCTAssertEqual(decoded.records.first?.localBreakdown, .available)
        XCTAssertEqual(decoded.records.first?.localTokenCount, 3)
        XCTAssertEqual(decoded.records.first?.localSessionCount, 1)
        XCTAssertEqual(decoded.records.first?.unattributedRemainder.value, 2)
        XCTAssertEqual(decoded.records.first?.unattributedRemainder.provenance, .calculated)
        let forecastTraces = try XCTUnwrap(decoded.records.first?.forecast.evidenceTraceReferences)
        let anomalyTraces = try XCTUnwrap(decoded.records.first?.anomaly.evidenceTraceReferences)
        XCTAssertEqual(decoded.records.first?.forecast.status, .available)
        XCTAssertNotEqual(decoded.records.first?.anomaly.status, .unavailable)
        XCTAssertFalse(forecastTraces.isEmpty)
        XCTAssertFalse(anomalyTraces.isEmpty)
        XCTAssertNotEqual(forecastTraces, anomalyTraces)
        XCTAssertTrue(Set(forecastTraces).isSubset(of: Set(anomalyTraces)))
        XCTAssertEqual(decoded.records.first?.resetBoundary, reset)
        XCTAssertEqual(decoded.records.first?.resetBoundaryProvenance, .reported)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("evidence.json")
        try artifact.save(to: destination)
        let saved = try String(contentsOf: destination, encoding: .utf8)
        for sentinel in sentinels {
            XCTAssertFalse(try artifact.preview.contains(sentinel))
            XCTAssertFalse(saved.contains(sentinel))
        }
        for identity in analyticalInputs.map(\.stableIdentity.digest) {
            XCTAssertFalse(try artifact.preview.contains(identity))
            XCTAssertFalse(saved.contains(identity))
        }
    }

    func testQuotaEvidenceBuilderSortsBeforeHundredRecordProjectionCap() throws {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let ordered = (0..<137).map { investigationRecord(index: $0, start: start) }
        let shuffled = Array(Array(ordered[51...] + ordered[..<51]).reversed())
        let first = ForensicInvestigationSnapshot(generation: 1, publicationState: .partial, publishedAt: start, products: [.init(product: .codex, records: ordered)], apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary, message: nil)
        let second = ForensicInvestigationSnapshot(generation: 1, publicationState: .partial, publishedAt: start, products: [.init(product: .codex, records: shuffled)], apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary, message: nil)
        let end = start.addingTimeInterval(20_000)

        let firstReport = try QuotaEvidenceReportBuilder.make(snapshot: first, product: .codex, rangeStart: start, rangeEnd: end)
        let secondReport = try QuotaEvidenceReportBuilder.make(snapshot: second, product: .codex, rangeStart: start, rangeEnd: end)

        XCTAssertEqual(firstReport, secondReport)
        XCTAssertEqual(firstReport.omittedRecordCount, 129)
        XCTAssertEqual(firstReport.records.first?.intervalStart, start.addingTimeInterval(136 * 60))
    }

    private func observations(
        identity: QuotaWindowIdentity,
        now: Date,
        values: [Double],
        spacing: TimeInterval = 600
    ) throws -> [MeasuredQuotaObservation] {
        try values.enumerated().map { index, value in
            try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: value,
                observedAt: now.addingTimeInterval(Double(index - (values.count - 1)) * spacing),
                source: .codexLocalReport
            )
        }
    }

    private func investigationRecord(index: Int, start: Date) -> InvestigationRecord {
        InvestigationRecord(
            id: "record-\(index)",
            identity: nil,
            resetBoundary: nil,
            start: start.addingTimeInterval(Double(index) * 60),
            end: start.addingTimeInterval(Double(index + 1) * 60),
            authoritativeTotal: "Unavailable",
            localBreakdown: "Gap",
            unattributed: "Unattributed",
            forecast: .init(status: "Unavailable", summary: "Unavailable", details: "Unavailable"),
            anomaly: .init(status: "Unavailable", summary: "Unavailable", details: "Unavailable"),
            version: "Unavailable",
            limitations: "Unavailable",
            traces: "Unavailable",
            freshness: "Unavailable",
            isGap: true,
            isObservedZero: false
        )
    }

    private func input(
        now: Date,
        snapshot: CodexRateLimitSnapshot? = nil,
        explanation: CodexQuotaExplanationState,
        retained: Bool = false,
        forecasts: [QuotaWindowIdentity: QuotaInsightState] = [:],
        anomalies: [QuotaWindowIdentity: QuotaAnomalyState] = [:]
    ) -> ForensicInvestigationInput {
        ForensicInvestigationInput(
            generation: 7,
            publishedAt: now,
            codexSnapshot: snapshot,
            codexExplanation: explanation,
            codexExplanationRetained: retained,
            claudeExplanationCatalog: .empty,
            forecasts: forecasts,
            anomalies: anomalies,
            storageAvailable: true,
            storeOpen: true
        )
    }

    private func anomalyFixture(values: [Double]) throws -> (observations: [MeasuredQuotaObservation], now: Date, gap: QuotaAnomalyPeriod) {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let now = start.addingTimeInterval(3_600)
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: now.addingTimeInterval(3_600))
        let observations = try values.enumerated().map { index, value in
            try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: value,
                observedAt: start.addingTimeInterval(Double(index) * 600),
                source: .codexLocalReport
            )
        }
        let gap = try QuotaAnomalyPeriod(start: start, end: start.addingTimeInterval(600))
        return (observations, now, gap)
    }
}
