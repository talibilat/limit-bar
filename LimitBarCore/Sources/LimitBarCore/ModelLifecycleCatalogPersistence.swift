import Foundation

public enum ModelLifecycleCatalogStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case invalidStore
    case writeFailed
    case invalidScenario
}

public final class ModelLifecycleCatalogStore: @unchecked Sendable {
    public static let schemaVersion = 1
    public static let maximumCatalogs = 5
    public static let maximumScenarios = 500
    public static let scenarioRetention: TimeInterval = 365 * 24 * 60 * 60

    private struct State: Codable {
        let schemaVersion: Int
        var catalogs: [SignedModelLifecycleCatalog]
        var scenarios: [CalculatedReplacementCostScenario]
    }

    private struct VersionHeader: Decodable { let schemaVersion: Int }
    private struct LegacyState: Decodable {
        let schemaVersion: Int
        let catalogs: [SignedModelLifecycleCatalog]
    }

    private let fileURL: URL
    private let verifier: ModelCatalogVerifier
    private let lock = NSLock()

    public init(fileURL: URL, verifier: ModelCatalogVerifier) {
        self.fileURL = fileURL
        self.verifier = verifier
    }

    public static func production(verifier: ModelCatalogVerifier) throws -> ModelLifecycleCatalogStore {
        let locations = try LimitBarFileLocations.production()
        return ModelLifecycleCatalogStore(
            fileURL: locations.limitBarApplicationSupportDirectory.appendingPathComponent("model-lifecycle-radar-v1.json"),
            verifier: verifier
        )
    }

    @discardableResult
    public func recordCatalog(_ envelope: SignedModelLifecycleCatalog) throws -> ModelLifecycleCatalog {
        let catalog = try verifier.verify(envelope)
        try withLock {
            var state = try loadState()
            if let currentEnvelope = state.catalogs.last {
                let current = try verifier.verify(currentEnvelope)
                if currentEnvelope == envelope { return }
                guard let candidateVersion = CatalogVersion(catalog.catalogVersion),
                      let currentVersion = CatalogVersion(current.catalogVersion),
                      candidateVersion > currentVersion else {
                    throw ModelCatalogValidationError.rollbackCatalogVersion
                }
                guard catalog.publishedAt > current.publishedAt else {
                    throw ModelCatalogValidationError.rollbackPublication
                }
                let currentRevisions = Dictionary(uniqueKeysWithValues: current.pricingRevisions.map { ($0.id, $0) })
                guard catalog.pricingRevisions.allSatisfy({ revision in
                    currentRevisions[revision.id].map { $0 == revision } ?? true
                }) else {
                    throw ModelCatalogValidationError.rollbackPricingRevision
                }
                if let currentEffective = current.pricingRevisions.map(\.effectiveAt).max() {
                    guard let candidateEffective = catalog.pricingRevisions.map(\.effectiveAt).max(),
                          candidateEffective >= currentEffective else {
                        throw ModelCatalogValidationError.rollbackPricingRevision
                    }
                }
            }
            state.catalogs.removeAll { (try? verifier.verify($0).catalogVersion) == catalog.catalogVersion }
            state.catalogs.append(envelope)
            state.catalogs = Array(state.catalogs.suffix(Self.maximumCatalogs))
            try save(state)
        }
        return catalog
    }

    public func latestCatalog() throws -> ModelLifecycleCatalog? {
        try withLock {
            guard let latest = try loadState().catalogs.last else { return nil }
            return try verifier.verify(latest)
        }
    }

    public func catalogHistory() throws -> [ModelLifecycleCatalog] {
        try withLock { try loadState().catalogs.map { try verifier.verify($0) } }
    }

    public func recordScenario(_ scenario: CalculatedReplacementCostScenario, now: Date = Date()) throws {
        try withLock {
            var state = try loadState()
            guard let catalog = state.catalogs.compactMap({ try? verifier.verify($0) }).first(where: { $0.catalogVersion == scenario.catalogVersion }),
                  let record = catalog.records.first(where: { $0.identity == scenario.original }),
                  case let .calculated(recalculated) = ReplacementCostScenarioCalculator.calculate(
                    record: record,
                    workload: scenario.workload,
                    catalog: catalog,
                    at: scenario.calculatedAt
                  ),
                  Self.sameFrozenScenario(recalculated, scenario) else {
                throw ModelLifecycleCatalogStoreError.invalidScenario
            }
            state.scenarios.removeAll { $0.calculatedAt <= now.addingTimeInterval(-Self.scenarioRetention) || $0.id == scenario.id }
            state.scenarios.append(scenario)
            state.scenarios = Array(state.scenarios.sorted { $0.calculatedAt < $1.calculatedAt }.suffix(Self.maximumScenarios))
            try save(state)
        }
    }

    private static func sameFrozenScenario(
        _ lhs: CalculatedReplacementCostScenario,
        _ rhs: CalculatedReplacementCostScenario
    ) -> Bool {
        lhs.calculatedAt == rhs.calculatedAt
            && lhs.original == rhs.original
            && lhs.replacement == rhs.replacement
            && lhs.minimumCost == rhs.minimumCost
            && lhs.maximumCost == rhs.maximumCost
            && lhs.currencyCode == rhs.currencyCode
            && lhs.catalogVersion == rhs.catalogVersion
            && lhs.pricingRevisionID == rhs.pricingRevisionID
            && lhs.pricingEffectiveAt == rhs.pricingEffectiveAt
            && lhs.pricingSourceURL == rhs.pricingSourceURL
            && lhs.workload == rhs.workload
            && lhs.omittedDimensions == rhs.omittedDimensions
            && lhs.limitations == rhs.limitations
    }

    public func scenarios(now: Date = Date()) throws -> [CalculatedReplacementCostScenario] {
        try withLock {
            try loadState().scenarios.filter { $0.calculatedAt > now.addingTimeInterval(-Self.scenarioRetention) }
        }
    }

    public func deleteAll() throws {
        try withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do { try FileManager.default.removeItem(at: fileURL) } catch { throw ModelLifecycleCatalogStoreError.writeFailed }
        }
    }

    private func loadState() throws -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return State(schemaVersion: Self.schemaVersion, catalogs: [], scenarios: [])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let version = try ModelLifecycleCatalogJSON.decoder.decode(VersionHeader.self, from: data).schemaVersion
            if version == 0 {
                let legacy = try ModelLifecycleCatalogJSON.decoder.decode(LegacyState.self, from: data)
                let catalogs = try legacy.catalogs.filter { envelope in
                    _ = try verifier.verify(envelope)
                    return true
                }
                let migrated = State(schemaVersion: Self.schemaVersion, catalogs: Array(catalogs.suffix(Self.maximumCatalogs)), scenarios: [])
                try save(migrated)
                return migrated
            }
            guard version == Self.schemaVersion else {
                throw ModelLifecycleCatalogStoreError.unsupportedSchema(version)
            }
            return try ModelLifecycleCatalogJSON.decoder.decode(State.self, from: data)
        } catch let error as ModelLifecycleCatalogStoreError {
            throw error
        } catch {
            throw ModelLifecycleCatalogStoreError.invalidStore
        }
    }

    private func save(_ state: State) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ModelLifecycleCatalogJSON.encoder.encode(state).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw ModelLifecycleCatalogStoreError.writeFailed
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

public enum ModelCatalogArtifactError: Error, Equatable {
    case invalidFile
    case fileTooLarge
    case invalidEnvelope
}

public enum ModelCatalogArtifactLoader {
    public static let maximumBytes = 4 * 1_024 * 1_024

    public static func load(from url: URL) throws -> SignedModelLifecycleCatalog {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ModelCatalogArtifactError.invalidFile
        }
        guard let size = values.fileSize, size <= maximumBytes else { throw ModelCatalogArtifactError.fileTooLarge }
        guard let envelope = try? ModelLifecycleCatalogJSON.decoder.decode(SignedModelLifecycleCatalog.self, from: Data(contentsOf: url)) else {
            throw ModelCatalogArtifactError.invalidEnvelope
        }
        return envelope
    }
}

public struct ModelCatalogHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol ModelCatalogTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ModelCatalogHTTPResponse
}

extension URLSession: ModelCatalogTransport {
    public func send(_ request: URLRequest) async throws -> ModelCatalogHTTPResponse {
        let (data, response) = try await data(for: request)
        return ModelCatalogHTTPResponse(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum ModelCatalogRefreshError: Error, Equatable {
    case invalidEndpoint
    case unsuccessfulResponse(Int)
    case invalidEnvelope
}

public struct ModelCatalogRefreshService: Sendable {
    private let endpoint: URL
    private let transport: any ModelCatalogTransport
    private let store: ModelLifecycleCatalogStore

    public init(endpoint: URL, transport: any ModelCatalogTransport, store: ModelLifecycleCatalogStore) {
        self.endpoint = endpoint
        self.transport = transport
        self.store = store
    }

    /// This is intentionally the only network entry point. Callers invoke it from an explicit action.
    public func refresh() async throws -> ModelLifecycleCatalog {
        guard endpoint.scheme == "https", endpoint.query == nil, endpoint.fragment == nil else {
            throw ModelCatalogRefreshError.invalidEndpoint
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        guard response.statusCode == 200 else { throw ModelCatalogRefreshError.unsuccessfulResponse(response.statusCode) }
        guard let envelope = try? ModelLifecycleCatalogJSON.decoder.decode(SignedModelLifecycleCatalog.self, from: response.data) else {
            throw ModelCatalogRefreshError.invalidEnvelope
        }
        return try store.recordCatalog(envelope)
    }
}
