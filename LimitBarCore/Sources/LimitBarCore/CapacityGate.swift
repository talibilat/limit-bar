import Darwin
import Foundation

public enum CapacityProviderProduct: String, Codable, CaseIterable, Equatable, Sendable {
    case claudeCode = "claude-code"
    case codex

    var providerProduct: ProviderProduct {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }

    init?(_ product: ProviderProduct) {
        switch product {
        case .claudeCode: self = .claudeCode
        case .codex: self = .codex
        case .anthropicAPI, .openAIAPI, .azureOpenAI: return nil
        }
    }
}

public enum CapacityQuotaWindowKind: String, Codable, CaseIterable, Equatable, Sendable {
    case session
    case weekly
    case other

    init(_ kind: QuotaInsightWindowKind) {
        switch kind {
        case .session: self = .session
        case .weekly: self = .weekly
        case .other: self = .other
        }
    }
}

public enum CapacityOperationClass: String, Codable, CaseIterable, Equatable, Sendable {
    case prompt
    case subagent
    case queuedRun = "queued-run"
    case ciJob = "ci-job"
}

public enum CapacityEvaluationMode: String, Codable, Equatable, Sendable {
    case observation
    case failClosed = "fail-closed"
}

public enum CapacityDecision: String, Codable, Equatable, Sendable {
    case allow
    case warn
    case pause
}

public enum CapacityReason: String, Codable, Equatable, Sendable {
    case measuredCapacityHealthy = "measured_capacity_healthy"
    case measuredCapacityWarning = "measured_capacity_warning"
    case measuredCapacityExhausted = "measured_capacity_exhausted"
    case providerIncidentActive = "provider_incident_active"
    case staleEvidence = "stale_evidence"
    case unavailableEvidence = "unavailable_evidence"
    case malformedEvidence = "malformed_evidence"
    case incompatibleEvidence = "incompatible_evidence"
    case boundaryUnavailable = "boundary_unavailable"
    case unsupportedProduct = "unsupported_product"
    case unsupportedOperation = "unsupported_operation"
    case timedOut = "timed_out"
}

public struct CapacityRequest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let product: CapacityProviderProduct
    public let operationClass: CapacityOperationClass
    public let mode: CapacityEvaluationMode

    public init(
        product: CapacityProviderProduct,
        operationClass: CapacityOperationClass,
        mode: CapacityEvaluationMode = .observation
    ) {
        schemaVersion = Self.schemaVersion
        self.product = product
        self.operationClass = operationClass
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case product
        case operationClass = "operation_class"
        case mode
    }
}

public struct CapacityPublication: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public struct Observation: Codable, Equatable, Sendable {
        public let product: CapacityProviderProduct
        public let windowKind: CapacityQuotaWindowKind
        public let percentageUsed: Double
        public let observedAt: Date
        public let expiresAt: Date
        public let resetBoundary: Date

        public init(
            product: CapacityProviderProduct,
            windowKind: CapacityQuotaWindowKind = .other,
            percentageUsed: Double,
            observedAt: Date,
            expiresAt: Date,
            resetBoundary: Date
        ) {
            self.product = product
            self.windowKind = windowKind
            self.percentageUsed = percentageUsed
            self.observedAt = observedAt
            self.expiresAt = expiresAt
            self.resetBoundary = resetBoundary
        }

        init?(_ observation: QuotaObservation) {
            guard let product = CapacityProviderProduct(observation.identity.product) else { return nil }
            self.init(
                product: product,
                windowKind: CapacityQuotaWindowKind(observation.identity.insightWindowKind),
                percentageUsed: observation.percentageUsed,
                observedAt: observation.observedAt,
                expiresAt: observation.expiresAt,
                resetBoundary: observation.identity.resetBoundary
            )
        }

        private enum CodingKeys: String, CodingKey {
            case product
            case windowKind = "window_kind"
            case percentageUsed = "percentage_used"
            case observedAt = "observed_at"
            case expiresAt = "expires_at"
            case resetBoundary = "reset_boundary"
        }
    }

    public struct Incident: Codable, Equatable, Sendable {
        public let product: CapacityProviderProduct
        public let observedAt: Date
        public let expiresAt: Date

        public init(product: CapacityProviderProduct, observedAt: Date, expiresAt: Date) {
            self.product = product
            self.observedAt = observedAt
            self.expiresAt = expiresAt
        }

        private enum CodingKeys: String, CodingKey {
            case product
            case observedAt = "observed_at"
            case expiresAt = "expires_at"
        }
    }

    public let schemaVersion: Int
    public let publishedAt: Date
    public let observations: [Observation]
    public let incidents: [Incident]

    public init(publishedAt: Date, observations: [Observation], incidents: [Incident] = []) {
        schemaVersion = Self.schemaVersion
        self.publishedAt = publishedAt
        self.observations = observations
        self.incidents = incidents
    }

    public init(publishedAt: Date, quotaObservations: [QuotaObservation], incidents: [Incident] = []) {
        self.init(
            publishedAt: publishedAt,
            observations: quotaObservations.compactMap(Observation.init),
            incidents: incidents
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case publishedAt = "published_at"
        case observations
        case incidents
    }
}

public struct CapacityEvidence: Codable, Equatable, Sendable {
    public let percentageUsed: Double?
    public let observationAgeSeconds: Int?
    public let resetBoundary: Date?
    public let incidentActive: Bool

    public init(
        percentageUsed: Double? = nil,
        observationAgeSeconds: Int? = nil,
        resetBoundary: Date? = nil,
        incidentActive: Bool = false
    ) {
        self.percentageUsed = percentageUsed
        self.observationAgeSeconds = observationAgeSeconds
        self.resetBoundary = resetBoundary
        self.incidentActive = incidentActive
    }

    private enum CodingKeys: String, CodingKey {
        case percentageUsed = "percentage_used"
        case observationAgeSeconds = "observation_age_seconds"
        case resetBoundary = "reset_boundary"
        case incidentActive = "incident_active"
    }
}

public struct CapacityResponse: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let product: String
    public let operationClass: String
    public let mode: CapacityEvaluationMode
    public let decision: CapacityDecision
    public let reasons: [CapacityReason]
    public let evidence: CapacityEvidence

    public init(
        product: String,
        operationClass: String,
        mode: CapacityEvaluationMode,
        decision: CapacityDecision,
        reasons: [CapacityReason],
        evidence: CapacityEvidence = CapacityEvidence()
    ) {
        schemaVersion = Self.schemaVersion
        self.product = product
        self.operationClass = operationClass
        self.mode = mode
        self.decision = decision
        self.reasons = reasons.isEmpty ? [.unavailableEvidence] : reasons
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case product
        case operationClass = "operation_class"
        case mode
        case decision
        case reasons
        case evidence
    }
}

public enum CapacityPublicationReadError: Error, Equatable {
    case unavailable
    case malformed
    case unsupportedVersion
    case boundaryUnavailable
    case timedOut
}

public enum CapacityPublicationCodec {
    public static let maximumBytes = 64 * 1024

    public static func encode(_ publication: CapacityPublication) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(publication)
    }

    public static func decode(_ data: Data) throws -> CapacityPublication {
        guard !data.isEmpty, data.count <= maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CapacityPublicationReadError.malformed
        }
        try requireExactKeys(root, allowed: ["schema_version", "published_at", "observations", "incidents"])
        guard let version = root["schema_version"] as? Int else {
            throw CapacityPublicationReadError.malformed
        }
        guard version == CapacityPublication.schemaVersion else {
            throw CapacityPublicationReadError.unsupportedVersion
        }
        guard let observations = root["observations"] as? [[String: Any]],
              let incidents = root["incidents"] as? [[String: Any]] else {
            throw CapacityPublicationReadError.malformed
        }
        for observation in observations {
            let allowed: Set<String> = ["product", "window_kind", "percentage_used", "observed_at", "expires_at", "reset_boundary"]
            if observation["reset_boundary"] == nil {
                throw CapacityPublicationReadError.boundaryUnavailable
            }
            try requireExactKeys(observation, allowed: allowed)
        }
        for incident in incidents {
            try requireExactKeys(incident, allowed: ["product", "observed_at", "expires_at"])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(CapacityPublication.self, from: data)
        } catch {
            throw CapacityPublicationReadError.malformed
        }
    }

    private static func requireExactKeys(_ value: [String: Any], allowed: Set<String>) throws {
        guard Set(value.keys).isSubset(of: allowed) else {
            throw CapacityPublicationReadError.unsupportedVersion
        }
        guard Set(value.keys) == allowed else { throw CapacityPublicationReadError.malformed }
    }
}

public enum CapacityEvaluator {
    public static let warningPercentage = 80.0
    public static let pausePercentage = 90.0

    public static func evaluate(
        request: CapacityRequest,
        publication: CapacityPublication,
        now: Date
    ) -> CapacityResponse {
        let relevant = publication.observations.filter { $0.product == request.product }
        let activeIncident = publication.incidents.contains {
            $0.product == request.product
                && $0.observedAt.timeIntervalSince1970.isFinite
                && $0.observedAt <= now
                && $0.expiresAt >= now
        }
        let valid = relevant.filter {
            let maximumAge = $0.product == .claudeCode
                ? QuotaObservationAdapter.claudeMaximumAge
                : QuotaObservationAdapter.codexMaximumAge
            return $0.percentageUsed.isFinite
                && (0...100).contains($0.percentageUsed)
                && $0.observedAt.timeIntervalSince1970.isFinite
                && $0.observedAt <= now
                && now.timeIntervalSince($0.observedAt) <= maximumAge
                && $0.expiresAt >= now
                && $0.expiresAt <= $0.observedAt.addingTimeInterval(maximumAge)
                && $0.resetBoundary.timeIntervalSince1970.isFinite
                && $0.resetBoundary > now
        }
        guard let observation = valid.max(by: { $0.percentageUsed < $1.percentageUsed }) else {
            let reason: CapacityReason = relevant.isEmpty ? .unavailableEvidence : .staleEvidence
            return CapacityResponse(
                product: request.product.rawValue,
                operationClass: request.operationClass.rawValue,
                mode: request.mode,
                decision: request.mode == .failClosed ? .pause : .warn,
                reasons: activeIncident ? [reason, .providerIncidentActive] : [reason],
                evidence: CapacityEvidence(incidentActive: activeIncident)
            )
        }

        let baseDecision: CapacityDecision
        let baseReason: CapacityReason
        if observation.percentageUsed >= pausePercentage {
            baseDecision = .pause
            baseReason = .measuredCapacityExhausted
        } else if observation.percentageUsed >= warningPercentage {
            baseDecision = .warn
            baseReason = .measuredCapacityWarning
        } else {
            baseDecision = activeIncident ? .warn : .allow
            baseReason = .measuredCapacityHealthy
        }
        var reasons = [baseReason]
        if activeIncident { reasons.append(.providerIncidentActive) }
        return CapacityResponse(
            product: request.product.rawValue,
            operationClass: request.operationClass.rawValue,
            mode: request.mode,
            decision: baseDecision,
            reasons: reasons,
            evidence: CapacityEvidence(
                percentageUsed: observation.percentageUsed,
                observationAgeSeconds: Int(now.timeIntervalSince(observation.observedAt).rounded(.down)),
                resetBoundary: observation.resetBoundary,
                incidentActive: activeIncident
            )
        )
    }

    public static func unavailable(
        product: String,
        operationClass: String,
        mode: CapacityEvaluationMode,
        reason: CapacityReason
    ) -> CapacityResponse {
        CapacityResponse(
            product: product,
            operationClass: operationClass,
            mode: mode,
            decision: mode == .failClosed ? .pause : .warn,
            reasons: [reason]
        )
    }
}

public struct CapacityPublicationWriter: Sendable {
    public let destination: URL

    public init(destination: URL) {
        self.destination = destination
    }

    public static func production(fileManager: FileManager = .default) throws -> Self {
        Self(destination: try LimitBarFileLocations.production(fileManager: fileManager).capacityPublication)
    }

    public func publish(_ publication: CapacityPublication, fileManager: FileManager = .default) throws {
        let data = try CapacityPublicationCodec.encode(publication)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".capacity-\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            let result: Int32 = temporary.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    guard let source, let target else { return -1 }
                    return Darwin.rename(source, target)
                }
            }
            guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

private final class CapacityReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func store(_ result: Result<Data, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

public struct CapacityCommandResult: Equatable, Sendable {
    public let output: String
    public let exitCode: Int32
}

public enum CapacityCommand {
    public static let usageExitCode: Int32 = 64
    public static let pausedExitCode: Int32 = 75

    public static func run(
        _ arguments: [String],
        now: Date = Date(),
        defaultPublicationURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> CapacityCommandResult {
        run(
            arguments,
            now: now,
            defaultPublicationURL: defaultPublicationURL,
            fileManager: fileManager,
            publicationReader: readPublication
        )
    }

    static func run(
        _ arguments: [String],
        now: Date,
        defaultPublicationURL: URL?,
        fileManager: FileManager,
        publicationReader: @escaping @Sendable (URL) throws -> Data
    ) -> CapacityCommandResult {
        var productValue = ""
        var operationValue = ""
        var mode: CapacityEvaluationMode = .observation
        var publicationURL = defaultPublicationURL
        var timeout = 1.0

        guard arguments.first == "capacity" else {
            return invocationFailure(product: productValue, operation: operationValue, mode: mode, reason: .unsupportedOperation)
        }
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard index + 1 < arguments.count else {
                return invocationFailure(product: productValue, operation: operationValue, mode: mode, reason: .unsupportedOperation)
            }
            let value = arguments[index + 1]
            switch key {
            case "--product": productValue = value
            case "--operation": operationValue = value
            case "--mode":
                guard let parsed = CapacityEvaluationMode(rawValue: value) else {
                    return invocationFailure(product: productValue, operation: operationValue, mode: mode, reason: .incompatibleEvidence)
                }
                mode = parsed
            case "--state-file": publicationURL = URL(fileURLWithPath: value)
            case "--timeout":
                guard let parsed = Double(value), parsed.isFinite, parsed > 0, parsed <= 5 else {
                    return invocationFailure(product: productValue, operation: operationValue, mode: mode, reason: .timedOut)
                }
                timeout = parsed
            default:
                return invocationFailure(product: productValue, operation: operationValue, mode: mode, reason: .unsupportedOperation)
            }
            index += 2
        }
        guard let product = CapacityProviderProduct(rawValue: productValue) else {
            return invocationFailure(product: productValue, operation: operationValue, mode: mode, reason: .unsupportedProduct)
        }
        guard let operation = CapacityOperationClass(rawValue: operationValue) else {
            return invocationFailure(product: productValue, operation: operationValue, mode: mode, reason: .unsupportedOperation)
        }
        let request = CapacityRequest(product: product, operationClass: operation, mode: mode)

        let url: URL
        do {
            url = try publicationURL ?? LimitBarFileLocations.production(fileManager: fileManager).capacityPublication
        } catch {
            return decisionResult(CapacityEvaluator.unavailable(
                product: productValue, operationClass: operationValue, mode: mode, reason: .unavailableEvidence
            ))
        }
        let publication: CapacityPublication
        do {
            let state = CapacityReadState()
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                state.store(Result { try publicationReader(url) })
                completed.signal()
            }
            guard completed.wait(timeout: .now() + timeout) == .success,
                  let readResult = state.load() else {
                throw CapacityPublicationReadError.timedOut
            }
            publication = try CapacityPublicationCodec.decode(readResult.get())
        } catch let error as CapacityPublicationReadError {
            let reason: CapacityReason
            switch error {
            case .unavailable: reason = .unavailableEvidence
            case .malformed: reason = .malformedEvidence
            case .unsupportedVersion: reason = .incompatibleEvidence
            case .boundaryUnavailable: reason = .boundaryUnavailable
            case .timedOut: reason = .timedOut
            }
            return decisionResult(CapacityEvaluator.unavailable(
                product: productValue, operationClass: operationValue, mode: mode, reason: reason
            ))
        } catch {
            return decisionResult(CapacityEvaluator.unavailable(
                product: productValue, operationClass: operationValue, mode: mode, reason: .unavailableEvidence
            ))
        }
        return decisionResult(CapacityEvaluator.evaluate(request: request, publication: publication, now: now))
    }

    private static func readPublication(_ url: URL) throws -> Data {
        guard let canonicalURL = SecureRegularFile.canonicalURL(url) else {
            throw CapacityPublicationReadError.unavailable
        }
        let handle = try SecureRegularFile.open(canonicalURL)
        defer { try? handle.close() }
        return try handle.read(upToCount: CapacityPublicationCodec.maximumBytes + 1) ?? Data()
    }

    private static func invocationFailure(
        product: String,
        operation: String,
        mode: CapacityEvaluationMode,
        reason: CapacityReason
    ) -> CapacityCommandResult {
        CapacityCommandResult(
            output: encode(CapacityResponse(
                product: product,
                operationClass: operation,
                mode: mode,
                decision: .pause,
                reasons: [reason]
            )),
            exitCode: usageExitCode
        )
    }

    private static func decisionResult(_ response: CapacityResponse) -> CapacityCommandResult {
        CapacityCommandResult(
            output: encode(response),
            exitCode: response.mode == .failClosed && response.decision == .pause ? pausedExitCode : 0
        )
    }

    private static func encode(_ response: CapacityResponse) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response), let value = String(data: data, encoding: .utf8) else {
            return #"{"decision":"pause","reasons":["malformed_evidence"],"schema_version":1}"#
        }
        return value
    }
}
