import Foundation
import Testing
@testable import LimitBarCore

@Suite("Local refresh coordinator")
struct LocalRefreshCoordinatorTests {
    @Test("start refreshes immediately and then exactly every five seconds")
    func periodicTiming() async throws {
        let clock = ManualRefreshClock()
        let calls = CallRecorder()
        let coordinator = LocalRefreshCoordinator(
            dependencies: dependencies(calls: calls),
            clock: clock.clock,
            now: { Date(timeIntervalSince1970: 100) },
            calendar: Calendar(identifier: .gregorian)
        )

        await coordinator.start()
        await eventually { await calls.counts == [1, 1] }
        await clock.advance(by: 4)
        await Task.yield()
        #expect(await calls.usageCount == 1)

        await clock.advance(by: 1)
        await eventually { await calls.counts == [2, 2] }
        await coordinator.stop()
    }

    @Test("changing cadence refreshes immediately and restarts periodic timing")
    func cadenceChange() async {
        let clock = ManualRefreshClock()
        let calls = CallRecorder()
        let coordinator = LocalRefreshCoordinator(dependencies: dependencies(calls: calls), clock: clock.clock)

        await coordinator.start()
        await eventually { await calls.usageCount == 1 }

        await coordinator.setRefreshInterval(15)
        await eventually { await calls.usageCount == 2 }
        await clock.advance(by: 5)
        await Task.yield()
        #expect(await calls.usageCount == 2)

        await clock.advance(by: 10)
        await eventually { await calls.usageCount == 3 }
        await coordinator.stop()
    }

    @Test("changing cadence during a refresh preserves one coalesced follow-up")
    func cadenceChangeDuringRefresh() async {
        let clock = ManualRefreshClock()
        let gate = AsyncGate()
        let calls = CallRecorder()
        let coordinator = LocalRefreshCoordinator(
            dependencies: LocalRefreshDependencies(
                refreshUsage: { _, _ in
                    await calls.recordUsage()
                    await gate.wait()
                    return emptyUsageRefresh()
                },
                scanCodex: { _ in await calls.recordCodex(); return nil }
            ),
            clock: clock.clock
        )

        await coordinator.start()
        await eventually { await calls.usageCount == 1 }
        await coordinator.setRefreshInterval(15)
        await coordinator.setRefreshInterval(30)
        await gate.open()
        await eventually { await calls.usageCount == 2 }

        #expect(await calls.usageCount == 2)
        await coordinator.stop()
    }

    @Test("multiple requests during a refresh produce at most one coalesced refresh")
    func coalescing() async {
        let gate = AsyncGate()
        let calls = CallRecorder()
        let coordinator = LocalRefreshCoordinator(
            dependencies: LocalRefreshDependencies(
                refreshUsage: { _, _ in
                    await calls.recordUsage()
                    await gate.wait()
                    return emptyUsageRefresh()
                },
                scanCodex: { _ in await calls.recordCodex(); return nil }
            )
        )

        async let first: Void = coordinator.requestRefresh()
        await eventually { await calls.usageCount == 1 }
        async let second: Void = coordinator.requestRefresh()
        async let third: Void = coordinator.requestRefresh()
        await gate.open()
        _ = await (first, second, third)

        #expect(await calls.usageCount == 2)
    }

    @Test("five-second ticks coalesce even while a refresh is running")
    func tickDuringRefresh() async {
        let clock = ManualRefreshClock()
        let gate = AsyncGate()
        let calls = CallRecorder()
        let coordinator = LocalRefreshCoordinator(
            dependencies: LocalRefreshDependencies(
                refreshUsage: { _, _ in
                    await calls.recordUsage()
                    await gate.wait()
                    return emptyUsageRefresh()
                },
                scanCodex: { _ in await calls.recordCodex(); return nil }
            ),
            clock: clock.clock
        )

        await coordinator.start()
        await eventually { await calls.usageCount == 1 }
        await clock.advance(by: 5)
        await gate.open()
        await eventually { await calls.usageCount == 2 }

        #expect(await calls.usageCount == 2)
        await coordinator.stop()
    }

    @Test("stop cancels periodic refreshes")
    func stop() async {
        let clock = ManualRefreshClock()
        let calls = CallRecorder()
        let coordinator = LocalRefreshCoordinator(dependencies: dependencies(calls: calls), clock: clock.clock)
        await coordinator.start()
        await eventually { await calls.usageCount == 1 }

        await coordinator.stop()
        await clock.advance(by: 10)
        await Task.yield()

        #expect(await calls.usageCount == 1)
    }

    @Test("periodic task does not retain an otherwise released coordinator")
    func coordinatorRelease() async {
        let clock = ManualRefreshClock()
        let calls = CallRecorder()
        var coordinator: LocalRefreshCoordinator? = LocalRefreshCoordinator(
            dependencies: dependencies(calls: calls),
            clock: clock.clock
        )
        let releasedCoordinator = WeakCoordinator(coordinator)

        await coordinator?.start()
        await eventually { await calls.usageCount == 1 }
        coordinator = nil
        await eventually { releasedCoordinator.value == nil }

        #expect(releasedCoordinator.value == nil)
    }

    @Test("stop and restart keep a cancelled in-flight refresh isolated from the new generation")
    func stopRestartInFlight() async {
        let clock = ManualRefreshClock()
        let probe = RestartProbe()
        let coordinator = LocalRefreshCoordinator(dependencies: await probe.dependencies, clock: clock.clock)
        var iterator = coordinator.snapshots.makeAsyncIterator()

        await coordinator.start()
        await eventually { await probe.callCount == 1 }
        await coordinator.stop()
        await coordinator.start()
        await clock.advance(by: 5)
        for _ in 0..<100 { await Task.yield() }

        #expect(await probe.callCount == 1)
        #expect(await probe.maximumConcurrentCalls == 1)

        await probe.releaseFirst()
        await eventually { await probe.callCount == 2 }
        let snapshot = await iterator.next()

        #expect(snapshot?.usage == nil)
        #expect(snapshot?.codex?.reportedAt == Date(timeIntervalSince1970: 2))
        #expect(await probe.maximumConcurrentCalls == 1)
        #expect(await probe.callCount == 2)
        await coordinator.stop()
    }

    @Test("a failed source preserves its last successful component and snapshots remain ordered")
    func preservesComponents() async {
        let calls = ThrowingSourceRecorder()
        let coordinator = LocalRefreshCoordinator(dependencies: await calls.dependencies)
        var iterator = coordinator.snapshots.makeAsyncIterator()

        await coordinator.requestRefresh()
        let first = await iterator.next()
        await coordinator.requestRefresh()
        let second = await iterator.next()

        #expect(first?.sequence == 1)
        #expect(second?.sequence == 2)
        #expect(second?.usage == first?.usage)
        #expect(second?.codex?.reportedAt == Date(timeIntervalSince1970: 2))
        #expect(first?.usageRefreshed == true)
        #expect(first?.codexRefreshed == true)
        #expect(second?.usageRefreshed == false)
        #expect(second?.codexRefreshed == true)
    }

    @Test("a failed Codex scan preserves display data but marks it ineligible for alerts")
    func marksPreservedCodexAsNotRefreshed() async {
        let calls = CodexFailureRecorder()
        let coordinator = LocalRefreshCoordinator(dependencies: await calls.dependencies)
        var iterator = coordinator.snapshots.makeAsyncIterator()

        await coordinator.requestRefresh()
        let first = await iterator.next()
        await coordinator.requestRefresh()
        let second = await iterator.next()

        #expect(first?.codexRefreshed == true)
        #expect(second?.codex == first?.codex)
        #expect(second?.codexRefreshed == false)
        #expect(second?.usageRefreshed == true)
    }

    @Test("a failed Codex publication preserves display data but does not publish fresh explanation evidence")
    func failedCodexPublicationDropsExplanationEvidence() async {
        let calls = CodexPublicationFailureRecorder()
        let coordinator = LocalRefreshCoordinator(dependencies: await calls.dependencies)
        var iterator = coordinator.snapshots.makeAsyncIterator()

        await coordinator.requestRefresh()
        let first = await iterator.next()
        await coordinator.requestRefresh()
        let second = await iterator.next()

        #expect(first?.codexRefreshed == true)
        #expect(first?.codexExplanation == codexObservedZero(movement: 2))
        #expect(second?.codex == first?.codex)
        #expect(second?.codexRefreshed == false)
        #expect(second?.codexExplanation == .unavailable(.unsupportedEvidence))
    }

    @Test("a failed Codex scan can publish a retained explanation marked retained")
    func failedCodexScanPublishesRetainedExplanation() async {
        let coordinator = LocalRefreshCoordinator(dependencies: LocalRefreshDependencies(
            refreshUsage: { _, _ in emptyUsageRefresh() },
            scanCodexPublication: { _ in throw TestFailure() },
            loadRetainedCodexExplanation: { _ in codexObservedZero(movement: 1) }
        ))
        var iterator = coordinator.snapshots.makeAsyncIterator()

        await coordinator.requestRefresh()
        let snapshot = await iterator.next()

        #expect(snapshot?.codexRefreshed == false)
        #expect(snapshot?.codexExplanation == codexObservedZero(movement: 1))
        #expect(snapshot?.codexExplanationRetained == true)
    }
}

private func codexObservedZero(movement: Double) -> CodexQuotaExplanationState {
    .observedZero(CodexQuotaObservedZero(
        intervalStart: Date(timeIntervalSince1970: 100),
        intervalEnd: Date(timeIntervalSince1970: 200),
        calculatedQuotaMovementPercent: movement,
        quotaResetBoundary: Date(timeIntervalSince1970: 600),
        observationIdentities: [],
        evidenceIdentities: [],
        observationIdentityCount: 2,
        evidenceIdentityCount: 1
    ))
}

private func dependencies(calls: CallRecorder) -> LocalRefreshDependencies {
    LocalRefreshDependencies(
        refreshUsage: { _, _ in await calls.recordUsage(); return emptyUsageRefresh() },
        scanCodex: { _ in await calls.recordCodex(); return nil }
    )
}

private func emptyUsageRefresh() -> LocalUsageRefresh {
    LocalUsageRefresh(
        snapshot: StoredUsageMetricsSnapshot(
            metrics: [],
            health: UsageStoreHealth(isOpen: true, message: "OK"),
            localImport: .empty(fileURL: URL(fileURLWithPath: "/tmp/events"))
        ),
        customDiagnostics: []
    )
}

private actor CallRecorder {
    private(set) var usageCount = 0
    private(set) var codexCount = 0
    func recordUsage() { usageCount += 1 }
    func recordCodex() { codexCount += 1 }
    var counts: [Int] { [usageCount, codexCount] }
}

private actor AsyncGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if openState { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        openState = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class ManualRefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var sleepers: [(deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []

    var clock: LocalRefreshClock {
        LocalRefreshClock { [self] duration in
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { sleepers.append((elapsed + duration, continuation)) }
            }
        }
    }

    func advance(by duration: TimeInterval) async {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            elapsed += duration
            let due = sleepers.filter { $0.deadline <= elapsed }.map(\.continuation)
            sleepers.removeAll { $0.deadline <= elapsed }
            return due
        }
        due.forEach { $0.resume() }
        await Task.yield()
    }
}

private actor ThrowingSourceRecorder {
    private var pass = 0
    private var codexPass = 0
    var dependencies: LocalRefreshDependencies {
        LocalRefreshDependencies(
            refreshUsage: { [self] _, _ in try await refreshUsage() },
            scanCodex: { [self] _ in await scanCodex() }
        )
    }

    private func refreshUsage() throws -> LocalUsageRefresh {
        pass += 1
        if pass == 2 { throw TestFailure() }
        return emptyUsageRefresh()
    }

    private func scanCodex() -> CodexRateLimitSnapshot {
        codexPass += 1
        return CodexRateLimitSnapshot(planType: nil, primary: nil, secondary: nil, credits: CodexCredits(hasCredits: true, unlimited: false, balance: 1), reportedAt: Date(timeIntervalSince1970: TimeInterval(codexPass)))
    }
}

private actor CodexFailureRecorder {
    private var codexPass = 0

    var dependencies: LocalRefreshDependencies {
        LocalRefreshDependencies(
            refreshUsage: { _, _ in emptyUsageRefresh() },
            scanCodex: { [self] _ in try await scanCodex() }
        )
    }

    private func scanCodex() throws -> CodexRateLimitSnapshot {
        codexPass += 1
        if codexPass == 2 { throw TestFailure() }
        return CodexRateLimitSnapshot(
            planType: "plus",
            primary: CodexRateLimitWindow(percentUsed: 80, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 600)),
            secondary: nil,
            credits: nil,
            reportedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private actor CodexPublicationFailureRecorder {
    private var codexPass = 0

    var dependencies: LocalRefreshDependencies {
        LocalRefreshDependencies(
            refreshUsage: { _, _ in emptyUsageRefresh() },
            scanCodexPublication: { [self] _ in try await scanCodex() }
        )
    }

    private func scanCodex() throws -> CodexSessionScanPublication {
        codexPass += 1
        if codexPass == 2 { throw TestFailure() }
        return CodexSessionScanPublication(
            snapshot: CodexRateLimitSnapshot(
                planType: "plus",
                primary: CodexRateLimitWindow(percentUsed: 80, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 600)),
                secondary: nil,
                credits: nil,
                reportedAt: Date(timeIntervalSince1970: 1)
            ),
            explanation: codexObservedZero(movement: 2),
            evidence: [],
            barriers: [],
            coverageStart: Date(timeIntervalSince1970: 0),
            coverageEnd: Date(timeIntervalSince1970: 2)
        )
    }
}

private actor RestartProbe {
    private(set) var callCount = 0
    private var concurrentCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    var dependencies: LocalRefreshDependencies {
        LocalRefreshDependencies(
            refreshUsage: { [self] _, _ in try await refreshUsage() },
            scanCodex: { [self] _ in await codexSnapshot() }
        )
    }

    private func refreshUsage() async throws -> LocalUsageRefresh {
        callCount += 1
        let call = callCount
        concurrentCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
        defer { concurrentCalls -= 1 }
        if call == 1 {
            await withCheckedContinuation { firstContinuation = $0 }
            return emptyUsageRefresh()
        }
        throw TestFailure()
    }

    private func codexSnapshot() -> CodexRateLimitSnapshot {
        let call = max(callCount, 1)
        return CodexRateLimitSnapshot(
            planType: nil,
            primary: nil,
            secondary: nil,
            credits: CodexCredits(hasCredits: true, unlimited: false, balance: 1),
            reportedAt: Date(timeIntervalSince1970: TimeInterval(call))
        )
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private struct TestFailure: Error {}

private final class WeakCoordinator: @unchecked Sendable {
    weak var value: LocalRefreshCoordinator?
    init(_ value: LocalRefreshCoordinator?) { self.value = value }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
}
