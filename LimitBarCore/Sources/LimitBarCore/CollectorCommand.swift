import Foundation

public enum CollectorCommandError: Error, CustomStringConvertible, Equatable, Sendable {
    case usage(String)

    public var description: String {
        switch self {
        case let .usage(message): message
        }
    }
}

public enum CollectorCommand {
    public static let usage = """
    Usage:
      limitbar-collect --event-id UUID --provider anthropic|azureOpenAI|openAI --timestamp ISO8601 --model LABEL --input-tokens N --output-tokens N [--deployment LABEL] [--output PATH]
      limitbar-collect --event-id UUID --custom-source-id UUID --timestamp ISO8601 --model LABEL --input-tokens N --output-tokens N --output PATH

    Token values are per-event deltas. Persist the UUID before submission and reuse it
    only when retrying the identical event.
    """

    public static func run(_ arguments: [String]) throws -> String {
        if arguments == ["--help"] { return usage }
        let values = try parseArguments(arguments)
        guard let eventID = UUID(uuidString: try required("--event-id", in: values)) else { throw CollectorCommandError.usage("Invalid --event-id UUID") }
        let identity: CollectorIdentity
        switch (values["--provider"], values["--custom-source-id"]) {
        case let (providerName?, nil):
            guard let provider = CollectorProvider(rawValue: providerName) else { throw CollectorCommandError.usage("Unsupported --provider") }
            identity = .provider(provider)
        case let (nil, sourceText?):
            guard let sourceID = UUID(uuidString: sourceText) else { throw CollectorCommandError.usage("Invalid --custom-source-id UUID") }
            identity = .customSource(sourceID)
        default:
            throw CollectorCommandError.usage("Specify exactly one of --provider or --custom-source-id")
        }
        guard let timestamp = CollectorSchemaV1.parseTimestamp(try required("--timestamp", in: values)) else { throw CollectorCommandError.usage("Invalid --timestamp") }
        guard let inputTokens = Int(try required("--input-tokens", in: values)), let outputTokens = Int(try required("--output-tokens", in: values)) else {
            throw CollectorCommandError.usage("Token counters must be integers")
        }
        let outputURL: URL
        if let path = values["--output"] {
            outputURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        } else if case .provider = identity {
            outputURL = try LocalUsageEventImporter.usageEventsURL()
        } else {
            throw CollectorCommandError.usage("Custom sources require --output with their configured JSONL path")
        }
        let event = CollectorEventV1(eventID: eventID, identity: identity, timestamp: timestamp, model: try required("--model", in: values), deployment: values["--deployment"], inputTokens: inputTokens, outputTokens: outputTokens)
        switch try CollectorWriter().append(event, to: outputURL) {
        case .appended: return "accepted"
        case .duplicate: return "duplicate"
        case .appendedAfterRotation: return "accepted (rotated)"
        }
    }

    private static func parseArguments(_ arguments: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else { throw CollectorCommandError.usage("Expected --name value arguments.\n\(usage)") }
            guard values[key] == nil else { throw CollectorCommandError.usage("Duplicate option: \(key)") }
            values[key] = arguments[index + 1]
            index += 2
        }
        let allowed: Set<String> = ["--event-id", "--provider", "--custom-source-id", "--timestamp", "--model", "--deployment", "--input-tokens", "--output-tokens", "--output"]
        if let unknown = Set(values.keys).subtracting(allowed).sorted().first { throw CollectorCommandError.usage("Unknown option: \(unknown)") }
        return values
    }

    private static func required(_ key: String, in values: [String: String]) throws -> String {
        guard let value = values[key] else { throw CollectorCommandError.usage("Missing required option: \(key)") }
        return value
    }
}
