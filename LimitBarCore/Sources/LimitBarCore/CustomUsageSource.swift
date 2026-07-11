import Foundation

// A user-configured local log file for a tool LimitBar has no built-in
// adapter for (Aider, Cursor, Windsurf, or anything else that can write a
// line of JSON per response). Each source gets its own display name and is
// read fresh on every popover load rather than persisted to SQLite, since
// these are arbitrary external files LimitBar does not own.
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

// Deliberately narrower than LocalUsageEventParser: no provider or deployment
// field, because a custom source is already scoped to one named tool by
// virtue of being its own configured file.
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
        if let date = fractionalFormatter.date(from: text) {
            return date
        }
        return ISO8601DateFormatter().date(from: text)
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

    private static let windows: [TimeWindow] = [.today, .currentWeek]

    // Returns an empty array (never throws) when the file does not exist,
    // since an unconfigured or not-yet-used custom source should simply be
    // absent from the Usage tab, not shown as an error.
    public static func metrics(
        from fileURL: URL,
        sourceName: String,
        now: Date,
        calendar: Calendar,
        fileManager: FileManager = .default
    ) -> [UsageMetric] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        var aggregates: [AggregateKey: AggregateValue] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = try? CustomUsageEventParser.parseLine(String(line)) else {
                continue
            }
            for window in windows {
                let interval = window.interval(containing: now, calendar: calendar)
                guard event.timestamp >= interval.start, event.timestamp < interval.end else {
                    continue
                }
                let key = AggregateKey(timeWindow: window, model: event.model)
                var value = aggregates[key] ?? AggregateValue(inputTokens: 0, outputTokens: 0, latestTimestamp: event.timestamp)
                value.inputTokens += event.inputTokens
                value.outputTokens += event.outputTokens
                value.latestTimestamp = max(value.latestTimestamp, event.timestamp)
                aggregates[key] = value
            }
        }

        return aggregates.map { key, value in
            UsageMetric(
                provider: .custom,
                accountLabel: sourceName,
                projectLabel: nil,
                modelLabel: key.model,
                deploymentLabel: nil,
                timeWindow: key.timeWindow,
                tokenUsage: TokenUsage(inputTokens: value.inputTokens, outputTokens: value.outputTokens),
                cost: nil,
                limitStatus: .unsupportedByProviderAPI,
                refreshedAt: value.latestTimestamp,
                freshness: .fresh
            )
        }
    }
}
