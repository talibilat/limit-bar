import CryptoKit
import Foundation

public struct CustomUsageSource: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var filePath: String

    public init(id: UUID = UUID(), name: String, filePath: String) {
        self.id = id
        self.name = name
        let fileURL = URL(fileURLWithPath: filePath)
        self.filePath = SecureRegularFile.canonicalURL(fileURL)?.path ?? fileURL.standardizedFileURL.path
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, filePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        filePath = SecureRegularFile.stableStoredPath(try container.decode(String.self, forKey: .filePath))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(filePath, forKey: .filePath)
    }
}

public struct CustomUsageEvent: Equatable, Sendable {
    public let eventID: UUID?
    public let customSourceID: UUID?
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let project: CollectorAttribution?
    public let agent: CollectorAttribution?
}

public enum CustomUsageEventError: Error, Equatable {
    case malformedJSON
    case missingRequiredField(String)
    case negativeTokenCount
}

public enum CustomUsageLoadError: Error, Equatable, Sendable {
    case unreadableFile
    case notRegularFile
    case fileTooLarge
    case unresolvedWindows
    case tokenOverflow
    case tooManyAggregates
    case noValidEvents(diagnostics: [CustomUsageLoadDiagnostic], rejectedLineCount: Int)
    case cancelled
}

public struct CustomUsageLoadDiagnostic: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case malformedEvent
        case invalidUTF8
        case lineTooLong
        case futureTimestamp
    }

    public let lineNumber: Int
    public let reason: Reason

    public init(lineNumber: Int, reason: Reason) {
        self.lineNumber = lineNumber
        self.reason = reason
    }
}

public struct CustomUsageLoadResult: Equatable, Sendable {
    public let metrics: [UsageMetric]
    public let attributionBreakdowns: [ObservedLocalAttributionBreakdown]
    public let diagnostics: [CustomUsageLoadDiagnostic]
    public let rejectedLineCount: Int
    public let hasFutureTimestampRejection: Bool
    public let sourceRevision: String?

    public init(
        metrics: [UsageMetric],
        attributionBreakdowns: [ObservedLocalAttributionBreakdown] = [],
        diagnostics: [CustomUsageLoadDiagnostic],
        rejectedLineCount: Int,
        hasFutureTimestampRejection: Bool = false,
        sourceRevision: String? = nil
    ) {
        self.metrics = metrics
        self.attributionBreakdowns = attributionBreakdowns
        self.diagnostics = diagnostics
        self.rejectedLineCount = rejectedLineCount
        self.hasFutureTimestampRejection = hasFutureTimestampRejection
        self.sourceRevision = sourceRevision
    }
}

public enum CustomUsageEventParser {
    private struct RawEvent: Decodable {
        let timestamp: String?
        let model: String?
        let inputTokens: Int?
        let outputTokens: Int?
    }

    public static func parseLine(_ line: String) throws -> CustomUsageEvent {
        guard let data = line.data(using: .utf8) else {
            throw CustomUsageEventError.malformedJSON
        }
        if CollectorSchemaV2.hasStrictSchema(in: data) {
            guard let event = try? CollectorSchemaV2.decode(data), case let .customSource(sourceID) = event.identity else {
                throw CustomUsageEventError.malformedJSON
            }
            return CustomUsageEvent(
                eventID: event.eventID,
                customSourceID: sourceID,
                timestamp: event.timestamp,
                model: event.model,
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                project: event.project,
                agent: event.agent
            )
        }
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: data) else {
            throw CustomUsageEventError.malformedJSON
        }
        guard let timestampText = raw.timestamp,
              let timestamp = CollectorSchemaV1.parseTimestamp(timestampText) else {
            throw CustomUsageEventError.missingRequiredField("timestamp")
        }
        guard let rawModel = raw.model else {
            throw CustomUsageEventError.missingRequiredField("model")
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw CustomUsageEventError.missingRequiredField("model")
        }
        guard let inputTokens = raw.inputTokens else {
            throw CustomUsageEventError.missingRequiredField("inputTokens")
        }
        guard let outputTokens = raw.outputTokens else {
            throw CustomUsageEventError.missingRequiredField("outputTokens")
        }
        guard inputTokens >= 0, outputTokens >= 0 else {
            throw CustomUsageEventError.negativeTokenCount
        }
        return CustomUsageEvent(
            eventID: nil, customSourceID: nil, timestamp: timestamp, model: model,
            inputTokens: inputTokens, outputTokens: outputTokens, project: nil, agent: nil
        )
    }
}

public enum CustomUsageAggregator {
    private struct AggregateKey: Hashable {
        let timeWindow: TimeWindow
        let model: String
    }

    private struct AggregateValue {
        var inputTokens: Int
        var outputTokens: Int
        var latestTimestamp: Date
    }

    private struct AttributionKey: Hashable {
        let window: ExactUsageWindow
        let model: String
        let project: CollectorAttribution?
        let agent: CollectorAttribution?
    }

    private struct AttributionValue {
        var inputTokens: Int
        var outputTokens: Int
        var eventIDs: [UUID]
        var latestTimestamp: Date
    }

    private static let maximumFileBytes = 100 * 1_024 * 1_024
    private static let chunkBytes = 64 * 1_024
    private static let maximumLineBytes = 1 * 1_024 * 1_024
    private static let maximumDiagnostics = 20
    private static let maximumAggregateKeys = 10_000
    private static let futureTolerance: TimeInterval = 5 * 60

    public static func metrics(
        from fileURL: URL,
        source: CustomUsageSource,
        now: Date,
        calendar: Calendar,
        fileManager: FileManager = .default
    ) async -> [UsageMetric] {
        (try? await loadMetrics(from: fileURL, source: source, now: now, calendar: calendar, fileManager: fileManager).metrics) ?? []
    }

    public static func loadMetrics(
        from fileURL: URL,
        source: CustomUsageSource,
        now: Date,
        calendar: Calendar,
        fileManager: FileManager = .default
    ) async throws -> CustomUsageLoadResult {
        try await loadMetrics(from: fileURL, source: source, now: now, calendar: calendar, fileManager: fileManager, onChunkRead: nil)
    }

    static func loadMetrics(
        from fileURL: URL,
        source: CustomUsageSource,
        now: Date,
        calendar: Calendar,
        fileManager: FileManager = .default,
        onChunkRead: ((Int) throws -> Void)?
    ) async throws -> CustomUsageLoadResult {
        guard !Task.isCancelled else { throw CustomUsageLoadError.cancelled }
        guard let windows = try? CurrentUsageWindows.resolve(at: now, calendar: calendar) else {
            throw CustomUsageLoadError.unresolvedWindows
        }
        guard !SecureRegularFile.isSymbolicLink(fileURL) else {
            throw CustomUsageLoadError.notRegularFile
        }

        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw CustomUsageLoadError.unreadableFile
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CustomUsageLoadError.notRegularFile }
        guard let fileSize = values.fileSize, fileSize <= maximumFileBytes else {
            throw CustomUsageLoadError.fileTooLarge
        }
        let authorizedFileURL = URL(fileURLWithPath: source.filePath)
        guard SecureRegularFile.canonicalURL(fileURL)?.path == authorizedFileURL.path else {
            throw CustomUsageLoadError.unreadableFile
        }

        let handle: FileHandle
        do {
            handle = try SecureRegularFile.open(authorizedFileURL)
        } catch {
            throw CustomUsageLoadError.unreadableFile
        }
        defer { try? handle.close() }

        var aggregates: [AggregateKey: AggregateValue] = [:]
        var attributionAggregates: [AttributionKey: AttributionValue] = [:]
        var diagnostics: [CustomUsageLoadDiagnostic] = []
        var rejectedLineCount = 0
        var hasFutureTimestampRejection = false
        var validEventCount = 0
        var lineNumber = 1
        var line = Data()
        var discardingOverlongLine = false
        var bytesRead = 0
        var hasher = SHA256()

        func reject(_ reason: CustomUsageLoadDiagnostic.Reason) {
            rejectedLineCount += 1
            if reason == .futureTimestamp {
                hasFutureTimestampRejection = true
            }
            if diagnostics.count < maximumDiagnostics {
                diagnostics.append(CustomUsageLoadDiagnostic(lineNumber: lineNumber, reason: reason))
            }
        }

        func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw CustomUsageLoadError.tokenOverflow }
            return sum
        }

        func consumeLine() throws {
            defer {
                line.removeAll(keepingCapacity: true)
                lineNumber += 1
            }
            guard !line.isEmpty else { return }
            guard let text = String(data: line, encoding: .utf8) else {
                reject(.invalidUTF8)
                return
            }
            guard let event = try? CustomUsageEventParser.parseLine(text) else {
                reject(.malformedEvent)
                return
            }
            guard event.customSourceID == nil || event.customSourceID == source.id else {
                reject(.malformedEvent)
                return
            }
            guard event.timestamp <= now.addingTimeInterval(futureTolerance) else {
                reject(.futureTimestamp)
                return
            }
            validEventCount += 1
            for window in [windows.today, windows.currentWeek] where event.timestamp >= window.start && event.timestamp < window.end {
                let key = AggregateKey(timeWindow: window.timeWindow, model: event.model)
                let attributionKey: AttributionKey? = if event.project != nil || event.agent != nil, event.eventID != nil {
                    AttributionKey(window: window, model: event.model, project: event.project, agent: event.agent)
                } else {
                    nil
                }
                let addedKeyCount = (aggregates[key] == nil ? 1 : 0)
                    + (attributionKey.map { attributionAggregates[$0] == nil ? 1 : 0 } ?? 0)
                if aggregates.count + attributionAggregates.count + addedKeyCount > maximumAggregateKeys {
                    throw CustomUsageLoadError.tooManyAggregates
                }
                var value = aggregates[key] ?? AggregateValue(inputTokens: 0, outputTokens: 0, latestTimestamp: event.timestamp)
                value.inputTokens = try checkedSum(value.inputTokens, event.inputTokens)
                value.outputTokens = try checkedSum(value.outputTokens, event.outputTokens)
                _ = try checkedSum(value.inputTokens, value.outputTokens)
                value.latestTimestamp = max(value.latestTimestamp, event.timestamp)
                aggregates[key] = value

                guard let attributionKey, let eventID = event.eventID else { continue }
                var attribution = attributionAggregates[attributionKey] ?? AttributionValue(inputTokens: 0, outputTokens: 0, eventIDs: [], latestTimestamp: event.timestamp)
                attribution.inputTokens = try checkedSum(attribution.inputTokens, event.inputTokens)
                attribution.outputTokens = try checkedSum(attribution.outputTokens, event.outputTokens)
                _ = try checkedSum(attribution.inputTokens, attribution.outputTokens)
                attribution.eventIDs.append(eventID)
                attribution.latestTimestamp = max(attribution.latestTimestamp, event.timestamp)
                attributionAggregates[attributionKey] = attribution
            }
        }

        do {
            while true {
                guard !Task.isCancelled else { throw CustomUsageLoadError.cancelled }
                let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
                if chunk.isEmpty { break }
                bytesRead = try checkedSum(bytesRead, chunk.count)
                guard bytesRead <= maximumFileBytes else { throw CustomUsageLoadError.fileTooLarge }
                hasher.update(data: chunk)
                try onChunkRead?(bytesRead)
                for byte in chunk {
                    if byte == 0x0A {
                        if discardingOverlongLine {
                            discardingOverlongLine = false
                            lineNumber += 1
                        } else {
                            try consumeLine()
                        }
                    } else if !discardingOverlongLine {
                        if line.count == maximumLineBytes {
                            reject(.lineTooLong)
                            line.removeAll(keepingCapacity: true)
                            discardingOverlongLine = true
                        } else {
                            line.append(byte)
                        }
                    }
                }
                await Task.yield()
            }
            if !discardingOverlongLine, !line.isEmpty {
                try consumeLine()
            }
        } catch let error as CustomUsageLoadError {
            throw error
        } catch {
            throw CustomUsageLoadError.unreadableFile
        }

        if bytesRead > 0, validEventCount == 0, rejectedLineCount > 0 {
            throw CustomUsageLoadError.noValidEvents(
                diagnostics: diagnostics,
                rejectedLineCount: rejectedLineCount
            )
        }

        let metrics = aggregates.map { key, value in
            UsageMetric(
                provider: .custom,
                accountLabel: source.name,
                projectLabel: nil,
                modelLabel: key.model,
                deploymentLabel: nil,
                provenance: .bounded(source: .custom(source.id), window: key.timeWindow == .today ? windows.today : windows.currentWeek),
                tokenUsage: TokenUsage(inputTokens: value.inputTokens, outputTokens: value.outputTokens),
                cost: nil,
                limitStatus: .unsupportedByProviderAPI,
                refreshedAt: value.latestTimestamp,
                freshness: .fresh
            )
        }.sorted { ($0.timeWindow.rawValue, $0.modelLabel) < ($1.timeWindow.rawValue, $1.modelLabel) }

        return CustomUsageLoadResult(
            metrics: metrics,
            attributionBreakdowns: attributionAggregates.map { key, value in
                ObservedLocalAttributionBreakdown(
                    source: .custom(source.id), provider: .custom, window: key.window, model: key.model, deployment: nil,
                    project: key.project, agent: key.agent,
                    tokenUsage: TokenUsage(inputTokens: value.inputTokens, outputTokens: value.outputTokens),
                    eventIDs: value.eventIDs.sorted { $0.uuidString < $1.uuidString },
                    observedAt: value.latestTimestamp
                )
            }.sorted {
                ($0.window.start, $0.model, $0.project?.id ?? "", $0.agent?.id ?? "")
                    < ($1.window.start, $1.model, $1.project?.id ?? "", $1.agent?.id ?? "")
            },
            diagnostics: diagnostics,
            rejectedLineCount: rejectedLineCount,
            hasFutureTimestampRejection: hasFutureTimestampRejection,
            sourceRevision: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}
