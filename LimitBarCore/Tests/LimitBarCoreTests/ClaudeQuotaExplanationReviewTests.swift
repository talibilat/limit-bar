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
        let contained = evidence(start: 120, end: 150, identity: "contained")
        let crossing = evidence(start: 90, end: 130, identity: "crossing")

        let catalog = ClaudeQuotaExplanationEngine.catalog(
            observations: observations,
            evidence: [contained, crossing],
            source: .available(expectedAccountIdentity: "account-a"),
            evidenceLimitations: [],
            now: date(300)
        )

        let selection = try #require(catalog.defaultSelection)
        guard case let .movement(value) = selection.state else {
            Issue.record("Expected movement")
            return
        }
        #expect(value.evidenceIdentities == ["contained"])
        #expect(value.observationIdentities.count == 2)
        #expect(selection.limitations.contains(.partialCoverage))
        #expect(value.provenance.reportedQuota == .reported)
        #expect(value.provenance.movement == .calculated)
        #expect(value.provenance.localBreakdown == .measured)
    }

    private func scoped(_ identity: QuotaWindowIdentity, _ percent: Double, _ at: TimeInterval, account: String = "account-a") throws -> ClaudeScopedQuotaObservation {
        ClaudeScopedQuotaObservation(observation: try measured(identity, percent, at), accountIdentity: account, unit: .percentageUsed)
    }

    private func measured(_ identity: QuotaWindowIdentity, _ percent: Double, _ at: TimeInterval) throws -> MeasuredQuotaObservation {
        try MeasuredQuotaObservation(identity: identity, percentageUsed: percent, observedAt: date(at), source: .claudeProviderReport)
    }

    private func evidence(start: TimeInterval, end: TimeInterval, identity: String) -> ClaudeCodeOTLPEvidence {
        ClaudeCodeOTLPEvidence(identity: identity, accountIdentity: "account-a", sessionIdentity: "session-a", intervalStart: date(start), intervalEnd: date(end), model: "claude-sonnet-4-5", tokenType: .input, tokenCount: 1, sourceVersion: ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion, adapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion)
    }
}

private func date(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: value) }
