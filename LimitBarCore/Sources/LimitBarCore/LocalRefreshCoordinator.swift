import Foundation
import Observation

public struct LocalUsageRefresh: Equatable, Sendable {
    public let snapshot: StoredUsageMetricsSnapshot
    public let customDiagnostics: [CustomUsageRefreshDiagnostic]

    public init(snapshot: StoredUsageMetricsSnapshot, customDiagnostics: [CustomUsageRefreshDiagnostic]) {
        self.snapshot = snapshot
        self.customDiagnostics = customDiagnostics
    }
}

public struct LocalRefreshDependencies: Sendable {
    public let refreshUsage: @Sendable (Date, Calendar) async throws -> LocalUsageRefresh
    public let scanCodex: @Sendable (Date) async throws -> CodexRateLimitSnapshot?

    public init(
        refreshUsage: @escaping @Sendable (Date, Calendar) async throws -> LocalUsageRefresh,
        scanCodex: @escaping @Sendable (Date) async throws -> CodexRateLimitSnapshot?
    ) {
        self.refreshUsage = refreshUsage
        self.scanCodex = scanCodex
    }
}

public protocol LocalUsageRefreshing: Sendable {
    func refresh(now: Date, calendar: Calendar) async throws -> LocalUsageRefresh
}

public protocol LocalCodexScanning: Sendable {
    func scan(now: Date) async throws -> CodexRateLimitSnapshot?
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
}

public struct CodexSessionScanner: LocalCodexScanning {
    private let sessionsDirectory: URL

    public init(sessionsDirectory: URL) {
        self.sessionsDirectory = sessionsDirectory
    }

    public func scan(now: Date) throws -> CodexRateLimitSnapshot? {
        do {
            return try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: sessionsDirectory, now: now)
        } catch CodexRateLimitFailure.notFound {
            return nil
        }
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
    public let refreshedAt: Date
    public let usageRefreshed: Bool
    public let codexRefreshed: Bool

    public init(
        sequence: UInt64,
        usage: LocalUsageRefresh?,
        codex: CodexRateLimitSnapshot?,
        refreshedAt: Date,
        usageRefreshed: Bool = true,
        codexRefreshed: Bool = true
    ) {
        self.sequence = sequence
        self.usage = usage
        self.codex = codex
        self.refreshedAt = refreshedAt
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

    public init() {}

    public func apply(_ refresh: LocalRefreshSnapshot) {
        if let usage = refresh.usage {
            metrics = usage.snapshot.metrics
            storeHealth = usage.snapshot.health
            localImport = usage.snapshot.localImport
            customImportFailures = usage.customDiagnostics.filter { $0.failureMessage != nil }.count
            customRejectedLines = usage.customDiagnostics.reduce(0) { $0 + $1.rejectedLineCount }
            status = AppStatus.from(menuBarStatus: MenuBarStatus.from(metrics: metrics))
        }
        codexSnapshot = refresh.codex
    }
}

public actor LocalRefreshCoordinator {
    private struct RefreshExecution {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }

    public nonisolated let snapshots: AsyncStream<LocalRefreshSnapshot>

    private let dependencies: LocalRefreshDependencies
    private let clock: LocalRefreshClock
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let continuation: AsyncStream<LocalRefreshSnapshot>.Continuation
    private var periodicTask: Task<Void, Never>?
    private var refreshExecution: RefreshExecution?
    private var pendingGeneration: UInt64?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var lastUsage: LocalUsageRefresh?
    private var lastCodex: CodexRateLimitSnapshot?

    public init(
        dependencies: LocalRefreshDependencies,
        clock: LocalRefreshClock = .continuous,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.dependencies = dependencies
        self.clock = clock
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
        let startGeneration = generation
        let clock = clock
        periodicTask = Task { [weak self, startGeneration, clock] in
            await self?.scheduleRefresh(for: startGeneration)
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: 5)
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
        pendingGeneration = nil
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
        if let refreshExecution {
            pendingGeneration = requestedGeneration
            return refreshExecution.task
        }

        let id = UUID()
        let task = Task { [weak self, id, requestedGeneration] in
            guard let self else { return }
            await self.runRefreshes(id: id, generation: requestedGeneration)
        }
        refreshExecution = RefreshExecution(id: id, generation: requestedGeneration, task: task)
        return task
    }

    private func runRefreshes(id: UUID, generation refreshGeneration: UInt64) async {
        repeat {
            if pendingGeneration == refreshGeneration {
                pendingGeneration = nil
            }
            await performRefresh(generation: refreshGeneration)
        } while pendingGeneration == refreshGeneration
            && refreshGeneration == generation
            && !Task.isCancelled

        guard refreshExecution?.id == id else { return }
        refreshExecution = nil
        if pendingGeneration == generation {
            let pending = generation
            pendingGeneration = nil
            scheduleRefresh(for: pending)
        }
    }

    private func performRefresh(generation refreshGeneration: UInt64) async {
        let refreshDate = now()
        async let usageResult = asyncResult { try await dependencies.refreshUsage(refreshDate, calendar) }
        async let codexResult = asyncResult { try await dependencies.scanCodex(refreshDate) }

        let resolvedUsage = await usageResult
        let resolvedCodex = await codexResult
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
            codex: lastCodex,
            refreshedAt: refreshDate,
            usageRefreshed: resolvedUsage.isSuccess,
            codexRefreshed: resolvedCodex.isSuccess
        ))
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
