import Foundation

public enum CollectorProvider: String, CaseIterable, Sendable {
    case anthropic
    case azureOpenAI
    case openAI
}

public enum CollectorIdentity: Equatable, Sendable {
    case provider(CollectorProvider)
    case customSource(UUID)
}

/// One immutable, normalized usage occurrence. Token values are per-event deltas.
public struct CollectorEventV1: Equatable, Sendable {
    public static let schemaVersion = 1

    public let eventID: UUID
    public let identity: CollectorIdentity
    public let timestamp: Date
    public let model: String
    public let deployment: String?
    public let inputTokens: Int
    public let outputTokens: Int

    public init(eventID: UUID, identity: CollectorIdentity, timestamp: Date, model: String, deployment: String? = nil, inputTokens: Int, outputTokens: Int) {
        self.eventID = eventID
        self.identity = identity
        self.timestamp = timestamp
        self.model = model
        self.deployment = deployment
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum CollectorSchemaError: Error, Equatable, Sendable {
    case requestTooLarge
    case malformedJSON
    case unknownField(String)
    case missingField(String)
    case invalidSchemaVersion
    case invalidEventID
    case invalidIdentity
    case invalidTimestamp
    case invalidLabel(String)
    case invalidAttribution(String)
    case deploymentNotAllowed
    case invalidCounter(String)
}

public enum CollectorSchemaV1 {
    public static let maximumRequestBytes = 16 * 1_024
    public static let maximumLabelBytes = 256

    private static let requiredFields: Set<String> = ["schemaVersion", "eventID", "timestamp", "model", "inputTokens", "outputTokens"]
    private static let allowedFields = requiredFields.union(["provider", "customSourceID", "deployment"])

    public static func decode(_ data: Data) throws -> CollectorEventV1 {
        guard data.count <= maximumRequestBytes else { throw CollectorSchemaError.requestTooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw CollectorSchemaError.malformedJSON }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CollectorSchemaError.malformedJSON
        }
        guard let object = value as? [String: Any] else { throw CollectorSchemaError.malformedJSON }
        if let unknown = Set(object.keys).subtracting(allowedFields).sorted().first {
            throw CollectorSchemaError.unknownField(unknown)
        }
        if let missing = requiredFields.subtracting(object.keys).sorted().first {
            throw CollectorSchemaError.missingField(missing)
        }
        guard integer(object["schemaVersion"]) == CollectorEventV1.schemaVersion else { throw CollectorSchemaError.invalidSchemaVersion }
        guard let eventIDText = object["eventID"] as? String, let eventID = UUID(uuidString: eventIDText) else {
            throw CollectorSchemaError.invalidEventID
        }

        let identity: CollectorIdentity
        switch (object["provider"], object["customSourceID"]) {
        case let (providerText as String, nil):
            guard let provider = CollectorProvider(rawValue: providerText) else { throw CollectorSchemaError.invalidIdentity }
            identity = .provider(provider)
        case let (nil, sourceText as String):
            guard let sourceID = UUID(uuidString: sourceText) else { throw CollectorSchemaError.invalidIdentity }
            identity = .customSource(sourceID)
        default:
            throw CollectorSchemaError.invalidIdentity
        }

        guard let timestampText = object["timestamp"] as? String, let timestamp = parseTimestamp(timestampText) else {
            throw CollectorSchemaError.invalidTimestamp
        }
        let model = try label(object["model"], field: "model")
        let deployment: String?
        if object.keys.contains("deployment") {
            guard identity == .provider(.azureOpenAI) else { throw CollectorSchemaError.deploymentNotAllowed }
            deployment = try label(object["deployment"], field: "deployment")
        } else {
            deployment = nil
        }
        guard let inputTokens = integer(object["inputTokens"]), inputTokens >= 0 else {
            throw CollectorSchemaError.invalidCounter("inputTokens")
        }
        guard let outputTokens = integer(object["outputTokens"]), outputTokens >= 0 else {
            throw CollectorSchemaError.invalidCounter("outputTokens")
        }
        return CollectorEventV1(eventID: eventID, identity: identity, timestamp: timestamp, model: model, deployment: deployment, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    public static func encode(_ event: CollectorEventV1) throws -> Data {
        let unvalidated = try JSONSerialization.data(withJSONObject: object(for: event), options: [.sortedKeys])
        let normalized = try decode(unvalidated)
        return try JSONSerialization.data(withJSONObject: object(for: normalized), options: [.sortedKeys])
    }

    public static func parseTimestamp(_ text: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func object(for event: CollectorEventV1) -> [String: Any] {
        var object: [String: Any] = [
            "schemaVersion": CollectorEventV1.schemaVersion,
            "eventID": event.eventID.uuidString.lowercased(),
            "timestamp": formatTimestamp(event.timestamp),
            "model": event.model,
            "inputTokens": event.inputTokens,
            "outputTokens": event.outputTokens
        ]
        switch event.identity {
        case let .provider(provider): object["provider"] = provider.rawValue
        case let .customSource(sourceID): object["customSourceID"] = sourceID.uuidString.lowercased()
        }
        if let deployment = event.deployment { object["deployment"] = deployment }
        return object
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        let decimal = number.decimalValue
        var source = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard decimal == rounded else { return nil }
        return Int(NSDecimalNumber(decimal: decimal).stringValue)
    }

    private static func label(_ value: Any?, field: String) throws -> String {
        guard let text = value as? String else { throw CollectorSchemaError.invalidLabel(field) }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.lengthOfBytes(using: .utf8) <= maximumLabelBytes,
              normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CollectorSchemaError.invalidLabel(field)
        }
        return normalized
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
