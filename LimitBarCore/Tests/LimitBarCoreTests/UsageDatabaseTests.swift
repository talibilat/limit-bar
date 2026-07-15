import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Usage database")
struct UsageDatabaseTests {
    @Test("opens lazily once and returns only current bounded rows")
    func opensLazilyOnceAndReadsCurrentRows() async throws {
        let counter = LockedCounter()
        let path = temporaryDatabasePath()
        let store = try SQLiteUsageMetricStore(path: path)
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: utcCalendar())
        try store.save([
            metric(model: "current", window: windows.today, refreshedAt: now),
            metric(model: "expired", window: try ExactUsageWindow(timeWindow: .today, start: windows.today.start.addingTimeInterval(-86_400), end: windows.today.end.addingTimeInterval(-86_400), basis: .localCalendar), refreshedAt: now)
        ])
        let database = UsageDatabase(pathFactory: {
            counter.increment()
            return path
        }, localEventsURL: missingEventsURL())

        #expect(counter.value == 0)
        let first = await database.snapshot(now: now, calendar: utcCalendar())
        let second = await database.snapshot(now: now, calendar: utcCalendar())

        #expect(counter.value == 1)
        #expect(first.metrics.map(\.modelLabel) == ["current"])
        #expect(second.metrics == first.metrics)
    }

    @Test("archives bounded metrics and exposes gaps separately from confirmed zero")
    func archivesHistoricalUsage() async throws {
        let currentPath = temporaryDatabasePath()
        let historyPath = temporaryDatabasePath()
        defer {
            try? FileManager.default.removeItem(atPath: currentPath)
            try? FileManager.default.removeItem(atPath: historyPath)
        }
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let database = UsageDatabase(
            pathFactory: { currentPath },
            localEventsURL: missingEventsURL(),
            historicalPathFactory: { historyPath }
        )
        let zero = metric(model: "confirmed-zero", window: windows.today, refreshedAt: now, input: 0, output: 0)

        let history = await database.historicalUsage(metrics: [zero], now: now, calendar: calendar)

        #expect(history.health.isOpen)
        #expect(history.dailyBuckets.last?.value != .gap)
        guard case let .observed(observations) = history.dailyBuckets.last?.value else {
            Issue.record("Expected an observed zero bucket")
            return
        }
        #expect(observations.first?.sample.tokenUsage.totalTokens == 0)
        #expect(history.dailyBuckets.last?.authoritativeTotals.count == 1)
        #expect(history.dailyBuckets.last?.modelAttributions.count == 1)
        #expect(history.dailyBuckets.last?.preferredTokenObservations.count == 1)
        #expect(history.dailyBuckets.last?.preferredTokenObservations.first?.sample.coverage == .providerTotal)
        #expect(history.dailyBuckets.dropLast().allSatisfy { $0.value == HistoricalUsageTrendBucket.Value.gap })
    }

    @Test("history deletion preserves current metrics")
    func deletesOnlyHistoricalUsage() async throws {
        let currentPath = temporaryDatabasePath()
        let historyPath = temporaryDatabasePath()
        defer {
            try? FileManager.default.removeItem(atPath: currentPath)
            try? FileManager.default.removeItem(atPath: historyPath)
        }
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let retained = metric(model: "retained", window: windows.today, refreshedAt: now)
        let currentStore = try SQLiteUsageMetricStore(path: currentPath)
        try currentStore.save([retained])
        let database = UsageDatabase(
            pathFactory: { currentPath },
            localEventsURL: missingEventsURL(),
            historicalPathFactory: { historyPath }
        )
        _ = await database.historicalUsage(metrics: [retained], now: now, calendar: calendar)

        #expect(await database.deleteHistoricalUsage())
        let current = await database.snapshot(now: now, calendar: calendar)
        let history = await database.historicalUsage(metrics: [], now: now, calendar: calendar)

        #expect(current.metrics == [retained])
        #expect(history.dailyBuckets.allSatisfy { $0.value == HistoricalUsageTrendBucket.Value.gap })
    }

    @Test("successful empty local source records observed zero")
    func emptyLocalSourceRecordsZero() async throws {
        let currentPath = temporaryDatabasePath()
        let historyPath = temporaryDatabasePath()
        defer {
            try? FileManager.default.removeItem(atPath: currentPath)
            try? FileManager.default.removeItem(atPath: historyPath)
        }
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let database = UsageDatabase(
            pathFactory: { currentPath },
            localEventsURL: missingEventsURL(),
            historicalPathFactory: { historyPath }
        )
        let local = metric(
            model: "removed",
            window: windows.today,
            refreshedAt: now,
            source: .builtInLocalLog
        )
        _ = await database.historicalUsage(metrics: [local], now: now, calendar: calendar)

        let history = await database.historicalUsage(
            metrics: [],
            now: now.addingTimeInterval(60),
            calendar: calendar,
            observedSources: [.builtInLocalLog]
        )

        #expect(history.dailyBuckets.last?.preferredTotalTokens == 0)
    }

    @Test("retries opening after failure instead of caching a broken connection")
    func retriesOpenAfterFailure() async {
        let attempts = LockedCounter()
        let validPath = temporaryDatabasePath()
        let database = UsageDatabase(pathFactory: {
            if attempts.increment() == 1 { throw TestError.openFailed }
            return validPath
        }, localEventsURL: missingEventsURL())

        let failed = await database.snapshot(now: Date(), calendar: .current)
        let recovered = await database.snapshot(now: Date(), calendar: .current)

        #expect(!failed.health.isOpen)
        #expect(recovered.health.isOpen)
        #expect(attempts.value == 2)
    }

    @Test("clean database recovery archives the database and sidecars before replacement")
    func cleanDatabaseRecoveryArchivesOriginalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("usage-metrics.sqlite").path
        _ = try SQLiteUsageMetricStore(path: path)
        try Data("synthetic wal".utf8).write(to: URL(fileURLWithPath: path + "-wal"))
        try Data("synthetic shm".utf8).write(to: URL(fileURLWithPath: path + "-shm"))
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())

        let archive = try await database.createCleanDatabaseRecovery(
            at: Date(timeIntervalSince1970: 1_783_716_000)
        )

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent("usage-metrics.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent("usage-metrics.sqlite-wal").path))
        #expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent("usage-metrics.sqlite-shm").path))
        let snapshot = await database.snapshot(now: Date(timeIntervalSince1970: 1_783_716_000), calendar: utcCalendar())
        #expect(snapshot.health.isOpen)
        #expect(snapshot.metrics.isEmpty)
    }

    @Test("clean database recovery refuses a database held by another writer")
    func cleanDatabaseRecoveryRefusesLockedDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("usage-metrics.sqlite").path
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let retained = metric(model: "retained", window: try CurrentUsageWindows.resolve(at: now, calendar: utcCalendar()).today, refreshedAt: now)
        do {
            let store = try SQLiteUsageMetricStore(path: path)
            try store.save([retained])
        }
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())
        #expect(await database.snapshot(now: now, calendar: utcCalendar()).metrics == [retained])
        var lockDatabase: OpaquePointer?
        guard sqlite3_open(path, &lockDatabase) == SQLITE_OK else { throw TestError.openFailed }
        defer { sqlite3_close(lockDatabase) }
        guard sqlite3_exec(lockDatabase, "BEGIN EXCLUSIVE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            throw TestError.openFailed
        }
        await #expect(throws: UsageDatabaseRecoveryError.databaseBusy) {
            try await database.createCleanDatabaseRecovery()
        }

        #expect(FileManager.default.fileExists(atPath: path))
        let fallback = await database.snapshot(now: now, calendar: utcCalendar())
        #expect(fallback.metrics == [retained])
        #expect(!fallback.health.isOpen)
    }

    @Test("clean database recovery retains a corrupt database before replacement")
    func cleanDatabaseRecoveryRetainsCorruptDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("usage-metrics.sqlite").path
        let corruptBytes = Data("not a sqlite database".utf8)
        try corruptBytes.write(to: URL(fileURLWithPath: path))
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())

        let archive = try await database.createCleanDatabaseRecovery()

        #expect(try Data(contentsOf: archive.appendingPathComponent("usage-metrics.sqlite")) == corruptBytes)
        #expect((try? SQLiteUsageMetricStore(path: path)) != nil)
    }

    @Test("clean database recovery retains a read-only database before replacement")
    func cleanDatabaseRecoveryRetainsReadOnlyDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("usage-metrics.sqlite").path
        _ = try SQLiteUsageMetricStore(path: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())

        let archive = try await database.createCleanDatabaseRecovery()

        #expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent("usage-metrics.sqlite").path))
        #expect((try? SQLiteUsageMetricStore(path: path)) != nil)
    }

    @Test("provider apply and reads are serialized through the actor")
    func providerApplyAndReadAreSerialized() async throws {
        let path = temporaryDatabasePath()
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())

        let diagnostic = await database.applyOpenAI(.success([metric(model: "codex", window: windows.today, refreshedAt: now)]), windows: windows, now: now)
        let snapshot = await database.snapshot(now: now, calendar: calendar)

        #expect(diagnostic.state == .connected)
        #expect(snapshot.metrics.map(\.modelLabel) == ["codex"])
    }

    @Test("pre-cancelled provider applies do not open storage or replace previous rows")
    func preCancelledProviderAppliesPreserveState() async throws {
        let opens = LockedCounter()
        let path = temporaryDatabasePath()
        let store = try SQLiteUsageMetricStore(path: path)
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: utcCalendar())
        let retained = metric(model: "retained", window: windows.today, refreshedAt: now)
        try store.save([retained])
        let database = UsageDatabase(pathFactory: {
            opens.increment()
            return path
        }, localEventsURL: missingEventsURL())

        let anthropic = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await database.applyAnthropic(.cancelled, windows: windows, now: now)
        }.value
        let openAI = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await database.applyOpenAI(.cancelled, windows: windows, now: now)
        }.value

        #expect(opens.value == 0)
        #expect(anthropic.state == .cancelled)
        #expect(openAI.state == .cancelled)
        let snapshot = await database.snapshot(now: now, calendar: utcCalendar())
        #expect(snapshot.metrics == [retained])
    }

    @Test(arguments: [ProviderKind.anthropic, .openAI])
    func staleProviderGenerationDoesNotPersist(provider: ProviderKind) async throws {
        let now = Date()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: utcCalendar())
        let database = UsageDatabase(pathFactory: temporaryDatabasePath, localEventsURL: missingEventsURL())
        let generation = await database.providerConfigurationGeneration(for: provider)
        await database.advanceProviderConfigurationGeneration(for: provider)

        let diagnostic = switch provider {
        case .anthropic:
            await database.applyAnthropic(.success([metric(model: "stale", window: windows.today, refreshedAt: now)]), windows: windows, expectedGeneration: generation, now: now)
        case .openAI:
            await database.applyOpenAI(.success([metric(model: "stale", window: windows.today, refreshedAt: now)]), windows: windows, expectedGeneration: generation, now: now)
        default:
            ProviderDiagnostic(provider: provider, state: .cancelled, failureReason: nil, updatedAt: now)
        }

        #expect(diagnostic.state == .cancelled)
        #expect(await database.snapshot(now: now, calendar: utcCalendar()).metrics.isEmpty)
        let isCurrent = await database.isProviderConfigurationGenerationCurrent(generation, for: provider)
        #expect(!isCurrent)
    }

    @MainActor
    @Test("provider configuration mutation advances generation before updating settings")
    func configurationMutationOrder() async {
        let database = UsageDatabase(pathFactory: temporaryDatabasePath, localEventsURL: missingEventsURL())
        var observedGeneration: UInt64?

        await database.mutateProviderConfiguration(for: .openAI) {
            observedGeneration = await database.providerConfigurationGeneration(for: .openAI)
        }

        #expect(observedGeneration == 1)
    }

    @Test("cancellation avoids opening and returns the last valid snapshot without unhealthy mutation")
    func cancellationPreservesLastValidSnapshot() async throws {
        let opens = LockedCounter()
        let path = temporaryDatabasePath()
        let store = try SQLiteUsageMetricStore(path: path)
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        try store.save([metric(model: "retained", window: windows.today, refreshedAt: now)])
        let database = UsageDatabase(pathFactory: {
            opens.increment()
            return path
        }, localEventsURL: missingEventsURL())
        let valid = await database.snapshot(now: now, calendar: calendar)

        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await database.snapshot(now: now, calendar: calendar)
        }.value

        #expect(opens.value == 1)
        #expect(cancelled == valid)
    }

    @Test("custom refresh persists by source and failure preserves the prior source snapshot")
    func customRefreshPersistsAndPreservesOnFailure() async throws {
        let path = temporaryDatabasePath()
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try #"{"timestamp":"2026-07-10T10:00:00Z","model":"first","inputTokens":3,"outputTokens":1}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let source = CustomUsageSource(name: "Tool", filePath: fileURL.path)
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())

        let success = await database.refreshCustomSources([source], now: now, calendar: calendar)
        try #"{"timestamp":"2026-07-10T11:00:00Z","model":"renamed","inputTokens":4,"outputTokens":2}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let renamedSource = CustomUsageSource(id: source.id, name: "Renamed Tool", filePath: fileURL.path)
        _ = await database.refreshCustomSources([renamedSource], now: now, calendar: calendar)
        try FileManager.default.removeItem(at: fileURL)
        let failure = await database.refreshCustomSources([renamedSource], now: now, calendar: calendar)
        let snapshot = await database.snapshot(now: now, calendar: calendar)
        let customMetrics = snapshot.metrics.filter { $0.provenance.source == .custom(source.id) }

        #expect(success.first?.failureMessage == nil)
        #expect(failure.first?.failureMessage != nil)
        #expect(customMetrics.allSatisfy { $0.modelLabel == "renamed" && $0.accountLabel == "Renamed Tool" })
    }

    @Test("wholly invalid custom content preserves the prior source snapshot and safe diagnostics")
    func invalidCustomContentPreservesPriorSnapshot() async throws {
        let path = temporaryDatabasePath()
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try #"{"timestamp":"2026-07-10T10:00:00Z","model":"retained","inputTokens":3,"outputTokens":1}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let source = CustomUsageSource(name: "Tool", filePath: fileURL.path)
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())
        _ = await database.refreshCustomSources([source], now: now, calendar: calendar)
        try "private-invalid-content".write(to: fileURL, atomically: true, encoding: .utf8)

        let diagnostics = await database.refreshCustomSources([source], now: now, calendar: calendar)
        let snapshot = await database.snapshot(now: now, calendar: calendar)

        #expect(diagnostics.first?.failureMessage == "Custom usage import failed")
        #expect(diagnostics.first?.rejectedLineCount == 1)
        #expect(String(describing: diagnostics).contains("private-invalid-content") == false)
        #expect(snapshot.metrics.contains { $0.modelLabel == "retained" && $0.provenance.source == .custom(source.id) })
    }

    @Test("custom refresh removes sources that are no longer configured")
    func customRefreshRemovesUnconfiguredSources() async throws {
        let path = temporaryDatabasePath()
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try #"{"timestamp":"2026-07-10T10:00:00Z","model":"custom","inputTokens":1,"outputTokens":1}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let source = CustomUsageSource(name: "Tool", filePath: fileURL.path)
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())
        _ = await database.refreshCustomSources([source], now: now, calendar: utcCalendar())

        _ = await database.refreshCustomSources([], now: now, calendar: utcCalendar())
        let snapshot = await database.snapshot(now: now, calendar: utcCalendar())

        #expect(snapshot.metrics.allSatisfy { $0.provenance.source != .custom(source.id) })
    }

    @Test("custom source removal deletes current and historical aggregates")
    func customRefreshRemovesHistoricalSource() async throws {
        let currentPath = temporaryDatabasePath()
        let historyPath = temporaryDatabasePath()
        defer {
            try? FileManager.default.removeItem(atPath: currentPath)
            try? FileManager.default.removeItem(atPath: historyPath)
        }
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let source = CustomUsageSource(name: "Removed", filePath: "/not-read")
        let custom = customMetric(source: source, window: windows.today, refreshedAt: now)
        let database = UsageDatabase(
            pathFactory: { currentPath },
            localEventsURL: missingEventsURL(),
            historicalPathFactory: { historyPath },
            customUsageLoader: { _, _, _, _ in
                CustomUsageLoadResult(metrics: [custom], diagnostics: [], rejectedLineCount: 0)
            }
        )
        _ = await database.refreshCustomSources([source], now: now, calendar: calendar)
        _ = await database.historicalUsage(metrics: [custom], now: now, calendar: calendar)

        _ = await database.refreshCustomSources([], now: now, calendar: calendar)
        let current = await database.snapshot(now: now, calendar: calendar)
        let history = await database.historicalUsage(metrics: [], now: now, calendar: calendar)

        #expect(current.metrics.allSatisfy { $0.provenance.source != .custom(source.id) })
        #expect(history.dailyBuckets.allSatisfy { bucket in
            guard case let .observed(observations) = bucket.value else { return true }
            return observations.allSatisfy { $0.sample.source != .custom(source.id) }
        })

    }

    @Test("custom source removal stays revoked when current database cleanup is blocked")
    func customRemovalFiltersFallbackDuringCleanupFailure() async throws {
        let currentPath = temporaryDatabasePath()
        let historyPath = temporaryDatabasePath()
        defer {
            try? FileManager.default.removeItem(atPath: currentPath)
            try? FileManager.default.removeItem(atPath: historyPath)
        }
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let source = CustomUsageSource(name: "Removed", filePath: "/not-read")
        let custom = customMetric(source: source, window: windows.today, refreshedAt: now)
        let database = UsageDatabase(
            pathFactory: { currentPath },
            localEventsURL: missingEventsURL(),
            historicalPathFactory: { historyPath },
            busyTimeoutMilliseconds: 1,
            customUsageLoader: { _, _, _, _ in
                CustomUsageLoadResult(metrics: [custom], diagnostics: [], rejectedLineCount: 0)
            }
        )
        _ = await database.refreshCustomSources([source], now: now, calendar: calendar)
        let populated = await database.snapshot(now: now, calendar: calendar)
        _ = await database.historicalUsage(metrics: [custom], now: now, calendar: calendar)
        #expect(populated.metrics.contains { $0.provenance.source == .custom(source.id) })

        var lockDatabase: OpaquePointer?
        #expect(sqlite3_open(currentPath, &lockDatabase) == SQLITE_OK)
        defer { sqlite3_close(lockDatabase) }
        #expect(sqlite3_exec(lockDatabase, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)

        _ = await database.refreshCustomSources([], now: now, calendar: calendar)
        let current = await database.snapshot(now: now, calendar: calendar)
        let history = await database.historicalUsage(metrics: [], now: now, calendar: calendar)

        #expect(current.metrics.allSatisfy { $0.provenance.source != .custom(source.id) })
        #expect(history.dailyBuckets.allSatisfy { bucket in
            guard case let .observed(observations) = bucket.value else { return true }
            return observations.allSatisfy { $0.sample.source != .custom(source.id) }
        })

        #expect(sqlite3_exec(lockDatabase, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
        _ = await database.refreshCustomSources([], now: now, calendar: calendar)
        let reopenedStore = try SQLiteUsageMetricStore(path: currentPath)
        #expect(try reopenedStore.allMetrics().allSatisfy { $0.provenance.source != .custom(source.id) })
    }

    @Test("unchanged custom source reuses its persisted result without reading the file again")
    func unchangedCustomSourceIsNotReloaded() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("{}".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let source = CustomUsageSource(name: "Cached", filePath: fileURL.path)
        let reads = LockedCounter()
        let database = UsageDatabase(
            pathFactory: temporaryDatabasePath,
            localEventsURL: missingEventsURL(),
            customUsageLoader: { _, _, _, _ in
                reads.increment()
                return CustomUsageLoadResult(metrics: [], diagnostics: [], rejectedLineCount: 0)
            }
        )

        _ = await database.refreshCustomSources([source], now: Date(), calendar: utcCalendar())
        _ = await database.refreshCustomSources([source], now: Date(), calendar: utcCalendar())

        #expect(reads.value == 1)
    }

    @Test("custom source results with future timestamps are never reused")
    func futureTimestampCustomSourceIsReloaded() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("{}".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let source = CustomUsageSource(name: "Future", filePath: fileURL.path)
        let reads = LockedCounter()
        let database = UsageDatabase(
            pathFactory: temporaryDatabasePath,
            localEventsURL: missingEventsURL(),
            customUsageLoader: { _, _, _, _ in
                reads.increment()
                return CustomUsageLoadResult(
                    metrics: [],
                    diagnostics: [CustomUsageLoadDiagnostic(lineNumber: 1, reason: .futureTimestamp)],
                    rejectedLineCount: 1,
                    hasFutureTimestampRejection: true
                )
            }
        )

        _ = await database.refreshCustomSources([source], now: Date(), calendar: utcCalendar())
        _ = await database.refreshCustomSources([source], now: Date().addingTimeInterval(10), calendar: utcCalendar())

        #expect(reads.value == 2)
    }

    @Test("future timestamp after the diagnostic sample cap still prevents cache reuse")
    func sampledOutFutureTimestampIsReloaded() async throws {
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let malformed = Array(repeating: "not-json", count: 20)
        let futureDate = ISO8601DateFormatter().string(from: now.addingTimeInterval(301))
        let future = "{\"timestamp\":\"\(futureDate)\",\"model\":\"future\",\"inputTokens\":1,\"outputTokens\":1}"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try (malformed + [future]).joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let source = CustomUsageSource(name: "Future after cap", filePath: fileURL.path)
        let reads = LockedCounter()
        let database = UsageDatabase(
            pathFactory: temporaryDatabasePath,
            localEventsURL: missingEventsURL(),
            customUsageLoader: { fileURL, source, now, calendar in
                reads.increment()
                return try await CustomUsageAggregator.loadMetrics(from: fileURL, source: source, now: now, calendar: calendar)
            }
        )

        let first = await database.refreshCustomSources([source], now: now, calendar: utcCalendar())
        _ = await database.refreshCustomSources([source], now: now.addingTimeInterval(10), calendar: utcCalendar())

        #expect(first.first?.diagnostics.count == 20)
        #expect(first.first?.diagnostics.contains(where: { $0.reason == .futureTimestamp }) == false)
        #expect(reads.value == 2)
    }

    @Test("unchanged built-in local log reuses its import until the local day changes")
    func unchangedBuiltInLogIsCachedUntilDayChange() async throws {
        let path = temporaryDatabasePath()
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let firstEvent = #"{"provider":"openAI","timestamp":"2026-07-10T10:00:00Z","model":"first!","inputTokens":1,"outputTokens":1}"#
        let secondEvent = #"{"provider":"openAI","timestamp":"2026-07-11T10:00:00Z","model":"second","inputTokens":1,"outputTokens":1}"#
        #expect(firstEvent.utf8.count == secondEvent.utf8.count)
        try firstEvent.write(to: fileURL, atomically: true, encoding: .utf8)
        let originalModificationDate = try #require(fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: fileURL)
        let calendar = utcCalendar()
        let firstNow = try date("2026-07-10T12:00:00Z")

        let first = await database.snapshot(now: firstNow, calendar: calendar)
        try secondEvent.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: originalModificationDate], ofItemAtPath: fileURL.path)
        let cached = await database.snapshot(now: firstNow.addingTimeInterval(5), calendar: calendar)
        let nextDay = await database.snapshot(now: try date("2026-07-11T12:00:00Z"), calendar: calendar)

        let firstLocal = first.metrics.filter { $0.provenance.source == .builtInLocalLog }
        let cachedLocal = cached.metrics.filter { $0.provenance.source == .builtInLocalLog }
        let nextDayLocal = nextDay.metrics.filter { $0.provenance.source == .builtInLocalLog }
        #expect(firstLocal.count == 2)
        #expect(Set(firstLocal.map(\.modelLabel)) == ["first!"])
        #expect(cachedLocal.count == 2)
        #expect(Set(cachedLocal.map(\.modelLabel)) == ["first!"])
        #expect(nextDayLocal.count == 2)
        #expect(Set(nextDayLocal.map(\.modelLabel)) == ["second"])
    }

    @Test("built-in attribution persists, deletes independently, and stays deleted across refresh and restart")
    func builtInAttributionDeletionAndRestart() async throws {
        let path = temporaryDatabasePath()
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let event = #"{"schemaVersion":2,"eventID":"00000000-0000-0000-0000-000000000001","provider":"openAI","timestamp":"2026-07-10T10:00:00Z","model":"gpt-5","inputTokens":3,"outputTokens":2,"projectID":"alpha","agentID":"reviewer"}"#
        try event.write(to: fileURL, atomically: true, encoding: .utf8)
        let sourceBytes = try Data(contentsOf: fileURL)
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: fileURL)

        let populated = await database.snapshot(now: now, calendar: utcCalendar())
        #expect(populated.attributionBreakdowns.count == 2)
        let parentMetrics = populated.metrics
        await database.deleteAllAttributionEvidence(now: now)
        let deleted = await database.snapshot(now: now, calendar: utcCalendar())
        #expect(deleted.attributionBreakdowns.isEmpty)
        #expect(deleted.metrics == parentMetrics)
        #expect(try Data(contentsOf: fileURL) == sourceBytes)

        let restarted = UsageDatabase(pathFactory: { path }, localEventsURL: fileURL)
        let afterRestart = await restarted.snapshot(now: now.addingTimeInterval(1), calendar: utcCalendar())
        #expect(afterRestart.attributionBreakdowns.isEmpty)
        #expect(afterRestart.metrics == parentMetrics)

        let changed = event + "\n" + #"{"schemaVersion":2,"eventID":"00000000-0000-0000-0000-000000000002","provider":"openAI","timestamp":"2026-07-10T11:00:00Z","model":"gpt-5","inputTokens":1,"outputTokens":1,"projectID":"beta","agentID":"builder"}"#
        try changed.write(to: fileURL, atomically: true, encoding: .utf8)
        let changedSourceProcess = UsageDatabase(pathFactory: { path }, localEventsURL: fileURL)
        let afterChange = await changedSourceProcess.snapshot(now: now.addingTimeInterval(2), calendar: utcCalendar())
        #expect(afterChange.localImport.validEventCount == 2)
        #expect(afterChange.localImport.malformedEventCount == 0)
        #expect(Set(afterChange.attributionBreakdowns.compactMap(\.project?.id)) == ["alpha", "beta"])
    }

    @Test("custom attribution reaches snapshots and deletion suppression survives restart")
    func customAttributionDeletionAndRestart() async throws {
        let path = temporaryDatabasePath()
        let sourceID = UUID(uuidString: "9598575e-259b-47df-9f34-f161c9015e65")!
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        try #"{"schemaVersion":2,"eventID":"00000000-0000-0000-0000-000000000001","customSourceID":"9598575e-259b-47df-9f34-f161c9015e65","timestamp":"2026-07-10T10:00:00Z","model":"local","inputTokens":3,"outputTokens":2,"projectID":"alpha","agentID":"builder"}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let source = CustomUsageSource(id: sourceID, name: "Tool", filePath: fileURL.path)
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())

        _ = await database.refreshCustomSources([source], now: now, calendar: utcCalendar())
        let populated = await database.snapshot(now: now, calendar: utcCalendar())
        #expect(populated.attributionBreakdowns.count == 2)
        #expect(populated.attributionBreakdowns.allSatisfy { $0.source == .custom(sourceID) })
        await database.deleteAllAttributionEvidence(now: now)
        _ = await database.refreshCustomSources([source], now: now.addingTimeInterval(1), calendar: utcCalendar())
        #expect(await database.snapshot(now: now.addingTimeInterval(1), calendar: utcCalendar()).attributionBreakdowns.isEmpty)

        let restarted = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL())
        _ = await restarted.refreshCustomSources([source], now: now.addingTimeInterval(2), calendar: utcCalendar())
        let afterRestart = await restarted.snapshot(now: now.addingTimeInterval(2), calendar: utcCalendar())
        #expect(afterRestart.attributionBreakdowns.isEmpty)
        #expect(afterRestart.metrics.contains { $0.provenance.source == .custom(sourceID) })
    }

    @Test("built-in local log with a future rejection bypasses the unchanged-file cache")
    func futureRejectedBuiltInLogIsReloaded() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try #"{"provider":"openAI","timestamp":"2026-07-10T10:06:00Z","model":"future","inputTokens":1,"outputTokens":1}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let database = UsageDatabase(pathFactory: temporaryDatabasePath, localEventsURL: fileURL)
        let calendar = utcCalendar()

        let rejected = await database.snapshot(now: try date("2026-07-10T10:00:00Z"), calendar: calendar)
        let accepted = await database.snapshot(now: try date("2026-07-10T10:01:00Z"), calendar: calendar)

        #expect(rejected.localImport.malformedEventCount == 1)
        #expect(accepted.localImport.validEventCount == 1)
        #expect(accepted.metrics.contains { $0.modelLabel == "future" && $0.provenance.source == .builtInLocalLog })
    }

    @Test("an older suspended custom refresh cannot resurrect a removed source")
    func staleCustomRefreshCannotResurrectRemovedSource() async throws {
        let path = temporaryDatabasePath()
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let source = CustomUsageSource(name: "Removed", filePath: "/not-read")
        let gate = SuspendedCustomLoader(result: CustomUsageLoadResult(
            metrics: [customMetric(source: source, window: windows.today, refreshedAt: now)],
            diagnostics: [],
            rejectedLineCount: 0
        ))
        let database = UsageDatabase(
            pathFactory: { path },
            localEventsURL: missingEventsURL(),
            customUsageLoader: { _, _, _, _ in try await gate.load() }
        )

        let olderRefresh = Task {
            await database.refreshCustomSources([source], now: now, calendar: calendar)
        }
        await gate.waitUntilStarted()
        _ = await database.refreshCustomSources([], now: now, calendar: calendar)
        await gate.resume()
        _ = await olderRefresh.value

        let snapshot = await database.snapshot(now: now, calendar: calendar)
        #expect(snapshot.metrics.allSatisfy { $0.provenance.source != .custom(source.id) })
    }

    @Test("exclusive SQLite lock returns last valid unhealthy snapshot and later recovers")
    func exclusiveLockRecovery() async throws {
        let path = temporaryDatabasePath()
        let now = Date(timeIntervalSince1970: 1_783_716_000)
        let calendar = utcCalendar()
        let database = UsageDatabase(pathFactory: { path }, localEventsURL: missingEventsURL(), busyTimeoutMilliseconds: 1)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        _ = await database.applyOpenAI(.success([metric(model: "retained", window: windows.today, refreshedAt: now)]), windows: windows, now: now)
        let valid = await database.snapshot(now: now, calendar: calendar)
        var lockDatabase: OpaquePointer?
        #expect(sqlite3_open(path, &lockDatabase) == SQLITE_OK)
        defer { sqlite3_close(lockDatabase) }
        #expect(sqlite3_exec(lockDatabase, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)

        let locked = await database.snapshot(now: now, calendar: calendar)
        #expect(sqlite3_exec(lockDatabase, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
        let recovered = await database.snapshot(now: now, calendar: calendar)

        #expect(locked.metrics == valid.metrics)
        #expect(!locked.health.isOpen)
        #expect(recovered.health.isOpen)
        #expect(recovered.metrics == valid.metrics)
    }

    private func metric(
        model: String,
        window: ExactUsageWindow,
        refreshedAt: Date,
        input: Int = 1,
        output: Int = 1,
        source: UsageMetricSource = .providerAPI
    ) -> UsageMetric {
        UsageMetric(provider: .openAI, accountLabel: "org", projectLabel: nil, modelLabel: model, deploymentLabel: nil, provenance: .bounded(source: source, window: window), tokenUsage: TokenUsage(inputTokens: input, outputTokens: output), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: refreshedAt, freshness: .fresh)
    }

    private func customMetric(source: CustomUsageSource, window: ExactUsageWindow, refreshedAt: Date) -> UsageMetric {
        UsageMetric(provider: .custom, accountLabel: source.name, projectLabel: nil, modelLabel: "custom", deploymentLabel: nil, provenance: .bounded(source: .custom(source.id), window: window), tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: refreshedAt, freshness: .fresh)
    }

    private func missingEventsURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite").path
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ iso8601: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso8601))
    }
}

private actor SuspendedCustomLoader {
    private let result: CustomUsageLoadResult
    private var continuation: CheckedContinuation<Void, Never>?

    init(result: CustomUsageLoadResult) {
        self.result = result
    }

    func load() async throws -> CustomUsageLoadResult {
        await withCheckedContinuation { continuation = $0 }
        return result
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private enum TestError: Error { case openFailed }

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
