import Foundation
import LimitBarCore

@main
struct LimitBarRefreshBenchmark {
    static func main() async throws {
        let iterations = try parseIterations()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_783_890_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let eventTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let builtInLine = "{\"provider\":\"openAI\",\"timestamp\":\"\(eventTimestamp)\",\"model\":\"synthetic-model\",\"inputTokens\":100,\"outputTokens\":20}\n"
        let customLine = "{\"timestamp\":\"\(eventTimestamp)\",\"model\":\"synthetic-model\",\"inputTokens\":50,\"outputTokens\":10}\n"

        var results: [BenchmarkResult] = []
        results += try await builtInResults(root: root, line: builtInLine, now: now, calendar: calendar, iterations: iterations)
        results += try await customResults(root: root, line: customLine, now: now, calendar: calendar, iterations: iterations)
        results += try sqliteResults(root: root, now: now, calendar: calendar, iterations: iterations)
        results += try codexResults(root: root, now: now, iterations: iterations)

        let output = BenchmarkOutput(formatVersion: 1, iterations: iterations, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    }

    private static func builtInResults(
        root: URL,
        line: String,
        now: Date,
        calendar: Calendar,
        iterations: Int
    ) async throws -> [BenchmarkResult] {
        let events = root.appendingPathComponent("built-in.jsonl")
        try line.write(to: events, atomically: true, encoding: .utf8)
        let databasePath = root.appendingPathComponent("built-in.sqlite").path
        let database = UsageDatabase(pathFactory: { databasePath }, localEventsURL: events)
        _ = await database.snapshot(now: now, calendar: calendar)

        let unchanged = try await measure(name: "built-in-jsonl-unchanged", iterations: iterations) {
            let snapshot = await database.snapshot(now: now, calendar: calendar)
            return snapshot.localImport.validEventCount
        }
        var sequence = 0
        let changing = try await measure(name: "built-in-jsonl-changing", iterations: iterations) {
            sequence += 1
            try (line + String(repeating: "\n", count: sequence)).write(to: events, atomically: true, encoding: .utf8)
            let snapshot = await database.snapshot(now: now, calendar: calendar)
            return snapshot.localImport.validEventCount
        }
        return [unchanged, changing]
    }

    private static func customResults(
        root: URL,
        line: String,
        now: Date,
        calendar: Calendar,
        iterations: Int
    ) async throws -> [BenchmarkResult] {
        let events = root.appendingPathComponent("custom.jsonl")
        try line.write(to: events, atomically: true, encoding: .utf8)
        let emptyBuiltIn = root.appendingPathComponent("empty-built-in.jsonl")
        try Data().write(to: emptyBuiltIn)
        let databasePath = root.appendingPathComponent("custom.sqlite").path
        let database = UsageDatabase(pathFactory: { databasePath }, localEventsURL: emptyBuiltIn)
        let source = CustomUsageSource(
            id: UUID(uuidString: "4A613A87-9D4D-4208-80D5-7F6D94A6DBE7")!,
            name: "Synthetic source",
            filePath: events.path
        )
        _ = await database.refreshCustomSources([source], now: now, calendar: calendar)

        let unchanged = try await measure(name: "custom-jsonl-unchanged", iterations: iterations) {
            let diagnostics = await database.refreshCustomSources([source], now: now, calendar: calendar)
            return diagnostics.count
        }
        var sequence = 0
        let changing = try await measure(name: "custom-jsonl-changing", iterations: iterations) {
            sequence += 1
            try (line + String(repeating: "\n", count: sequence)).write(to: events, atomically: true, encoding: .utf8)
            let diagnostics = await database.refreshCustomSources([source], now: now, calendar: calendar)
            return diagnostics.count
        }
        return [unchanged, changing]
    }

    private static func sqliteResults(
        root: URL,
        now: Date,
        calendar: Calendar,
        iterations: Int
    ) throws -> [BenchmarkResult] {
        let store = try SQLiteUsageMetricStore(path: root.appendingPathComponent("standalone.sqlite").path)
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        func metric(inputTokens: Int) -> UsageMetric {
            UsageMetric(
                provider: .openAI,
                accountLabel: "Synthetic local log",
                projectLabel: nil,
                modelLabel: "synthetic-model",
                deploymentLabel: nil,
                provenance: .bounded(source: .builtInLocalLog, window: windows.today),
                tokenUsage: TokenUsage(inputTokens: inputTokens, outputTokens: 20),
                cost: nil,
                limitStatus: .unsupportedByProviderAPI,
                refreshedAt: now,
                freshness: .fresh
            )
        }
        try store.save([metric(inputTokens: 100)])
        let unchanged = try measureSync(name: "sqlite-unchanged", iterations: iterations) {
            try store.currentMetrics(at: now, calendar: calendar).count
        }
        var sequence = 0
        let changing = try measureSync(name: "sqlite-changing", iterations: iterations) {
            sequence += 1
            try store.save([metric(inputTokens: 100 + sequence)])
            return try store.currentMetrics(at: now, calendar: calendar).count
        }
        return [unchanged, changing]
    }

    private static func codexResults(root: URL, now: Date, iterations: Int) throws -> [BenchmarkResult] {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let session = sessions.appendingPathComponent("synthetic.jsonl")
        func line(percent: Int) -> String {
            "{\"timestamp\":\"2026-07-12T18:30:00Z\",\"payload\":{\"rate_limits\":{\"plan_type\":\"synthetic\",\"primary\":{\"used_percent\":\(percent),\"window_minutes\":300}}}}\n"
        }
        try line(percent: 20).write(to: session, atomically: true, encoding: .utf8)
        let unchanged = try measureSync(name: "codex-unchanged", iterations: iterations) {
            let snapshot = try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: sessions, now: now)
            return snapshot.primary == nil ? 0 : 1
        }
        var sequence = 0
        let changing = try measureSync(name: "codex-changing", iterations: iterations) {
            sequence += 1
            try line(percent: 20 + sequence % 10).write(to: session, atomically: true, encoding: .utf8)
            let snapshot = try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: sessions, now: now)
            return snapshot.primary == nil ? 0 : 1
        }
        return [unchanged, changing]
    }

    private static func measure(
        name: String,
        iterations: Int,
        operation: () async throws -> Int
    ) async throws -> BenchmarkResult {
        var durations: [Double] = []
        var aggregateCount = 0
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            aggregateCount += try await operation()
            durations.append(milliseconds(start.duration(to: .now)))
        }
        return result(name: name, durations: durations, aggregateCount: aggregateCount)
    }

    private static func measureSync(
        name: String,
        iterations: Int,
        operation: () throws -> Int
    ) throws -> BenchmarkResult {
        var durations: [Double] = []
        var aggregateCount = 0
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            aggregateCount += try operation()
            durations.append(milliseconds(start.duration(to: .now)))
        }
        return result(name: name, durations: durations, aggregateCount: aggregateCount)
    }

    private static func result(name: String, durations: [Double], aggregateCount: Int) -> BenchmarkResult {
        let sorted = durations.sorted()
        return BenchmarkResult(
            scenario: name,
            aggregateCount: aggregateCount,
            minimumMilliseconds: sorted.first ?? 0,
            medianMilliseconds: percentile(sorted, 0.5),
            p95Milliseconds: percentile(sorted, 0.95),
            maximumMilliseconds: sorted.last ?? 0
        )
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[index]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func parseIterations() throws -> Int {
        guard CommandLine.arguments.count <= 2 else { throw BenchmarkError.invalidArguments }
        if CommandLine.arguments.count == 1 { return 10 }
        guard let iterations = Int(CommandLine.arguments[1]), iterations > 0 else {
            throw BenchmarkError.invalidArguments
        }
        return iterations
    }
}

private struct BenchmarkOutput: Codable {
    let formatVersion: Int
    let iterations: Int
    let results: [BenchmarkResult]
}

private struct BenchmarkResult: Codable {
    let scenario: String
    let aggregateCount: Int
    let minimumMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
}

private enum BenchmarkError: Error {
    case invalidArguments
}
