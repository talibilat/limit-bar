import Foundation
import Testing
@testable import LimitBarCore

@Suite("Planned workload assessment")
struct PlannedWorkloadAssessmentTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("comparable measured runs produce a traceable calculated completion range")
    func comparableRuns() throws {
        let fixture = try Fixture(start: start)
        let result = WorkloadPlanning.assess(
            fixture.plan(units: 10),
            historicalRuns: try fixture.runs(requirements: [18, 20, 22, 24], durations: [1_800, 1_900, 2_000, 2_100]),
            currentEvidence: fixture.current(used: 30, exhaustionMinutes: 180),
            now: start.addingTimeInterval(31 * 60)
        )

        guard case let .available(assessment) = result else {
            Issue.record("Expected an available assessment")
            return
        }
        #expect(assessment.conclusion == .likelyCompletionBeforeExhaustion)
        #expect(assessment.requirementPercent.lower == 19.5)
        #expect(assessment.requirementPercent.upper == 22.5)
        #expect(assessment.availablePercent == 70)
        #expect(assessment.currentEvidence.forecastMethod == .pairwisePositiveSlopeInterquartileV2)
        #expect(assessment.currentEvidence.identity.resetBoundary == fixture.identity.resetBoundary)
        #expect(assessment.sample.includedRunIDs == ["run-0", "run-1", "run-2", "run-3"])
        #expect(assessment.sample.excluded[.incompatibleProviderProduct] == 1)
        #expect(assessment.metadata.comparabilityMethod == .strictMeasuredOperationsV1)
        #expect(assessment.metadata.rangeMethod == .interquartilePerUnitV1)
        #expect(assessment.reasons.contains(.requirementBelowAvailableQuota))
        #expect(assessment.limitations.contains(.syntheticFixtureValidationOnly))
    }

    @Test("strict comparison excludes incomplete, failed, version-divergent, and incompatible runs")
    func strictCompatibility() throws {
        let fixture = try Fixture(start: start)
        var runs = try fixture.runs(requirements: [18, 20, 22, 24], durations: [1_800, 1_900, 2_000, 2_100])
        runs.append(try fixture.run(id: "incomplete", requirement: 10, outcome: .incomplete))
        runs.append(try fixture.run(id: "failed", requirement: 10, outcome: .failed))
        runs.append(try fixture.run(id: "client-v2", requirement: 10, clientVersion: "codex-2"))
        runs.append(try fixture.run(id: "adapter-v2", requirement: 10, adapterVersion: "adapter-2"))
        runs.append(try fixture.run(id: "weekly", requirement: 10, windowKind: .weekly))

        guard case let .available(value) = WorkloadPlanning.assess(
            fixture.plan(units: 10), historicalRuns: runs,
            currentEvidence: fixture.current(used: 30, exhaustionMinutes: 180),
            now: start.addingTimeInterval(31 * 60)
        ) else {
            Issue.record("Expected compatible runs to remain available")
            return
        }
        #expect(value.sample.includedRunIDs.count == 4)
        #expect(value.sample.excluded[.incompleteOutcome] == 1)
        #expect(value.sample.excluded[.failedOutcome] == 1)
        #expect(value.sample.excluded[.incompatibleClientVersion] == 1)
        #expect(value.sample.excluded[.incompatibleAdapterVersion] == 1)
        #expect(value.sample.excluded[.incompatibleWindowSemantics] == 1)
    }

    @Test("insufficient or wholly incompatible history is unavailable with distinct reasons")
    func unavailableHistory() throws {
        let fixture = try Fixture(start: start)
        let current = fixture.current(used: 30, exhaustionMinutes: 180)
        let insufficient = WorkloadPlanning.assess(
            fixture.plan(units: 10),
            historicalRuns: try fixture.runs(requirements: [18, 20, 22], durations: [1_800, 1_900, 2_000], includeIncompatible: false),
            currentEvidence: current,
            now: start.addingTimeInterval(31 * 60)
        )
        let incompatible = WorkloadPlanning.assess(
            fixture.plan(units: 10),
            historicalRuns: [try fixture.run(id: "other", requirement: 10, product: .claudeCode)],
            currentEvidence: current,
            now: start.addingTimeInterval(31 * 60)
        )
        let incomplete = WorkloadPlanning.assess(
            fixture.plan(units: 10),
            historicalRuns: [try fixture.run(id: "incomplete", requirement: 10, outcome: .incomplete)],
            currentEvidence: current,
            now: start.addingTimeInterval(31 * 60)
        )

        #expect(insufficient.unavailableReason == .insufficientComparableRuns)
        #expect(incompatible.unavailableReason == .incompatibleHistoricalRuns)
        #expect(incomplete.unavailableReason == .incompleteHistoricalRuns)
    }

    @Test("stale, unqualified, expired, and identity-mismatched current evidence is unavailable")
    func unavailableCurrentEvidence() throws {
        let fixture = try Fixture(start: start)
        let runs = try fixture.runs(requirements: [18, 20, 22, 24], durations: [1_800, 1_900, 2_000, 2_100])
        let plan = fixture.plan(units: 10)
        let now = start.addingTimeInterval(31 * 60)

        #expect(WorkloadPlanning.assess(plan, historicalRuns: runs, currentEvidence: nil, now: now).unavailableReason == .missingCurrentQuotaEvidence)
        #expect(WorkloadPlanning.assess(plan, historicalRuns: runs, currentEvidence: fixture.unqualified(), now: now).unavailableReason == .unqualifiedCurrentQuotaEvidence)
        #expect(WorkloadPlanning.assess(plan, historicalRuns: runs, currentEvidence: fixture.staleCurrent(), now: now).unavailableReason == .staleCurrentQuotaEvidence)
        #expect(WorkloadPlanning.assess(plan, historicalRuns: runs, currentEvidence: fixture.current(used: 30, exhaustionMinutes: 180), now: start.addingTimeInterval(241 * 60)).unavailableReason == .expiredCurrentQuotaBoundary)
        #expect(WorkloadPlanning.assess(plan, historicalRuns: runs, currentEvidence: fixture.mismatchedCurrent(), now: now).unavailableReason == .incompatibleCurrentQuotaEvidence)
    }

    @Test("overlapping ranges remain indeterminate and do not promise completion")
    func indeterminateRange() throws {
        let fixture = try Fixture(start: start)
        let result = WorkloadPlanning.assess(
            fixture.plan(units: 10),
            historicalRuns: try fixture.runs(requirements: [65, 70, 75, 80], durations: [1_800, 1_900, 2_000, 2_100]),
            currentEvidence: fixture.current(used: 30, exhaustionMinutes: 180),
            now: start.addingTimeInterval(31 * 60)
        )

        guard case let .indeterminate(value) = result else {
            Issue.record("Expected an indeterminate overlap")
            return
        }
        #expect(value.reason == .requirementOverlapsAvailableQuota)
        #expect(value.requirementPercent.lower == 68.75)
        #expect(value.requirementPercent.upper == 76.25)
        #expect(value.options.isEmpty)
    }

    @Test("reset and exhaustion interactions are explicit")
    func resetAndExhaustion() throws {
        let fixture = try Fixture(start: start)
        let runs = try fixture.runs(requirements: [18, 20, 22, 24], durations: [14_000, 14_400, 14_800, 15_200])
        let reset = WorkloadPlanning.assess(
            fixture.plan(units: 10), historicalRuns: runs,
            currentEvidence: fixture.current(used: 10, exhaustionMinutes: nil),
            now: start.addingTimeInterval(31 * 60)
        )
        let exhaustion = WorkloadPlanning.assess(
            fixture.plan(units: 10), historicalRuns: runs,
            currentEvidence: fixture.current(used: 10, exhaustionMinutes: 60),
            now: start.addingTimeInterval(31 * 60)
        )

        #expect(reset.availableConclusion == .likelyResetBeforeCompletion)
        #expect(exhaustion.availableConclusion == .likelyExhaustionBeforeCompletion)
    }

    @Test("options appear only when their measured prerequisites hold")
    func evidenceBackedOptions() throws {
        let fixture = try Fixture(start: start)
        let high = try fixture.runs(requirements: [75, 78, 81, 84], durations: [1_800, 1_900, 2_000, 2_100], includeIncompatible: false)
        let lowerConcurrency = try (0..<4).map {
            try fixture.run(id: "lower-\($0)", requirement: Double(35 + $0), concurrency: 1)
        }
        let result = WorkloadPlanning.assess(
            fixture.plan(units: 10), historicalRuns: high + lowerConcurrency,
            currentEvidence: fixture.current(used: 30, exhaustionMinutes: 180),
            now: start.addingTimeInterval(31 * 60)
        )

        guard case let .available(value) = result else {
            Issue.record("Expected an available insufficiency conclusion")
            return
        }
        #expect(value.conclusion == .likelyInsufficientCurrentQuota)
        #expect(value.options.map(\.kind) == [.reduceConcurrency, .reduceWorkUnits, .deferUntilReset])

        let withoutAlternatives = WorkloadPlanning.assess(
            fixture.plan(units: 10), historicalRuns: high,
            currentEvidence: fixture.current(used: 30, exhaustionMinutes: 180),
            now: start.addingTimeInterval(31 * 60)
        )
        #expect(withoutAlternatives.options.map(\.kind) == [.reduceWorkUnits, .deferUntilReset])
    }

    @Test("bounded workload input rejects arbitrary labels and invalid counts")
    func boundedInput() throws {
        #expect(throws: WorkloadPlanningValidationError.self) {
            try PlannedWorkload(
                product: .codex, kind: .codingAgentOperations, quotaWindowKind: .session,
                executionMode: .interactive, concurrency: 0, workUnits: 10,
                adapterVersion: "adapter-1", clientVersion: "codex-1"
            )
        }
        #expect(throws: WorkloadPlanningValidationError.self) {
            try PlannedWorkload(
                product: .codex, kind: .codingAgentOperations, quotaWindowKind: .session,
                executionMode: .interactive, concurrency: 2, workUnits: 10,
                adapterVersion: String(repeating: "x", count: 129), clientVersion: "codex-1"
            )
        }
        #expect(throws: WorkloadPlanningValidationError.self) {
            try Fixture(start: start).run(
                id: "sentinel", requirement: 10,
                clientVersion: "prompt:/private/source.swift"
            )
        }
    }

    @Test("Observed Zero, Gap, unavailable, and duplicate evidence stay distinct")
    func evidenceStateDistinctions() throws {
        let fixture = try Fixture(start: start)
        let completed = try fixture.runs(
            requirements: [18, 20, 22, 24], durations: [1_800, 1_900, 2_000, 2_100], includeIncompatible: false
        )
        var runs = completed
        runs.append(try fixture.run(id: "zero", requirement: 0, outcome: .observedZero))
        runs.append(try fixture.run(id: "gap", requirement: 1, outcome: .gap))
        runs.append(try fixture.run(id: "unavailable", requirement: 1, outcome: .unavailable))
        runs.append(completed[0])

        guard case let .available(value) = WorkloadPlanning.assess(
            fixture.plan(units: 10), historicalRuns: runs,
            currentEvidence: fixture.current(used: 30, exhaustionMinutes: 180),
            now: start.addingTimeInterval(31 * 60)
        ) else {
            Issue.record("Expected completed evidence to remain available")
            return
        }
        #expect(value.sample.excluded[.observedZeroUnsupported] == 1)
        #expect(value.sample.excluded[.gap] == 1)
        #expect(value.sample.excluded[.unavailableEvidence] == 1)
        #expect(value.sample.excluded[.duplicateRun] == 1)
    }

    @Test("conflicting run identity excludes every conflicting record")
    func conflictingRunIdentity() throws {
        let fixture = try Fixture(start: start)
        let first = try fixture.run(id: "conflict", requirement: 10)
        let second = try fixture.run(id: "conflict", requirement: 20)
        let result = WorkloadPlanning.assess(
            fixture.plan(units: 10), historicalRuns: [first, second],
            currentEvidence: fixture.current(used: 30, exhaustionMinutes: 180),
            now: start.addingTimeInterval(31 * 60)
        )

        guard case let .unavailable(value) = result else {
            Issue.record("Expected conflicting evidence to be unavailable")
            return
        }
        #expect(value.reason == .incompleteHistoricalRuns)
        #expect(value.sample.includedRunIDs.isEmpty)
        #expect(value.sample.excluded[.conflictingRunIdentity] == 2)
    }
}

private extension WorkloadPlanningState {
    var unavailableReason: WorkloadPlanningUnavailableReason? {
        guard case let .unavailable(value) = self else { return nil }
        return value.reason
    }

    var availableConclusion: WorkloadPlanningConclusion? {
        guard case let .available(value) = self else { return nil }
        return value.conclusion
    }

    var options: [WorkloadPlanningOption] {
        switch self {
        case let .available(value): value.options
        case let .indeterminate(value): value.options
        case .unavailable: []
        }
    }
}

private struct Fixture {
    let start: Date
    let identity: QuotaWindowIdentity

    init(start: Date) throws {
        self.start = start
        identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: start.addingTimeInterval(240 * 60))
    }

    func plan(units: Int) -> PlannedWorkload {
        try! PlannedWorkload(
            product: .codex, kind: .codingAgentOperations, quotaWindowKind: .session,
            executionMode: .interactive, concurrency: 2, workUnits: units,
            adapterVersion: "adapter-1", clientVersion: "codex-1"
        )
    }

    func runs(
        requirements: [Double], durations: [TimeInterval], includeIncompatible: Bool = true
    ) throws -> [MeasuredHistoricalRun] {
        var values = try zip(requirements, durations).enumerated().map {
            try run(id: "run-\($0.offset)", requirement: $0.element.0, duration: $0.element.1)
        }
        if includeIncompatible {
            values.append(try run(id: "other-product", requirement: 1, product: .claudeCode))
        }
        return values
    }

    func run(
        id: String,
        requirement: Double,
        duration: TimeInterval = 1_800,
        product: ProviderProduct = .codex,
        concurrency: Int = 2,
        outcome: MeasuredHistoricalRunOutcome = .completed,
        clientVersion: String = "codex-1",
        adapterVersion: String = "adapter-1",
        windowKind: WorkloadQuotaWindowKind = .session
    ) throws -> MeasuredHistoricalRun {
        try MeasuredHistoricalRun(
            id: id,
            product: product,
            kind: .codingAgentOperations,
            quotaWindowKind: windowKind,
            executionMode: .interactive,
            concurrency: concurrency,
            completedWorkUnits: 10,
            startedAt: start.addingTimeInterval(-duration),
            endedAt: start,
            measuredQuotaUsedPercent: requirement,
            quotaUnit: .providerReportedPercentage,
            outcome: outcome,
            adapterVersion: adapterVersion,
            clientVersion: clientVersion,
            evidenceIDs: ["evidence-\(id)"]
        )
    }

    func current(used: Double, exhaustionMinutes: Double?) -> CurrentWorkloadQuotaEvidence {
        let observedAt = start.addingTimeInterval(30 * 60)
        let observation = try! MeasuredQuotaObservation(
            identity: identity, percentageUsed: used, observedAt: observedAt, source: .codexLocalReport
        )
        let insight = QualifiedQuotaInsight(
            identity: identity,
            measuredObservationCount: 4,
            measuredSpan: 30 * 60,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            createdAt: start.addingTimeInterval(31 * 60),
            evidenceAge: 60,
            inputObservationIdentities: [observation.stableIdentity],
            interpretationVersions: [.codexLocalReportV1],
            calculatedBurnPercentPerHour: .init(lower: 5, upper: 10),
            calculatedExhaustionRange: exhaustionMinutes.map {
                start.addingTimeInterval($0 * 60)...start.addingTimeInterval(($0 + 20) * 60)
            }
        )
        return CurrentWorkloadQuotaEvidence(observation: observation, forecast: .qualified(insight))
    }

    func unqualified() -> CurrentWorkloadQuotaEvidence {
        let observation = try! MeasuredQuotaObservation(
            identity: identity, percentageUsed: 30, observedAt: start.addingTimeInterval(30 * 60), source: .codexLocalReport
        )
        let unavailable = UnavailableQuotaInsight(
            reason: .insufficientObservations,
            implicatedIdentities: [identity],
            measuredObservationCount: 1,
            measuredSpan: 0,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            createdAt: start.addingTimeInterval(31 * 60),
            evidenceAge: 60,
            inputObservationIdentities: [observation.stableIdentity],
            interpretationVersions: [.codexLocalReportV1]
        )
        return CurrentWorkloadQuotaEvidence(observation: observation, forecast: .unavailable(unavailable))
    }

    func staleCurrent() -> CurrentWorkloadQuotaEvidence {
        let observedAt = start.addingTimeInterval(-7 * 60 * 60)
        let observation = try! MeasuredQuotaObservation(
            identity: identity, percentageUsed: 30, observedAt: observedAt, source: .codexLocalReport
        )
        let insight = QualifiedQuotaInsight(
            identity: identity, measuredObservationCount: 4, measuredSpan: 1_800,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            createdAt: start.addingTimeInterval(31 * 60), evidenceAge: 60,
            inputObservationIdentities: [observation.stableIdentity], interpretationVersions: [.codexLocalReportV1],
            calculatedBurnPercentPerHour: .init(lower: 5, upper: 10), calculatedExhaustionRange: nil
        )
        return CurrentWorkloadQuotaEvidence(observation: observation, forecast: .qualified(insight))
    }

    func mismatchedCurrent() -> CurrentWorkloadQuotaEvidence {
        let observation = try! MeasuredQuotaObservation(
            identity: identity, percentageUsed: 30, observedAt: start.addingTimeInterval(30 * 60), source: .codexLocalReport
        )
        let other = try! QuotaWindowIdentity(product: .codex, identifier: "secondary:10080", resetBoundary: identity.resetBoundary)
        let insight = QualifiedQuotaInsight(
            identity: other, measuredObservationCount: 4, measuredSpan: 1_800,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            createdAt: start.addingTimeInterval(31 * 60), evidenceAge: 60,
            inputObservationIdentities: [observation.stableIdentity], interpretationVersions: [.codexLocalReportV1],
            calculatedBurnPercentPerHour: .init(lower: 5, upper: 10), calculatedExhaustionRange: nil
        )
        return CurrentWorkloadQuotaEvidence(observation: observation, forecast: .qualified(insight))
    }
}
