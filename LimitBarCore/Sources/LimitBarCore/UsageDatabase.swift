import CryptoKit
import Foundation
import SQLite3

public typealias CustomUsageLoader = @Sendable (URL, CustomUsageSource, Date, Calendar) async throws -> CustomUsageLoadResult

public actor UsageDatabase {
    public static let shared = UsageDatabase.applicationSupport()

    private let pathFactory: @Sendable () throws -> String
    private let localEventsURLFactory: @Sendable () throws -> URL
    private let historicalPathFactory: @Sendable () throws -> String
    private let busyTimeoutMilliseconds: Int32
    private let customUsageLoader: CustomUsageLoader
    private var store: SQLiteUsageMetricStore?
    private var historicalStore: HistoricalUsageTrendStore?
    private var attributionStore: SQLiteUsageAttributionStore?
    private var resolvedCurrentPath: String?
    private var lastValidSnapshot: StoredUsageMetricsSnapshot?
    private var lastValidHistory: HistoricalUsageSnapshot?
    private var localImportCache: LocalImportCacheEntry?
    private var customRefreshGeneration = UUID()
    private var customSourceCache: [UUID: CustomSourceCacheEntry] = [:]
    private var configuredCustomSourceIDs: Set<UUID>?
    private var providerConfigurationGenerations: [ProviderKind: UInt64] = [:]
    private var observedProviderWindows: [ProviderKind: Set<ExactUsageWindow>] = [:]

    public init(
        pathFactory: @escaping @Sendable () throws -> String,
        localEventsURL: URL,
        historicalPathFactory: (@Sendable () throws -> String)? = nil,
        busyTimeoutMilliseconds: Int32 = 5_000
    ) {
        self.pathFactory = pathFactory
        self.localEventsURLFactory = { localEventsURL }
        self.historicalPathFactory = historicalPathFactory ?? { try historicalDatabasePath(from: pathFactory()) }
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.customUsageLoader = defaultCustomUsageLoader
    }

    init(
        pathFactory: @escaping @Sendable () throws -> String,
        localEventsURL: URL,
        historicalPathFactory: (@Sendable () throws -> String)? = nil,
        busyTimeoutMilliseconds: Int32 = 5_000,
        customUsageLoader: @escaping CustomUsageLoader
    ) {
        self.pathFactory = pathFactory
        self.localEventsURLFactory = { localEventsURL }
        self.historicalPathFactory = historicalPathFactory ?? { try historicalDatabasePath(from: pathFactory()) }
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.customUsageLoader = customUsageLoader
    }

    private init(
        pathFactory: @escaping @Sendable () throws -> String,
        localEventsURLFactory: @escaping @Sendable () throws -> URL,
        historicalPathFactory: @escaping @Sendable () throws -> String,
        busyTimeoutMilliseconds: Int32 = 5_000
    ) {
        self.pathFactory = pathFactory
        self.localEventsURLFactory = localEventsURLFactory
        self.historicalPathFactory = historicalPathFactory
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.customUsageLoader = defaultCustomUsageLoader
    }

    public static func applicationSupport(fileManager: FileManager = .default) -> UsageDatabase {
        let fileManager = SendableFileManager(fileManager)
        return UsageDatabase(
            pathFactory: { try applicationSupportDatabasePath(fileManager: fileManager.value) },
            localEventsURLFactory: { try LocalUsageEventImporter.usageEventsURL(fileManager: fileManager.value) },
            historicalPathFactory: { try applicationSupportHistoricalDatabasePath(fileManager: fileManager.value) }
        )
    }

    public func databaseDirectoryURL() throws -> URL {
        URL(fileURLWithPath: try pathFactory()).deletingLastPathComponent()
    }

    public func createCleanDatabaseRecovery(at date: Date = Date()) throws -> URL {
        let databaseURL = URL(fileURLWithPath: try pathFactory())
        store = nil
        attributionStore = nil

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

            if let revision = try? attributionSourceRevision(for: eventsURL) {
                try? openAttributionStore().replace(
                    importResult.attributionBreakdowns,
                    source: .builtInLocalLog,
                    sourceRevision: revision,
                    now: now
                )
            }
            let persistedAttribution = (try? openAttributionStore().all(now: now)) ?? lastValidSnapshot?.attributionBreakdowns ?? []
            let snapshot = filterConfiguredCustomSources(StoredUsageMetricsSnapshot(
                metrics: try store.currentMetrics(at: now, calendar: calendar),
                health: store.health(),
                localImport: importResult,
                attributionBreakdowns: persistedAttribution
            ))
            lastValidSnapshot = snapshot
            return snapshot
        } catch is CancellationError {
            return cancellationSnapshot()
        } catch {
            return fallbackSnapshot()
        }
    }

    public func historicalUsage(
        metrics: [UsageMetric],
        now: Date = Date(),
        calendar: Calendar = .current,
        pricing: PricingTable = .empty,
        pricingRevision: String = PricingTable.bundledDefaultsVersion,
        observedSources: Set<UsageMetricSource> = []
    ) -> HistoricalUsageSnapshot {
        do {
            let store = try openHistoricalStore()
            var samples = try metrics.compactMap { metric -> HistoricalUsageTrendSample? in
                guard case let .bounded(source, window) = metric.provenance,
                      window.basis == .localCalendar else { return nil }
                let timeZone = window.basis == .utcBilling ? "UTC" : calendar.timeZone.identifier
                let period = try HistoricalUsageTrendPeriod(window: window, timeZoneIdentifier: timeZone)
                let providerCost = metric.cost?.source == .providerReported ? metric.cost : nil
                let calculated: HistoricalUsageCalculatedCost?
                if providerCost == nil,
                   let entry = pricing.price(for: metric, usageDate: window.start),
                   let cost = CostCalculator.cost(for: metric, pricing: pricing, usageDate: window.start) {
                    calculated = try HistoricalUsageCalculatedCost(
                        cost: cost,
                        pricingRevision: pricingRevision,
                        pricingEffectiveAt: entry.effectiveAt
                    )
                } else {
                    calculated = nil
                }
                return try HistoricalUsageTrendSample(
                    provider: metric.provider,
                    source: source,
                    coverage: .model(metric.modelLabel),
                    period: period,
                    tokenUsage: metric.tokenUsage,
                    providerReportedCost: providerCost,
                    calculatedCost: calculated
                )
            }
            samples.append(contentsOf: try providerTotalSamples(from: samples))
            let observedScopes = try historicalObservedScopes(
                sources: observedSources,
                samples: samples,
                now: now,
                calendar: calendar
            )
            try store.record(samples, observedScopes: observedScopes, now: now)
            let snapshot = filterConfiguredCustomSources(try loadHistory(from: store, now: now, calendar: calendar))
            lastValidHistory = snapshot
            return snapshot
        } catch {
            return historicalFallback()
        }
    }

    public func historicalRetention() -> HistoricalUsageRetention {
        (try? openHistoricalStore().retention()) ?? lastValidHistory?.retention ?? .default
    }

    @discardableResult
    public func setHistoricalRetention(_ retention: HistoricalUsageRetention, now: Date = Date()) -> Bool {
        do {
            try openHistoricalStore().setRetention(retention, now: now)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func deleteHistoricalUsage() -> Bool {
        do {
            let store = try openHistoricalStore()
            try store.deleteAll()
            lastValidHistory = HistoricalUsageSnapshot(
                dailyBuckets: [],
                weeklyBuckets: [],
                health: UsageStoreHealth(isOpen: true, message: "Historical usage database opened"),
                retention: try store.retention()
            )
            return true
        } catch {
            return false
        }
    }

    public func applyAnthropic(
        _ result: AnthropicRefreshResult,
        windows: CurrentUsageWindows,
        expectedGeneration: UInt64? = nil,
        now: Date = Date()
    ) -> ProviderDiagnostic {
        guard generationIsCurrent(expectedGeneration, provider: .anthropic) else { return staleDiagnostic(provider: .anthropic, now: now) }
        let diagnostic = apply(provider: .anthropic, now: now) { store in
            try AnthropicRefreshPersistence.apply(result, to: store, windows: windows, now: now)
        }
        rememberObservedProviderWindows(diagnostic, windows: windows)
        return diagnostic
    }

    public func applyAnthropic(
        _ batch: AnthropicRefreshBatch,
        windows: CurrentUsageWindows,
        expectedGeneration: UInt64? = nil,
        now: Date = Date()
    ) -> ProviderDiagnostic {
        guard generationIsCurrent(expectedGeneration, provider: .anthropic) else { return staleDiagnostic(provider: .anthropic, now: now) }
        let diagnostic = apply(provider: .anthropic, now: now) { store in
            try AnthropicRefreshPersistence.apply(batch, to: store, windows: windows, now: now)
        }
        rememberObservedProviderWindows(diagnostic, windows: windows)
        return diagnostic
    }

    public func applyOpenAI(
        _ result: OpenAIRefreshResult,
        windows: CurrentUsageWindows,
        expectedGeneration: UInt64? = nil,
        now: Date = Date()
    ) -> ProviderDiagnostic {
        guard generationIsCurrent(expectedGeneration, provider: .openAI) else { return staleDiagnostic(provider: .openAI, now: now) }
        let diagnostic = apply(provider: .openAI, now: now) { store in
            try OpenAIRefreshPersistence.apply(result, to: store, windows: windows, now: now)
        }
        rememberObservedProviderWindows(diagnostic, windows: windows)
        return diagnostic
    }

    public func applyOpenAI(
        _ batch: OpenAIRefreshBatch,
        windows: CurrentUsageWindows,
        expectedGeneration: UInt64? = nil,
        now: Date = Date()
    ) -> ProviderDiagnostic {
        guard generationIsCurrent(expectedGeneration, provider: .openAI) else { return staleDiagnostic(provider: .openAI, now: now) }
        let diagnostic = apply(provider: .openAI, now: now) { store in
            try OpenAIRefreshPersistence.apply(batch, to: store, windows: windows, now: now)
        }
        rememberObservedProviderWindows(diagnostic, windows: windows)
        return diagnostic
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
        let sourceIDs = Set(sources.map(\.id))
        configuredCustomSourceIDs = sourceIDs
        do {
            let store = try openStore()
            let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
            try openHistoricalStore().deleteCustomSources(excluding: sourceIDs)
            try store.deleteCustomMetrics(excluding: sourceIDs)
            try? openAttributionStore().deleteCustomSources(excluding: sourceIDs, now: now)
            lastValidHistory = nil
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
                    if let revision = try? attributionSourceRevision(for: fileURL) {
                        try? openAttributionStore().replace(
                            result.attributionBreakdowns,
                            source: .custom(source.id),
                            sourceRevision: revision,
                            now: now
                        )
                    }
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
                } catch let CustomUsageLoadError.noValidEvents(loadDiagnostics, rejectedLineCount) {
                    diagnostics.append(CustomUsageRefreshDiagnostic(
                        sourceID: source.id,
                        failureMessage: "Custom usage import failed",
                        rejectedLineCount: rejectedLineCount,
                        diagnostics: loadDiagnostics
                    ))
                } catch {
                    diagnostics.append(CustomUsageRefreshDiagnostic(sourceID: source.id, failureMessage: "Custom usage import failed"))
                }
            }
            return diagnostics
        } catch {
            return sources.map { CustomUsageRefreshDiagnostic(sourceID: $0.id, failureMessage: "Custom usage import failed") }
        }
    }

    private func filterConfiguredCustomSources(_ snapshot: StoredUsageMetricsSnapshot) -> StoredUsageMetricsSnapshot {
        guard let configuredCustomSourceIDs else { return snapshot }
        return StoredUsageMetricsSnapshot(
            metrics: snapshot.metrics.filter { metric in
                guard case let .custom(id) = metric.provenance.source else { return true }
                return configuredCustomSourceIDs.contains(id)
            },
            health: snapshot.health,
            localImport: snapshot.localImport,
            attributionBreakdowns: snapshot.attributionBreakdowns.filter { breakdown in
                guard case let .custom(id) = breakdown.source else { return true }
                return configuredCustomSourceIDs.contains(id)
            }
        )
    }

    public func deleteAllAttributionEvidence(now: Date = Date()) {
        try? openAttributionStore().deleteAll(now: now)
        if let lastValidSnapshot {
            self.lastValidSnapshot = StoredUsageMetricsSnapshot(
                metrics: lastValidSnapshot.metrics,
                health: lastValidSnapshot.health,
                localImport: lastValidSnapshot.localImport,
                attributionBreakdowns: []
            )
        }
    }

    private func filterConfiguredCustomSources(_ snapshot: HistoricalUsageSnapshot) -> HistoricalUsageSnapshot {
        guard let configuredCustomSourceIDs else { return snapshot }
        func filter(_ buckets: [HistoricalUsageTrendBucket]) -> [HistoricalUsageTrendBucket] {
            buckets.map { bucket in
                guard case let .observed(observations) = bucket.value else { return bucket }
                let retained = observations.filter { observation in
                    guard case let .custom(id) = observation.sample.source else { return true }
                    return configuredCustomSourceIDs.contains(id)
                }
                return HistoricalUsageTrendBucket(
                    period: bucket.period,
                    value: retained.isEmpty ? .gap : .observed(retained)
                )
            }
        }
        return HistoricalUsageSnapshot(
            dailyBuckets: filter(snapshot.dailyBuckets),
            weeklyBuckets: filter(snapshot.weeklyBuckets),
            health: snapshot.health,
            retention: snapshot.retention
        )
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

    private func rememberObservedProviderWindows(
        _ diagnostic: ProviderDiagnostic,
        windows: CurrentUsageWindows
    ) {
        guard diagnostic.state == .connected else { return }
        observedProviderWindows[diagnostic.provider] = [windows.today, windows.currentWeek]
    }

    private func historicalObservedScopes(
        sources: Set<UsageMetricSource>,
        samples: [HistoricalUsageTrendSample],
        now: Date,
        calendar: Calendar
    ) throws -> Set<HistoricalUsageObservedScope> {
        var result = Set(samples.map {
            HistoricalUsageObservedScope(provider: $0.provider, source: $0.source, period: $0.period)
        })
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let periods = try [windows.today, windows.currentWeek].map {
            try HistoricalUsageTrendPeriod(window: $0, timeZoneIdentifier: calendar.timeZone.identifier)
        }
        for source in sources {
            let providers: [ProviderKind]
            switch source {
            case .builtInLocalLog:
                providers = LocalUsageEventImporter.supportedProviders.sorted { $0.rawValue < $1.rawValue }
            case .custom:
                providers = [.custom]
            case .providerAPI:
                providers = []
            }
            for provider in providers {
                for period in periods {
                    result.insert(HistoricalUsageObservedScope(provider: provider, source: source, period: period))
                }
            }
        }
        for (provider, providerWindows) in observedProviderWindows {
            for window in providerWindows where window.basis == .localCalendar {
                let period = try HistoricalUsageTrendPeriod(
                    window: window,
                    timeZoneIdentifier: calendar.timeZone.identifier
                )
                result.insert(HistoricalUsageObservedScope(provider: provider, source: .providerAPI, period: period))
            }
        }
        return result
    }

    private func generationIsCurrent(_ expected: UInt64?, provider: ProviderKind) -> Bool {
        expected.map { providerConfigurationGenerations[provider, default: 0] == $0 } ?? true
    }

    private func staleDiagnostic(provider: ProviderKind, now: Date) -> ProviderDiagnostic {
        ProviderDiagnostic(provider: provider, state: .cancelled, failureReason: nil, updatedAt: now)
    }

    private func openStore() throws -> SQLiteUsageMetricStore {
        if let store { return store }
        let opened = try SQLiteUsageMetricStore(path: resolvedDatabasePath(), busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        store = opened
        return opened
    }

    private func openHistoricalStore() throws -> HistoricalUsageTrendStore {
        if let historicalStore { return historicalStore }
        let opened = try HistoricalUsageTrendStore(
            path: historicalPathFactory(),
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        historicalStore = opened
        return opened
    }

    private func openAttributionStore() throws -> SQLiteUsageAttributionStore {
        if let attributionStore { return attributionStore }
        let opened = try SQLiteUsageAttributionStore(
            path: attributionDatabasePath(from: resolvedDatabasePath()),
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        attributionStore = opened
        return opened
    }

    private func resolvedDatabasePath() throws -> String {
        if let resolvedCurrentPath { return resolvedCurrentPath }
        let path = try pathFactory()
        resolvedCurrentPath = path
        return path
    }

    private func loadHistory(
        from store: HistoricalUsageTrendStore,
        now: Date,
        calendar: Calendar
    ) throws -> HistoricalUsageSnapshot {
        let daily = try periodsIncludingStoredTimeZones(
            store: store,
            window: .today,
            count: 30,
            now: now,
            calendar: calendar
        )
        let weekly = try periodsIncludingStoredTimeZones(
            store: store,
            window: .currentWeek,
            count: 12,
            now: now,
            calendar: calendar
        )
        return HistoricalUsageSnapshot(
            dailyBuckets: try store.buckets(for: daily),
            weeklyBuckets: try store.buckets(for: weekly),
            health: UsageStoreHealth(isOpen: true, message: "Historical usage database opened"),
            retention: try store.retention()
        )
    }

    private func periodsIncludingStoredTimeZones(
        store: HistoricalUsageTrendStore,
        window: TimeWindow,
        count: Int,
        now: Date,
        calendar: Calendar
    ) throws -> [HistoricalUsageTrendPeriod] {
        let expected = try historicalPeriods(window: window, count: count, now: now, calendar: calendar)
        guard let first = expected.first, let last = expected.last else { return [] }
        let stored = try store.periods(
            from: first.window.start.addingTimeInterval(-2 * 24 * 60 * 60),
            through: last.window.end.addingTimeInterval(2 * 24 * 60 * 60),
            window: window
        )
        let storedDateKeys = Set(stored.map(historicalCalendarKey))
        return Array(Set(expected.filter { !storedDateKeys.contains(historicalCalendarKey($0)) } + stored)).sorted {
            if $0.window.start != $1.window.start { return $0.window.start < $1.window.start }
            return $0.timeZoneIdentifier < $1.timeZoneIdentifier
        }
    }

    private func providerTotalSamples(
        from samples: [HistoricalUsageTrendSample]
    ) throws -> [HistoricalUsageTrendSample] {
        let apiModels = samples.filter { sample in
            guard sample.source == .providerAPI else { return false }
            if case .model = sample.coverage { return true }
            return false
        }
        let grouped = Dictionary(grouping: apiModels) {
            HistoricalProviderPeriodKey(provider: $0.provider, period: $0.period)
        }
        return try grouped.map { key, values in
            var input = 0
            var output = 0
            for value in values {
                let inputResult = input.addingReportingOverflow(value.tokenUsage.inputTokens)
                let outputResult = output.addingReportingOverflow(value.tokenUsage.outputTokens)
                guard !inputResult.overflow, !outputResult.overflow else {
                    throw HistoricalUsageTrendStoreError.executeFailed("Historical provider total overflow")
                }
                input = inputResult.partialValue
                output = outputResult.partialValue
            }
            return try HistoricalUsageTrendSample(
                provider: key.provider,
                source: .providerAPI,
                coverage: .providerTotal,
                period: key.period,
                tokenUsage: TokenUsage(inputTokens: input, outputTokens: output)
            )
        }
    }

    private func historicalFallback() -> HistoricalUsageSnapshot {
        filterConfiguredCustomSources(HistoricalUsageSnapshot(
            dailyBuckets: lastValidHistory?.dailyBuckets ?? [],
            weeklyBuckets: lastValidHistory?.weeklyBuckets ?? [],
            health: UsageStoreHealth(isOpen: false, message: "Historical usage unavailable"),
            retention: lastValidHistory?.retention ?? .default
        ))
    }

    private func fallbackSnapshot() -> StoredUsageMetricsSnapshot {
        if let lastValidSnapshot {
            return filterConfiguredCustomSources(StoredUsageMetricsSnapshot(
                metrics: lastValidSnapshot.metrics,
                health: UsageStoreHealth(isOpen: false, message: "SQLite store unavailable"),
                localImport: lastValidSnapshot.localImport,
                attributionBreakdowns: lastValidSnapshot.attributionBreakdowns
            ))
        }
        return StoredUsageMetricsSnapshot(
            metrics: [],
            health: UsageStoreHealth(isOpen: false, message: "SQLite store unavailable"),
            localImport: .empty(fileURL: URL(fileURLWithPath: ""))
        )
    }

    private func cancellationSnapshot() -> StoredUsageMetricsSnapshot {
        lastValidSnapshot.map(filterConfiguredCustomSources) ?? fallbackSnapshot()
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

private func attributionSourceRevision(for fileURL: URL) throws -> String {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return "missing" }
    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
          let fileSize = values.fileSize, fileSize <= 100 * 1_024 * 1_024 else {
        throw LocalUsageEventError.unreadableFile
    }
    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
    try LimitBarFileLocations.production(fileManager: fileManager).usageMetricsDatabase.path
}

private func applicationSupportHistoricalDatabasePath(fileManager: FileManager) throws -> String {
    try LimitBarFileLocations.production(fileManager: fileManager).historicalUsageDatabase.path
}

private func historicalDatabasePath(from currentPath: String) throws -> String {
    if currentPath == ":memory:" { return ":memory:" }
    return currentPath + ".history.sqlite"
}

private func attributionDatabasePath(from currentPath: String) throws -> String {
    let currentURL = URL(fileURLWithPath: currentPath)
    let stem = currentURL.deletingPathExtension().lastPathComponent
    return currentURL.deletingLastPathComponent().appendingPathComponent("\(stem)-attribution.sqlite").path
}

private func historicalPeriods(
    window: TimeWindow,
    count: Int,
    now: Date,
    calendar: Calendar
) throws -> [HistoricalUsageTrendPeriod] {
    let current = window.interval(containing: now, calendar: calendar)
    return try (0..<count).reversed().map { offset in
        let component: Calendar.Component = window == .today ? .day : .weekOfYear
        guard let start = calendar.date(byAdding: component, value: -offset, to: current.start),
              let end = calendar.date(byAdding: component, value: 1, to: start) else {
            throw CurrentUsageWindows.ResolutionError.unableToResolveBoundary
        }
        let exact = try ExactUsageWindow(timeWindow: window, start: start, end: end, basis: .localCalendar)
        return try HistoricalUsageTrendPeriod(window: exact, timeZoneIdentifier: calendar.timeZone.identifier)
    }
}

private func historicalCalendarKey(_ period: HistoricalUsageTrendPeriod) -> HistoricalCalendarKey {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: period.timeZoneIdentifier) ?? .gmt
    let components = calendar.dateComponents([.year, .month, .day], from: period.window.start)
    return HistoricalCalendarKey(
        window: period.window.timeWindow,
        year: components.year ?? 0,
        month: components.month ?? 0,
        day: components.day ?? 0
    )
}

private struct HistoricalCalendarKey: Hashable {
    let window: TimeWindow
    let year: Int
    let month: Int
    let day: Int
}

private struct HistoricalProviderPeriodKey: Hashable {
    let provider: ProviderKind
    let period: HistoricalUsageTrendPeriod
}

// Only transfers FileManager into factories invoked under UsageDatabase actor isolation.
private final class SendableFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}
