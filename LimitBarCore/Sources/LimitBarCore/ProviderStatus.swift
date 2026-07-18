import Foundation

public enum ProviderStatusService: String, Codable, CaseIterable, Equatable, Sendable {
    case anthropic
    case openAI = "openai"

    public var endpoint: URL {
        switch self {
        case .anthropic: URL(string: "https://status.anthropic.com/api/v2/summary.json")!
        case .openAI: URL(string: "https://status.openai.com/api/v2/summary.json")!
        }
    }

    public func isApproved(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443 else { return false }
        return url.host?.lowercased() == endpoint.host?.lowercased()
    }
}

public enum ProviderStatusProduct: String, Codable, CaseIterable, Equatable, Sendable {
    case claudeCode = "claude_code"
    case anthropicAPI = "anthropic_api"
    case claudeConsole = "claude_console"
    case claudeAI = "claude_ai"
    case codex = "codex"
    case openAIAPI = "openai_api"
    case codexVSCode = "codex_vscode"
    case codexChatGPT = "codex_chatgpt"
}

public enum ProviderIncidentImpact: String, Codable, Equatable, Sendable {
    case none, minor, major, critical, unknown
}

public enum ProviderIncidentStatus: String, Codable, Equatable, Sendable {
    case investigating, identified, monitoring, resolved, postmortem, unknown
}

public enum ProviderComponentStatus: String, Codable, Equatable, Sendable {
    case operational, degradedPerformance = "degraded_performance", partialOutage = "partial_outage"
    case majorOutage = "major_outage", underMaintenance = "under_maintenance", unknown
}

public struct NormalizedProviderIncident: Codable, Equatable, Identifiable, Sendable {
    public static let modelVersion = 1

    public let modelVersion: Int
    public let id: String
    public let service: ProviderStatusService
    public let products: [ProviderStatusProduct]
    public let impact: ProviderIncidentImpact
    public let status: ProviderIncidentStatus
    public let startedAt: Date
    public let updatedAt: Date
    public let resolvedAt: Date?
    public let componentStates: [ProviderStatusProduct: ProviderComponentStatus]
    public let latestUpdateState: ProviderIncidentStatus

    public init(
        id: String,
        service: ProviderStatusService,
        products: [ProviderStatusProduct],
        impact: ProviderIncidentImpact,
        status: ProviderIncidentStatus,
        startedAt: Date,
        updatedAt: Date,
        resolvedAt: Date?,
        componentStates: [ProviderStatusProduct: ProviderComponentStatus],
        latestUpdateState: ProviderIncidentStatus
    ) {
        modelVersion = Self.modelVersion
        self.id = id
        self.service = service
        self.products = products
        self.impact = impact
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
        self.componentStates = componentStates
        self.latestUpdateState = latestUpdateState
    }

    public func overlaps(_ instant: Date) -> Bool {
        startedAt <= instant && (resolvedAt.map { instant < $0 } ?? true)
    }

    public func isQualifiedActive(at instant: Date) -> Bool {
        let activeStatuses: Set<ProviderIncidentStatus> = [.investigating, .identified, .monitoring]
        let activeComponentStatuses: Set<ProviderComponentStatus> = [.degradedPerformance, .partialOutage, .majorOutage]
        guard [.minor, .major, .critical].contains(impact), activeStatuses.contains(status),
              activeStatuses.contains(latestUpdateState),
              resolvedAt == nil, startedAt <= instant, updatedAt <= instant else { return false }
        return componentStates.values.contains { activeComponentStatuses.contains($0) }
    }
}

public enum ProviderStatusCheckOutcome: String, Codable, Equatable, Sendable {
    case incidentsPublished = "incidents_published"
    case noPublishedIncident = "no_published_incident"
    case unsupportedComponent = "unsupported_component"
    case endpointUnavailable = "endpoint_unavailable"
    case malformedPayload = "malformed_payload"
    case unsupportedSchema = "unsupported_schema"
}

public struct ProviderStatusObservation: Codable, Equatable, Identifiable, Sendable {
    public static let modelVersion = 1

    public let modelVersion: Int
    public let id: UUID
    public let service: ProviderStatusService
    public let checkedAt: Date
    public let outcome: ProviderStatusCheckOutcome
    public let incidents: [NormalizedProviderIncident]
    public let unsupportedComponentCount: Int

    public init(
        id: UUID = UUID(),
        service: ProviderStatusService,
        checkedAt: Date,
        outcome: ProviderStatusCheckOutcome,
        incidents: [NormalizedProviderIncident] = [],
        unsupportedComponentCount: Int = 0
    ) {
        modelVersion = Self.modelVersion
        self.id = id
        self.service = service
        self.checkedAt = checkedAt
        self.outcome = outcome
        self.incidents = Array(incidents.prefix(ProviderStatusLimits.maximumIncidentsPerObservation))
        self.unsupportedComponentCount = min(max(0, unsupportedComponentCount), ProviderStatusLimits.maximumComponents)
    }
}

public enum ProviderStatusLimits {
    public static let maximumResponseBytes = 1_048_576
    public static let maximumComponents = 128
    public static let maximumIncidentsPerObservation = 64
    public static let maximumUpdatesPerIncident = 32
    public static let maximumIdentifierLength = 160
    public static let maximumStoredObservations = 96
    public static let retention: TimeInterval = 14 * 86_400
    public static let freshness: TimeInterval = 6 * 3_600
    public static let subscriptionCadence: TimeInterval = 6 * 3_600
}

public enum ProviderStatusNormalizationError: Error, Equatable {
    case malformedPayload
    case unsupportedSchema
}

public enum ProviderStatusNormalizer {
    private struct Summary: Decodable {
        struct Component: Decodable { let id: String; let name: String; let status: String }
        struct Incident: Decodable {
            struct Update: Decodable { let status: String; let created_at: String; let updated_at: String? }
            let id: String
            let impact: String
            let status: String
            let created_at: String
            let updated_at: String
            let resolved_at: String?
            let components: [Component]?
            let incident_updates: [Update]?
        }
        let components: [Component]
        let incidents: [Incident]
    }

    public static func normalize(
        _ data: Data,
        service: ProviderStatusService,
        checkedAt: Date
    ) throws -> ProviderStatusObservation {
        guard !data.isEmpty, data.count <= ProviderStatusLimits.maximumResponseBytes else {
            throw ProviderStatusNormalizationError.malformedPayload
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderStatusNormalizationError.malformedPayload
        }
        let required: Set<String> = ["components", "incidents"]
        guard required.isSubset(of: Set(root.keys)) else {
            throw ProviderStatusNormalizationError.unsupportedSchema
        }
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data),
              summary.components.count <= ProviderStatusLimits.maximumComponents,
              summary.incidents.count <= ProviderStatusLimits.maximumIncidentsPerObservation else {
            throw ProviderStatusNormalizationError.malformedPayload
        }
        let supportedComponents = summary.components.compactMap { component -> (String, ProviderStatusProduct, ProviderComponentStatus)? in
            guard bounded(component.id), bounded(component.name), let product = product(id: component.id, name: component.name, service: service) else { return nil }
            return (component.id, product, componentStatus(component.status))
        }
        let componentByID = Dictionary(uniqueKeysWithValues: supportedComponents.map { ($0.0, ($0.1, $0.2)) })
        let unsupportedCount = summary.components.count - supportedComponents.count
        var normalized: [NormalizedProviderIncident] = []
        for incident in summary.incidents {
            guard bounded(incident.id),
                  let startedAt = timestamp(incident.created_at),
                  let updatedAt = timestamp(incident.updated_at),
                  startedAt <= updatedAt,
                  incident.incident_updates?.count ?? 0 <= ProviderStatusLimits.maximumUpdatesPerIncident else {
                throw ProviderStatusNormalizationError.malformedPayload
            }
            let mapped = (incident.components ?? []).compactMap { componentByID[$0.id] }
            let products = Array(Set(mapped.map(\.0))).sorted { $0.rawValue < $1.rawValue }
            let resolvedAt = try incident.resolved_at.map {
                guard let value = timestamp($0), value >= startedAt else { throw ProviderStatusNormalizationError.malformedPayload }
                return value
            }
            let updates = incident.incident_updates ?? []
            let validatedUpdates = try updates.map { update -> (timestamp: Date, status: ProviderIncidentStatus) in
                guard let createdAt = timestamp(update.created_at) else {
                    throw ProviderStatusNormalizationError.malformedPayload
                }
                let updateAt: Date
                if let value = update.updated_at {
                    guard let parsed = timestamp(value), parsed >= createdAt else {
                        throw ProviderStatusNormalizationError.malformedPayload
                    }
                    updateAt = parsed
                } else {
                    updateAt = createdAt
                }
                return (updateAt, incidentStatus(update.status))
            }
            let latestUpdate = validatedUpdates.max { $0.timestamp < $1.timestamp }
            normalized.append(NormalizedProviderIncident(
                id: incident.id,
                service: service,
                products: products,
                impact: impact(incident.impact),
                status: incidentStatus(incident.status),
                startedAt: startedAt,
                updatedAt: updatedAt,
                resolvedAt: resolvedAt,
                componentStates: Dictionary(mapped, uniquingKeysWith: { _, latest in latest }),
                latestUpdateState: latestUpdate?.status ?? incidentStatus(incident.status)
            ))
        }
        let outcome: ProviderStatusCheckOutcome
        if normalized.contains(where: { !$0.products.isEmpty }) { outcome = .incidentsPublished }
        else if !summary.incidents.isEmpty || (supportedComponents.isEmpty && unsupportedCount > 0) { outcome = .unsupportedComponent }
        else { outcome = .noPublishedIncident }
        return ProviderStatusObservation(
            service: service,
            checkedAt: checkedAt,
            outcome: outcome,
            incidents: normalized.sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) },
            unsupportedComponentCount: unsupportedCount
        )
    }

    private static func product(id: String, name: String, service: ProviderStatusService) -> ProviderStatusProduct? {
        let value = name.lowercased().replacingOccurrences(of: "-", with: " ")
        switch service {
        case .anthropic:
            if value.contains("claude code") { return .claudeCode }
            if value.contains("claude api") || value == "api" { return .anthropicAPI }
            if value.contains("console") { return .claudeConsole }
            if value.contains("claude.ai") || value.contains("claude ai") { return .claudeAI }
        case .openAI:
            let ids: [String: ProviderStatusProduct] = [
                "01KMP3KP5MGE23B80K1EK4S8PV": .codex,
                "01KMP3KP5M8X0EBTVW6KN327EE": .codexVSCode,
                "01KMKFAMWKQ81YWSE1Z18R6VHR": .codexChatGPT,
            ]
            if let product = ids[id] { return product }
            let names: [String: ProviderStatusProduct] = [
                "Codex API": .codex,
                "VS Code extension": .codexVSCode,
                "Codex in ChatGPT Desktop": .codexChatGPT,
                "API": .openAIAPI,
                "OpenAI API": .openAIAPI,
            ]
            return names[name]
        }
        return nil
    }

    private static func impact(_ value: String) -> ProviderIncidentImpact {
        ProviderIncidentImpact(rawValue: value) ?? .unknown
    }

    private static func incidentStatus(_ value: String) -> ProviderIncidentStatus {
        ProviderIncidentStatus(rawValue: value) ?? .unknown
    }

    private static func componentStatus(_ value: String) -> ProviderComponentStatus {
        ProviderComponentStatus(rawValue: value) ?? .unknown
    }

    private static func timestamp(_ value: String) -> Date? { CollectorSchemaV1.parseTimestamp(value) }
    private static func bounded(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= ProviderStatusLimits.maximumIdentifierLength }
}

struct OfficialProviderStatusClient: Sendable {
    private let httpClient: any HTTPClient
    public let service: ProviderStatusService

    init(service: ProviderStatusService, httpClient: any HTTPClient) {
        self.service = service
        self.httpClient = httpClient
    }

    func check(now: Date = Date()) async -> ProviderStatusObservation {
        let request = HTTPRequest(url: service.endpoint, method: .get, headers: [:], body: nil)
        guard service.isApproved(url: request.url) else {
            return ProviderStatusObservation(service: service, checkedAt: now, outcome: .endpointUnavailable)
        }
        do {
            let response = try await httpClient.send(request)
            guard response.statusCode == 200, response.data.count <= ProviderStatusLimits.maximumResponseBytes else {
                return ProviderStatusObservation(service: service, checkedAt: now, outcome: .endpointUnavailable)
            }
            return try ProviderStatusNormalizer.normalize(response.data, service: service, checkedAt: now)
        } catch ProviderStatusNormalizationError.unsupportedSchema {
            return ProviderStatusObservation(service: service, checkedAt: now, outcome: .unsupportedSchema)
        } catch ProviderStatusNormalizationError.malformedPayload {
            return ProviderStatusObservation(service: service, checkedAt: now, outcome: .malformedPayload)
        } catch {
            return ProviderStatusObservation(service: service, checkedAt: now, outcome: .endpointUnavailable)
        }
    }
}

public struct AnthropicPublicStatusClient: Sendable {
    private let client: OfficialProviderStatusClient
    public init() { client = OfficialProviderStatusClient(service: .anthropic, httpClient: URLSessionHTTPClient(redirectPolicy: .sameOrigin)) }
    init(httpClient: any HTTPClient) { client = OfficialProviderStatusClient(service: .anthropic, httpClient: httpClient) }
    public func check(now: Date = Date()) async -> ProviderStatusObservation { await client.check(now: now) }
}

public struct OpenAIPublicStatusClient: Sendable {
    private let client: OfficialProviderStatusClient
    public init() { client = OfficialProviderStatusClient(service: .openAI, httpClient: URLSessionHTTPClient(redirectPolicy: .sameOrigin)) }
    init(httpClient: any HTTPClient) { client = OfficialProviderStatusClient(service: .openAI, httpClient: httpClient) }
    public func check(now: Date = Date()) async -> ProviderStatusObservation { await client.check(now: now) }
}

public enum ProviderStatusCorrelation {
    public static let overlapLanguage = "Official incident overlapped this failure. Temporal overlap does not establish causation."
    public static let noIncidentLanguage = "No published incident overlapped this failure. This does not establish provider health or quota exhaustion."

    public static func incidents(
        overlapping failureAt: Date,
        product: ProviderStatusProduct,
        observations: [ProviderStatusObservation]
    ) -> [NormalizedProviderIncident] {
        observations.flatMap { observation -> [NormalizedProviderIncident] in
            guard observation.outcome == .incidentsPublished else { return [] }
            return observation.incidents.filter { incident in
                guard incident.products.contains(product), incident.status != .unknown else { return false }
                if let resolvedAt = incident.resolvedAt {
                    return incident.startedAt <= failureAt
                        && failureAt < resolvedAt
                        && failureAt <= observation.checkedAt
                }
                let activeStatuses: Set<ProviderIncidentStatus> = [.investigating, .identified, .monitoring]
                return activeStatuses.contains(incident.status)
                    && activeStatuses.contains(incident.latestUpdateState)
                    && incident.startedAt <= failureAt
                    && failureAt <= observation.checkedAt
            }
        }.reduce(into: [String: NormalizedProviderIncident]()) { result, incident in
                let key = "\(incident.service.rawValue):\(incident.id)"
                if result[key].map({ $0.updatedAt < incident.updatedAt }) ?? true { result[key] = incident }
            }.values.sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
    }
}

public enum ProviderStatusCapacity {
    public static func incidents(
        from observations: [ProviderStatusObservation],
        now: Date
    ) -> [CapacityPublication.Incident] {
        let latest = Dictionary(grouping: observations, by: \.service).values.compactMap { serviceObservations -> ProviderStatusObservation? in
            guard let latestCheckedAt = serviceObservations.map(\.checkedAt).max() else { return nil }
            let candidates = serviceObservations.filter { $0.checkedAt == latestCheckedAt }
            guard candidates.count == 1 else { return nil }
            return candidates[0]
        }
        return latest.flatMap { observation -> [CapacityPublication.Incident] in
            guard observation.outcome == .incidentsPublished,
                  observation.checkedAt <= now,
                  now.timeIntervalSince(observation.checkedAt) <= ProviderStatusLimits.freshness else { return [] }
            return observation.incidents.flatMap { incident in
                CapacityProviderProduct.allCases.compactMap { product in
                    CapacityPublication.Incident(incident, observation: observation, product: product)
                }
            }
        }
    }
}

public enum ProviderLocalFailureClass: String, Codable, CaseIterable, Equatable, Sendable {
    case rateLimited = "rate_limited_429"
    case overloaded
    case capacity
    case authentication
    case usageLimit = "usage_limit"
    case concurrency
    case network
    case malformedResponse = "malformed_response"
    case unknown
}

public struct ProviderLocalFailure: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let product: ProviderStatusProduct
    public let failureClass: ProviderLocalFailureClass
    public let occurredAt: Date

    public init(id: UUID = UUID(), product: ProviderStatusProduct, failureClass: ProviderLocalFailureClass, occurredAt: Date) {
        self.id = id
        self.product = product
        self.failureClass = failureClass
        self.occurredAt = occurredAt
    }
}

public enum ProviderAuthenticationEvidence: String, Codable, Equatable, Sendable {
    case connected
    case authorizationRequired = "authorization_required"
    case notConfigured = "not_configured"
    case expired
    case rejected
    case unavailable
    case unknown
}

public struct ProviderStatusSubscriptionSettings: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public var isEnabled: Bool
    public let cadenceSeconds: Int

    public init(isEnabled: Bool = false) {
        schemaVersion = Self.schemaVersion
        self.isEnabled = isEnabled
        cadenceSeconds = Int(ProviderStatusLimits.subscriptionCadence)
    }

    public static func decode(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schemaVersion == schemaVersion,
              value.cadenceSeconds == Int(ProviderStatusLimits.subscriptionCadence) else { return Self() }
        return value
    }
}

public enum ProviderStatusSubscriptionSchedule {
    public static func isDue(enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return now >= lastCheck.addingTimeInterval(ProviderStatusLimits.subscriptionCadence)
    }

    public static func delay(lastCheck: Date?, now: Date) -> TimeInterval {
        guard let lastCheck else { return 0 }
        return max(0, lastCheck.addingTimeInterval(ProviderStatusLimits.subscriptionCadence).timeIntervalSince(now))
    }
}

public final class ProviderStatusStore: @unchecked Sendable {
    public static let schemaVersion = 2
    private let destination: URL
    private let lock = NSLock()

    public init(destination: URL) { self.destination = destination }

    public static func production(fileManager: FileManager = .default) throws -> Self {
        Self(destination: try LimitBarFileLocations.production(fileManager: fileManager).providerStatusTimeline)
    }

    public func load(now: Date = Date()) throws -> [ProviderStatusObservation] {
        try lock.withLock {
            let observations = try loadUnlocked(now: now)
            if FileManager.default.fileExists(atPath: destination.path) { try write(observations) }
            return observations
        }
    }

    public func record(_ observations: [ProviderStatusObservation], now: Date = Date()) throws -> [ProviderStatusObservation] {
        try lock.withLock {
            let retained = try bounded(try loadUnlocked(now: now) + observations, now: now)
            try write(retained)
            return retained
        }
    }

    public func deleteAll() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: destination.path) else { return }
            try FileManager.default.removeItem(at: destination)
        }
    }

    private struct Envelope: Codable { let schemaVersion: Int; let observations: [ProviderStatusObservation] }
    private func loadUnlocked(now: Date) throws -> [ProviderStatusObservation] {
        guard FileManager.default.fileExists(atPath: destination.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= ProviderStatusLimits.maximumResponseBytes * 2 else {
            throw ProviderStatusNormalizationError.malformedPayload
        }
        let data = try Data(contentsOf: destination)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let envelope = try? decoder.decode(Envelope.self, from: data), envelope.schemaVersion == Self.schemaVersion {
            return try bounded(envelope.observations, now: now)
        }
        throw ProviderStatusNormalizationError.unsupportedSchema
    }

    private func bounded(_ observations: [ProviderStatusObservation], now: Date) throws -> [ProviderStatusObservation] {
        guard observations.allSatisfy({ observation in
            observation.incidents.allSatisfy { $0.service == observation.service }
        }) else {
            throw ProviderStatusNormalizationError.malformedPayload
        }
        return observations.compactMap { observation -> ProviderStatusObservation? in
            guard observation.modelVersion == ProviderStatusObservation.modelVersion,
                  observation.checkedAt <= now,
                  now.timeIntervalSince(observation.checkedAt) <= ProviderStatusLimits.retention else { return nil }
            let retainsTimeline = observation.outcome == .incidentsPublished || observation.outcome == .unsupportedComponent
            let incidents = (retainsTimeline ? observation.incidents : []).filter { incident in
                incident.modelVersion == NormalizedProviderIncident.modelVersion
                    && !incident.id.isEmpty
                    && incident.id.utf8.count <= ProviderStatusLimits.maximumIdentifierLength
                    && incident.startedAt <= incident.updatedAt
                    && incident.resolvedAt.map { $0 >= incident.startedAt } ?? true
            }
            return ProviderStatusObservation(
                id: observation.id,
                service: observation.service,
                checkedAt: observation.checkedAt,
                outcome: observation.outcome,
                incidents: incidents,
                unsupportedComponentCount: observation.unsupportedComponentCount
            )
        }.sorted { ($0.checkedAt, $0.id.uuidString) > ($1.checkedAt, $1.id.uuidString) }
            .reduce(into: [UUID: ProviderStatusObservation]()) { $0[$1.id] = $1 }
            .values.sorted { ($0.checkedAt, $0.id.uuidString) > ($1.checkedAt, $1.id.uuidString) }
            .prefix(ProviderStatusLimits.maximumStoredObservations).map { $0 }
    }

    private func write(_ observations: [ProviderStatusObservation]) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, observations: observations))
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

public extension LimitBarFileLocations {
    var providerStatusTimeline: URL { limitBarApplicationSupportDirectory.appendingPathComponent("provider-status-v2.json") }
}

public extension CapacityPublication.Incident {
    init?(
        _ incident: NormalizedProviderIncident,
        observation: ProviderStatusObservation,
        product: CapacityProviderProduct
    ) {
        let statusProduct: ProviderStatusProduct = product == .claudeCode ? .claudeCode : .codex
        guard incident.products.contains(statusProduct), incident.isQualifiedActive(at: observation.checkedAt) else { return nil }
        self.init(
            product: product,
            observedAt: observation.checkedAt,
            expiresAt: observation.checkedAt.addingTimeInterval(ProviderStatusLimits.freshness)
        )
    }
}
