import CryptoKit
import Foundation

public enum APISpendLocalEvidenceError: Error, Equatable {
    case unavailable
    case fileTooLarge
    case lineTooLong
    case malformedSchemaV2Event
    case eventIDConflict
    case tooManyAggregates
    case tokenOverflow
    case futureTimestamp
}

public struct APISpendLocalEvidenceSnapshot: Equatable, Sendable {
    public let sourceRevision: String
    public let breakdowns: [ObservedLocalAttributionBreakdown]

    public init(sourceRevision: String, breakdowns: [ObservedLocalAttributionBreakdown]) {
        self.sourceRevision = sourceRevision
        self.breakdowns = breakdowns
    }
}

public enum APISpendLocalEvidenceLoader {
    private static let maximumFileBytes = 100 * 1_024 * 1_024
    private static let maximumLineBytes = 1_048_576
    private static let maximumAggregates = 10_000
    private static let futureTolerance: TimeInterval = 5 * 60

    private struct Key: Hashable {
        let window: ExactUsageWindow
        let model: String
        let project: CollectorAttribution?
        let agent: CollectorAttribution?
    }

    private struct Value {
        var inputTokens = 0
        var outputTokens = 0
        var eventIDs: [UUID] = []
        var observedAt: Date
    }

    public static func loadActiveSource(fileURL: URL? = nil, now: Date = Date()) throws -> APISpendLocalEvidenceSnapshot {
        let configuredURL: URL
        do { configuredURL = try fileURL ?? LimitBarFileLocations.production().usageEventsFile }
        catch { throw APISpendLocalEvidenceError.unavailable }

        if SecureRegularFile.isSymbolicLink(configuredURL) { throw APISpendLocalEvidenceError.unavailable }
        if !FileManager.default.fileExists(atPath: configuredURL.path) {
            return APISpendLocalEvidenceSnapshot(sourceRevision: digest(Data()), breakdowns: [])
        }
        guard let canonicalURL = SecureRegularFile.canonicalURL(configuredURL) else { throw APISpendLocalEvidenceError.unavailable }

        let handle: FileHandle
        do { handle = try SecureRegularFile.open(canonicalURL) }
        catch { throw APISpendLocalEvidenceError.unavailable }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalBytes = 0
        var line = Data()
        var aggregates: [Key: Value] = [:]
        var events: [UUID: CollectorEventV2] = [:]

        while let chunk = try read(handle), !chunk.isEmpty {
            try Task.checkCancellation()
            totalBytes = try checkedSum(totalBytes, chunk.count, error: .fileTooLarge)
            guard totalBytes <= maximumFileBytes else { throw APISpendLocalEvidenceError.fileTooLarge }
            hasher.update(data: chunk)
            for byte in chunk {
                if byte == 0x0A {
                    try process(line, now: now, events: &events, aggregates: &aggregates)
                    line.removeAll(keepingCapacity: true)
                } else {
                    guard line.count < maximumLineBytes else { throw APISpendLocalEvidenceError.lineTooLong }
                    line.append(byte)
                }
            }
        }
        if !line.isEmpty { try process(line, now: now, events: &events, aggregates: &aggregates) }

        let revision = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let breakdowns = aggregates.map { key, value in
            ObservedLocalAttributionBreakdown(
                source: .builtInLocalLog,
                provider: .anthropic,
                window: key.window,
                model: key.model,
                deployment: nil,
                project: key.project,
                agent: key.agent,
                tokenUsage: TokenUsage(inputTokens: value.inputTokens, outputTokens: value.outputTokens),
                eventIDs: value.eventIDs.sorted { $0.uuidString < $1.uuidString },
                observedAt: value.observedAt
            )
        }.sorted { ($0.window.start, $0.model, $0.project?.id ?? "", $0.agent?.id ?? "") < ($1.window.start, $1.model, $1.project?.id ?? "", $1.agent?.id ?? "") }
        return APISpendLocalEvidenceSnapshot(sourceRevision: revision, breakdowns: breakdowns)
    }

    private static func process(_ line: Data, now: Date, events: inout [UUID: CollectorEventV2], aggregates: inout [Key: Value]) throws {
        guard !line.isEmpty, CollectorSchemaV2.hasStrictSchema(in: line) else { return }
        let event: CollectorEventV2
        do { event = try CollectorSchemaV2.decode(line) }
        catch { throw APISpendLocalEvidenceError.malformedSchemaV2Event }
        guard case .provider(.anthropic) = event.identity else { return }
        guard event.timestamp <= now.addingTimeInterval(futureTolerance) else { throw APISpendLocalEvidenceError.futureTimestamp }
        if let prior = events[event.eventID] {
            guard prior == event else { throw APISpendLocalEvidenceError.eventIDConflict }
            return
        }
        events[event.eventID] = event
        guard event.project != nil || event.agent != nil else { return }

        let key = Key(window: try utcDay(containing: event.timestamp), model: event.model, project: event.project, agent: event.agent)
        guard aggregates[key] != nil || aggregates.count < maximumAggregates else { throw APISpendLocalEvidenceError.tooManyAggregates }
        var value = aggregates[key] ?? Value(observedAt: event.timestamp)
        value.inputTokens = try checkedSum(value.inputTokens, event.inputTokens, error: .tokenOverflow)
        value.outputTokens = try checkedSum(value.outputTokens, event.outputTokens, error: .tokenOverflow)
        _ = try checkedSum(value.inputTokens, value.outputTokens, error: .tokenOverflow)
        value.eventIDs.append(event.eventID)
        value.observedAt = max(value.observedAt, event.timestamp)
        aggregates[key] = value
    }

    private static func utcDay(containing date: Date) throws -> ExactUsageWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw APISpendLocalEvidenceError.unavailable }
        return try ExactUsageWindow(timeWindow: .today, start: start, end: end, basis: .utcBilling)
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int, error: APISpendLocalEvidenceError) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw error }
        return result.partialValue
    }

    private static func read(_ handle: FileHandle) throws -> Data? {
        do { return try handle.read(upToCount: 64 * 1_024) }
        catch { throw APISpendLocalEvidenceError.unavailable }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
