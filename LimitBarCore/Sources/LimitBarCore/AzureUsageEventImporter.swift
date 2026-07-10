import Foundation

public struct AzureUsageEvent: Equatable, Sendable {
    public let provider: ProviderKind
    public let timestamp: Date
    public let model: String
    public let deployment: String?
    public let inputTokens: Int
    public let outputTokens: Int
}

public enum AzureUsageEventError: Error, Equatable {
    case malformedJSON
    case unsupportedProvider
    case missingRequiredField(String)
    case negativeTokenCount
    case tokenCountOverflow
}

public struct MalformedAzureUsageEvent: Equatable, Sendable {
    public let lineNumber: Int
    public let reason: String
}

public struct AzureUsageImportResult: Equatable, Sendable {
    public let fileURL: URL
    public let validEventCount: Int
    public let malformedEventCount: Int
    public let malformedEvents: [MalformedAzureUsageEvent]
    public let failureMessage: String?

    public static func empty(fileURL: URL) -> AzureUsageImportResult {
        AzureUsageImportResult(fileURL: fileURL, validEventCount: 0, malformedEventCount: 0, malformedEvents: [], failureMessage: nil)
    }

    public static func failed(fileURL: URL, message: String) -> AzureUsageImportResult {
        AzureUsageImportResult(fileURL: fileURL, validEventCount: 0, malformedEventCount: 0, malformedEvents: [], failureMessage: message)
    }
}

public enum AzureUsageEventParser {
    private struct RawEvent: Decodable {
        let provider: String?
        let timestamp: String?
        let model: String?
        let inputTokens: Int?
        let outputTokens: Int?
        let deployment: String?
    }

    public static func parseLine(_ line: String) throws -> AzureUsageEvent {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawEvent.self, from: data) else {
            throw AzureUsageEventError.malformedJSON
        }

        guard raw.provider == ProviderKind.azureOpenAI.rawValue else {
            throw AzureUsageEventError.unsupportedProvider
        }

        guard let timestampText = raw.timestamp, let timestamp = parseTimestamp(timestampText) else {
            throw AzureUsageEventError.missingRequiredField("timestamp")
        }

        guard let rawModel = raw.model else {
            throw AzureUsageEventError.missingRequiredField("model")
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AzureUsageEventError.missingRequiredField("model")
        }

        let deployment: String?
        if let rawDeployment = raw.deployment {
            let trimmedDeployment = rawDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDeployment.isEmpty else {
                throw AzureUsageEventError.missingRequiredField("deployment")
            }
            deployment = trimmedDeployment
        } else {
            deployment = nil
        }

        guard let inputTokens = raw.inputTokens else {
            throw AzureUsageEventError.missingRequiredField("inputTokens")
        }

        guard let outputTokens = raw.outputTokens else {
            throw AzureUsageEventError.missingRequiredField("outputTokens")
        }

        guard inputTokens >= 0, outputTokens >= 0 else {
            throw AzureUsageEventError.negativeTokenCount
        }

        return AzureUsageEvent(
            provider: .azureOpenAI,
            timestamp: timestamp,
            model: model,
            deployment: deployment,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    private static func parseTimestamp(_ timestampText: String) -> Date? {
        let standardFormatter = ISO8601DateFormatter()
        if let timestamp = standardFormatter.date(from: timestampText) {
            return timestamp
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: timestampText)
    }
}

public enum AzureUsageEventImporter {
    private struct AggregateKey: Hashable {
        let timeWindow: TimeWindow
        let model: String
        let deployment: String?
    }

    private struct AggregateValue {
        var inputTokens: Int
        var outputTokens: Int
        var latestTimestamp: Date
    }

    private static let importedAccountLabel = "Azure OpenAI"
    private static let importedWindows: [TimeWindow] = [.today, .currentWeek]

    public static func usageEventsURL(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("LimitBar", isDirectory: true)
            .appendingPathComponent("usage-events.jsonl")
    }

    public static func usageEventsURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("LimitBar", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return usageEventsURL(applicationSupportDirectory: applicationSupport)
    }

    @discardableResult
    public static func importEvents(
        from fileURL: URL,
        to store: SQLiteUsageMetricStore,
        now: Date,
        calendar: Calendar
    ) throws -> AzureUsageImportResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try store.replaceMetrics(provider: .azureOpenAI, timeWindows: importedWindows, with: [])
            return .empty(fileURL: fileURL)
        }

        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        var aggregates: [AggregateKey: AggregateValue] = [:]
        var validEventCount = 0
        var malformedEventCount = 0
        var malformed: [MalformedAzureUsageEvent] = []
        var buffer = Data()
        var lineNumber = 1

        while let chunk = try fileHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            var consumedThrough = buffer.startIndex
            while let newline = buffer[consumedThrough...].firstIndex(of: 0x0A) {
                try process(
                    lineData: buffer[consumedThrough..<newline],
                    lineNumber: lineNumber,
                    now: now,
                    calendar: calendar,
                    aggregates: &aggregates,
                    validEventCount: &validEventCount,
                    malformedEventCount: &malformedEventCount,
                    malformed: &malformed
                )
                lineNumber += 1
                consumedThrough = buffer.index(after: newline)
            }
            if consumedThrough > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<consumedThrough)
            }
        }
        if !buffer.isEmpty {
            try process(
                lineData: buffer[...],
                lineNumber: lineNumber,
                now: now,
                calendar: calendar,
                aggregates: &aggregates,
                validEventCount: &validEventCount,
                malformedEventCount: &malformedEventCount,
                malformed: &malformed
            )
        }

        try store.replaceMetrics(
            provider: .azureOpenAI,
            timeWindows: importedWindows,
            with: metrics(from: aggregates)
        )

        return AzureUsageImportResult(
            fileURL: fileURL,
            validEventCount: validEventCount,
            malformedEventCount: malformedEventCount,
            malformedEvents: malformed,
            failureMessage: nil
        )
    }

    private static func process(
        lineData: Data.SubSequence,
        lineNumber: Int,
        now: Date,
        calendar: Calendar,
        aggregates: inout [AggregateKey: AggregateValue],
        validEventCount: inout Int,
        malformedEventCount: inout Int,
        malformed: inout [MalformedAzureUsageEvent]
    ) throws {
        guard let line = String(data: lineData, encoding: .utf8) else {
            recordMalformed(AzureUsageEventError.malformedJSON, lineNumber: lineNumber, count: &malformedEventCount, events: &malformed)
            return
        }
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        do {
            let event = try AzureUsageEventParser.parseLine(line)
            validEventCount += 1
            try add(event, now: now, calendar: calendar, to: &aggregates)
        } catch let error as AzureUsageEventError where error != .tokenCountOverflow {
            recordMalformed(error, lineNumber: lineNumber, count: &malformedEventCount, events: &malformed)
        }
    }

    private static func recordMalformed(
        _ error: AzureUsageEventError,
        lineNumber: Int,
        count: inout Int,
        events: inout [MalformedAzureUsageEvent]
    ) {
        count += 1
        if events.count < 20 {
            events.append(MalformedAzureUsageEvent(lineNumber: lineNumber, reason: String(describing: error)))
        }
    }

    private static func add(
        _ event: AzureUsageEvent,
        now: Date,
        calendar: Calendar,
        to aggregates: inout [AggregateKey: AggregateValue]
    ) throws {
        for window in importedWindows {
            let interval = window.interval(containing: now, calendar: calendar)
            guard event.timestamp >= interval.start, event.timestamp < interval.end else {
                continue
            }
            let key = AggregateKey(timeWindow: window, model: event.model, deployment: event.deployment)
            var value = aggregates[key] ?? AggregateValue(inputTokens: 0, outputTokens: 0, latestTimestamp: event.timestamp)
            value.inputTokens = try checkedSum(value.inputTokens, event.inputTokens)
            value.outputTokens = try checkedSum(value.outputTokens, event.outputTokens)
            _ = try checkedSum(value.inputTokens, value.outputTokens)
            value.latestTimestamp = max(value.latestTimestamp, event.timestamp)
            aggregates[key] = value
        }
    }

    private static func metrics(from aggregates: [AggregateKey: AggregateValue]) -> [UsageMetric] {
        aggregates.map { key, value in
            UsageMetric(
                provider: .azureOpenAI,
                accountLabel: importedAccountLabel,
                projectLabel: nil,
                modelLabel: key.model,
                deploymentLabel: key.deployment,
                timeWindow: key.timeWindow,
                tokenUsage: TokenUsage(
                    inputTokens: value.inputTokens,
                    outputTokens: value.outputTokens
                ),
                cost: nil,
                limitStatus: .unsupportedByProviderAPI,
                refreshedAt: value.latestTimestamp,
                freshness: .fresh
            )
        }
        .sorted { lhs, rhs in
            let lhsWindow = importedWindows.firstIndex(of: lhs.timeWindow) ?? importedWindows.endIndex
            let rhsWindow = importedWindows.firstIndex(of: rhs.timeWindow) ?? importedWindows.endIndex
            return (lhsWindow, lhs.modelLabel, lhs.deploymentLabel ?? "") < (rhsWindow, rhs.modelLabel, rhs.deploymentLabel ?? "")
        }
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw AzureUsageEventError.tokenCountOverflow
        }
        return sum
    }
}
