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
}

public struct MalformedAzureUsageEvent: Equatable, Sendable {
    public let lineNumber: Int
    public let reason: String
}

public struct AzureUsageImportResult: Equatable, Sendable {
    public let fileURL: URL
    public let validEventCount: Int
    public let malformedEvents: [MalformedAzureUsageEvent]
    public let failureMessage: String?

    public static func empty(fileURL: URL) -> AzureUsageImportResult {
        AzureUsageImportResult(fileURL: fileURL, validEventCount: 0, malformedEvents: [], failureMessage: nil)
    }

    public static func failed(fileURL: URL, message: String) -> AzureUsageImportResult {
        AzureUsageImportResult(fileURL: fileURL, validEventCount: 0, malformedEvents: [], failureMessage: message)
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

        guard let model = raw.model, !model.isEmpty else {
            throw AzureUsageEventError.missingRequiredField("model")
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
            deployment: raw.deployment,
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

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        var validEvents: [AzureUsageEvent] = []
        var malformed: [MalformedAzureUsageEvent] = []

        for (offset, line) in contents.components(separatedBy: .newlines).enumerated() {
            guard !line.isEmpty else {
                continue
            }
            do {
                validEvents.append(try AzureUsageEventParser.parseLine(line))
            } catch {
                malformed.append(MalformedAzureUsageEvent(lineNumber: offset + 1, reason: String(describing: error)))
            }
        }

        try store.replaceMetrics(
            provider: .azureOpenAI,
            timeWindows: importedWindows,
            with: metrics(from: validEvents, now: now, calendar: calendar)
        )

        return AzureUsageImportResult(fileURL: fileURL, validEventCount: validEvents.count, malformedEvents: malformed, failureMessage: nil)
    }

    private static func metrics(from events: [AzureUsageEvent], now: Date, calendar: Calendar) -> [UsageMetric] {
        [TimeWindow.today, .currentWeek].flatMap { window in
            aggregate(events.filter { window.interval(containing: now, calendar: calendar).contains($0.timestamp) }, timeWindow: window)
        }
    }

    private static func aggregate(_ events: [AzureUsageEvent], timeWindow: TimeWindow) -> [UsageMetric] {
        let groups = Dictionary(grouping: events, by: \.model)

        return groups.values.map { groupedEvents in
            let first = groupedEvents[0]
            let deployments = Set(groupedEvents.compactMap(\.deployment)).sorted()
            return UsageMetric(
                provider: .azureOpenAI,
                accountLabel: importedAccountLabel,
                projectLabel: nil,
                modelLabel: first.model,
                deploymentLabel: deployments.isEmpty ? nil : deployments.joined(separator: ", "),
                timeWindow: timeWindow,
                tokenUsage: TokenUsage(
                    inputTokens: groupedEvents.reduce(0) { $0 + $1.inputTokens },
                    outputTokens: groupedEvents.reduce(0) { $0 + $1.outputTokens }
                ),
                cost: nil,
                limitStatus: .unsupportedByProviderAPI,
                refreshedAt: groupedEvents.map(\.timestamp).max(),
                freshness: .fresh
            )
        }
        .sorted { lhs, rhs in
            return lhs.modelLabel < rhs.modelLabel
        }
    }
}
