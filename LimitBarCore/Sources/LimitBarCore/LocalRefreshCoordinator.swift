import Foundation
import Observation
import os

public struct LocalUsageRefresh: Equatable, Sendable {
    public let snapshot: StoredUsageMetricsSnapshot
    public let customDiagnostics: [CustomUsageRefreshDiagnostic]
    public let history: HistoricalUsageSnapshot

    public init(
        snapshot: StoredUsageMetricsSnapshot,
        customDiagnostics: [CustomUsageRefreshDiagnostic],
        history: HistoricalUsageSnapshot = .loading
    ) {
        self.snapshot = snapshot
        self.customDiagnostics = customDiagnostics
        self.history = history
    }
}

public struct LocalRefreshDependencies: Sendable {
    public let refreshUsage: @Sendable (Date, Calendar) async throws -> LocalUsageRefresh
    public let scanCodex: @Sendable (Date) async throws -> CodexSessionScanPublication?
    public let loadRetainedCodexExplanation: @Sendable (Date) async -> CodexQuotaExplanationState?

    public init(
        refreshUsage: @escaping @Sendable (Date, Calendar) async throws -> LocalUsageRefresh,
        scanCodex: @escaping @Sendable (Date) async throws -> CodexRateLimitSnapshot?
    ) {
        self.refreshUsage = refreshUsage
        loadRetainedCodexExplanation = { _ in nil }
        self.scanCodex = { now in
            let snapshot = try await scanCodex(now)
            return snapshot.map {
                CodexSessionScanPublication(
                    snapshot: $0,
                    explanation: .unavailable(.insufficientObservations),
                    evidence: [],
                    barriers: [],
                    coverageStart: nil,
                    coverageEnd: nil
                )
            }
        }
    }

    public init(
        refreshUsage: @escaping @Sendable (Date, Calendar) async throws -> LocalUsageRefresh,
        scanCodexPublication: @escaping @Sendable (Date) async throws -> CodexSessionScanPublication?,
        loadRetainedCodexExplanation: @escaping @Sendable (Date) async -> CodexQuotaExplanationState? = { _ in nil }
    ) {
        self.refreshUsage = refreshUsage
        scanCodex = scanCodexPublication
        self.loadRetainedCodexExplanation = loadRetainedCodexExplanation
    }
}

public protocol LocalUsageRefreshing: Sendable {
    func refresh(now: Date, calendar: Calendar) async throws -> LocalUsageRefresh
}

public protocol LocalCodexScanning: Sendable {
    func scan(now: Date) async throws -> CodexRateLimitSnapshot?
}

public protocol LocalCodexEvidenceScanning: Sendable {
    func scanPublication(now: Date) async throws -> CodexSessionScanPublication?
    func retainedExplanation(now: Date) async -> CodexQuotaExplanationState?
}

public extension LocalRefreshDependencies {
    static func live(
        usage: any LocalUsageRefreshing,
        codex: any LocalCodexScanning
    ) -> LocalRefreshDependencies {
        LocalRefreshDependencies(
            refreshUsage: { now, calendar in try await usage.refresh(now: now, calendar: calendar) },
            scanCodex: { now in try await codex.scan(now: now) }
        )
    }

    static func live(
        usage: any LocalUsageRefreshing,
        codexEvidence: any LocalCodexEvidenceScanning
    ) -> LocalRefreshDependencies {
        LocalRefreshDependencies(
            refreshUsage: { now, calendar in try await usage.refresh(now: now, calendar: calendar) },
            scanCodexPublication: { now in try await codexEvidence.scanPublication(now: now) },
            loadRetainedCodexExplanation: { now in await codexEvidence.retainedExplanation(now: now) }
        )
    }
}

public struct CodexSessionScanner: LocalCodexScanning, LocalCodexEvidenceScanning {
    private let sessionsDirectory: URL
    private let identityKey: Data
    private let explanationStore: SQLiteCodexExplanationStore?

    public init(
        sessionsDirectory: URL,
        identityKey: Data = Data("LimitBar-Codex-local-identity-v1".utf8),
        explanationStore: SQLiteCodexExplanationStore? = nil
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.identityKey = identityKey
        self.explanationStore = explanationStore
    }

    public func scan(now: Date) throws -> CodexRateLimitSnapshot? {
        try scanPublication(now: now)?.snapshot
    }

    public func scanPublication(now: Date) throws -> CodexSessionScanPublication? {
        do {
            let publication = try CodexSessionEvidenceReader.scan(sessionsDirectory: sessionsDirectory, now: now, identityKey: identityKey)
            try? explanationStore?.record(publication.explanation, now: now)
            return publication
        } catch CodexRateLimitFailure.notFound {
            return nil
        }
    }

    public func retainedExplanation(now: Date) -> CodexQuotaExplanationState? {
        try? explanationStore?.latest(now: now)
    }
}

public struct LocalRefreshClock: Sendable {
    private let sleepImplementation: @Sendable (TimeInterval) async throws -> Void

    public init(sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        sleepImplementation = sleep
    }

    public func sleep(for duration: TimeInterval) async throws {
        try await sleepImplementation(duration)
    }

    public static let continuous = LocalRefreshClock { duration in
        try await Task.sleep(for: .seconds(duration))
    }
}

public struct LocalRefreshSnapshot: Equatable, Sendable {
    public let sequence: UInt64
    public let usage: LocalUsageRefresh?
    public let codex: CodexRateLimitSnapshot?
    public let codexExplanation: CodexQuotaExplanationState
    public let codexExplanationRetained: Bool
    public let refreshedAt: Date
    public let triggeredAt: ContinuousClock.Instant
    public let usageRefreshed: Bool
    public let codexRefreshed: Bool

    public init(
        sequence: UInt64,
        usage: LocalUsageRefresh?,
        codex: CodexRateLimitSnapshot?,
        codexExplanation: CodexQuotaExplanationState = .unavailable(.insufficientObservations),
        codexExplanationRetained: Bool = false,
        refreshedAt: Date,
        triggeredAt: ContinuousClock.Instant = .now,
        usageRefreshed: Bool = true,
        codexRefreshed: Bool = true
    ) {
        self.sequence = sequence
        self.usage = usage
        self.codex = codex
        self.codexExplanation = codexExplanation
        self.codexExplanationRetained = codexExplanationRetained
        self.refreshedAt = refreshedAt
        self.triggeredAt = triggeredAt
        self.usageRefreshed = usageRefreshed
        self.codexRefreshed = codexRefreshed
    }
}

@MainActor
@Observable
public final class LimitBarLocalStateProjection {
    public private(set) var status = AppStatus.initial
    public private(set) var metrics: [UsageMetric] = []
    public private(set) var storeHealth = UsageStoreHealth(isOpen: false, message: "Loading SQLite store")
    public private(set) var localImport = LocalUsageImportResult.empty(fileURL: URL(fileURLWithPath: ""))
    public private(set) var customImportFailures = 0
    public private(set) var customRejectedLines = 0
    public private(set) var codexSnapshot: CodexRateLimitSnapshot?
    public private(set) var codexExplanation: CodexQuotaExplanationState = .unavailable(.insufficientObservations)
    public private(set) var codexExplanationRetained = false
    public private(set) var history = HistoricalUsageSnapshot.loading

    public init() {}

    public func apply(_ refresh: LocalRefreshSnapshot) {
        if let usage = refresh.usage {
            metrics = usage.snapshot.metrics
            storeHealth = usage.snapshot.health
            localImport = usage.snapshot.localImport
            customImportFailures = usage.customDiagnostics.filter { $0.failureMessage != nil }.count
            customRejectedLines = usage.customDiagnostics.reduce(0) { $0 + $1.rejectedLineCount }
            history = usage.history
            status = AppStatus.from(menuBarStatus: MenuBarStatus.from(metrics: metrics))
        }
        codexSnapshot = refresh.codex
        codexExplanation = refresh.codexExplanation
        codexExplanationRetained = refresh.codexExplanationRetained
    }

    public func restoreCodexExplanation(_ state: CodexQuotaExplanationState?) {
        codexExplanation = state ?? .unavailable(.insufficientObservations)
        codexExplanationRetained = state != nil
    }

    public func clearCodexExplanation() {
        codexExplanation = .unavailable(.insufficientObservations)
        codexExplanationRetained = false
    }

    public func clearHistory() {
        history = HistoricalUsageSnapshot(
            dailyBuckets: [],
            weeklyBuckets: [],
            health: UsageStoreHealth(isOpen: true, message: "Historical usage database opened"),
            retention: history.retention
        )
    }
}

public actor LocalRefreshCoordinator {
    private struct RefreshExecution {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private struct PendingRefresh {
        let generation: UInt64
        let triggeredAt: ContinuousClock.Instant
    }

    public nonisolated let snapshots: AsyncStream<LocalRefreshSnapshot>

    private let dependencies: LocalRefreshDependencies
    private let clock: LocalRefreshClock
    private var refreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let continuation: AsyncStream<LocalRefreshSnapshot>.Continuation
    private var periodicTask: Task<Void, Never>?
    private var refreshExecution: RefreshExecution?
    private var pendingRefresh: PendingRefresh?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var lastUsage: LocalUsageRefresh?
    private var lastCodex: CodexSessionScanPublication?

    public init(
        dependencies: LocalRefreshDependencies,
        clock: LocalRefreshClock = .continuous,
        refreshInterval: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        precondition(refreshInterval > 0)
        self.dependencies = dependencies
        self.clock = clock
        self.refreshInterval = refreshInterval
        self.now = now
        self.calendar = calendar
        let pair = AsyncStream<LocalRefreshSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshots = pair.stream
        continuation = pair.continuation
    }

    deinit {
        continuation.finish()
        periodicTask?.cancel()
        refreshExecution?.task.cancel()
    }

    public func start() {
        guard periodicTask == nil else { return }
        startPeriodicTask()
    }

    public func setRefreshInterval(_ refreshInterval: TimeInterval) {
        precondition(refreshInterval > 0)
        guard refreshInterval != self.refreshInterval else { return }
        self.refreshInterval = refreshInterval
        guard periodicTask != nil else { return }
        periodicTask?.cancel()
        periodicTask = nil
        startPeriodicTask()
    }

    private func startPeriodicTask() {
        let startGeneration = generation
        let clock = clock
        let refreshInterval = refreshInterval
        periodicTask = Task { [weak self, startGeneration, clock, refreshInterval] in
            await self?.scheduleRefresh(for: startGeneration)
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: refreshInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.scheduleRefresh(for: startGeneration)
            }
        }
    }

    public func stop() {
        generation &+= 1
        periodicTask?.cancel()
        periodicTask = nil
        refreshExecution?.task.cancel()
        pendingRefresh = nil
    }

    public func requestRefresh() async {
        let task = scheduleRefresh(for: generation)
        await task.value
    }

    @discardableResult
    private func scheduleRefresh(for requestedGeneration: UInt64) -> Task<Void, Never> {
        guard requestedGeneration == generation else {
            return Task {}
        }
        let triggeredAt = ContinuousClock.now
        if let refreshExecution {
            if pendingRefresh?.generation != requestedGeneration {
                pendingRefresh = PendingRefresh(generation: requestedGeneration, triggeredAt: triggeredAt)
            }
            return refreshExecution.task
        }

        let id = UUID()
        let task = Task { [weak self, id, requestedGeneration, triggeredAt] in
            guard let self else { return }
            await self.runRefreshes(id: id, generation: requestedGeneration, triggeredAt: triggeredAt)
        }
        refreshExecution = RefreshExecution(id: id, generation: requestedGeneration, task: task)
        return task
    }

    private func runRefreshes(
        id: UUID,
        generation refreshGeneration: UInt64,
        triggeredAt firstTriggeredAt: ContinuousClock.Instant
    ) async {
        var triggeredAt = firstTriggeredAt
        while refreshGeneration == generation, !Task.isCancelled {
            await performRefresh(generation: refreshGeneration, triggeredAt: triggeredAt)
            guard let pendingRefresh, pendingRefresh.generation == refreshGeneration else { break }
            self.pendingRefresh = nil
            triggeredAt = pendingRefresh.triggeredAt
        }

        guard refreshExecution?.id == id else { return }
        refreshExecution = nil
        if let pendingRefresh, pendingRefresh.generation == generation {
            self.pendingRefresh = nil
            scheduleRefresh(for: pendingRefresh.generation)
        }
    }

    private func performRefresh(
        generation refreshGeneration: UInt64,
        triggeredAt: ContinuousClock.Instant
    ) async {
        let signpostLog = OSLog(subsystem: "com.factor.limitbar", category: "LocalRefresh")
        os_signpost(.begin, log: signpostLog, name: "LocalRefreshCycle")
        defer { os_signpost(.end, log: signpostLog, name: "LocalRefreshCycle") }
        let refreshDate = now()
        async let usageResult = asyncResult { try await dependencies.refreshUsage(refreshDate, calendar) }
        async let codexResult = asyncResult { try await dependencies.scanCodex(refreshDate) }

        let resolvedUsage = await usageResult
        let resolvedCodex = await codexResult
        let retainedCodexExplanation = await dependencies.loadRetainedCodexExplanation(refreshDate)
        if case let .success(usage) = resolvedUsage {
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            lastUsage = usage
        }
        if case let .success(codex) = resolvedCodex {
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            lastCodex = codex
        }
        guard refreshGeneration == generation, !Task.isCancelled else { return }

        sequence += 1
        guard refreshGeneration == generation, !Task.isCancelled else { return }
        continuation.yield(LocalRefreshSnapshot(
            sequence: sequence,
            usage: lastUsage,
            codex: lastCodex?.snapshot,
            codexExplanation: codexExplanation(
                resolvedCodex: resolvedCodex,
                retained: retainedCodexExplanation
            ),
            codexExplanationRetained: codexExplanationIsRetained(
                resolvedCodex: resolvedCodex,
                retained: retainedCodexExplanation
            ),
            refreshedAt: refreshDate,
            triggeredAt: triggeredAt,
            usageRefreshed: resolvedUsage.isSuccess,
            codexRefreshed: resolvedCodex.isSuccess
        ))
    }

    private func codexExplanation(
        resolvedCodex: Result<CodexSessionScanPublication?, any Error>,
        retained: CodexQuotaExplanationState?
    ) -> CodexQuotaExplanationState {
        if resolvedCodex.isSuccess {
            return lastCodex?.explanation ?? retained ?? .unavailable(.gap)
        }
        return retained ?? .unavailable(.unsupportedEvidence)
    }

    private func codexExplanationIsRetained(
        resolvedCodex: Result<CodexSessionScanPublication?, any Error>,
        retained: CodexQuotaExplanationState?
    ) -> Bool {
        retained != nil && (resolvedCodex.isSuccess ? lastCodex == nil : true)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private func asyncResult<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
) async -> Result<Value, any Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}
