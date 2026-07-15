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
      limitbar-collect --schema-version 2 --event-id UUID --provider anthropic|azureOpenAI|openAI --timestamp ISO8601 --model LABEL --input-tokens N --output-tokens N [--project-id ID] [--project-label LABEL] [--agent-id ID] [--agent-label LABEL] [--deployment LABEL] [--output PATH]
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
        let attributionOptions = ["--project-id", "--project-label", "--agent-id", "--agent-label"]
        let hasAttribution = attributionOptions.contains { values[$0] != nil }
        let schemaVersion: Int
        if let explicitVersion = values["--schema-version"] {
            guard explicitVersion == "1" || explicitVersion == "2", let parsed = Int(explicitVersion) else {
                throw CollectorCommandError.usage("Unsupported --schema-version")
            }
            schemaVersion = parsed
        } else {
            schemaVersion = CollectorEventV1.schemaVersion
        }
        guard !hasAttribution || schemaVersion == CollectorEventV2.schemaVersion else {
            throw CollectorCommandError.usage("Attribution options require --schema-version 2")
        }
        let result: CollectorWriteResult
        if schemaVersion == CollectorEventV2.schemaVersion {
            let project = try attribution(id: values["--project-id"], label: values["--project-label"], field: "project")
            let agent = try attribution(id: values["--agent-id"], label: values["--agent-label"], field: "agent")
            let event = CollectorEventV2(
                eventID: eventID, identity: identity, timestamp: timestamp, model: try required("--model", in: values),
                deployment: values["--deployment"], inputTokens: inputTokens, outputTokens: outputTokens,
                project: project, agent: agent
            )
            result = try CollectorWriter().append(event, to: outputURL)
        } else {
            let event = CollectorEventV1(eventID: eventID, identity: identity, timestamp: timestamp, model: try required("--model", in: values), deployment: values["--deployment"], inputTokens: inputTokens, outputTokens: outputTokens)
            result = try CollectorWriter().append(event, to: outputURL)
        }
        switch result {
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
        let allowed: Set<String> = [
            "--schema-version", "--event-id", "--provider", "--custom-source-id", "--timestamp", "--model", "--deployment",
            "--input-tokens", "--output-tokens", "--project-id", "--project-label", "--agent-id", "--agent-label", "--output"
        ]
        if let unknown = Set(values.keys).subtracting(allowed).sorted().first { throw CollectorCommandError.usage("Unknown option: \(unknown)") }
        return values
    }

    private static func required(_ key: String, in values: [String: String]) throws -> String {
        guard let value = values[key] else { throw CollectorCommandError.usage("Missing required option: \(key)") }
        return value
    }

    private static func attribution(id: String?, label: String?, field: String) throws -> CollectorAttribution? {
        guard let id else {
            guard label == nil else { throw CollectorCommandError.usage("--\(field)-label requires --\(field)-id") }
            return nil
        }
        return CollectorAttribution(id: id, label: label)
    }
}
