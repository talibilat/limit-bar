import Foundation

public struct CollectorAttribution: Equatable, Hashable, Sendable {
    public let id: String
    public let label: String?

    public init(id: String, label: String? = nil) {
        self.id = id
        self.label = label
    }
}

/// Schema v2 preserves v1 usage semantics and adds only explicit producer attribution.
public struct CollectorEventV2: Equatable, Sendable {
    public static let schemaVersion = 2

    public let eventID: UUID
    public let identity: CollectorIdentity
    public let timestamp: Date
    public let model: String
    public let deployment: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let project: CollectorAttribution?
    public let agent: CollectorAttribution?

    public init(
        eventID: UUID,
        identity: CollectorIdentity,
        timestamp: Date,
        model: String,
        deployment: String? = nil,
        inputTokens: Int,
        outputTokens: Int,
        project: CollectorAttribution? = nil,
        agent: CollectorAttribution? = nil
    ) {
        self.eventID = eventID
        self.identity = identity
        self.timestamp = timestamp
        self.model = model
        self.deployment = deployment
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.project = project
        self.agent = agent
    }
}

enum CollectorEvent: Equatable {
    case v1(CollectorEventV1)
    case v2(CollectorEventV2)

    var eventID: UUID {
        switch self {
        case let .v1(event): event.eventID
        case let .v2(event): event.eventID
        }
    }

    var timestamp: Date {
        switch self {
        case let .v1(event): event.timestamp
        case let .v2(event): event.timestamp
        }
    }
}

enum CollectorSchema {
    static func decode(_ data: Data) throws -> CollectorEvent {
        guard data.count <= CollectorSchemaV1.maximumRequestBytes else { throw CollectorSchemaError.requestTooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorSchemaError.malformedJSON
        }
        guard object.keys.contains("schemaVersion") else {
            return .v1(try CollectorSchemaV1.decode(data))
        }
        switch integer(object["schemaVersion"]) {
        case CollectorEventV1.schemaVersion: return .v1(try CollectorSchemaV1.decode(data))
        case CollectorEventV2.schemaVersion: return .v2(try CollectorSchemaV2.decode(data))
        default: throw CollectorSchemaError.invalidSchemaVersion
        }
    }

    static func encode(_ event: CollectorEvent) throws -> Data {
        switch event {
        case let .v1(event): try CollectorSchemaV1.encode(event)
        case let .v2(event): try CollectorSchemaV2.encode(event)
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        return Int(exactly: number)
    }
}

public enum CollectorSchemaV2 {
    public static let maximumRequestBytes = CollectorSchemaV1.maximumRequestBytes
    public static let maximumAttributionBytes = 64

    private static let attributionFields: Set<String> = ["projectID", "projectLabel", "agentID", "agentLabel"]
    private static let v1Fields: Set<String> = [
        "schemaVersion", "eventID", "provider", "customSourceID", "timestamp", "model", "deployment", "inputTokens", "outputTokens"
    ]

    public static func decode(_ data: Data) throws -> CollectorEventV2 {
        guard data.count <= maximumRequestBytes else { throw CollectorSchemaError.requestTooLarge }
        guard String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorSchemaError.malformedJSON
        }
        if let unknown = Set(object.keys).subtracting(v1Fields.union(attributionFields)).sorted().first {
            throw CollectorSchemaError.unknownField(unknown)
        }
        guard let version = integer(object["schemaVersion"]), version == CollectorEventV2.schemaVersion else {
            throw CollectorSchemaError.invalidSchemaVersion
        }

        var base = object
        base["schemaVersion"] = CollectorEventV1.schemaVersion
        attributionFields.forEach { base.removeValue(forKey: $0) }
        let baseEvent = try CollectorSchemaV1.decode(try JSONSerialization.data(withJSONObject: base))
        let project = try attribution(in: object, idField: "projectID", labelField: "projectLabel")
        let agent = try attribution(in: object, idField: "agentID", labelField: "agentLabel")
        return CollectorEventV2(
            eventID: baseEvent.eventID,
            identity: baseEvent.identity,
            timestamp: baseEvent.timestamp,
            model: baseEvent.model,
            deployment: baseEvent.deployment,
            inputTokens: baseEvent.inputTokens,
            outputTokens: baseEvent.outputTokens,
            project: project,
            agent: agent
        )
    }

    public static func encode(_ event: CollectorEventV2) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": CollectorEventV2.schemaVersion,
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
        add(event.project, prefix: "project", to: &object)
        add(event.agent, prefix: "agent", to: &object)
        let unvalidated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let normalized = try decode(unvalidated)
        if normalized != event {
            return try encode(normalized)
        }
        return unvalidated
    }

    private static func attribution(in object: [String: Any], idField: String, labelField: String) throws -> CollectorAttribution? {
        let hasID = object.keys.contains(idField)
        let hasLabel = object.keys.contains(labelField)
        guard hasID else {
            if hasLabel { throw CollectorSchemaError.invalidAttribution(labelField) }
            return nil
        }
        guard let identifier = object[idField] as? String, validIdentifier(identifier), !credentialLike(identifier) else {
            throw CollectorSchemaError.invalidAttribution(idField)
        }
        var label: String?
        if hasLabel {
            guard let value = object[labelField] as? String, validLabel(value), !credentialLike(value) else {
                throw CollectorSchemaError.invalidAttribution(labelField)
            }
            label = value
        }
        return CollectorAttribution(id: identifier, label: label)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumAttributionBytes, value.unicodeScalars.allSatisfy(\.isASCII),
              value.first?.isASCIIAlphaNumeric == true else { return false }
        return value.allSatisfy { $0.isASCIIAlphaNumeric || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private static func validLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumAttributionBytes, value.unicodeScalars.allSatisfy(\.isASCII),
              value.first?.isASCIIAlphaNumeric == true, value.last?.isASCIIAlphaNumeric == true else { return false }
        return value.allSatisfy { $0.isASCIIAlphaNumeric || " ._()-".contains($0) }
    }

    private static func credentialLike(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("sk-") || lower.hasPrefix("ghp_") || lower.hasPrefix("github_pat_")
            || lower.hasPrefix("bearer ") || lower.hasPrefix("akia")
    }

    private static func add(_ attribution: CollectorAttribution?, prefix: String, to object: inout [String: Any]) {
        guard let attribution else { return }
        object["\(prefix)ID"] = attribution.id
        if let label = attribution.label { object["\(prefix)Label"] = label }
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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
}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) } == true
    }
}
