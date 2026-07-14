import Foundation
import SQLite3

public typealias CustomUsageLoader = @Sendable (URL, CustomUsageSource, Date, Calendar) async throws -> CustomUsageLoadResult

public actor UsageDatabase {
    public static let shared = UsageDatabase.applicationSupport()

    private let pathFactory: @Sendable () throws -> String
    private let localEventsURLFactory: @Sendable () throws -> URL
    private let busyTimeoutMilliseconds: Int32
    private let customUsageLoader: CustomUsageLoader
    private var store: SQLiteUsageMetricStore?
    private var lastValidSnapshot: StoredUsageMetricsSnapshot?
    private var localImportCache: LocalImportCacheEntry?
    private var customRefreshGeneration = UUID()
    private var customSourceCache: [UUID: CustomSourceCacheEntry] = [:]
    private var providerConfigurationGenerations: [ProviderKind: UInt64] = [:]

    public init(
        pathFactory: @escaping @Sendable () throws -> String,
        localEventsURL: URL,
        busyTimeoutMilliseconds: Int32 = 5_000
    ) {
        self.pathFactory = pathFactory
        self.localEventsURLFactory = { localEventsURL }
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.customUsageLoader = defaultCustomUsageLoader
    }

    init(
        pathFactory: @escaping @Sendable () throws -> String,
        localEventsURL: URL,
        busyTimeoutMilliseconds: Int32 = 5_000,
        customUsageLoader: @escaping CustomUsageLoader
    ) {
        self.pathFactory = pathFactory
        self.localEventsURLFactory = { localEventsURL }
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.customUsageLoader = customUsageLoader
    }

    private init(
        pathFactory: @escaping @Sendable () throws -> String,
        localEventsURLFactory: @escaping @Sendable () throws -> URL,
        busyTimeoutMilliseconds: Int32 = 5_000
    ) {
        self.pathFactory = pathFactory
        self.localEventsURLFactory = localEventsURLFactory
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.customUsageLoader = defaultCustomUsageLoader
    }

    public static func applicationSupport(fileManager: FileManager = .default) -> UsageDatabase {
        let fileManager = SendableFileManager(fileManager)
        return UsageDatabase(
            pathFactory: { try applicationSupportDatabasePath(fileManager: fileManager.value) },
            localEventsURLFactory: { try LocalUsageEventImporter.usageEventsURL(fileManager: fileManager.value) }
        )
    }

    public func databaseDirectoryURL() throws -> URL {
        URL(fileURLWithPath: try pathFactory()).deletingLastPathComponent()
    }

    public func createCleanDatabaseRecovery(at date: Date = Date()) throws -> URL {
        let databaseURL = URL(fileURLWithPath: try pathFactory())
        store = nil

        let archive = try archiveDatabaseFiles(at: databaseURL, date: date)
        lastValidSnapshot = nil
        localImportCache = nil
        customSourceCache = [:]
        _ = try openStore()
        return archive
    }

    public func snapshot(now: Date = Date(), calendar: Calendar = .current) -> StoredUsageMetricsSnapshot {
        guard !Task.isCancelled else { return cancellationSnapshot() }

        do {
            let store = try openStore()
            try store.deleteMetrics(olderThan: now.addingTimeInterval(-(90 * 24 * 60 * 60)))
            if try !store.hasInitializedMetrics() {
                try store.markMetricsInitialized()
            }

            let eventsURL = try localEventsURLFactory()
            let importResult: LocalUsageImportResult
            do {
                try Task.checkCancellation()
                let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
                let fingerprint = try? localEventsFingerprint(for: eventsURL, windows: windows)
                if let fingerprint, let cached = localImportCache, cached.fingerprint == fingerprint {
                    importResult = cached.result
                } else {
                    importResult = try LocalUsageEventImporter.importEvents(
                        from: eventsURL,
                        to: store,
                        now: now,
                        calendar: calendar
                    )
                    if let fingerprint, !importResult.hasFutureTimestampRejection {
                        localImportCache = LocalImportCacheEntry(fingerprint: fingerprint, result: importResult)
                    } else {
                        localImportCache = nil
                    }
                }
            } catch is CancellationError {
                return cancellationSnapshot()
            } catch {
                importResult = .failed(fileURL: eventsURL, message: "Local usage import failed")
            }

            let snapshot = StoredUsageMetricsSnapshot(
                metrics: try store.currentMetrics(at: now, calendar: calendar),
                health: store.health(),
                localImport: importResult
            )
            lastValidSnapshot = snapshot
            return snapshot
        } catch is CancellationError {
            return cancellationSnapshot()
        } catch {
            return fallbackSnapshot()
        }
    }

    public func applyAnthropic(
        _ result: AnthropicRefreshResult,
        windows: CurrentUsageWindows,
        expectedGeneration: UInt64? = nil,
        now: Date = Date()
    ) -> ProviderDiagnostic {
        guard generationIsCurrent(expectedGeneration, provider: .anthropic) else { return staleDiagnostic(provider: .anthropic, now: now) }
        return apply(provider: .anthropic, now: now) { store in
            try AnthropicRefreshPersistence.apply(result, to: store, windows: windows, now: now)
        }
    }

    public func applyAnthropic(
        _ batch: AnthropicRefreshBatch,
        windows: CurrentUsageWindows,
        expectedGeneration: UInt64? = nil,
        now: Date = Date()
    ) -> ProviderDiagnostic {
        guard generationIsCurrent(expectedGeneration, provider: .anthropic) else { return staleDiagnostic(provider: .anthropic, now: now) }
        return apply(provider: .anthropic, now: now) { store in
            try AnthropicRefreshPersistence.apply(batch, to: store, windows: windows, now: now)
        }
    }

    public func applyOpenAI(
        _ result: OpenAIRefreshResult,
        windows: CurrentUsageWindows,
        expectedGeneration: UInt64? = nil,
        now: Date = Date()
    ) -> ProviderDiagnostic {
        guard generationIsCurrent(expectedGeneration, provider: .openAI) else { return staleDiagnostic(provider: .openAI, now: now) }
        return apply(provider: .openAI, now: now) { store in
            try OpenAIRefreshPersistence.apply(result, to: store, windows: windows, now: now)
        }
    }

    public func applyOpenAI(
        _ batch: OpenAIRefreshBatch,
        windows: CurrentUsageWindows,
        expectedGeneration: UInt64? = nil,
        now: Date = Date()
    ) -> ProviderDiagnostic {
        guard generationIsCurrent(expectedGeneration, provider: .openAI) else { return staleDiagnostic(provider: .openAI, now: now) }
        return apply(provider: .openAI, now: now) { store in
            try OpenAIRefreshPersistence.apply(batch, to: store, windows: windows, now: now)
        }
    }

    public func providerConfigurationGeneration(for provider: ProviderKind) -> UInt64 {
        providerConfigurationGenerations[provider, default: 0]
    }

    public func advanceProviderConfigurationGeneration(for provider: ProviderKind) {
        providerConfigurationGenerations[provider, default: 0] &+= 1
    }

    public func mutateProviderConfiguration(
        for provider: ProviderKind,
        mutation: @MainActor @Sendable () async -> Void
    ) async {
        providerConfigurationGenerations[provider, default: 0] &+= 1
        await mutation()
    }

    public func isProviderConfigurationGenerationCurrent(_ generation: UInt64, for provider: ProviderKind) -> Bool {
        providerConfigurationGenerations[provider, default: 0] == generation
    }

    public func refreshCustomSources(
        _ sources: [CustomUsageSource],
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> [CustomUsageRefreshDiagnostic] {
        guard !Task.isCancelled else {
            return []
        }
        let generation = UUID()
        customRefreshGeneration = generation
        do {
            let store = try openStore()
            let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
            let sourceIDs = Set(sources.map(\.id))
            try store.deleteCustomMetrics(excluding: sourceIDs)
            customSourceCache = customSourceCache.filter { sourceIDs.contains($0.key) }
            var diagnostics: [CustomUsageRefreshDiagnostic] = []
            for source in sources {
                guard !Task.isCancelled else { return diagnostics }
                do {
                    let fileURL = URL(fileURLWithPath: source.filePath)
                    let fingerprint = try? customSourceFingerprint(for: fileURL, source: source, windows: windows)
                    if let fingerprint, let cached = customSourceCache[source.id], cached.fingerprint == fingerprint {
                        diagnostics.append(cached.diagnostic)
                        continue
                    }
                    let result = try await customUsageLoader(fileURL, source, now, calendar)
                    guard customRefreshGeneration == generation else { return diagnostics }
                    try store.replaceMetrics(
                        in: UsageReplacementScope(provider: .custom, source: .custom(source.id), windows: [windows.today, windows.currentWeek]),
                        with: result.metrics
                    )
                    let diagnostic = CustomUsageRefreshDiagnostic(
                        sourceID: source.id,
                        failureMessage: nil,
                        rejectedLineCount: result.rejectedLineCount,
                        diagnostics: result.diagnostics
                    )
                    diagnostics.append(diagnostic)
                    if let fingerprint, !result.hasFutureTimestampRejection {
                        customSourceCache[source.id] = CustomSourceCacheEntry(fingerprint: fingerprint, diagnostic: diagnostic)
                    }
                } catch CustomUsageLoadError.cancelled {
                    return diagnostics
                } catch {
                    diagnostics.append(CustomUsageRefreshDiagnostic(sourceID: source.id, failureMessage: "Custom usage import failed"))
                }
            }
            return diagnostics
        } catch {
            return sources.map { CustomUsageRefreshDiagnostic(sourceID: $0.id, failureMessage: "Custom usage import failed") }
        }
    }

    private func apply(
        provider: ProviderKind,
        now: Date,
        operation: (SQLiteUsageMetricStore) throws -> ProviderDiagnostic
    ) -> ProviderDiagnostic {
        guard !Task.isCancelled else {
            return ProviderDiagnostic(provider: provider, state: .cancelled, failureReason: nil, updatedAt: now)
        }
        do {
            return try operation(openStore())
        } catch {
            return ProviderDiagnostic(provider: provider, state: .failed, failureReason: .refreshFailed, updatedAt: now)
        }
    }

    private func generationIsCurrent(_ expected: UInt64?, provider: ProviderKind) -> Bool {
        expected.map { providerConfigurationGenerations[provider, default: 0] == $0 } ?? true
    }

    private func staleDiagnostic(provider: ProviderKind, now: Date) -> ProviderDiagnostic {
        ProviderDiagnostic(provider: provider, state: .cancelled, failureReason: nil, updatedAt: now)
    }

    private func openStore() throws -> SQLiteUsageMetricStore {
        if let store { return store }
        let opened = try SQLiteUsageMetricStore(path: pathFactory(), busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        store = opened
        return opened
    }

    private func fallbackSnapshot() -> StoredUsageMetricsSnapshot {
        if let lastValidSnapshot {
            return StoredUsageMetricsSnapshot(
                metrics: lastValidSnapshot.metrics,
                health: UsageStoreHealth(isOpen: false, message: "SQLite store unavailable"),
                localImport: lastValidSnapshot.localImport
            )
        }
        return StoredUsageMetricsSnapshot(
            metrics: [],
            health: UsageStoreHealth(isOpen: false, message: "SQLite store unavailable"),
            localImport: .empty(fileURL: URL(fileURLWithPath: ""))
        )
    }

    private func cancellationSnapshot() -> StoredUsageMetricsSnapshot {
        lastValidSnapshot ?? fallbackSnapshot()
    }

    private func archiveDatabaseFiles(at databaseURL: URL, date: Date) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw UsageDatabaseRecoveryError.databaseMissing
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate]
        let archiveURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(
                "usage-metrics-\(formatter.string(from: date).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: archiveURL, withIntermediateDirectories: true)

        var lockDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &lockDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        var holdsExclusiveLock = false
        if openResult == SQLITE_OK {
            sqlite3_busy_timeout(lockDatabase, 1_000)
            let lockResult = sqlite3_exec(lockDatabase, "BEGIN EXCLUSIVE TRANSACTION;", nil, nil, nil)
            if lockResult == SQLITE_OK {
                holdsExclusiveLock = true
            } else if lockResult == SQLITE_BUSY || lockResult == SQLITE_LOCKED {
                sqlite3_close(lockDatabase)
                try? fileManager.removeItem(at: archiveURL)
                throw UsageDatabaseRecoveryError.databaseBusy
            } else if fileManager.isWritableFile(atPath: databaseURL.path),
                      ![SQLITE_NOTADB, SQLITE_CORRUPT].contains(sqlite3_extended_errcode(lockDatabase)) {
                sqlite3_close(lockDatabase)
                try? fileManager.removeItem(at: archiveURL)
                throw UsageDatabaseRecoveryError.databaseBusy
            }
        } else if fileManager.isWritableFile(atPath: databaseURL.path) {
            sqlite3_close(lockDatabase)
            try? fileManager.removeItem(at: archiveURL)
            throw UsageDatabaseRecoveryError.databaseBusy
        }
        defer {
            if holdsExclusiveLock {
                sqlite3_exec(lockDatabase, "ROLLBACK;", nil, nil, nil)
            }
            sqlite3_close(lockDatabase)
        }

        // Inventory sidecars only after excluding writers so a newly committed WAL cannot be omitted.
        let sourceURLs = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ].filter { fileManager.fileExists(atPath: $0.path) }
        do {
            for source in sourceURLs {
                let destination = archiveURL.appendingPathComponent(source.lastPathComponent)
                try fileManager.copyItem(at: source, to: destination)
            }
            for source in sourceURLs {
                try fileManager.removeItem(at: source)
            }
        } catch {
            throw error
        }
        return archiveURL
    }
}

public enum UsageDatabaseRecoveryError: Error, Equatable {
    case databaseMissing
    case databaseBusy
}

private struct LocalEventsFingerprint: Equatable {
    let fileURL: URL
    let modificationDate: Date?
    let fileSize: Int?
    let todayStart: Date
    let weekStart: Date
}

private struct LocalImportCacheEntry {
    let fingerprint: LocalEventsFingerprint
    let result: LocalUsageImportResult
}

private func localEventsFingerprint(for fileURL: URL, windows: CurrentUsageWindows) throws -> LocalEventsFingerprint {
    let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return LocalEventsFingerprint(
        fileURL: fileURL.standardizedFileURL,
        modificationDate: values.contentModificationDate,
        fileSize: values.fileSize,
        todayStart: windows.today.start,
        weekStart: windows.currentWeek.start
    )
}

private struct CustomSourceFingerprint: Equatable {
    let source: CustomUsageSource
    let modificationDate: Date?
    let fileSize: Int?
    let todayStart: Date
    let weekStart: Date
}

private struct CustomSourceCacheEntry {
    let fingerprint: CustomSourceFingerprint
    let diagnostic: CustomUsageRefreshDiagnostic
}

private func customSourceFingerprint(
    for fileURL: URL,
    source: CustomUsageSource,
    windows: CurrentUsageWindows
) throws -> CustomSourceFingerprint {
    let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return CustomSourceFingerprint(
        source: source,
        modificationDate: values.contentModificationDate,
        fileSize: values.fileSize,
        todayStart: windows.today.start,
        weekStart: windows.currentWeek.start
    )
}

private let defaultCustomUsageLoader: CustomUsageLoader = { fileURL, source, now, calendar in
    try await CustomUsageAggregator.loadMetrics(
        from: fileURL,
        source: source,
        now: now,
        calendar: calendar
    )
}

public struct CustomUsageRefreshDiagnostic: Equatable, Sendable {
    public let sourceID: UUID
    public let failureMessage: String?
    public let rejectedLineCount: Int
    public let diagnostics: [CustomUsageLoadDiagnostic]

    public init(
        sourceID: UUID,
        failureMessage: String?,
        rejectedLineCount: Int = 0,
        diagnostics: [CustomUsageLoadDiagnostic] = []
    ) {
        self.sourceID = sourceID
        self.failureMessage = failureMessage
        self.rejectedLineCount = rejectedLineCount
        self.diagnostics = diagnostics
    }
}

private func applicationSupportDatabasePath(fileManager: FileManager) throws -> String {
    let applicationSupport = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let directory = applicationSupport.appendingPathComponent("LimitBar", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("usage-metrics.sqlite").path
}

// Only transfers FileManager into factories invoked under UsageDatabase actor isolation.
private final class SendableFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}
