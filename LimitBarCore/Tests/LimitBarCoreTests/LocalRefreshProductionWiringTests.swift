import Foundation
import Testing
@testable import LimitBarCore

@Suite("Local refresh production wiring")
struct LocalRefreshProductionWiringTests {
    @MainActor
    @Test("live local dependencies publish usage, menu status, and Codex into one state projection")
    func liveLocalProjection() async throws {
        let metric = UsageMetric(
            provider: .anthropic,
            accountLabel: "Local",
            projectLabel: nil,
            modelLabel: "claude",
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1),
            cost: nil,
            limitStatus: .confirmed(used: 82, limit: 100),
            refreshedAt: Date(timeIntervalSince1970: 1),
            freshness: .fresh
        )
        let usage = LocalUsageSourceSpy(refresh: LocalUsageRefresh(
            snapshot: StoredUsageMetricsSnapshot(
                metrics: [metric],
                health: UsageStoreHealth(isOpen: true, message: "OK"),
                localImport: .empty(fileURL: URL(fileURLWithPath: "/tmp/events"))
            ),
            customDiagnostics: []
        ))
        let codexSnapshot = CodexRateLimitSnapshot(
            planType: "plus",
            primary: CodexRateLimitWindow(percentUsed: 10, windowMinutes: 300, resetsAt: nil),
            secondary: nil,
            credits: nil,
            reportedAt: Date(timeIntervalSince1970: 2)
        )
        let codex = LocalCodexSourceSpy(snapshot: codexSnapshot)
        let dependencies = LocalRefreshDependencies.live(usage: usage, codex: codex)
        let coordinator = LocalRefreshCoordinator(dependencies: dependencies)
        let state = LimitBarLocalStateProjection()
        var iterator = coordinator.snapshots.makeAsyncIterator()

        await coordinator.requestRefresh()
        let published = try #require(await iterator.next())
        state.apply(published)

        #expect(await usage.callCount == 1)
        #expect(await codex.callCount == 1)
        #expect(state.metrics == [metric])
        #expect(state.status.menuBarText == "82%")
        #expect(state.codexSnapshot == codexSnapshot)
    }
}

private actor LocalUsageSourceSpy: LocalUsageRefreshing {
    private let refresh: LocalUsageRefresh
    private(set) var callCount = 0

    init(refresh: LocalUsageRefresh) { self.refresh = refresh }

    func refresh(now: Date, calendar: Calendar) -> LocalUsageRefresh {
        callCount += 1
        return refresh
    }
}

private actor LocalCodexSourceSpy: LocalCodexScanning {
    private let snapshot: CodexRateLimitSnapshot?
    private(set) var callCount = 0

    init(snapshot: CodexRateLimitSnapshot?) { self.snapshot = snapshot }

    func scan(now _: Date) -> CodexRateLimitSnapshot? {
        callCount += 1
        return snapshot
    }
}
