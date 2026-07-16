import Foundation
import Testing
@testable import LimitBarCore

@Suite("Claude Code quota explanation")
struct ClaudeQuotaExplanationTests {
    @Test("unscoped public observations fail closed without fabricated account identity")
    func unscopedFailsClosed() throws {
        let result = ClaudeQuotaExplanationEngine.explain(
            observations: try observations(10, 14),
            evidence: [],
            expectedAccountIdentity: digest("a"),
            sourceConfigured: true,
            now: date(250)
        )

        #expect(result == .unavailable(.quotaAccountScopeUnavailable))
    }

    @Test("explicitly scoped observations preserve calculated movement while source is unavailable")
    func scopedMovement() throws {
        let catalog = ClaudeQuotaExplanationEngine.catalog(
            observations: try observations(10, 14).map { ClaudeScopedQuotaObservation(observation: $0, accountIdentity: digest("a"), unit: .percentageUsed) },
            evidence: [],
            source: .unavailable([.receiverNotConfigured, .accountBindingUnavailable]),
            evidenceLimitations: [],
            now: date(250)
        )

        guard case let .movement(value) = catalog.defaultSelection?.state else {
            Issue.record("Expected scoped calculated movement")
            return
        }
        #expect(value.reportedQuotaMovementPercent == 4)
        #expect(value.attribution == .unavailable(.receiverNotConfigured))
        #expect(value.observationIdentities.count == 2)
        #expect(value.provenance.reportedQuota == .reported)
        #expect(value.provenance.movement == .calculated)
        #expect(value.provenance.localBreakdown == .unavailable)
    }

    @Test("flat movement remains distinct and makes no no-activity claim")
    func flatMovement() throws {
        let catalog = ClaudeQuotaExplanationEngine.catalog(
            observations: try observations(10, 10).map { ClaudeScopedQuotaObservation(observation: $0, accountIdentity: digest("a"), unit: .percentageUsed) },
            evidence: [],
            source: .unavailable([.receiverNotConfigured]),
            evidenceLimitations: [],
            now: date(250)
        )

        guard case .flat = catalog.defaultSelection?.state else {
            Issue.record("Expected flat movement")
            return
        }
        #expect(catalog.defaultSelection?.state.displayText.contains("does not prove") == true)
    }

    private func observations(_ lower: Double, _ upper: Double) throws -> [MeasuredQuotaObservation] {
        let identity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: date(600))
        return try [
            MeasuredQuotaObservation(identity: identity, percentageUsed: lower, observedAt: date(100), source: .claudeProviderReport),
            MeasuredQuotaObservation(identity: identity, percentageUsed: upper, observedAt: date(200), source: .claudeProviderReport)
        ]
    }
}

func date(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: value) }
func digest(_ character: Character) -> String { String(repeating: character, count: 64) }
