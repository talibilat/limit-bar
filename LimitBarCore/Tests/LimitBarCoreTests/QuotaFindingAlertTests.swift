import Foundation
import Testing
@testable import LimitBarCore

@Suite("Quota finding alerts")
struct QuotaFindingAlertTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    @Test("qualified forecast uses the existing quota rule and privacy-safe copy")
    func qualifiedForecastCandidate() throws {
        let rule = QuotaAlertRule(
            id: UUID(uuidString: "D706BCEA-4356-4763-987D-404B9E6B73BC")!,
            product: .codex,
            thresholds: try PercentageThresholds([70, 90])
        )
        let identity = try QuotaWindowIdentity(
            product: .codex,
            identifier: "private-account/project/session/model/token-123",
            resetBoundary: now.addingTimeInterval(3_600)
        )
        let inputs = try traceInputs(identity: identity, percentage: 10)
        let latestInput = try #require(inputs.last)
        let finding = QualifiedQuotaInsight(
            identity: identity,
            measuredObservationCount: 4,
            measuredSpan: 1_800,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            createdAt: now,
            evidenceAge: 60,
            inputObservationIdentities: inputs,
            latestObservationIdentity: latestInput,
            latestObservationAt: now.addingTimeInterval(-60),
            interpretationVersions: [.codexLocalReportV1],
            calculatedBurnPercentPerHour: QuotaInsightRange(lower: 10, upper: 20),
            calculatedExhaustionRange: now.addingTimeInterval(1_200)...now.addingTimeInterval(1_800)
        )
        let quota = QuotaObservation(
            identity: identity,
            percentageUsed: 92,
            observedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(60)
        )

        let candidates = QuotaFindingAlertAdapter.candidates(
            forecasts: [.qualified(finding)],
            anomalies: [],
            quota: [quota],
            now: now
        )
        let evaluations = AlertEvaluator.evaluate(
            preferences: try AlertPreferences(quotaRules: [rule], costBudgetRules: []),
            quota: [],
            costs: [],
            findings: candidates,
            satisfied: [],
            now: now
        )

        let evaluation = try #require(evaluations.first)
        #expect(evaluations.count == 1)
        #expect(evaluation.occurrence.ruleID == rule.id)
        #expect(evaluation.occurrence.window == .quota(identity))
        #expect(evaluation.occurrence.thresholds == [70, 90])
        #expect(evaluation.findingTraces == candidates.flatMap(\.traces))
        guard case let .forecast(method, qualification, inputs, evidenceRange, classification) = try #require(evaluation.findingTraces.first) else {
            Issue.record("Expected typed forecast trace")
            return
        }
        #expect(method == .pairwisePositiveSlopeInterquartileV2)
        #expect(qualification == .qualified)
        #expect(!inputs.isEmpty)
        #expect(evidenceRange.lowerBound < evidenceRange.upperBound)
        #expect(classification == .calculated)
        #expect(evaluation.notification.title == "Quota forecast")
        #expect(evaluation.notification.body == "Calculated Codex forecast indicates quota may exhaust before reset. Open LimitBar for details.")
        for prohibited in ["account", "project", "session", "model", "token", "123", "92", "90%"] {
            #expect(!evaluation.notification.body.lowercased().contains(prohibited))
        }
    }

    @Test("qualified anomaly is calculated and coalesces with matching measured quota")
    func qualifiedAnomalyCandidate() throws {
        let identity = try window(identifier: "private-account/project/session/model/token-456")
        let quota = observation(identity: identity, percentage: 75)
        let candidate = try #require(QuotaFindingAlertAdapter.candidates(
            forecasts: [],
            anomalies: [try anomaly(identity: identity)],
            quota: [quota],
            now: now
        ).first)
        let rule = QuotaAlertRule(product: .codex, thresholds: try PercentageThresholds([70]))
        let evaluations = AlertEvaluator.evaluate(
            preferences: try AlertPreferences(quotaRules: [rule], costBudgetRules: []),
            quota: [quota],
            costs: [],
            findings: [candidate],
            satisfied: [],
            now: now
        )

        let evaluation = try #require(evaluations.first)
        #expect(evaluations.count == 1)
        guard case let .anomaly(method, qualification, inputs, evidenceRange, classification, limitations) = try #require(candidate.traces.first) else {
            Issue.record("Expected typed anomaly trace")
            return
        }
        #expect(method == .trailingMedianRatioV1)
        #expect(qualification == .qualified)
        #expect(!inputs.isEmpty)
        #expect(evidenceRange.lowerBound < evidenceRange.upperBound)
        #expect(classification == .calculated)
        #expect(limitations == [.noCausalAttribution, .syntheticFixtureValidationOnly])
        #expect(evaluation.findingTraces == candidate.traces)
        #expect(evaluation.notification.title == "Quota anomaly")
        #expect(evaluation.notification.body == "Calculated Codex analysis found unusual quota consumption. Open LimitBar for details.")
        for prohibited in ["account", "project", "session", "model", "token", "456", "75", "70%"] {
            #expect(!evaluation.notification.body.lowercased().contains(prohibited))
        }
    }

    @Test("one threshold opportunity represents forecast and anomaly together")
    func simultaneousFindingCategory() throws {
        let identity = try window()
        let quota = observation(identity: identity, percentage: 75)
        let findings = QuotaFindingAlertAdapter.candidates(
            forecasts: [forecast(identity: identity)],
            anomalies: [try anomaly(identity: identity)],
            quota: [quota],
            now: now
        )
        let rule = QuotaAlertRule(product: .codex, thresholds: try PercentageThresholds([70]))

        let evaluations = AlertEvaluator.evaluate(
            preferences: try AlertPreferences(quotaRules: [rule], costBudgetRules: []),
            quota: [quota],
            costs: [],
            findings: findings,
            satisfied: [],
            now: now
        )

        #expect(evaluations.count == 1)
        #expect(evaluations.first?.notification.title == "Quota forecast and anomaly")
        #expect(evaluations.first?.notification.body == "Calculated Codex analysis found a possible exhaustion before reset and unusual quota consumption. Open LimitBar for details.")
        #expect(evaluations.first?.findingTraces.count == 2)
    }

    @Test("unsafe findings cannot become candidates")
    func rejectsUnsafeFindings() throws {
        let active = try window()
        let stale = forecast(identity: active, createdAt: now.addingTimeInterval(-30_000), evidenceAge: 1)
        let unavailable = QuotaInsightAnalytics.analyze([], now: now, maximumAge: 60, expectedIdentity: active)
        let noExhaustion = forecast(identity: active, hasExhaustion: false)
        let expired = try QuotaWindowIdentity(
            product: .codex,
            identifier: "codex:primary:300",
            resetBoundary: now
        )
        let unqualifiedAnomaly = try anomaly(identity: active, qualification: .unavailable)

        #expect(QuotaFindingAlertAdapter.candidates(
            forecasts: [stale, unavailable, noExhaustion],
            anomalies: [unqualifiedAnomaly],
            quota: [observation(identity: active, percentage: 95)],
            now: now
        ).isEmpty)
        #expect(QuotaFindingAlertAdapter.candidates(
            forecasts: [forecast(identity: expired)],
            anomalies: [],
            quota: [observation(identity: expired, percentage: 95)],
            now: now
        ).isEmpty)
        #expect(QuotaFindingAlertAdapter.candidates(
            forecasts: [forecast(identity: active)],
            anomalies: [try anomaly(identity: active)],
            quota: [],
            now: now
        ).isEmpty)
    }

    @Test("exact boundary mismatch and provider reports without a boundary fail closed")
    func exactBoundaryRequired() throws {
        let findingIdentity = try window()
        let otherBoundary = try window(reset: now.addingTimeInterval(7_200))
        #expect(QuotaFindingAlertAdapter.candidates(
            forecasts: [forecast(identity: findingIdentity)],
            anomalies: [try anomaly(identity: findingIdentity)],
            quota: [observation(identity: otherBoundary, percentage: 95)],
            now: now
        ).isEmpty)

        let boundaryless = CodexRateLimitWindow(percentUsed: 95, windowMinutes: 300, resetsAt: nil)
        #expect(QuotaWindowIdentity.codex(slot: "primary", window: boundaryless) == nil)
        let snapshot = CodexRateLimitSnapshot(
            planType: "plus",
            primary: boundaryless,
            secondary: nil,
            credits: nil,
            reportedAt: now
        )
        #expect(QuotaObservationAdapter.codex(snapshot, now: now).isEmpty)
    }

    @Test("anomaly limitations distinguish informational qualification from blocking incompatibility")
    func anomalyLimitationPolicy() throws {
        let identity = try window()
        let quota = observation(identity: identity, percentage: 75)
        let informational = try anomaly(identity: identity, limitations: [
            .providerWeightingUnknown,
            .noCausalAttribution,
            .syntheticFixtureValidationOnly,
            .supersededEvidenceExcluded,
        ])
        let blocking = try anomaly(identity: identity, limitations: [.incompatibleAdapterVersion])

        #expect(QuotaFindingAlertAdapter.candidates(
            forecasts: [], anomalies: [informational], quota: [quota], now: now
        ).count == 1)
        #expect(QuotaFindingAlertAdapter.candidates(
            forecasts: [], anomalies: [blocking], quota: [quota], now: now
        ).isEmpty)
    }

    @Test("disabled rules suppress findings and changed thresholds preserve prior satisfaction")
    func disabledAndChangedRules() throws {
        let identity = try window()
        let finding = try #require(QuotaFindingAlertAdapter.candidates(
            forecasts: [forecast(identity: identity)],
            anomalies: [],
            quota: [observation(identity: identity, percentage: 96)],
            now: now
        ).first)
        let ruleID = UUID(uuidString: "81D6673F-08D8-4FE1-A480-94BAB6DB6ECA")!
        let disabled = QuotaAlertRule(id: ruleID, product: .codex, thresholds: try PercentageThresholds([70]), isEnabled: false)
        #expect(evaluate(rule: disabled, finding: finding).isEmpty)

        let original = QuotaAlertRule(id: ruleID, product: .codex, thresholds: try PercentageThresholds([70, 90]))
        let first = try #require(evaluate(rule: original, finding: finding).first)
        let satisfied = Set(first.occurrence.thresholds.map {
            AlertThresholdSatisfaction(ruleID: ruleID, window: first.occurrence.window, threshold: $0)
        })
        let changed = QuotaAlertRule(id: ruleID, product: .codex, thresholds: try PercentageThresholds([70, 90, 95]))
        let next = AlertEvaluator.evaluate(
            preferences: try AlertPreferences(quotaRules: [changed], costBudgetRules: []),
            quota: [],
            costs: [],
            findings: [finding],
            satisfied: satisfied,
            now: now
        )
        #expect(next.map(\.occurrence.thresholds) == [[95]])
    }

    @Test("ledger survives restart, rejects supersession, and isolates a reset window")
    func durableExactWindowSemantics() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rule = QuotaAlertRule(
            id: UUID(uuidString: "A5AC0BBA-EA56-4E15-A56B-54DE25BFBB56")!,
            product: .codex,
            thresholds: try PercentageThresholds([70])
        )
        let firstIdentity = try window()
        let firstFinding = try candidate(identity: firstIdentity, percentage: 75, inputPercentage: 10)
        let firstEvaluation = try #require(evaluate(rule: rule, finding: firstFinding).first)
        do {
            let store = try SQLiteAlertDeliveryStore(path: path)
            let reserved = try store.reserve(firstEvaluation.occurrence, now: now)
            let reservation = try #require(reserved)
            try store.markDelivered(reservation, at: now)
        }

        let reopened = try SQLiteAlertDeliveryStore(path: path)
        let satisfied = Set(try reopened.satisfactions(for: rule.id, window: .quota(firstIdentity)))
        let supersedingFinding = try candidate(identity: firstIdentity, percentage: 99, inputPercentage: 11)
        #expect(firstFinding.traces != supersedingFinding.traces)
        #expect(AlertEvaluator.evaluate(
            preferences: try AlertPreferences(quotaRules: [rule], costBudgetRules: []),
            quota: [],
            costs: [],
            findings: [supersedingFinding],
            satisfied: satisfied,
            now: now
        ).isEmpty)
        #expect(try reopened.reserve(firstEvaluation.occurrence, now: now) == nil)

        let resetIdentity = try window(identifier: firstIdentity.identifier, reset: now.addingTimeInterval(7_200))
        let resetEvaluation = try #require(evaluate(rule: rule, finding: candidate(identity: resetIdentity, percentage: 75)).first)
        #expect(try reopened.reserve(resetEvaluation.occurrence, now: now) != nil)
    }

    @Test("deleting quota history does not mutate rules or delivery decisions")
    func historyDeletionIndependence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quotaStore = try SQLiteQuotaObservationStore(path: directory.appendingPathComponent("quota.sqlite").path)
        let deliveryStore = try SQLiteAlertDeliveryStore(path: directory.appendingPathComponent("delivery.sqlite").path)
        let identity = try window()
        _ = try quotaStore.record([
            try MeasuredQuotaObservation(identity: identity, percentageUsed: 75, observedAt: now, source: .codexLocalReport)
        ], now: now)
        let rule = QuotaAlertRule(product: .codex, thresholds: try PercentageThresholds([70]))
        let evaluation = try #require(evaluate(rule: rule, finding: candidate(identity: identity, percentage: 75)).first)
        let reserved = try deliveryStore.reserve(evaluation.occurrence, now: now)
        let reservation = try #require(reserved)
        try deliveryStore.markDelivered(reservation, at: now)

        try quotaStore.deleteAll()

        #expect(try quotaStore.observations(for: identity, now: now).isEmpty)
        #expect(try deliveryStore.satisfactions(for: rule.id, window: .quota(identity)).map(\.threshold) == [70])
        #expect(rule.isEnabled)
    }

    @Test("concurrent equivalent candidates reserve at most one delivery")
    func concurrentEquivalentCandidates() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try SQLiteAlertDeliveryStore(path: path)
        let identity = try window()
        let rule = QuotaAlertRule(product: .codex, thresholds: try PercentageThresholds([70]))
        let occurrence = try #require(evaluate(rule: rule, finding: candidate(identity: identity, percentage: 75)).first?.occurrence)
        let evaluationDate = now

        let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let store = try SQLiteAlertDeliveryStore(path: path)
                    return try store.reserve(occurrence, now: evaluationDate) != nil
                }
            }
            return try await group.reduce(into: 0) { count, reserved in
                if reserved { count += 1 }
            }
        }

        #expect(accepted == 1)
    }

    private func window(
        identifier: String = "codex:primary:300",
        reset: Date? = nil
    ) throws -> QuotaWindowIdentity {
        try QuotaWindowIdentity(
            product: .codex,
            identifier: identifier,
            resetBoundary: reset ?? now.addingTimeInterval(3_600)
        )
    }

    private func observation(identity: QuotaWindowIdentity, percentage: Double) -> QuotaObservation {
        QuotaObservation(
            identity: identity,
            percentageUsed: percentage,
            observedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(60)
        )
    }

    private func forecast(
        identity: QuotaWindowIdentity,
        createdAt: Date? = nil,
        evidenceAge: TimeInterval = 60,
        hasExhaustion: Bool = true,
        inputPercentage: Double = 10
    ) -> QuotaInsightState {
        let createdAt = createdAt ?? now
        let exhaustion: ClosedRange<Date>? = hasExhaustion
            ? createdAt.addingTimeInterval(600)...createdAt.addingTimeInterval(1_200)
            : nil
        let inputs = try! traceInputs(identity: identity, percentage: inputPercentage)
        return .qualified(QualifiedQuotaInsight(
            identity: identity,
            measuredObservationCount: 4,
            measuredSpan: 1_800,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            createdAt: createdAt,
            evidenceAge: evidenceAge,
            inputObservationIdentities: inputs,
            latestObservationIdentity: inputs.last!,
            latestObservationAt: createdAt.addingTimeInterval(-evidenceAge),
            interpretationVersions: [.codexLocalReportV1],
            calculatedBurnPercentPerHour: QuotaInsightRange(lower: 10, upper: 20),
            calculatedExhaustionRange: exhaustion
        ))
    }

    private func anomaly(
        identity: QuotaWindowIdentity,
        qualification: QuotaAnomalyQualification = .qualified,
        limitations: [QuotaAnomalyLimitation] = [.noCausalAttribution, .syntheticFixtureValidationOnly]
    ) throws -> QuotaAnomalyState {
        let current = try QuotaAnomalyPeriod(start: now.addingTimeInterval(-660), end: now.addingTimeInterval(-60))
        let baseline = try QuotaAnomalyPeriod(start: now.addingTimeInterval(-3_660), end: now.addingTimeInterval(-660))
        let metadata = QuotaAnomalyResultMetadata(
            method: .trailingMedianRatioV1,
            qualification: qualification,
            createdAt: now,
            implicatedIdentities: [identity],
            currentPeriod: current,
            baselinePeriod: baseline,
            inputObservationIdentities: try traceInputs(identity: identity, percentage: 20),
            interpretationVersions: [.codexLocalReportV1],
            evidenceVersions: [],
            inputClassifications: [.measured],
            denominatorInputs: [],
            limitations: limitations
        )
        return .finding(QuotaConsumptionAnomalyFinding(
            metadata: metadata,
            findingType: .quotaConsumptionAnomaly,
            direction: .higher,
            identity: identity,
            calculatedCurrentValue: 8,
            calculatedBaselineValues: [2, 2, 2, 2, 2],
            calculatedBaselineMedian: 2,
            calculatedRatio: 4,
            calculatedThreshold: 3,
            normalization: .directQuotaMovement,
            valueClassification: .calculated,
            attribution: .unattributed
        ))
    }

    private func candidate(
        identity: QuotaWindowIdentity,
        percentage: Double,
        inputPercentage: Double = 10
    ) throws -> QuotaFindingAlertObservation {
        try #require(QuotaFindingAlertAdapter.candidates(
            forecasts: [forecast(identity: identity, inputPercentage: inputPercentage)],
            anomalies: [],
            quota: [observation(identity: identity, percentage: percentage)],
            now: now
        ).first)
    }

    private func traceInputs(identity: QuotaWindowIdentity, percentage: Double) throws -> [QuotaObservationIdentity] {
        try [-1_800.0, -60].map { offset in
            try MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: percentage,
                observedAt: now.addingTimeInterval(offset),
                source: .codexLocalReport
            ).stableIdentity
        }
    }

    private func evaluate(rule: QuotaAlertRule, finding: QuotaFindingAlertObservation) -> [AlertEvaluation] {
        AlertEvaluator.evaluate(
            preferences: try! AlertPreferences(quotaRules: [rule], costBudgetRules: []),
            quota: [],
            costs: [],
            findings: [finding],
            satisfied: [],
            now: now
        )
    }
}
