import Foundation
import Testing
@testable import LimitBarCore

@Suite("Claude quota explanation review boundaries")
struct ClaudeQuotaExplanationReviewTests {
    @Test("enumerates adjacent active and completed intervals and honors selection")
    func intervalCatalog() throws {
        let completed = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: date(250))
        let active = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: date(900))
        let observations = try [
            scoped(completed, 10, 100), scoped(completed, 12, 200),
            scoped(active, 20, 300), scoped(active, 22, 400), scoped(active, 25, 500)
        ]

        let catalog = ClaudeQuotaExplanationEngine.catalog(
            observations: observations,
            evidence: [],
            source: .unavailable([.receiverNotConfigured, .accountBindingUnavailable]),
            evidenceLimitations: [],
            now: date(600)
        )

        #expect(catalog.intervals.count == 3)
        #expect(catalog.intervals.filter { $0.lifecycle == .active }.count == 2)
        #expect(catalog.intervals.filter { $0.lifecycle == .completed }.count == 1)
        #expect(catalog.defaultSelectionID == catalog.intervals.first { $0.intervalEnd == date(500) }?.id)
        let historical = try #require(catalog.intervals.first { $0.lifecycle == .completed })
        #expect(catalog.selection(id: historical.id)?.interval.lifecycle == .completed)
        #expect(catalog.selection(id: historical.id)?.state.isMovement == true)
    }

    @Test("production account-unscoped observations never produce movement")
    func conservativeProductionBoundary() throws {
        let identity = try QuotaWindowIdentity(product: .claudeCode, identifier: "weekly:weekly_all", resetBoundary: date(900))
        let observations = try [
            ClaudeScopedQuotaObservation(observation: measured(identity, 10, 100), accountIdentity: nil, unit: .percentageUsed),
            ClaudeScopedQuotaObservation(observation: measured(identity, 15, 200), accountIdentity: nil, unit: .percentageUsed)
        ]

        let catalog = ClaudeQuotaExplanationEngine.catalog(
            observations: observations,
            evidence: [],
            source: .unavailable([.receiverNotConfigured, .accountBindingUnavailable]),
            evidenceLimitations: [],
            now: date(300)
        )

        let selection = try #require(catalog.defaultSelection)
        #expect(selection.state == .unavailable(.quotaAccountScopeUnavailable))
        #expect(selection.limitations.contains(.receiverNotConfigured))
        #expect(selection.limitations.contains(.accountBindingUnavailable))
        #expect(selection.limitations.contains(.quotaAccountScopeUnavailable))
    }

    @Test("account transitions and incompatible units fail closed")
    func incompatibleInputs() throws {
        let identity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: date(900))
        let lower = try scoped(identity, 10, 100, account: "a")
        let changedAccount = try scoped(identity, 12, 200, account: "b")
        let changedUnit = ClaudeScopedQuotaObservation(observation: try measured(identity, 12, 200), accountIdentity: "a", unit: .requests)

        let account = ClaudeQuotaExplanationEngine.catalog(observations: [lower, changedAccount], evidence: [], source: .unavailable([.receiverNotConfigured]), evidenceLimitations: [], now: date(300))
        let unit = ClaudeQuotaExplanationEngine.catalog(observations: [lower, changedUnit], evidence: [], source: .unavailable([.receiverNotConfigured]), evidenceLimitations: [], now: date(300))

        #expect(account.defaultSelection?.state == .unavailable(.accountTransitionUnverified))
        #expect(unit.defaultSelection?.state == .unavailable(.incompatibleUnit))
    }

    @Test("evidence intervals must be fully contained and expose trace and limitations")
    func evidenceContainment() throws {
        let identity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: date(900))
        let observations = try [scoped(identity, 10, 100), scoped(identity, 15, 200)]
        let contained = try evidence(start: 100, end: 200, identity: "c")
        let crossing = try evidence(start: 90, end: 130, identity: "d")

        let catalog = ClaudeQuotaExplanationEngine.catalog(
            observations: observations,
            evidence: [contained, crossing],
            source: .available(expectedAccountIdentity: digest("a")),
            evidenceLimitations: [],
            now: date(300)
        )

        let selection = try #require(catalog.defaultSelection)
        guard case let .movement(value) = selection.state else {
            Issue.record("Expected movement")
            return
        }
        #expect(value.evidenceIdentities == [digest("c")])
        #expect(value.observationIdentities.count == 2)
        #expect(selection.limitations.contains(.partialCoverage))
        #expect(value.provenance.reportedQuota == .reported)
        #expect(value.provenance.movement == .calculated)
        #expect(value.provenance.localBreakdown == .measured)
    }

    @Test("counter decrease invalidates its whole exact window and a new boundary recovers")
    func wholeWindowCounterDecrease() throws {
        let invalid = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: date(900))
        let recovered = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: date(1_500))
        let values = try [scoped(invalid, 10, 100), scoped(invalid, 8, 200), scoped(invalid, 12, 300), scoped(recovered, 1, 400), scoped(recovered, 2, 500)]

        let catalog = ClaudeQuotaExplanationEngine.catalog(observations: values, evidence: [], source: .unavailable([.receiverNotConfigured]), evidenceLimitations: [], now: date(600))

        let invalidSelections = catalog.selections.filter { $0.interval.identity == invalid }
        #expect(invalidSelections.count == 2)
        #expect(invalidSelections.allSatisfy { $0.state == .unavailable(.counterDecreased) })
        #expect(catalog.selections.first { $0.interval.identity == recovered }?.state.isMovement == true)
    }

    @Test("full coverage distinguishes leading trailing internal gaps overlap and exact zero")
    func completeCoverageUnion() throws {
        let identity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: date(900))
        let observations = try [scoped(identity, 10, 100), scoped(identity, 12, 200)]

        func attribution(_ evidence: [ClaudeCodeOTLPEvidence]) -> ClaudeQuotaAttribution? {
            let state = ClaudeQuotaExplanationEngine.catalog(observations: observations, evidence: evidence, source: .available(expectedAccountIdentity: digest("a")), evidenceLimitations: [], now: date(300)).defaultSelection?.state
            switch state {
            case let .movement(value), let .flat(value): return value.attribution
            case .unavailable, nil: return nil
            }
        }

        #expect(try attribution([evidence(start: 110, end: 200, identity: "c")]) == .unavailable(.gap))
        #expect(try attribution([evidence(start: 100, end: 190, identity: "c")]) == .unavailable(.gap))
        #expect(try attribution([evidence(start: 100, end: 140, identity: "c"), evidence(start: 150, end: 200, identity: "d")]) == .unavailable(.gap))
        guard case .partial = try attribution([evidence(start: 100, end: 160, identity: "c"), evidence(start: 150, end: 200, identity: "d")]) else {
            Issue.record("Expected overlapping intervals with exact union coverage")
            return
        }
        guard case .observedZero = try attribution([evidence(start: 100, end: 200, identity: "e", count: 0)]) else {
            Issue.record("Expected Observed Zero only for exact full coverage")
            return
        }
        let missingBoundary = ClaudeQuotaExplanationEngine.catalog(
            observations: observations,
            evidence: [try evidence(start: 100, end: 200, identity: "e", count: 0)],
            source: .available(expectedAccountIdentity: digest("a")),
            evidenceLimitations: [.missingEvidenceBoundary],
            now: date(300)
        )
        guard case let .movement(value) = missingBoundary.defaultSelection?.state else {
            Issue.record("Expected movement with unavailable attribution")
            return
        }
        #expect(value.attribution == .unavailable(.partialCoverage))
    }

    private func scoped(_ identity: QuotaWindowIdentity, _ percent: Double, _ at: TimeInterval, account: String = digest("a")) throws -> ClaudeScopedQuotaObservation {
        ClaudeScopedQuotaObservation(observation: try measured(identity, percent, at), accountIdentity: account, unit: .percentageUsed)
    }

    private func measured(_ identity: QuotaWindowIdentity, _ percent: Double, _ at: TimeInterval) throws -> MeasuredQuotaObservation {
        try MeasuredQuotaObservation(identity: identity, percentageUsed: percent, observedAt: date(at), source: .claudeProviderReport)
    }

    private func evidence(start: TimeInterval, end: TimeInterval, identity: Character, count: Int64 = 1) throws -> ClaudeCodeOTLPEvidence {
        try ClaudeCodeOTLPEvidence.validated(identity: digest(identity), accountIdentity: digest("a"), sessionIdentity: digest("b"), intervalStart: date(start), intervalEnd: date(end), model: "claude-sonnet-4-5", tokenType: .input, tokenCount: count, sourceVersion: ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion, adapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion)
    }
}
