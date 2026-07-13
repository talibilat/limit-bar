import Foundation

public struct CustomUsageSource: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var filePath: String

    public init(id: UUID = UUID(), name: String, filePath: String) {
        self.id = id
        self.name = name
        self.filePath = filePath
    }
}

public struct CustomUsageEvent: Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
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
    public let diagnostics: [CustomUsageLoadDiagnostic]
    public let rejectedLineCount: Int
    public let hasFutureTimestampRejection: Bool

    public init(
        metrics: [UsageMetric],
        diagnostics: [CustomUsageLoadDiagnostic],
        rejectedLineCount: Int,
        hasFutureTimestampRejection: Bool = false
    ) {
        self.metrics = metrics
        self.diagnostics = diagnostics
        self.rejectedLineCount = rejectedLineCount
        self.hasFutureTimestampRejection = hasFutureTimestampRejection
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
        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawEvent.self, from: data) else {
            throw CustomUsageEventError.malformedJSON
        }
        guard let timestampText = raw.timestamp, let timestamp = parseTimestamp(timestampText) else {
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
        return CustomUsageEvent(timestamp: timestamp, model: model, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
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
        guard !Task.isCancelled else { throw CustomUsageLoadError.cancelled }
        guard let windows = try? CurrentUsageWindows.resolve(at: now, calendar: calendar) else {
            throw CustomUsageLoadError.unresolvedWindows
        }

        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw CustomUsageLoadError.unreadableFile
        }
        guard values.isRegularFile == true else { throw CustomUsageLoadError.notRegularFile }
        guard let fileSize = values.fileSize, fileSize <= maximumFileBytes else {
            throw CustomUsageLoadError.fileTooLarge
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw CustomUsageLoadError.unreadableFile
        }
        defer { try? handle.close() }

        var aggregates: [AggregateKey: AggregateValue] = [:]
        var diagnostics: [CustomUsageLoadDiagnostic] = []
        var rejectedLineCount = 0
        var hasFutureTimestampRejection = false
        var lineNumber = 1
        var line = Data()
        var discardingOverlongLine = false
        var bytesRead = 0

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
            guard event.timestamp <= now.addingTimeInterval(futureTolerance) else {
                reject(.futureTimestamp)
                return
            }
            for window in [windows.today, windows.currentWeek] where event.timestamp >= window.start && event.timestamp < window.end {
                let key = AggregateKey(timeWindow: window.timeWindow, model: event.model)
                if aggregates[key] == nil, aggregates.count >= maximumAggregateKeys {
                    throw CustomUsageLoadError.tooManyAggregates
                }
                var value = aggregates[key] ?? AggregateValue(inputTokens: 0, outputTokens: 0, latestTimestamp: event.timestamp)
                value.inputTokens = try checkedSum(value.inputTokens, event.inputTokens)
                value.outputTokens = try checkedSum(value.outputTokens, event.outputTokens)
                _ = try checkedSum(value.inputTokens, value.outputTokens)
                value.latestTimestamp = max(value.latestTimestamp, event.timestamp)
                aggregates[key] = value
            }
        }

        do {
            while true {
                guard !Task.isCancelled else { throw CustomUsageLoadError.cancelled }
                let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
                if chunk.isEmpty { break }
                bytesRead = try checkedSum(bytesRead, chunk.count)
                guard bytesRead <= maximumFileBytes else { throw CustomUsageLoadError.fileTooLarge }
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
            if discardingOverlongLine {
                // The diagnostic was recorded when the limit was crossed.
            } else if !line.isEmpty {
                try consumeLine()
            }
        } catch let error as CustomUsageLoadError {
            throw error
        } catch {
            throw CustomUsageLoadError.unreadableFile
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
            diagnostics: diagnostics,
            rejectedLineCount: rejectedLineCount,
            hasFutureTimestampRejection: hasFutureTimestampRejection
        )
    }
}
