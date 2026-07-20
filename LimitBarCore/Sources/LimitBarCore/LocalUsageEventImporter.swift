import CryptoKit
import Foundation

public struct LocalUsageEvent: Equatable, Sendable {
    public let eventID: UUID?
    public let provider: ProviderKind
    public let timestamp: Date
    public let model: String
    public let deployment: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let project: CollectorAttribution?
    public let agent: CollectorAttribution?
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
    case noValidEvents(diagnostics: [MalformedLocalUsageEvent], rejectedLineCount: Int, hasFutureTimestampRejection: Bool)
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
    public let attributionBreakdowns: [ObservedLocalAttributionBreakdown]
    public let sourceRevision: String?
    public let sixHourAggregates: [HistoricalSixHourUsageAggregate]

    public static func empty(fileURL: URL) -> LocalUsageImportResult {
        LocalUsageImportResult(fileURL: fileURL, validEventCount: 0, malformedEventCount: 0, malformedEvents: [], failureMessage: nil, hasFutureTimestampRejection: false, attributionBreakdowns: [], sourceRevision: sha256(Data()), sixHourAggregates: [])
    }

    public static func failed(fileURL: URL, message: String) -> LocalUsageImportResult {
        LocalUsageImportResult(fileURL: fileURL, validEventCount: 0, malformedEventCount: 0, malformedEvents: [], failureMessage: message, hasFutureTimestampRejection: false, attributionBreakdowns: [], sourceRevision: nil, sixHourAggregates: [])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        let data = Data(line.utf8)

        if CollectorSchemaV2.hasStrictSchema(in: data) {
            guard let event = try? CollectorSchemaV2.decode(data), case let .provider(provider) = event.identity,
                  let normalizedProvider = ProviderKind(rawValue: provider.rawValue) else {
                throw LocalUsageEventError.malformedJSON
            }
            return LocalUsageEvent(
                eventID: event.eventID,
                provider: normalizedProvider,
                timestamp: event.timestamp,
                model: event.model,
                deployment: event.deployment,
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                project: event.project,
                agent: event.agent
            )
        }
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: data) else {
            throw LocalUsageEventError.malformedJSON
        }

        guard let rawProvider = raw.provider,
              let provider = ProviderKind(rawValue: rawProvider),
              LocalUsageEventImporter.supportedProviders.contains(provider) else {
            throw LocalUsageEventError.unsupportedProvider
        }

        guard let timestampText = raw.timestamp,
              let timestamp = CollectorSchemaV1.parseTimestamp(timestampText) else {
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
            eventID: nil,
            provider: provider,
            timestamp: timestamp,
            model: model,
            deployment: deployment,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            project: nil,
            agent: nil
        )
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

    private struct SixHourAggregateKey: Hashable {
        let provider: ProviderKind
        let window: HistoricalSixHourUsageWindow
        let model: String
    }

    private struct AttributionKey: Hashable {
        let provider: ProviderKind
        let window: ExactUsageWindow
        let model: String
        let deployment: String?
        let project: CollectorAttribution?
        let agent: CollectorAttribution?
    }

    private struct AttributionValue {
        var inputTokens: Int
        var outputTokens: Int
        var eventIDs: [UUID]
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
        LimitBarFileLocations(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            applicationSupportDirectory: applicationSupportDirectory
        ).usageEventsFile
    }

    public static func usageEventsURL(fileManager: FileManager = .default) throws -> URL {
        try LimitBarFileLocations.production(fileManager: fileManager).usageEventsFile
    }

    @discardableResult
    public static func importEvents(
        from fileURL: URL,
        to store: SQLiteUsageMetricStore,
        now: Date,
        calendar: Calendar
    ) throws -> LocalUsageImportResult {
        try importEvents(from: fileURL, to: store, now: now, calendar: calendar, onChunkRead: nil)
    }

    static func importEvents(
        from fileURL: URL,
        to store: SQLiteUsageMetricStore,
        now: Date,
        calendar: Calendar,
        onChunkRead: ((Int) throws -> Void)?
    ) throws -> LocalUsageImportResult {
        try Task.checkCancellation()
        let windows = try CurrentUsageWindows.resolve(at: now, calendar: calendar)
        let importedWindows = [windows.today, windows.currentWeek]
        let fileHandle: FileHandle
        do {
            let currentFileURL = URL(fileURLWithPath: fileURL.path)
            let values = try currentFileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw LocalUsageEventError.notRegularFile
            }
            guard let fileSize = values.fileSize, fileSize <= maximumFileByteCount else {
                throw LocalUsageEventError.fileTooLarge
            }
            fileHandle = try FileHandle(forReadingFrom: currentFileURL)
        } catch {
            guard isFileNotFound(error) else {
                if let typedError = error as? LocalUsageEventError {
                    throw typedError
                }
                throw LocalUsageEventError.unreadableFile
            }
            try Task.checkCancellation()
            let empty = LocalUsageImportResult.empty(fileURL: fileURL)
            try replaceImportedMetrics(
                in: store,
                windows: importedWindows,
                aggregates: [:],
                sourceRevision: empty.sourceRevision,
                expectedAttributionBreakdownCount: 0
            )
            return empty
        }
        defer { try? fileHandle.close() }
        var aggregates: [AggregateKey: AggregateValue] = [:]
        var sixHourAggregates: [SixHourAggregateKey: TokenUsage] = [:]
        var attributionAggregates: [AttributionKey: AttributionValue] = [:]
        var validEventCount = 0
        var malformedEventCount = 0
        var malformed: [MalformedLocalUsageEvent] = []
        var buffer = Data()
        var lineNumber = 1
        var discardingOverlongLine = false
        var bytesRead = 0
        var hasFutureTimestampRejection = false
        var hasher = SHA256()

        while let chunk = try readChunk(from: fileHandle), !chunk.isEmpty {
            try Task.checkCancellation()
            bytesRead = try checkedSum(bytesRead, chunk.count)
            guard bytesRead <= maximumFileByteCount else {
                throw LocalUsageEventError.fileTooLarge
            }
            hasher.update(data: chunk)
            try onChunkRead?(bytesRead)
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
                        sixHourAggregates: &sixHourAggregates,
                        attributionAggregates: &attributionAggregates,
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
                sixHourAggregates: &sixHourAggregates,
                attributionAggregates: &attributionAggregates,
                validEventCount: &validEventCount,
                malformedEventCount: &malformedEventCount,
                malformed: &malformed,
                hasFutureTimestampRejection: &hasFutureTimestampRejection,
                now: now
            )
        }

        if bytesRead > 0, validEventCount == 0, malformedEventCount > 0 {
            throw LocalUsageEventError.noValidEvents(
                diagnostics: malformed,
                rejectedLineCount: malformedEventCount,
                hasFutureTimestampRejection: hasFutureTimestampRejection
            )
        }

        try Task.checkCancellation()
        let sourceRevision = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let attributionBreakdowns = breakdowns(from: attributionAggregates)
        try replaceImportedMetrics(
            in: store,
            windows: importedWindows,
            aggregates: aggregates,
            sourceRevision: sourceRevision,
            expectedAttributionBreakdownCount: attributionBreakdowns.count
        )

        return LocalUsageImportResult(
            fileURL: fileURL,
            validEventCount: validEventCount,
            malformedEventCount: malformedEventCount,
            malformedEvents: malformed,
            failureMessage: nil,
            hasFutureTimestampRejection: hasFutureTimestampRejection,
            attributionBreakdowns: attributionBreakdowns,
            sourceRevision: sourceRevision,
            sixHourAggregates: try historicalAggregates(from: sixHourAggregates)
        )
    }

    private static func replaceImportedMetrics(
        in store: SQLiteUsageMetricStore,
        windows: [ExactUsageWindow],
        aggregates: [AggregateKey: AggregateValue],
        sourceRevision: String?,
        expectedAttributionBreakdownCount: Int
    ) throws {
        let replacements = ProviderKind.orderedCases
            .filter { supportedProviders.contains($0) }
            .map { provider in
                UsageScopedReplacement(
                    scope: UsageReplacementScope(provider: provider, source: .builtInLocalLog, windows: Set(windows)),
                    metrics: metrics(from: aggregates.filter { $0.key.provider == provider })
                )
            }
        try store.replaceMetrics(
            replacements,
            sourceRevision: sourceRevision,
            expectedAttributionBreakdownCount: expectedAttributionBreakdownCount
        )
    }

    private static func process(
        lineData: Data.SubSequence,
        lineNumber: Int,
        windows: [ExactUsageWindow],
        aggregates: inout [AggregateKey: AggregateValue],
        sixHourAggregates: inout [SixHourAggregateKey: TokenUsage],
        attributionAggregates: inout [AttributionKey: AttributionValue],
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
        try add(
            event,
            windows: windows,
            to: &aggregates,
            sixHourAggregates: &sixHourAggregates,
            attributionAggregates: &attributionAggregates
        )
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
        to aggregates: inout [AggregateKey: AggregateValue],
        sixHourAggregates: inout [SixHourAggregateKey: TokenUsage],
        attributionAggregates: inout [AttributionKey: AttributionValue]
    ) throws {
        let sixHourWindow = try HistoricalSixHourUsageWindow.containing(event.timestamp)
        let sixHourKey = SixHourAggregateKey(provider: event.provider, window: sixHourWindow, model: event.model)
        if sixHourAggregates[sixHourKey] == nil,
           aggregates.count + attributionAggregates.count + sixHourAggregates.count == maximumAggregateKeys {
            throw LocalUsageEventError.tooManyAggregates
        }
        let sixHourValue = sixHourAggregates[sixHourKey] ?? TokenUsage(inputTokens: 0, outputTokens: 0)
        let sixHourInput = try checkedSum(sixHourValue.inputTokens, event.inputTokens)
        let sixHourOutput = try checkedSum(sixHourValue.outputTokens, event.outputTokens)
        _ = try checkedSum(sixHourInput, sixHourOutput)
        sixHourAggregates[sixHourKey] = TokenUsage(inputTokens: sixHourInput, outputTokens: sixHourOutput)

        for window in windows {
            try Task.checkCancellation()
            guard event.timestamp >= window.start, event.timestamp < window.end else {
                continue
            }
            let key = AggregateKey(provider: event.provider, window: window, model: event.model, deployment: event.deployment)
            let attributionKey: AttributionKey? = if event.project != nil || event.agent != nil, event.eventID != nil {
                AttributionKey(
                    provider: event.provider,
                    window: window,
                    model: event.model,
                    deployment: event.deployment,
                    project: event.project,
                    agent: event.agent
                )
            } else {
                nil
            }
            let addedKeyCount = (aggregates[key] == nil ? 1 : 0)
                + (attributionKey.map { attributionAggregates[$0] == nil ? 1 : 0 } ?? 0)
            if aggregates.count + attributionAggregates.count + sixHourAggregates.count + addedKeyCount > maximumAggregateKeys {
                throw LocalUsageEventError.tooManyAggregates
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

    private static func breakdowns(from aggregates: [AttributionKey: AttributionValue]) -> [ObservedLocalAttributionBreakdown] {
        aggregates.map { key, value in
            ObservedLocalAttributionBreakdown(
                source: .builtInLocalLog,
                provider: key.provider,
                window: key.window,
                model: key.model,
                deployment: key.deployment,
                project: key.project,
                agent: key.agent,
                tokenUsage: TokenUsage(inputTokens: value.inputTokens, outputTokens: value.outputTokens),
                eventIDs: value.eventIDs.sorted { $0.uuidString < $1.uuidString },
                observedAt: value.latestTimestamp
            )
        }.sorted {
            ($0.window.start, $0.provider.rawValue, $0.model, $0.project?.id ?? "", $0.agent?.id ?? "")
                < ($1.window.start, $1.provider.rawValue, $1.model, $1.project?.id ?? "", $1.agent?.id ?? "")
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

    private static func historicalAggregates(
        from aggregates: [SixHourAggregateKey: TokenUsage]
    ) throws -> [HistoricalSixHourUsageAggregate] {
        try aggregates.map { key, value in
            try HistoricalSixHourUsageAggregate(
                provider: key.provider,
                source: .builtInLocalLog,
                model: key.model,
                window: key.window,
                tokenUsage: value
            )
        }.sorted {
            ($0.window.start, $0.provider.rawValue, $0.model)
                < ($1.window.start, $1.provider.rawValue, $1.model)
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
