import Foundation
import Testing
@testable import LimitBarCore

@Suite("Codex quota explanation")
struct CodexQuotaExplanationTests {
    @Test("separates Calculated quota movement from Measured local token breakdown")
    func completeExplanation() throws {
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: date(600))
        let observations = try [
            MeasuredQuotaObservation(identity: identity, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: identity, percentageUsed: 13.5, observedAt: date(200), source: .codexLocalReport)
        ]
        let evidence = [evidence(at: 150, input: 7, output: 3)]

        let result = CodexQuotaExplanationEngine.explain(
            observations: observations,
            evidence: evidence,
            coverageStart: date(90),
            coverageEnd: date(210),
            barriers: []
        )

        guard case let .available(explanation) = result else {
            Issue.record("Expected available explanation")
            return
        }
        #expect(explanation.calculatedQuotaMovementPercent == 3.5)
        #expect(explanation.observedLocalBreakdown.tokens.total == 10)
        #expect(explanation.observedLocalBreakdown.tokens.cachedInput == 2)
        #expect(explanation.unattributed)
        #expect(explanation.inferredAllocation == nil)
        #expect(explanation.observationIdentities.count == 2)
        #expect(explanation.evidenceIdentities.count == 1)
        #expect(result.displayText.contains("input 7, cached input 2, output 3, reasoning output 1"))
        #expect(!result.displayText.contains(explanation.evidenceIdentities[0]))
    }

    @Test("evidence on the upper quota observation line is included")
    func evidenceAtUpperObservationIsIncluded() throws {
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: date(600))
        let lower = try MeasuredQuotaObservation(identity: identity, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport)
        let upper = try MeasuredQuotaObservation(identity: identity, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport)

        let result = CodexQuotaExplanationEngine.explain(
            observations: [lower, upper],
            evidence: [evidence(at: 200, input: 2, output: 3)],
            coverageStart: date(90),
            coverageEnd: date(200),
            barriers: []
        )

        guard case let .available(explanation) = result else {
            Issue.record("Expected upper-line evidence to be included")
            return
        }
        #expect(explanation.observedLocalBreakdown.tokens.total == 5)
    }

    @Test("multi-file evidence can produce partial coverage")
    func multiFileEvidenceCanRemainPartial() throws {
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: date(600))
        let lower = try MeasuredQuotaObservation(identity: identity, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport)
        let upper = try MeasuredQuotaObservation(identity: identity, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport)

        let result = CodexQuotaExplanationEngine.explain(
            observations: [lower, upper],
            evidence: [evidence(at: 150, input: 2, output: 3)],
            coverageStart: nil,
            coverageEnd: nil,
            barriers: []
        )

        guard case let .partial(explanation) = result else {
            Issue.record("Expected evidence without complete coverage to remain partial")
            return
        }
        #expect(explanation.observedLocalBreakdown.tokens.total == 5)
    }

    @Test("a barrier yields partial evidence without bridging")
    func partialBarrier() throws {
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: date(600))
        let observations = try [
            MeasuredQuotaObservation(identity: identity, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: identity, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport)
        ]

        let result = CodexQuotaExplanationEngine.explain(
            observations: observations,
            evidence: [evidence(at: 150, input: 1, output: 1)],
            coverageStart: date(90),
            coverageEnd: date(210),
            barriers: [.malformedRecord]
        )

        guard case let .partial(explanation) = result else {
            Issue.record("Expected partial explanation")
            return
        }
        #expect(explanation.barriers == [.malformedRecord])
        #expect(explanation.calculatedQuotaMovementPercent == 2)
    }

    @Test("distinguishes missing evidence, observed zero, counter decrease, and reset")
    func unavailableStates() throws {
        let first = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: date(600))
        let reset = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: date(700))
        let lower = try MeasuredQuotaObservation(identity: first, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport)
        let upper = try MeasuredQuotaObservation(identity: first, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport)
        let decreased = try MeasuredQuotaObservation(identity: first, percentageUsed: 9, observedAt: date(200), source: .codexLocalReport)
        let changedWindow = try MeasuredQuotaObservation(identity: reset, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport)

        #expect(CodexQuotaExplanationEngine.explain(observations: [lower, upper], evidence: [], coverageStart: nil, coverageEnd: nil, barriers: []) == .unavailable(.gap))
        #expect(CodexQuotaExplanationEngine.explain(observations: [lower, upper], evidence: [], coverageStart: nil, coverageEnd: nil, barriers: [.evidenceLimitExceeded]) == .unavailable(.unsupportedEvidence))
        #expect(CodexQuotaExplanationEngine.explain(observations: [lower, upper], evidence: [evidence(at: 150, input: 0, output: 0)], coverageStart: date(90), coverageEnd: date(210), barriers: []) == .observedZero(CodexQuotaObservedZero(
            intervalStart: date(100),
            intervalEnd: date(200),
            calculatedQuotaMovementPercent: 2,
            quotaResetBoundary: date(600),
            observationIdentities: [lower.stableIdentity, upper.stableIdentity],
            evidenceIdentities: ["\(String(repeating: "a", count: 64)):3:\(String(repeating: "b", count: 64))"],
            quotaWindowIdentity: first
        )))
        #expect(CodexQuotaExplanationEngine.explain(observations: [lower, decreased], evidence: [], coverageStart: date(90), coverageEnd: date(210), barriers: []) == .unavailable(.counterDecreased))
        #expect(CodexQuotaExplanationEngine.explain(observations: [lower, changedWindow], evidence: [], coverageStart: date(90), coverageEnd: date(210), barriers: []) == .unavailable(.incompatibleQuotaWindow))
    }

    @Test("counter decrease anywhere in a Quota window and Exact boundary rejects that window")
    func adjacentCounterDecreaseRejectsWindow() throws {
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: date(600))
        let decreaseAfterIncrease = try [10.0, 12, 11].enumerated().map { index, percent in
            try MeasuredQuotaObservation(identity: identity, percentageUsed: percent, observedAt: date(Double(index + 1) * 100), source: .codexLocalReport)
        }
        let decreaseBeforeIncrease = try [10.0, 9, 12].enumerated().map { index, percent in
            try MeasuredQuotaObservation(identity: identity, percentageUsed: percent, observedAt: date(Double(index + 1) * 100), source: .codexLocalReport)
        }

        #expect(CodexQuotaExplanationEngine.explain(observations: decreaseAfterIncrease, evidence: [], coverageStart: date(0), coverageEnd: date(400), barriers: []) == .unavailable(.counterDecreased))
        #expect(CodexQuotaExplanationEngine.explain(observations: decreaseBeforeIncrease, evidence: [], coverageStart: date(0), coverageEnd: date(400), barriers: []) == .unavailable(.counterDecreased))
    }

    @Test("selected quota window must be active and fresh at evaluation time")
    func activeFreshWindowRequired() throws {
        let expired = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: date(250))
        let active = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: date(1_000))
        let expiredObservations = try [
            MeasuredQuotaObservation(identity: expired, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: expired, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport)
        ]
        let staleObservations = try [
            MeasuredQuotaObservation(identity: active, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: active, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport)
        ]

        #expect(CodexQuotaExplanationEngine.explain(observations: expiredObservations, evidence: [], coverageStart: date(90), coverageEnd: date(210), barriers: [], now: date(300), maximumObservationAge: 1_000) == .unavailable(.expiredQuotaWindow))
        #expect(CodexQuotaExplanationEngine.explain(observations: staleObservations, evidence: [], coverageStart: date(90), coverageEnd: date(210), barriers: [], now: date(500), maximumObservationAge: 100) == .unavailable(.insufficientObservations))
    }

    @Test("selects the latest compatible pair within one Quota window and Exact boundary")
    func latestCompatiblePairWithinWindow() throws {
        let primary = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: date(600))
        let secondary = try QuotaWindowIdentity(product: .codex, identifier: "codex:secondary:10080", resetBoundary: date(700))
        let observations = try [
            MeasuredQuotaObservation(identity: primary, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: secondary, percentageUsed: 50, observedAt: date(100), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: primary, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: secondary, percentageUsed: 49, observedAt: date(200), source: .codexLocalReport)
        ]

        let result = CodexQuotaExplanationEngine.explain(
            observations: observations,
            evidence: [evidence(at: 150, input: 1, output: 1)],
            coverageStart: date(90),
            coverageEnd: date(210),
            barriers: []
        )

        guard case let .available(explanation) = result else {
            Issue.record("Expected primary explanation despite simultaneous secondary decrease")
            return
        }
        #expect(explanation.calculatedQuotaMovementPercent == 2)
        #expect(explanation.observationIdentities.count == 2)
    }

    @Test("prefers primary session when primary and secondary latest pairs are both compatible")
    func prefersPrimaryPair() throws {
        let primary = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: date(600))
        let secondary = try QuotaWindowIdentity(product: .codex, identifier: "codex:secondary:10080", resetBoundary: date(700))
        let observations = try [
            MeasuredQuotaObservation(identity: primary, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: secondary, percentageUsed: 50, observedAt: date(100), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: primary, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: secondary, percentageUsed: 55, observedAt: date(200), source: .codexLocalReport)
        ]

        let result = CodexQuotaExplanationEngine.explain(
            observations: observations,
            evidence: [evidence(at: 150, input: 1, output: 1)],
            coverageStart: date(90),
            coverageEnd: date(210),
            barriers: []
        )

        guard case let .available(explanation) = result else {
            Issue.record("Expected available explanation")
            return
        }
        #expect(explanation.calculatedQuotaMovementPercent == 2)
    }

    @Test("evidence identities include privacy-safe session identity to avoid ordinal digest collisions")
    func evidenceIdentityIncludesSessionDigest() throws {
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "codex:primary:300", resetBoundary: date(600))
        let observations = try [
            MeasuredQuotaObservation(identity: identity, percentageUsed: 10, observedAt: date(100), source: .codexLocalReport),
            MeasuredQuotaObservation(identity: identity, percentageUsed: 12, observedAt: date(200), source: .codexLocalReport)
        ]
        let first = CodexRolloutEvidence(
            sessionIdentity: String(repeating: "a", count: 64),
            lineOrdinal: 3,
            lineSHA256: String(repeating: "b", count: 64),
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            creatorVersion: "0.144.4",
            observedAt: date(150),
            tokens: CodexMeasuredTokens(input: 1, cachedInput: 0, output: 1, reasoningOutput: 0)
        )
        let second = CodexRolloutEvidence(
            sessionIdentity: String(repeating: "c", count: 64),
            lineOrdinal: 3,
            lineSHA256: String(repeating: "b", count: 64),
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            creatorVersion: "0.144.4",
            observedAt: date(160),
            tokens: CodexMeasuredTokens(input: 2, cachedInput: 0, output: 2, reasoningOutput: 0)
        )

        let result = CodexQuotaExplanationEngine.explain(
            observations: observations,
            evidence: [first, second],
            coverageStart: date(90),
            coverageEnd: date(210),
            barriers: []
        )

        guard case let .available(explanation) = result else {
            Issue.record("Expected available explanation")
            return
        }
        #expect(Set(explanation.evidenceIdentities).count == 2)
        #expect(explanation.evidenceIdentities.allSatisfy { $0.split(separator: ":").count == 3 })
    }

    private func evidence(at timestamp: TimeInterval, input: Int64, output: Int64) -> CodexRolloutEvidence {
        CodexRolloutEvidence(
            sessionIdentity: String(repeating: "a", count: 64),
            lineOrdinal: 3,
            lineSHA256: String(repeating: "b", count: 64),
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            creatorVersion: "0.144.4",
            observedAt: date(timestamp),
            tokens: CodexMeasuredTokens(input: input, cachedInput: min(2, input), output: output, reasoningOutput: min(1, output))
        )
    }
}
