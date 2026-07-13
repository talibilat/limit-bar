import Foundation

public struct LocalUsageEvent: Equatable, Sendable {
    public let provider: ProviderKind
    public let timestamp: Date
    public let model: String
    public let deployment: String?
    public let inputTokens: Int
    public let outputTokens: Int
}

public enum LocalUsageEventError: Error, Equatable {
    case malformedJSON
    case unsupportedProvider
    case missingRequiredField(String)
    case negativeTokenCount
    case tokenCountOverflow
    case lineTooLong
    case fileTooLarge
    case tooManyAggregates
    case futureTimestamp
    case unreadableFile
    case notRegularFile
}

public struct MalformedLocalUsageEvent: Equatable, Sendable {
    public let lineNumber: Int
    public let reason: String
}

public struct LocalUsageImportResult: Equatable, Sendable {
    public let fileURL: URL
    public let validEventCount: Int
    public let malformedEventCount: Int
    public let malformedEvents: [MalformedLocalUsageEvent]
    public let failureMessage: String?
    public let hasFutureTimestampRejection: Bool

    public static func empty(fileURL: URL) -> LocalUsageImportResult {
        LocalUsageImportResult(fileURL: fileURL, validEventCount: 0, malformedEventCount: 0, malformedEvents: [], failureMessage: nil, hasFutureTimestampRejection: false)
    }

    public static func failed(fileURL: URL, message: String) -> LocalUsageImportResult {
        LocalUsageImportResult(fileURL: fileURL, validEventCount: 0, malformedEventCount: 0, malformedEvents: [], failureMessage: message, hasFutureTimestampRejection: false)
    }
}

public enum LocalUsageEventParser {
    private struct RawEvent: Decodable {
        let provider: String?
        let timestamp: String?
        let model: String?
        let inputTokens: Int?
        let outputTokens: Int?
        let deployment: String?
    }

    public static func parseLine(_ line: String) throws -> LocalUsageEvent {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawEvent.self, from: data) else {
            throw LocalUsageEventError.malformedJSON
        }

        guard let rawProvider = raw.provider,
              let provider = ProviderKind(rawValue: rawProvider),
              LocalUsageEventImporter.supportedProviders.contains(provider) else {
            throw LocalUsageEventError.unsupportedProvider
        }

        guard let timestampText = raw.timestamp, let timestamp = parseTimestamp(timestampText) else {
            throw LocalUsageEventError.missingRequiredField("timestamp")
        }

        guard let rawModel = raw.model else {
            throw LocalUsageEventError.missingRequiredField("model")
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw LocalUsageEventError.missingRequiredField("model")
        }

        let deployment: String?
        if let rawDeployment = raw.deployment {
            let trimmedDeployment = rawDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDeployment.isEmpty else {
                throw LocalUsageEventError.missingRequiredField("deployment")
            }
            deployment = trimmedDeployment
        } else {
            deployment = nil
        }

        guard let inputTokens = raw.inputTokens else {
            throw LocalUsageEventError.missingRequiredField("inputTokens")
        }

        guard let outputTokens = raw.outputTokens else {
            throw LocalUsageEventError.missingRequiredField("outputTokens")
        }

        guard inputTokens >= 0, outputTokens >= 0 else {
            throw LocalUsageEventError.negativeTokenCount
        }

        return LocalUsageEvent(
            provider: provider,
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

public enum LocalUsageEventImporter {
    private struct AggregateKey: Hashable {
        let provider: ProviderKind
        let window: ExactUsageWindow
        let model: String
        let deployment: String?
    }

    private struct AggregateValue {
        var inputTokens: Int
        var outputTokens: Int
        var latestTimestamp: Date
    }

    // This importer only ever handles the shared usage-events.jsonl file and
    // the built-in providers that write to it. Custom sources (see
    // CustomUsageSource) are separate per-file imports and never reach here.
    public static let supportedProviders: Set<ProviderKind> = [.anthropic, .azureOpenAI, .openAI]

    // Locally imported metrics are scoped by these account labels so they can
    // coexist with provider-API metrics, which use nil or an organization label.
    public static func importedAccountLabel(for provider: ProviderKind) -> String {
        switch provider {
        case .anthropic, .openAI:
            "Local logs"
        case .azureOpenAI:
            "Azure OpenAI"
        case .custom:
            "Custom"
        }
    }

    private static let importedWindows: [TimeWindow] = [.today, .currentWeek]
    private static let maximumLineByteCount = 1_048_576
    private static let maximumFileByteCount = 100 * 1_024 * 1_024
    private static let maximumAggregateKeys = 10_000
    private static let futureTolerance: TimeInterval = 5 * 60

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
    ) throws -> LocalUsageImportResult {
        try Task.checkCancellation()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let importedWindows = [windows.today, windows.currentWeek]
        let fileHandle: FileHandle
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw LocalUsageEventError.notRegularFile
            }
            guard let fileSize = values.fileSize, fileSize <= maximumFileByteCount else {
                throw LocalUsageEventError.fileTooLarge
            }
            fileHandle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            guard isFileNotFound(error) else {
                if let typedError = error as? LocalUsageEventError {
                    throw typedError
                }
                throw LocalUsageEventError.unreadableFile
            }
            try Task.checkCancellation()
            try replaceImportedMetrics(in: store, windows: importedWindows, aggregates: [:])
            return .empty(fileURL: fileURL)
        }
        defer { try? fileHandle.close() }
        var aggregates: [AggregateKey: AggregateValue] = [:]
        var validEventCount = 0
        var malformedEventCount = 0
        var malformed: [MalformedLocalUsageEvent] = []
        var buffer = Data()
        var lineNumber = 1
        var discardingOverlongLine = false
        var bytesRead = 0
        var hasFutureTimestampRejection = false

        while let chunk = try readChunk(from: fileHandle), !chunk.isEmpty {
            try Task.checkCancellation()
            bytesRead = try checkedSum(bytesRead, chunk.count)
            guard bytesRead <= maximumFileByteCount else {
                throw LocalUsageEventError.fileTooLarge
            }
            for byte in chunk {
                if discardingOverlongLine {
                    if byte == 0x0A {
                        discardingOverlongLine = false
                        lineNumber += 1
                    }
                    continue
                }
                if byte == 0x0A {
                    try process(
                        lineData: buffer[...],
                        lineNumber: lineNumber,
                        windows: importedWindows,
                        aggregates: &aggregates,
                        validEventCount: &validEventCount,
                        malformedEventCount: &malformedEventCount,
                        malformed: &malformed,
                        hasFutureTimestampRejection: &hasFutureTimestampRejection,
                        now: now
                    )
                    buffer.removeAll(keepingCapacity: true)
                    lineNumber += 1
                } else if buffer.count == maximumLineByteCount {
                    recordMalformed(LocalUsageEventError.lineTooLong, lineNumber: lineNumber, count: &malformedEventCount, events: &malformed)
                    buffer.removeAll(keepingCapacity: true)
                    discardingOverlongLine = true
                } else {
                    buffer.append(byte)
                }
            }
        }
        if !discardingOverlongLine, !buffer.isEmpty {
            try process(
                lineData: buffer[...],
                lineNumber: lineNumber,
                windows: importedWindows,
                aggregates: &aggregates,
                validEventCount: &validEventCount,
                malformedEventCount: &malformedEventCount,
                malformed: &malformed,
                hasFutureTimestampRejection: &hasFutureTimestampRejection,
                now: now
            )
        }

        try Task.checkCancellation()
        try replaceImportedMetrics(in: store, windows: importedWindows, aggregates: aggregates)

        return LocalUsageImportResult(
            fileURL: fileURL,
            validEventCount: validEventCount,
            malformedEventCount: malformedEventCount,
            malformedEvents: malformed,
            failureMessage: nil,
            hasFutureTimestampRejection: hasFutureTimestampRejection
        )
    }

    private static func replaceImportedMetrics(
        in store: SQLiteUsageMetricStore,
        windows: [ExactUsageWindow],
        aggregates: [AggregateKey: AggregateValue]
    ) throws {
        let replacements = ProviderKind.orderedCases
            .filter { supportedProviders.contains($0) }
            .map { provider in
                UsageScopedReplacement(
                    scope: UsageReplacementScope(provider: provider, source: .builtInLocalLog, windows: Set(windows)),
                    metrics: metrics(from: aggregates.filter { $0.key.provider == provider })
                )
            }
        try store.replaceMetrics(replacements)
    }

    private static func process(
        lineData: Data.SubSequence,
        lineNumber: Int,
        windows: [ExactUsageWindow],
        aggregates: inout [AggregateKey: AggregateValue],
        validEventCount: inout Int,
        malformedEventCount: inout Int,
        malformed: inout [MalformedLocalUsageEvent],
        hasFutureTimestampRejection: inout Bool,
        now: Date
    ) throws {
        try Task.checkCancellation()
        guard let line = String(data: lineData, encoding: .utf8) else {
            recordMalformed(LocalUsageEventError.malformedJSON, lineNumber: lineNumber, count: &malformedEventCount, events: &malformed)
            return
        }
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let event: LocalUsageEvent
        do {
            event = try LocalUsageEventParser.parseLine(line)
        } catch let error as LocalUsageEventError {
            recordMalformed(error, lineNumber: lineNumber, count: &malformedEventCount, events: &malformed)
            return
        }
        guard event.timestamp <= now.addingTimeInterval(futureTolerance) else {
            hasFutureTimestampRejection = true
            recordMalformed(LocalUsageEventError.futureTimestamp, lineNumber: lineNumber, count: &malformedEventCount, events: &malformed)
            return
        }
        validEventCount += 1
        try add(event, windows: windows, to: &aggregates)
    }

    private static func recordMalformed(
        _ error: LocalUsageEventError,
        lineNumber: Int,
        count: inout Int,
        events: inout [MalformedLocalUsageEvent]
    ) {
        count += 1
        if events.count < 20 {
            events.append(MalformedLocalUsageEvent(lineNumber: lineNumber, reason: String(describing: error)))
        }
    }

    private static func add(
        _ event: LocalUsageEvent,
        windows: [ExactUsageWindow],
        to aggregates: inout [AggregateKey: AggregateValue]
    ) throws {
        for window in windows {
            try Task.checkCancellation()
            guard event.timestamp >= window.start, event.timestamp < window.end else {
                continue
            }
            let key = AggregateKey(provider: event.provider, window: window, model: event.model, deployment: event.deployment)
            if aggregates[key] == nil, aggregates.count >= maximumAggregateKeys {
                throw LocalUsageEventError.tooManyAggregates
            }
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
                provider: key.provider,
                accountLabel: importedAccountLabel(for: key.provider),
                projectLabel: nil,
                modelLabel: key.model,
                deploymentLabel: key.deployment,
                provenance: .bounded(source: .builtInLocalLog, window: key.window),
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
            throw LocalUsageEventError.tokenCountOverflow
        }
        return sum
    }

    private static func readChunk(from fileHandle: FileHandle) throws -> Data? {
        do {
            return try fileHandle.read(upToCount: 64 * 1024)
        } catch {
            throw LocalUsageEventError.unreadableFile
        }
    }

    private static func isFileNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
