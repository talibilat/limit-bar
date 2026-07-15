import Foundation
import Testing
@testable import LimitBarCore

@Suite("Claude Code quota explanation")
struct ClaudeQuotaExplanationTests {
    @Test("preserves measured movement when attribution evidence is unavailable")
    func movementWithoutEvidence() throws {
        let observations = try observations(10, 14)

        let result = ClaudeQuotaExplanationEngine.explain(
            observations: observations,
            evidence: [],
            expectedAccountIdentity: nil,
            sourceConfigured: false,
            now: date(250)
        )

        guard case let .movement(explanation) = result else {
            Issue.record("Expected measured movement")
            return
        }
        #expect(explanation.providerProduct == .claudeCode)
        #expect(explanation.reportedQuotaMovementPercent == 4)
        #expect(explanation.attribution == .unavailable(.sourceNotConfigured))
        #expect(explanation.unattributed)
        #expect(explanation.observationIdentities.count == 2)
        #expect(explanation.methodVersion == ClaudeQuotaExplanationEngine.methodVersion)
        #expect(result.displayText.contains("Claude Code"))
        #expect(result.displayText.contains("unattributed"))
    }

    @Test("qualifying telemetry is only a partial Observed Local Breakdown")
    func qualifyingEvidence() throws {
        let observations = try observations(10, 14)
        let evidence = [telemetry(at: 150, account: "account-a", type: .input, count: 100)]

        let result = ClaudeQuotaExplanationEngine.explain(
            observations: observations,
            evidence: evidence,
            expectedAccountIdentity: "account-a",
            sourceConfigured: true,
            now: date(250)
        )

        guard case let .movement(explanation) = result else {
            Issue.record("Expected measured movement")
            return
        }
        guard case let .partial(breakdown) = explanation.attribution else {
            Issue.record("Expected partial evidence")
            return
        }
        #expect(breakdown.inputTokens == 100)
        #expect(breakdown.outputTokens == 0)
        #expect(breakdown.modelCounts == ["claude-sonnet-4-5": 1])
        #expect(explanation.unattributed)
        #expect(explanation.inferredAllocationPercent == nil)
    }

    @Test("cross-account, duplicate, out-of-order, and incompatible evidence fail safely")
    func evidenceQualification() throws {
        let observations = try observations(10, 14)
        let duplicate = telemetry(at: 150, account: "account-a", type: .input, count: 100)
        let result = ClaudeQuotaExplanationEngine.explain(
            observations: observations,
            evidence: [telemetry(at: 160, account: "account-b", type: .output, count: 9), duplicate, duplicate],
            expectedAccountIdentity: "account-a",
            sourceConfigured: true,
            now: date(250)
        )

        guard case let .movement(explanation) = result,
              case let .partial(breakdown) = explanation.attribution else {
            Issue.record("Expected partial matching-account evidence")
            return
        }
        #expect(breakdown.inputTokens == 100)
        #expect(breakdown.outputTokens == 0)
        #expect(breakdown.evidenceCount == 1)

        let unsupported = ClaudeCodeOTLPEvidence(
            identity: "unsupported",
            accountIdentity: "account-a",
            sessionIdentity: "session-a",
            observedAt: date(150),
            model: "claude-sonnet-4-5",
            tokenType: .input,
            tokenCount: 1,
            sourceVersion: "3.0.0",
            adapterVersion: "future-adapter"
        )
        let rejected = ClaudeQuotaExplanationEngine.explain(
            observations: observations,
            evidence: [unsupported],
            expectedAccountIdentity: "account-a",
            sourceConfigured: true,
            now: date(250)
        )
        guard case let .movement(value) = rejected else {
            Issue.record("Expected movement")
            return
        }
        #expect(value.attribution == .unavailable(.unsupportedEvidence))
    }

    @Test("flat, decrease, reset, stale, and gap are distinct")
    func distinctStates() throws {
        let flat = ClaudeQuotaExplanationEngine.explain(observations: try observations(10, 10), evidence: [], expectedAccountIdentity: nil, sourceConfigured: false, now: date(250))
        guard case .flat = flat else {
            Issue.record("Expected flat movement")
            return
        }
        #expect(ClaudeQuotaExplanationEngine.explain(observations: try observations(10, 9), evidence: [], expectedAccountIdentity: nil, sourceConfigured: false, now: date(250)) == .unavailable(.counterDecreased))

        let first = try observations(10, 11)[0]
        let changed = try MeasuredQuotaObservation(
            identity: QuotaWindowIdentity(product: .claudeCode, identifier: "weekly:weekly_all", resetBoundary: date(800)),
            percentageUsed: 12,
            observedAt: date(200),
            source: .claudeProviderReport
        )
        #expect(ClaudeQuotaExplanationEngine.explain(observations: [first, changed], evidence: [], expectedAccountIdentity: nil, sourceConfigured: false, now: date(250)) == .unavailable(.incompatibleQuotaWindow))
        #expect(ClaudeQuotaExplanationEngine.explain(observations: [first], evidence: [], expectedAccountIdentity: nil, sourceConfigured: false, now: date(250)) == .unavailable(.insufficientObservations))
        #expect(ClaudeQuotaExplanationEngine.explain(observations: try observations(10, 11), evidence: [], expectedAccountIdentity: nil, sourceConfigured: false, now: date(1_000)) == .unavailable(.expiredQuotaWindow))
    }

    @Test("local activity beside flat movement makes no zero-quota claim")
    func activityWithFlatMovement() throws {
        let result = ClaudeQuotaExplanationEngine.explain(
            observations: try observations(10, 10),
            evidence: [telemetry(at: 150, account: "account-a", type: .output, count: 20)],
            expectedAccountIdentity: "account-a",
            sourceConfigured: true,
            now: date(250)
        )

        guard case let .flat(value) = result, case .partial = value.attribution else {
            Issue.record("Expected flat movement with a separate local breakdown")
            return
        }
        #expect(result.displayText.contains("does not prove that no Claude Code activity occurred"))
    }

    private func observations(_ lower: Double, _ upper: Double) throws -> [MeasuredQuotaObservation] {
        let identity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: date(600))
        return try [
            MeasuredQuotaObservation(identity: identity, percentageUsed: lower, observedAt: date(100), source: .claudeProviderReport),
            MeasuredQuotaObservation(identity: identity, percentageUsed: upper, observedAt: date(200), source: .claudeProviderReport)
        ]
    }

    private func telemetry(at timestamp: TimeInterval, account: String, type: ClaudeCodeTokenType, count: Int64) -> ClaudeCodeOTLPEvidence {
        ClaudeCodeOTLPEvidence(
            identity: "\(account)-\(timestamp)-\(type.rawValue)-\(count)",
            accountIdentity: account,
            sessionIdentity: "session-a",
            observedAt: date(timestamp),
            model: "claude-sonnet-4-5",
            tokenType: type,
            tokenCount: count,
            sourceVersion: "2.1.207",
            adapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion
        )
    }
}

private func date(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: value) }
