import Foundation
import Testing
@testable import LimitBarCore

@Suite("Claude analysis publication")
struct ClaudeAnalysisPublicationTests {
    @Test("forecast anomaly and explanation catalog publish in one actor snapshot")
    func coherentSnapshot() async throws {
        let service = QuotaInsightsService(store: try SQLiteQuotaObservationStore.inMemory())
        let reset = Date(timeIntervalSince1970: 1_000)
        _ = try await service.recordClaudeAnalysis(snapshot(percent: 10, at: 100, reset: reset), now: Date(timeIntervalSince1970: 100))
        let analysis = try await service.recordClaudeAnalysis(snapshot(percent: 12, at: 200, reset: reset), now: Date(timeIntervalSince1970: 200))

        let interval = try #require(analysis.claudeExplanations.defaultSelection?.interval)
        #expect(analysis.forecasts.keys.contains(interval.identity))
        #expect(analysis.anomalies.keys.contains(interval.identity))
        #expect(analysis.claudeExplanations.defaultSelection?.state == .unavailable(.quotaAccountScopeUnavailable))
        #expect(analysis.claudeExplanations.limitations.contains(.receiverNotConfigured))
        #expect(analysis.claudeExplanations.limitations.contains(.accountBindingUnavailable))
    }

    private func snapshot(percent: Double, at: TimeInterval, reset: Date) -> ClaudeRateLimitSnapshot {
        ClaudeRateLimitSnapshot(
            limits: [ClaudeRateLimit(kind: "session", group: .session, percentUsed: percent, severity: .normal, resetsAt: reset, scopeDisplayName: nil, isActive: true)],
            fetchedAt: Date(timeIntervalSince1970: at)
        )
    }
}
