import Foundation
import Testing
@testable import LimitBarCore

@Suite("Planned workload assessment")
struct PlannedWorkloadAssessmentTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("comparable exact-window runs produce a traceable calculated range")
    func comparableRuns() throws {
        let fixture = try Fixture(start: start)
        let result = WorkloadPlanning.assess(
            try fixture.plan(units: 10),
            historicalRuns: try fixture.runs(requirements: [18, 20, 22, 24]),
            currentEvidence: fixture.current(used: 30, burn: 5...10),
            now: fixture.now
        )

        guard case let .available(value) = result else {
            Issue.record("Expected an available assessment")
            return
        }
        #expect(value.conclusion == .likelyCompletionBeforeLimitingBoundary)
        #expect(value.requirementPercent == QuotaInsightRange(lower: 19.5, upper: 22.5))
        #expect(value.currentEvidence.availablePercent == 70)
        #expect(value.currentEvidence.boundaryInteraction == .resetExpectedFirst)
        #expect(value.sample.includedRevisionIdentities.count == 4)
        #expect(value.sample.observationIdentities.count == 4)
        #expect(value.sample.evidenceIdentities.count == 4)
        #expect(value.metadata.comparabilityMethod == .strictMeasuredOperationsV2)
    }

    @Test("historical runs require an exact contained interval and immutable typed evidence")
    func exactHistoricalWindowValidation() throws {
        let fixture = try Fixture(start: start)
        #expect(throws: WorkloadPlanningValidationError.self) {
            try fixture.run(index: 1, requirement: 10, startedAt: fixture.historicalWindowStart.addingTimeInterval(-1))
        }
        #expect(throws: WorkloadPlanningValidationError.self) {
            try fixture.run(index: 1, requirement: 10, endedAt: fixture.historicalIdentity.resetBoundary.addingTimeInterval(1))
        }
    }

    @Test("strict comparison rejects product, window, source, and every typed version boundary")
    func strictCompatibility() throws {
        let fixture = try Fixture(start: start)
        var runs = try fixture.runs(requirements: [18, 20, 22, 24])
        runs.append(try fixture.run(index: 10, requirement: 10, identity: fixture.otherProductIdentity))
        runs.append(try fixture.run(index: 11, requirement: 10, identity: fixture.weeklyIdentity))
        runs.append(try fixture.run(index: 12, requirement: 10, source: .normalizedCompletedRunAdapter, adapter: fixture.otherAdapter))
        runs.append(try fixture.run(index: 13, requirement: 10, client: fixture.otherClient))
        runs.append(try fixture.run(index: 14, requirement: 10, format: fixture.otherFormat))

        guard case let .available(value) = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: runs,
            currentEvidence: fixture.current(used: 30, burn: 5...10), now: fixture.now
        ) else {
            Issue.record("Expected compatible runs to remain available")
            return
        }
        #expect(value.sample.includedRevisionIdentities.count == 4)
        #expect(value.sample.excluded[.incompatibleProviderProduct] == 1)
        #expect(value.sample.excluded[.incompatibleWindowSemantics] == 1)
        #expect(value.sample.excluded[.incompatibleAdapterVersion] == 1)
        #expect(value.sample.excluded[.incompatibleClientVersion] == 1)
        #expect(value.sample.excluded[.incompatibleProviderFormatVersion] == 1)
    }

    @Test("corrections select one terminal immutable revision and retain superseded traceability")
    func corrections() throws {
        let fixture = try Fixture(start: start)
        var runs = try fixture.runs(requirements: [18, 20, 22, 24])
        let original = runs.removeFirst()
        let corrected = try fixture.run(
            index: 0,
            revision: 100,
            supersedes: original.revisionIdentity,
            requirement: 26
        )
        let result = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: [original, corrected] + runs,
            currentEvidence: fixture.current(used: 30, burn: 5...10), now: fixture.now
        )

        guard case let .available(value) = result else {
            Issue.record("Expected corrected sample")
            return
        }
        #expect(value.sample.includedRevisionIdentities.contains(corrected.revisionIdentity))
        #expect(!value.sample.includedRevisionIdentities.contains(original.revisionIdentity))
        #expect(value.sample.supersededRevisionIdentities == [original.revisionIdentity])
        #expect(value.sample.excluded[.supersededRevision] == 1)
    }

    @Test("retries and conflicting revision identities never qualify samples or options")
    func retriesAndConflicts() throws {
        let fixture = try Fixture(start: start)
        let high = try fixture.runs(requirements: [75, 78, 81, 84])
        let alternatives = try (20..<24).map { try fixture.run(index: $0, requirement: Double($0), concurrency: 1) }
        let retryFlood = Array(repeating: alternatives[0], count: 4)
        let conflict = try fixture.run(
            index: 99,
            revisionIdentity: alternatives[1].revisionIdentity,
            requirement: 1,
            concurrency: 1
        )
        let result = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: high + retryFlood + [alternatives[1], conflict],
            currentEvidence: fixture.current(used: 30, burn: 5...10), now: fixture.now
        )

        guard case let .available(value) = result else {
            Issue.record("Expected current-concurrency insufficiency")
            return
        }
        #expect(value.conclusion == .likelyInsufficientCurrentQuota)
        #expect(!value.options.map(\.kind).contains(.reduceConcurrency))
        #expect(value.sample.excluded[.duplicateRevision] == 3)
        #expect(value.sample.excluded[.conflictingRevisionIdentity] == 2)
    }

    @Test("current evidence must be the exact latest forecast observation")
    func latestCurrentObservation() throws {
        let fixture = try Fixture(start: start)
        let runs = try fixture.runs(requirements: [18, 20, 22, 24])
        let older = fixture.current(used: 30, burn: 5...10, passOlderObservation: true)

        let result = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: runs, currentEvidence: older, now: fixture.now
        )
        #expect(result.unavailable?.reason == .incompatibleCurrentQuotaEvidence)
        #expect(result.unavailable?.currentEvidence?.latestObservationIdentity == older.latestObservation.stableIdentity)
        #expect(result.unavailable?.currentEvidence?.unboundedExhaustionRange == nil)
        #expect(result.unavailable?.currentEvidence?.boundaryInteraction == nil)
    }

    @Test("unavailable current evidence retains safe qualification, method, age, and boundary metadata")
    func unavailableMetadata() throws {
        let fixture = try Fixture(start: start)
        let runs = try fixture.runs(requirements: [18, 20, 22, 24])
        let unqualified = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: runs,
            currentEvidence: fixture.unqualified(), now: fixture.now
        )
        let stale = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: runs,
            currentEvidence: fixture.staleCurrent(), now: fixture.now
        )
        let expired = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: runs,
            currentEvidence: fixture.current(used: 30, burn: 5...10),
            now: fixture.currentIdentity.resetBoundary
        )

        #expect(unqualified.unavailable?.currentEvidence?.forecastQualification == .unavailable)
        #expect(unqualified.unavailable?.currentEvidence?.forecastUnavailableReason == .insufficientObservations)
        #expect(unqualified.unavailable?.currentEvidence?.forecastMethod == .pairwisePositiveSlopeInterquartileV2)
        #expect(stale.unavailable?.currentEvidence?.evidenceAge == Double(7 * 60 * 60 + 31 * 60))
        #expect(stale.unavailable?.currentEvidence?.identity.resetBoundary == fixture.currentIdentity.resetBoundary)
        #expect(expired.unavailable?.currentEvidence?.identity.resetBoundary == fixture.currentIdentity.resetBoundary)
    }

    @Test("exhaustion and reset interactions distinguish before, overlap, equality, and after")
    func boundaryInteractions() throws {
        let fixture = try Fixture(start: start)
        let short = try fixture.runs(requirements: [18, 20, 22, 24], durations: [1_800, 1_900, 2_000, 2_100])
        let long = try fixture.runs(requirements: [18, 20, 22, 24], durations: [15_000, 15_100, 15_200, 15_300])

        let exhaustionFirst = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: long,
            currentEvidence: fixture.current(used: 10, burn: 60...90), now: fixture.now
        )
        let resetFirst = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: long,
            currentEvidence: fixture.current(used: 30, burn: 5...10), now: fixture.now
        )
        let straddling = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: long,
            currentEvidence: fixture.current(used: 10, burn: 20...40), now: fixture.now
        )
        let equal = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: long,
            currentEvidence: fixture.current(used: 30, burn: 10...20), now: fixture.now
        )
        let completesBeforeOverlap = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: short,
            currentEvidence: fixture.current(used: 10, burn: 20...40), now: fixture.now
        )

        #expect(exhaustionFirst.available?.conclusion == .likelyExhaustionBeforeCompletion)
        #expect(exhaustionFirst.available?.currentEvidence.boundaryInteraction == .exhaustionExpectedFirst)
        #expect(resetFirst.available?.conclusion == .likelyResetBeforeCompletion)
        #expect(resetFirst.available?.currentEvidence.boundaryInteraction == .resetExpectedFirst)
        #expect(straddling.indeterminate?.reason == .exhaustionOverlapsReset)
        #expect(equal.indeterminate?.reason == .exhaustionOverlapsReset)
        #expect(equal.indeterminate?.currentEvidence.boundaryInteraction == .indeterminateOverlap)
        #expect(completesBeforeOverlap.available?.conclusion == .likelyCompletionBeforeLimitingBoundary)
    }

    @Test("closed-range equality with workload completion is indeterminate")
    func boundaryEqualityIsIndeterminate() throws {
        let fixture = try Fixture(start: start)
        let exactDuration = fixture.currentIdentity.resetBoundary.timeIntervalSince(fixture.now)
        let runs = try fixture.runs(requirements: [18, 20, 22, 24], durations: Array(repeating: exactDuration, count: 4))
        let result = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: runs,
            currentEvidence: fixture.current(used: 30, burn: 5...10), now: fixture.now
        )
        #expect(result.indeterminate?.reason == .completionOverlapsReset)
    }

    @Test("defer option requires reset-first evidence and cites typed evidence")
    func deferOptionQualification() throws {
        let fixture = try Fixture(start: start)
        let high = try fixture.runs(requirements: [75, 78, 81, 84])
        let resetFirst = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: high,
            currentEvidence: fixture.current(used: 30, burn: 5...10), now: fixture.now
        )
        let exhaustionFirst = WorkloadPlanning.assess(
            try fixture.plan(units: 10), historicalRuns: high,
            currentEvidence: fixture.current(used: 30, burn: 60...90), now: fixture.now
        )

        let option = resetFirst.available?.options.first { $0.kind == .deferUntilReset }
        #expect(option?.limitation == .postResetCapacityUnknown)
        #expect(option?.observationIdentities.count == 1)
        #expect(option?.evidenceIdentities.count == 4)
        #expect(exhaustionFirst.available?.options.allSatisfy { $0.kind != .deferUntilReset } == true)
    }
}

private extension WorkloadPlanningState {
    var available: AvailableWorkloadPlanningAssessment? {
        guard case let .available(value) = self else { return nil }
        return value
    }
    var indeterminate: IndeterminateWorkloadPlanningAssessment? {
        guard case let .indeterminate(value) = self else { return nil }
        return value
    }
    var unavailable: UnavailableWorkloadPlanningAssessment? {
        guard case let .unavailable(value) = self else { return nil }
        return value
    }
}

private struct Fixture {
    let start: Date
    let now: Date
    let currentIdentity: QuotaWindowIdentity
    let historicalIdentity: QuotaWindowIdentity
    let weeklyIdentity: QuotaWindowIdentity
    let otherProductIdentity: QuotaWindowIdentity
    let historicalWindowStart: Date
    let adapter = WorkloadAdapterVersion(uuid(1))
    let otherAdapter = WorkloadAdapterVersion(uuid(2))
    let client = WorkloadClientVersion(uuid(3))
    let otherClient = WorkloadClientVersion(uuid(4))
    let format = WorkloadProviderFormatVersion(uuid(5))
    let otherFormat = WorkloadProviderFormatVersion(uuid(6))

    init(start: Date) throws {
        self.start = start
        now = start.addingTimeInterval(31 * 60)
        currentIdentity = try QuotaWindowIdentity(
            product: .codex, identifier: "codex:primary:300", resetBoundary: start.addingTimeInterval(240 * 60)
        )
        historicalIdentity = try QuotaWindowIdentity(
            product: .codex, identifier: "codex:primary:300", resetBoundary: start.addingTimeInterval(10 * 60)
        )
        weeklyIdentity = try QuotaWindowIdentity(
            product: .codex, identifier: "codex:secondary:10080", resetBoundary: start.addingTimeInterval(10 * 60)
        )
        otherProductIdentity = try QuotaWindowIdentity(
            product: .claudeCode, identifier: "session:session", resetBoundary: start.addingTimeInterval(10 * 60)
        )
        historicalWindowStart = start.addingTimeInterval(-300 * 60)
    }

    func plan(units: Int) throws -> PlannedWorkload {
        try PlannedWorkload(
            product: .codex, kind: .codingAgentOperations, quotaWindowKind: .session,
            executionMode: .interactive, concurrency: 2, workUnits: units,
            source: .normalizedCompletedRunAdapter, adapterVersion: adapter,
            clientVersion: client, providerFormatVersion: format
        )
    }

    func runs(requirements: [Double], durations: [TimeInterval]? = nil) throws -> [MeasuredHistoricalRun] {
        try requirements.enumerated().map {
            try run(index: $0.offset, requirement: $0.element, duration: durations?[$0.offset] ?? 1_800)
        }
    }

    func run(
        index: Int,
        revision: Int? = nil,
        revisionIdentity: HistoricalRunRevisionIdentity? = nil,
        supersedes: HistoricalRunRevisionIdentity? = nil,
        requirement: Double,
        duration: TimeInterval = 1_800,
        identity: QuotaWindowIdentity? = nil,
        concurrency: Int = 2,
        outcome: MeasuredHistoricalRunOutcome = .completed,
        source: WorkloadRunSourceProvenance = .normalizedCompletedRunAdapter,
        adapter: WorkloadAdapterVersion? = nil,
        client: WorkloadClientVersion? = nil,
        format: WorkloadProviderFormatVersion? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) throws -> MeasuredHistoricalRun {
        let quotaIdentity = identity ?? historicalIdentity
        let end = endedAt ?? start
        let observation = try MeasuredQuotaObservation(
            identity: quotaIdentity,
            percentageUsed: min(100, max(0, requirement)),
            observedAt: min(end, quotaIdentity.resetBoundary),
            source: quotaIdentity.product == .codex ? .codexLocalReport : .claudeProviderReport
        )
        return try MeasuredHistoricalRun(
            identity: HistoricalRunIdentity(uuid(index + 100)),
            revisionIdentity: revisionIdentity ?? HistoricalRunRevisionIdentity(uuid((revision ?? index) + 1_000)),
            supersedesRevisionIdentity: supersedes,
            quotaWindowIdentity: quotaIdentity,
            quotaWindowStart: historicalWindowStart,
            kind: .codingAgentOperations,
            executionMode: .interactive,
            concurrency: concurrency,
            completedWorkUnits: 10,
            startedAt: startedAt ?? end.addingTimeInterval(-duration),
            endedAt: end,
            measuredQuotaUsedPercent: requirement,
            quotaUnit: .providerReportedPercentage,
            outcome: outcome,
            source: source,
            adapterVersion: adapter ?? self.adapter,
            clientVersion: client ?? self.client,
            providerFormatVersion: format ?? self.format,
            observationIdentities: [observation.stableIdentity],
            evidenceIdentities: [WorkloadEvidenceIdentity(uuid(index + 2_000))]
        )
    }

    func current(
        used: Double,
        burn: ClosedRange<Double>,
        passOlderObservation: Bool = false
    ) -> CurrentWorkloadQuotaEvidence {
        let older = try! MeasuredQuotaObservation(
            identity: currentIdentity, percentageUsed: max(0, used - 1),
            observedAt: start.addingTimeInterval(20 * 60), source: .codexLocalReport
        )
        let latest = try! MeasuredQuotaObservation(
            identity: currentIdentity, percentageUsed: used,
            observedAt: start.addingTimeInterval(30 * 60), source: .codexLocalReport
        )
        let insight = QualifiedQuotaInsight(
            identity: currentIdentity,
            measuredObservationCount: 4,
            measuredSpan: 30 * 60,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            createdAt: now,
            evidenceAge: 60,
            inputObservationIdentities: [older.stableIdentity, latest.stableIdentity],
            latestObservationIdentity: latest.stableIdentity,
            latestObservationAt: latest.observedAt,
            interpretationVersions: [.codexLocalReportV1],
            calculatedBurnPercentPerHour: .init(lower: burn.lowerBound, upper: burn.upperBound),
            calculatedExhaustionRange: nil
        )
        return CurrentWorkloadQuotaEvidence(
            latestObservation: passOlderObservation ? older : latest,
            forecast: .qualified(insight)
        )
    }

    func unqualified() -> CurrentWorkloadQuotaEvidence {
        let observation = try! MeasuredQuotaObservation(
            identity: currentIdentity, percentageUsed: 30,
            observedAt: start.addingTimeInterval(30 * 60), source: .codexLocalReport
        )
        return CurrentWorkloadQuotaEvidence(
            latestObservation: observation,
            forecast: .unavailable(UnavailableQuotaInsight(
                reason: .insufficientObservations,
                implicatedIdentities: [currentIdentity],
                measuredObservationCount: 1,
                measuredSpan: 0,
                forecastMethod: .pairwisePositiveSlopeInterquartileV2,
                createdAt: now,
                evidenceAge: 60,
                inputObservationIdentities: [observation.stableIdentity],
                interpretationVersions: [.codexLocalReportV1]
            ))
        )
    }

    func staleCurrent() -> CurrentWorkloadQuotaEvidence {
        let observation = try! MeasuredQuotaObservation(
            identity: currentIdentity, percentageUsed: 30,
            observedAt: start.addingTimeInterval(-7 * 60 * 60), source: .codexLocalReport
        )
        let insight = QualifiedQuotaInsight(
            identity: currentIdentity, measuredObservationCount: 4, measuredSpan: 1_800,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            createdAt: now, evidenceAge: 60,
            inputObservationIdentities: [observation.stableIdentity],
            latestObservationIdentity: observation.stableIdentity,
            latestObservationAt: observation.observedAt,
            interpretationVersions: [.codexLocalReportV1],
            calculatedBurnPercentPerHour: .init(lower: 5, upper: 10), calculatedExhaustionRange: nil
        )
        return CurrentWorkloadQuotaEvidence(latestObservation: observation, forecast: .qualified(insight))
    }

}

private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}
