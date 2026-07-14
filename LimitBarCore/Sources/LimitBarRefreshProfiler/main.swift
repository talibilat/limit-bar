import Darwin
import Foundation
import LimitBarCore
import os

@main
struct LimitBarRefreshProfiler {
    static func main() async throws {
        let configuration = try RefreshProfileConfiguration.parse(arguments: Array(CommandLine.arguments.dropFirst()))
        let fixture = try RefreshProfileFixture(configuration: configuration)
        defer { fixture.remove() }

        let result = try await measure(configuration: configuration, fixture: fixture)
        let output = RefreshProfileOutput(
            formatVersion: 1,
            scenarioVersion: 1,
            configuration: configuration,
            environment: profileEnvironment(),
            statistics: try RefreshProfileStatistics(milliseconds: result.durations),
            resources: result.resources,
            aggregateResultCount: result.aggregateResultCount,
            cadenceOverrunCount: result.cadenceOverrunCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    }

    private static func measure(
        configuration: RefreshProfileConfiguration,
        fixture: RefreshProfileFixture
    ) async throws -> MeasurementResult {
        let operation = try await fixture.operation(for: configuration.scenario)
        for _ in 0..<configuration.warmupIterations {
            _ = try await operation()
        }
        if configuration.cadenceSeconds > 0 {
            return try await fixture.measureScheduledCycles(configuration: configuration)
        }

        let signpostLog = OSLog(subsystem: "com.factor.limitbar", category: "LocalRefreshProfile")
        var durations: [Double] = []
        var aggregateResultCount = 0
        let cadenceOverrunCount = 0
        var resourceAccumulator = ProcessResourceAccumulator()
        for _ in 0..<configuration.iterations {
            try fixture.mutateIfNeeded(for: configuration.scenario)
            let resourcesBefore = try ProcessResourceSnapshot.current()
            let start = ContinuousClock.now
            os_signpost(.begin, log: signpostLog, name: "ProfiledOperation")
            do {
                aggregateResultCount += try await operation()
                os_signpost(.end, log: signpostLog, name: "ProfiledOperation")
            } catch {
                os_signpost(.end, log: signpostLog, name: "ProfiledOperation")
                throw error
            }
            let duration = start.duration(to: .now)
            durations.append(milliseconds(duration))
            let resourcesAfter = try ProcessResourceSnapshot.current()
            resourceAccumulator.add(resourcesBefore.delta(to: resourcesAfter))

        }
        return MeasurementResult(
            durations: durations,
            aggregateResultCount: aggregateResultCount,
            cadenceOverrunCount: cadenceOverrunCount,
            resources: resourceAccumulator.resources
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func profileEnvironment() -> RefreshProfileEnvironment {
        let processInfo = ProcessInfo.processInfo
        return RefreshProfileEnvironment(
            operatingSystemVersion: processInfo.operatingSystemVersionString,
            architecture: architecture,
            processorCount: processInfo.processorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            powerState: RefreshProfilePowerState(
                rawValue: ProcessInfo.processInfo.environment["LIMITBAR_PROFILE_POWER_STATE"] ?? ""
            ) ?? .unknown
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private struct MeasurementResult {
    let durations: [Double]
    let aggregateResultCount: Int
    let cadenceOverrunCount: Int
    let resources: RefreshProfileResources
}

private final class RefreshProfileFixture {
    typealias Operation = () async throws -> Int

    private let configuration: RefreshProfileConfiguration
    private let root: URL
    private let builtInEvents: URL
    private var customEvents: [URL] = []
    private var customSources: [CustomUsageSource] = []
    private let sessionsDirectory: URL
    private let database: UsageDatabase
    private var sqliteStore: SQLiteUsageMetricStore?
    private let now: Date
    private let calendar: Calendar
    private let builtInLine: Data
    private let customLine: Data
    private let codexLine: Data

    init(configuration: RefreshProfileConfiguration) throws {
        self.configuration = configuration
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        builtInEvents = root.appendingPathComponent("built-in.jsonl")
        sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        now = Date()
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = utcCalendar

        let eventTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        builtInLine = Data(("{\"provider\":\"openAI\",\"timestamp\":\"" + eventTimestamp + "\",\"model\":\"synthetic-model\",\"inputTokens\":100,\"outputTokens\":20}\n").utf8)
        customLine = Data(("{\"timestamp\":\"" + eventTimestamp + "\",\"model\":\"synthetic-model\",\"inputTokens\":50,\"outputTokens\":10}\n").utf8)
        codexLine = Data(("{\"timestamp\":\"" + eventTimestamp + "\",\"payload\":{\"rate_limits\":{\"plan_type\":\"synthetic\",\"primary\":{\"used_percent\":20,\"window_minutes\":300}}}}\n").utf8)

        database = UsageDatabase(
            pathFactory: { [root] in root.appendingPathComponent("usage.sqlite").path },
            localEventsURL: builtInEvents
        )
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
            try Self.writeFixture(to: builtInEvents, line: builtInLine, targetBytes: configuration.fixtureBytes)

            for index in 0..<configuration.customSourceCount {
                let eventURL = root.appendingPathComponent("custom-\(index).jsonl")
                try Self.writeFixture(to: eventURL, line: customLine, targetBytes: configuration.fixtureBytes)
                customEvents.append(eventURL)
                customSources.append(CustomUsageSource(
                    id: UUID(),
                    name: "Synthetic source \(index)",
                    filePath: eventURL.path
                ))
            }

            for index in 0..<configuration.codexFileCount {
                let session = sessionsDirectory.appendingPathComponent("session-\(index).jsonl")
                try Self.writeFixture(to: session, line: codexLine, targetBytes: codexLine.count)
            }
            let store = try SQLiteUsageMetricStore(path: root.appendingPathComponent("standalone.sqlite").path)
            let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
            try store.save([Self.sqliteMetric(now: now, window: windows.today)])
            sqliteStore = store
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func operation(for scenario: RefreshProfileScenario) async throws -> Operation {
        switch scenario {
        case .cycleFingerprintStable, .cycleEventAppend:
            let usage = ProfileLocalUsageRefresher(database: database, sources: customSources)
            let scanner = CodexSessionScanner(sessionsDirectory: sessionsDirectory)
            let coordinator = LocalRefreshCoordinator(dependencies: .live(usage: usage, codex: scanner))
            let receiver = ProfileSnapshotReceiver(stream: coordinator.snapshots)
            return {
                await coordinator.requestRefresh()
                let snapshot = await receiver.next()
                return (snapshot?.usage?.snapshot.metrics.count ?? 0) + (snapshot?.codex == nil ? 0 : 1)
            }
        case .builtInFingerprintStable, .builtInEventAppend:
            _ = await database.snapshot(now: now, calendar: calendar)
            return { [database, now, calendar] in
                await database.snapshot(now: now, calendar: calendar).metrics.count
            }
        case .customFingerprintStable, .customEventAppend:
            _ = await database.refreshCustomSources(customSources, now: now, calendar: calendar)
            return { [database, customSources, now, calendar] in
                await database.refreshCustomSources(customSources, now: now, calendar: calendar).count
            }
        case .codexSessionScan:
            let scanner = CodexSessionScanner(sessionsDirectory: sessionsDirectory)
            return { [now] in
                let snapshot = try scanner.scan(now: now)
                return snapshot?.primary == nil ? 0 : 1
            }
        case .sqliteCurrentMetricsRead:
            guard let sqliteStore else { throw RefreshProfileFailure.missingStore }
            return { [now, calendar] in
                try sqliteStore.currentMetrics(at: now, calendar: calendar).count
            }
        }
    }

    func measureScheduledCycles(configuration: RefreshProfileConfiguration) async throws -> MeasurementResult {
        let usage = ProfileLocalUsageRefresher(database: database, sources: customSources)
        let scanner = CodexSessionScanner(sessionsDirectory: sessionsDirectory)
        let coordinator = LocalRefreshCoordinator(
            dependencies: .live(usage: usage, codex: scanner),
            refreshInterval: configuration.cadenceSeconds
        )
        var iterator = coordinator.snapshots.makeAsyncIterator()
        let signpostLog = OSLog(subsystem: "com.factor.limitbar", category: "LocalRefreshProfile")
        let resourcesBefore = try ProcessResourceSnapshot.current()
        os_signpost(.begin, log: signpostLog, name: "SustainedLocalRefresh")
        await coordinator.start()
        var durations: [Double] = []
        var aggregateResultCount = 0
        for _ in 0..<configuration.iterations {
            guard let snapshot = await iterator.next() else {
                await coordinator.stop()
                throw RefreshProfileFailure.snapshotStreamEnded
            }
            let publicationMilliseconds = Self.milliseconds(snapshot.triggeredAt.duration(to: .now))
            durations.append(publicationMilliseconds)
            aggregateResultCount += (snapshot.usage?.snapshot.metrics.count ?? 0) + (snapshot.codex == nil ? 0 : 1)
        }
        await coordinator.stop()
        os_signpost(.end, log: signpostLog, name: "SustainedLocalRefresh")
        let resourcesAfter = try ProcessResourceSnapshot.current()
        let intervalMilliseconds = configuration.cadenceSeconds * 1_000
        return MeasurementResult(
            durations: durations,
            aggregateResultCount: aggregateResultCount,
            cadenceOverrunCount: durations.filter { $0 >= intervalMilliseconds }.count,
            resources: resourcesBefore.delta(to: resourcesAfter)
        )
    }

    func mutateIfNeeded(for scenario: RefreshProfileScenario) throws {
        switch scenario {
        case .cycleEventAppend:
            try Self.append(builtInLine, to: builtInEvents)
            for eventURL in customEvents {
                try Self.append(customLine, to: eventURL)
            }
            if configuration.codexFileCount > 0 {
                try Self.append(codexLine, to: sessionsDirectory.appendingPathComponent("session-0.jsonl"))
            }
        case .builtInEventAppend:
            try Self.append(builtInLine, to: builtInEvents)
        case .customEventAppend:
            for eventURL in customEvents {
                try Self.append(customLine, to: eventURL)
            }
        case .cycleFingerprintStable, .builtInFingerprintStable, .customFingerprintStable,
             .sqliteCurrentMetricsRead, .codexSessionScan:
            break
        }
    }

    private static func writeFixture(to url: URL, line: Data, targetBytes: Int) throws {
        guard targetBytes > 0 else {
            try Data().write(to: url)
            return
        }
        let repetitions = max(1, targetBytes / line.count)
        var data = Data(capacity: repetitions * line.count)
        for _ in 0..<repetitions {
            data.append(line)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func sqliteMetric(now: Date, window: ExactUsageWindow) -> UsageMetric {
        UsageMetric(
            provider: .openAI,
            accountLabel: "Synthetic local log",
            projectLabel: nil,
            modelLabel: "synthetic-model",
            deploymentLabel: nil,
            provenance: .bounded(source: .builtInLocalLog, window: window),
            tokenUsage: TokenUsage(inputTokens: 100, outputTokens: 20),
            cost: nil,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: now,
            freshness: .fresh
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private enum RefreshProfileFailure: Error {
    case missingStore
    case snapshotStreamEnded
    case resourceUsageUnavailable
}

private struct ProcessResourceSnapshot {
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let maximumResidentSetBytes: UInt64
    let blockInputOperations: Int64
    let blockOutputOperations: Int64
    let voluntaryContextSwitches: Int64
    let involuntaryContextSwitches: Int64

    static func current() throws -> ProcessResourceSnapshot {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw RefreshProfileFailure.resourceUsageUnavailable
        }
        return ProcessResourceSnapshot(
            userCPUSeconds: seconds(usage.ru_utime),
            systemCPUSeconds: seconds(usage.ru_stime),
            maximumResidentSetBytes: UInt64(max(0, usage.ru_maxrss)),
            blockInputOperations: Int64(usage.ru_inblock),
            blockOutputOperations: Int64(usage.ru_oublock),
            voluntaryContextSwitches: Int64(usage.ru_nvcsw),
            involuntaryContextSwitches: Int64(usage.ru_nivcsw)
        )
    }

    func delta(to later: ProcessResourceSnapshot) -> RefreshProfileResources {
        RefreshProfileResources(
            userCPUSeconds: max(0, later.userCPUSeconds - userCPUSeconds),
            systemCPUSeconds: max(0, later.systemCPUSeconds - systemCPUSeconds),
            maximumResidentSetBytes: later.maximumResidentSetBytes,
            blockInputOperations: max(0, later.blockInputOperations - blockInputOperations),
            blockOutputOperations: max(0, later.blockOutputOperations - blockOutputOperations),
            voluntaryContextSwitches: max(0, later.voluntaryContextSwitches - voluntaryContextSwitches),
            involuntaryContextSwitches: max(0, later.involuntaryContextSwitches - involuntaryContextSwitches)
        )
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}

private struct ProcessResourceAccumulator {
    private var userCPUSeconds = 0.0
    private var systemCPUSeconds = 0.0
    private var maximumResidentSetBytes: UInt64 = 0
    private var blockInputOperations: Int64 = 0
    private var blockOutputOperations: Int64 = 0
    private var voluntaryContextSwitches: Int64 = 0
    private var involuntaryContextSwitches: Int64 = 0

    mutating func add(_ sample: RefreshProfileResources) {
        userCPUSeconds += sample.userCPUSeconds
        systemCPUSeconds += sample.systemCPUSeconds
        maximumResidentSetBytes = max(maximumResidentSetBytes, sample.maximumResidentSetBytes)
        blockInputOperations += sample.blockInputOperations
        blockOutputOperations += sample.blockOutputOperations
        voluntaryContextSwitches += sample.voluntaryContextSwitches
        involuntaryContextSwitches += sample.involuntaryContextSwitches
    }

    var resources: RefreshProfileResources {
        RefreshProfileResources(
            userCPUSeconds: userCPUSeconds,
            systemCPUSeconds: systemCPUSeconds,
            maximumResidentSetBytes: maximumResidentSetBytes,
            blockInputOperations: blockInputOperations,
            blockOutputOperations: blockOutputOperations,
            voluntaryContextSwitches: voluntaryContextSwitches,
            involuntaryContextSwitches: involuntaryContextSwitches
        )
    }
}

private actor ProfileSnapshotReceiver {
    private let stream: AsyncStream<LocalRefreshSnapshot>

    init(stream: AsyncStream<LocalRefreshSnapshot>) {
        self.stream = stream
    }

    func next() async -> LocalRefreshSnapshot? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}

private struct ProfileLocalUsageRefresher: LocalUsageRefreshing {
    let database: UsageDatabase
    let sources: [CustomUsageSource]

    func refresh(now: Date, calendar: Calendar) async -> LocalUsageRefresh {
        let diagnostics = await database.refreshCustomSources(sources, now: now, calendar: calendar)
        let snapshot = await database.snapshot(now: now, calendar: calendar)
        return LocalUsageRefresh(snapshot: snapshot, customDiagnostics: diagnostics)
    }
}
