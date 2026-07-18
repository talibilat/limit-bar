import CryptoKit
import Foundation

public enum ModelPlatform: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case anthropicAPI
    case openAIAPI
    case azureOpenAI
    case amazonBedrock
    case googleVertex

    public var displayName: String {
        switch self {
        case .anthropicAPI: "Anthropic API"
        case .openAIAPI: "OpenAI API"
        case .azureOpenAI: "Azure OpenAI"
        case .amazonBedrock: "Amazon Bedrock"
        case .googleVertex: "Google Vertex AI"
        }
    }

    public init?(provider: ProviderKind) {
        switch provider {
        case .anthropic: self = .anthropicAPI
        case .openAI: self = .openAIAPI
        case .azureOpenAI: self = .azureOpenAI
        case .custom: return nil
        }
    }
}

public enum ModelLifecycleStatus: String, Codable, Equatable, Sendable {
    case unspecified
    case active
    case deprecated
    case retired
}

public struct CatalogDate: Codable, Comparable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum ValidationError: Error, Equatable { case invalidDate }

    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(calendar: calendar, timeZone: .gmt, year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { throw ValidationError.invalidDate }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            throw ValidationError.invalidDate
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ value: String) throws {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            throw ValidationError.invalidDate
        }
        try self.init(year: year, month: month, day: day)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    public func utcBoundary() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public static func utcDate(containing date: Date) -> Self? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return try? Self(year: year, month: month, day: day)
    }

    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(description) }
}

public struct CatalogSourceReference: Codable, Equatable, Hashable, Sendable {
    public let url: URL
    public let retrievedAt: Date

    public init(url: URL, retrievedAt: Date) {
        self.url = url
        self.retrievedAt = retrievedAt
    }
}

public struct CatalogModelIdentity: Codable, Equatable, Hashable, Sendable {
    public let product: ProviderProduct
    public let platform: ModelPlatform
    public let modelID: String

    public init(product: ProviderProduct, platform: ModelPlatform, modelID: String) {
        self.product = product
        self.platform = platform
        self.modelID = modelID
    }
}

public struct ModelLifecycleRecord: Codable, Equatable, Sendable {
    public let identity: CatalogModelIdentity
    public let aliases: [String]
    public let status: ModelLifecycleStatus
    public let effectiveAt: Date
    public let retirementDate: CatalogDate?
    public let replacement: CatalogModelIdentity?
    public let lifecycleSource: CatalogSourceReference
    public let pricingRevisionIDs: [String]

    public init(
        identity: CatalogModelIdentity,
        aliases: [String] = [],
        status: ModelLifecycleStatus,
        effectiveAt: Date,
        retirementDate: CatalogDate?,
        replacement: CatalogModelIdentity?,
        lifecycleSource: CatalogSourceReference,
        pricingRevisionIDs: [String]
    ) {
        self.identity = identity
        self.aliases = aliases
        self.status = status
        self.effectiveAt = effectiveAt
        self.retirementDate = retirementDate
        self.replacement = replacement
        self.lifecycleSource = lifecycleSource
        self.pricingRevisionIDs = pricingRevisionIDs
    }
}

public enum ModelPriceDimension: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case input
    case output
    case cachedInput
    case cacheWriteFiveMinute
    case cacheWriteOneHour
    case longContextInput
    case longContextOutput
    case batchInput
    case batchOutput
    case flexInput
    case flexOutput
    case priorityInput
    case priorityOutput
    case regionalInput
    case regionalOutput
    case webSearchCall
    case fileSearchCall
    case codeInterpreterSession
    case containerSession

    public var displayName: String {
        switch self {
        case .input: "input tokens"
        case .output: "output tokens"
        case .cachedInput: "cached input tokens"
        case .cacheWriteFiveMinute: "5-minute cache writes"
        case .cacheWriteOneHour: "1-hour cache writes"
        case .longContextInput: "long-context input tokens"
        case .longContextOutput: "long-context output tokens"
        case .batchInput: "Batch input tokens"
        case .batchOutput: "Batch output tokens"
        case .flexInput: "Flex input tokens"
        case .flexOutput: "Flex output tokens"
        case .priorityInput: "Priority input tokens"
        case .priorityOutput: "Priority output tokens"
        case .regionalInput: "regional input tokens"
        case .regionalOutput: "regional output tokens"
        case .webSearchCall: "web search calls"
        case .fileSearchCall: "file search calls"
        case .codeInterpreterSession: "Code Interpreter sessions"
        case .containerSession: "container sessions"
        }
    }
}

public struct ModelUnitPrice: Codable, Equatable, Sendable {
    public let minimum: Decimal
    public let maximum: Decimal
    public let unitsPerPrice: Int

    public init(minimum: Decimal, maximum: Decimal, unitsPerPrice: Int) {
        self.minimum = minimum
        self.maximum = maximum
        self.unitsPerPrice = unitsPerPrice
    }
}

public struct ModelPricingRevision: Codable, Equatable, Sendable {
    public let id: String
    public let identity: CatalogModelIdentity
    public let effectiveAt: Date
    public let currencyCode: String
    public let prices: [ModelPriceDimension: ModelUnitPrice]
    public let source: CatalogSourceReference

    public init(
        id: String,
        identity: CatalogModelIdentity,
        effectiveAt: Date,
        currencyCode: String,
        prices: [ModelPriceDimension: ModelUnitPrice],
        source: CatalogSourceReference
    ) {
        self.id = id
        self.identity = identity
        self.effectiveAt = effectiveAt
        self.currencyCode = currencyCode
        self.prices = prices
        self.source = source
    }

    private struct EncodedPrice: Codable {
        let dimension: ModelPriceDimension
        let price: ModelUnitPrice
    }

    private enum CodingKeys: CodingKey {
        case id, identity, effectiveAt, currencyCode, prices, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode([EncodedPrice].self, forKey: .prices)
        var prices: [ModelPriceDimension: ModelUnitPrice] = [:]
        for entry in encoded {
            guard prices.updateValue(entry.price, forKey: entry.dimension) == nil else {
                throw DecodingError.dataCorruptedError(forKey: .prices, in: container, debugDescription: "Duplicate price dimension")
            }
        }
        self.init(
            id: try container.decode(String.self, forKey: .id),
            identity: try container.decode(CatalogModelIdentity.self, forKey: .identity),
            effectiveAt: try container.decode(Date.self, forKey: .effectiveAt),
            currencyCode: try container.decode(String.self, forKey: .currencyCode),
            prices: prices,
            source: try container.decode(CatalogSourceReference.self, forKey: .source)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(identity, forKey: .identity)
        try container.encode(effectiveAt, forKey: .effectiveAt)
        try container.encode(currencyCode, forKey: .currencyCode)
        try container.encode(prices.map { EncodedPrice(dimension: $0.key, price: $0.value) }.sorted { $0.dimension.rawValue < $1.dimension.rawValue }, forKey: .prices)
        try container.encode(source, forKey: .source)
    }
}

public struct ModelLifecycleCatalog: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let catalogVersion: String
    public let publishedAt: Date
    public let records: [ModelLifecycleRecord]
    public let pricingRevisions: [ModelPricingRevision]

    public init(
        schemaVersion: Int = supportedSchemaVersion,
        catalogVersion: String,
        publishedAt: Date,
        records: [ModelLifecycleRecord],
        pricingRevisions: [ModelPricingRevision]
    ) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.publishedAt = publishedAt
        self.records = records
        self.pricingRevisions = pricingRevisions
    }
}

public struct SignedModelLifecycleCatalog: Codable, Equatable, Sendable {
    public let keyID: String
    public let payload: Data
    public let signature: Data

    public init(keyID: String, payload: Data, signature: Data) {
        self.keyID = keyID
        self.payload = payload
        self.signature = signature
    }
}

public enum ModelCatalogValidationError: Error, Equatable {
    case unknownSigningKey
    case invalidSignature
    case invalidPayload
    case unsupportedSchema(Int)
    case invalidVersion
    case invalidProvenance
    case invalidIdentity
    case duplicateIdentity
    case duplicateAlias
    case invalidReplacement
    case invalidPricingRevision
    case unsupportedCurrency
    case rollbackCatalogVersion
    case rollbackPublication
    case rollbackPricingRevision
}

public struct ModelCatalogVerifier: Sendable {
    private let publicKeys: [String: Data]

    public init(publicKeys: [String: Data]) {
        self.publicKeys = publicKeys
    }

    public func verify(_ envelope: SignedModelLifecycleCatalog) throws -> ModelLifecycleCatalog {
        guard let rawKey = publicKeys[envelope.keyID],
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
            throw ModelCatalogValidationError.unknownSigningKey
        }
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw ModelCatalogValidationError.invalidSignature
        }
        let catalog: ModelLifecycleCatalog
        do {
            catalog = try ModelLifecycleCatalogJSON.decoder.decode(ModelLifecycleCatalog.self, from: envelope.payload)
        } catch {
            throw ModelCatalogValidationError.invalidPayload
        }
        try Self.validate(catalog)
        return catalog
    }

    public static func validate(_ catalog: ModelLifecycleCatalog) throws {
        guard catalog.schemaVersion == ModelLifecycleCatalog.supportedSchemaVersion else {
            throw ModelCatalogValidationError.unsupportedSchema(catalog.schemaVersion)
        }
        guard CatalogVersion(catalog.catalogVersion) != nil, catalog.publishedAt.timeIntervalSince1970.isFinite else {
            throw ModelCatalogValidationError.invalidVersion
        }
        var identities = Set<CatalogModelIdentity>()
        var namesByScope: [String: Set<String>] = [:]
        for record in catalog.records {
            guard valid(record.identity), record.effectiveAt.timeIntervalSince1970.isFinite else {
                throw ModelCatalogValidationError.invalidIdentity
            }
            guard record.effectiveAt <= catalog.publishedAt else { throw ModelCatalogValidationError.invalidVersion }
            guard identities.insert(record.identity).inserted else {
                throw ModelCatalogValidationError.duplicateIdentity
            }
            try validate(source: record.lifecycleSource)
            let scope = "\(record.identity.product.rawValue)|\(record.identity.platform.rawValue)"
            var names = namesByScope[scope, default: []]
            for name in [record.identity.modelID] + record.aliases {
                guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw ModelCatalogValidationError.invalidIdentity
                }
                guard names.insert(name).inserted else { throw ModelCatalogValidationError.duplicateAlias }
            }
            namesByScope[scope] = names
        }
        for record in catalog.records {
            if let replacement = record.replacement, !identities.contains(replacement) {
                throw ModelCatalogValidationError.invalidReplacement
            }
        }
        var revisionIDs = Set<String>()
        for revision in catalog.pricingRevisions {
            guard !revision.id.isEmpty, revisionIDs.insert(revision.id).inserted,
                  identities.contains(revision.identity),
                  revision.effectiveAt.timeIntervalSince1970.isFinite,
                  revision.effectiveAt <= catalog.publishedAt,
                  !revision.prices.isEmpty else {
                throw ModelCatalogValidationError.invalidPricingRevision
            }
            guard revision.currencyCode == "USD" else { throw ModelCatalogValidationError.unsupportedCurrency }
            try validate(source: revision.source)
            for price in revision.prices.values {
                guard price.unitsPerPrice > 0, finiteNonnegative(price.minimum),
                      finiteNonnegative(price.maximum), price.minimum <= price.maximum else {
                    throw ModelCatalogValidationError.invalidPricingRevision
                }
            }
        }
        guard catalog.records.allSatisfy({ Set($0.pricingRevisionIDs).isSubset(of: revisionIDs) }) else {
            throw ModelCatalogValidationError.invalidPricingRevision
        }
    }

    private static func valid(_ identity: CatalogModelIdentity) -> Bool {
        guard !identity.modelID.isEmpty else { return false }
        return switch (identity.product, identity.platform) {
        case (.anthropicAPI, .anthropicAPI), (.anthropicAPI, .amazonBedrock),
             (.anthropicAPI, .googleVertex), (.openAIAPI, .openAIAPI),
             (.azureOpenAI, .azureOpenAI): true
        default: false
        }
    }

    private static func validate(source: CatalogSourceReference) throws {
        guard source.retrievedAt.timeIntervalSince1970.isFinite,
              source.url.scheme == "https",
              let host = source.url.host?.lowercased(),
              host == "docs.anthropic.com" || host == "platform.openai.com" else {
            throw ModelCatalogValidationError.invalidProvenance
        }
    }

    private static func finiteNonnegative(_ value: Decimal) -> Bool {
        let number = NSDecimalNumber(decimal: value)
        return number != .notANumber && number.doubleValue.isFinite && value >= 0
    }
}

struct CatalogVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ value: String) {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        let components = pieces.compactMap { Int($0) }
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              components.count == pieces.count else { return nil }
        self.components = components
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public enum ModelCatalogMatcher {
    public static func match(
        product: ProviderProduct,
        platform: ModelPlatform,
        modelID: String,
        in catalog: ModelLifecycleCatalog
    ) -> ModelLifecycleRecord? {
        catalog.records.first {
            $0.identity.product == product
                && $0.identity.platform == platform
                && ($0.identity.modelID == modelID || $0.aliases.contains(modelID))
        }
    }
}

public struct RetainedModelUsage: Equatable, Sendable {
    public let identity: CatalogModelIdentity
    public let observedModelID: String
    public let workloadPeriod: DateInterval
    public let tokenUsage: TokenUsage

    public init(identity: CatalogModelIdentity, observedModelID: String, workloadPeriod: DateInterval, tokenUsage: TokenUsage) {
        self.identity = identity
        self.observedModelID = observedModelID
        self.workloadPeriod = workloadPeriod
        self.tokenUsage = tokenUsage
    }

    public var id: String {
        "\(identity.product.rawValue)|\(identity.platform.rawValue)|\(identity.modelID)|\(observedModelID)"
    }
}

public enum PricingModifier: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case cache
    case longContext
    case batch
    case flex
    case priority
    case serviceTier
    case regionalProcessing
    case tools
    case containers

    public var displayName: String {
        switch self {
        case .cache: "Cache reads or writes"
        case .longContext: "Long context"
        case .batch: "Batch"
        case .flex: "Flex"
        case .priority: "Priority"
        case .serviceTier: "Other service tier"
        case .regionalProcessing: "Regional processing"
        case .tools: "Billable tools"
        case .containers: "Containers"
        }
    }

    public var quantityDimensions: [ModelPriceDimension] {
        switch self {
        case .cache: [.cachedInput, .cacheWriteFiveMinute, .cacheWriteOneHour]
        case .longContext: [.longContextInput, .longContextOutput]
        case .batch: [.batchInput, .batchOutput]
        case .flex: [.flexInput, .flexOutput]
        case .priority: [.priorityInput, .priorityOutput]
        case .serviceTier: []
        case .regionalProcessing: [.regionalInput, .regionalOutput]
        case .tools: [.webSearchCall, .fileSearchCall, .codeInterpreterSession]
        case .containers: [.containerSession]
        }
    }
}

public enum PricingModifierEvidence: String, Codable, Equatable, Sendable {
    case notUsed
    case used
    case unknown

    public var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .notUsed: "No"
        case .used: "Yes"
        }
    }
}

public struct FrozenReplacementWorkload: Codable, Equatable, Sendable {
    public let periodStart: Date
    public let periodEnd: Date
    public let quantities: [ModelPriceDimension: Int]
    public let modifiers: [PricingModifier: PricingModifierEvidence]

    public init(
        periodStart: Date,
        periodEnd: Date,
        quantities: [ModelPriceDimension: Int],
        modifiers: [PricingModifier: PricingModifierEvidence]
    ) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.quantities = quantities
        self.modifiers = modifiers
    }
}

public enum ReplacementCostUnavailableReason: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case noDocumentedReplacement
    case replacementPlatformMismatch
    case pricingRevisionUnavailable
    case unsupportedCurrency
    case invalidWorkloadPeriod
    case inputTokensUnknown
    case outputTokensUnknown
    case cacheUseUnknown
    case longContextUseUnknown
    case batchUseUnknown
    case flexUseUnknown
    case priorityUseUnknown
    case serviceTierUnknown
    case regionalProcessingUnknown
    case toolUseUnknown
    case containerUseUnknown
    case usedDimensionUnpriced
    case invalidQuantity
    case incompatibleModifiers

    public var displayText: String {
        switch self {
        case .noDocumentedReplacement: "No replacement is documented in the catalog."
        case .replacementPlatformMismatch: "The documented replacement is for a different platform."
        case .pricingRevisionUnavailable: "No applicable replacement pricing revision is available."
        case .unsupportedCurrency: "The replacement price currency is unsupported."
        case .invalidWorkloadPeriod: "The retained workload period is invalid."
        case .inputTokensUnknown: "Input token quantity is unavailable."
        case .outputTokensUnknown: "Output token quantity is unavailable."
        case .cacheUseUnknown: "Cache use is unavailable."
        case .longContextUseUnknown: "Long-context applicability is unavailable."
        case .batchUseUnknown: "Batch applicability is unavailable."
        case .flexUseUnknown: "Flex tier applicability is unavailable."
        case .priorityUseUnknown: "Priority tier applicability is unavailable."
        case .serviceTierUnknown: "Service tier is unavailable."
        case .regionalProcessingUnknown: "Regional processing is unavailable."
        case .toolUseUnknown: "Tool usage is unavailable."
        case .containerUseUnknown: "Container usage is unavailable."
        case .usedDimensionUnpriced: "A used pricing dimension is not priced for the replacement."
        case .invalidQuantity: "A frozen workload quantity is invalid."
        case .incompatibleModifiers: "The selected modifiers cannot be priced together without a more specific breakdown."
        }
    }
}

public struct CalculatedReplacementCostScenario: Codable, Equatable, Sendable {
    public let id: UUID
    public let calculatedAt: Date
    public let original: CatalogModelIdentity
    public let replacement: CatalogModelIdentity
    public let minimumCost: Decimal
    public let maximumCost: Decimal
    public let currencyCode: String
    public let catalogVersion: String
    public let pricingRevisionID: String
    public let pricingEffectiveAt: Date
    public let pricingSourceURL: URL
    public let workload: FrozenReplacementWorkload
    public let omittedDimensions: [ModelPriceDimension]
    public let limitations: [String]

    public init(
        id: UUID = UUID(),
        calculatedAt: Date,
        original: CatalogModelIdentity,
        replacement: CatalogModelIdentity,
        minimumCost: Decimal,
        maximumCost: Decimal,
        currencyCode: String,
        catalogVersion: String,
        pricingRevisionID: String,
        pricingEffectiveAt: Date,
        pricingSourceURL: URL,
        workload: FrozenReplacementWorkload,
        omittedDimensions: [ModelPriceDimension],
        limitations: [String]
    ) {
        self.id = id
        self.calculatedAt = calculatedAt
        self.original = original
        self.replacement = replacement
        self.minimumCost = minimumCost
        self.maximumCost = maximumCost
        self.currencyCode = currencyCode
        self.catalogVersion = catalogVersion
        self.pricingRevisionID = pricingRevisionID
        self.pricingEffectiveAt = pricingEffectiveAt
        self.pricingSourceURL = pricingSourceURL
        self.workload = workload
        self.omittedDimensions = omittedDimensions
        self.limitations = limitations
    }
}

public enum ReplacementCostScenarioResult: Equatable, Sendable {
    case calculated(CalculatedReplacementCostScenario)
    case unavailable([ReplacementCostUnavailableReason])
}

public enum ReplacementCostScenarioCalculator {
    public static func calculate(
        record: ModelLifecycleRecord,
        workload: FrozenReplacementWorkload,
        catalog: ModelLifecycleCatalog,
        at date: Date
    ) -> ReplacementCostScenarioResult {
        var reasons: [ReplacementCostUnavailableReason] = []
        guard let replacement = record.replacement else { return .unavailable([.noDocumentedReplacement]) }
        if replacement.platform != record.identity.platform { reasons.append(.replacementPlatformMismatch) }
        if !workload.periodStart.timeIntervalSince1970.isFinite || !workload.periodEnd.timeIntervalSince1970.isFinite || workload.periodEnd <= workload.periodStart {
            reasons.append(.invalidWorkloadPeriod)
        }
        let inputDimensions: Set<ModelPriceDimension> = [.input, .longContextInput, .batchInput, .flexInput, .priorityInput, .regionalInput]
        let outputDimensions: Set<ModelPriceDimension> = [.output, .longContextOutput, .batchOutput, .flexOutput, .priorityOutput, .regionalOutput]
        if !workload.quantities.contains(where: { inputDimensions.contains($0.key) }) { reasons.append(.inputTokensUnknown) }
        if !workload.quantities.contains(where: { outputDimensions.contains($0.key) }) { reasons.append(.outputTokensUnknown) }
        let unknownReasons: [PricingModifier: ReplacementCostUnavailableReason] = [
            .cache: .cacheUseUnknown, .longContext: .longContextUseUnknown, .batch: .batchUseUnknown,
            .flex: .flexUseUnknown, .priority: .priorityUseUnknown, .serviceTier: .serviceTierUnknown,
            .regionalProcessing: .regionalProcessingUnknown, .tools: .toolUseUnknown,
            .containers: .containerUseUnknown
        ]
        for modifier in PricingModifier.allCases where workload.modifiers[modifier] == nil || workload.modifiers[modifier] == .unknown {
            if let reason = unknownReasons[modifier] { reasons.append(reason) }
        }
        for modifier in PricingModifier.allCases where workload.modifiers[modifier] == .used {
            let dimensions = modifier.quantityDimensions
            if dimensions.isEmpty || !dimensions.contains(where: { (workload.quantities[$0] ?? 0) > 0 }) {
                reasons.append(.usedDimensionUnpriced)
            }
        }
        let exclusiveModes: [PricingModifier] = [.longContext, .batch, .flex, .priority, .regionalProcessing]
        if exclusiveModes.filter({ workload.modifiers[$0] == .used }).count > 1
            || (workload.modifiers[.cache] == .used && exclusiveModes.contains(where: { workload.modifiers[$0] == .used })) {
            reasons.append(.incompatibleModifiers)
        }
        if workload.quantities.values.contains(where: { $0 < 0 }) { reasons.append(.invalidQuantity) }
        let revision = catalog.pricingRevisions
            .filter { $0.identity == replacement && $0.effectiveAt <= date && record.pricingRevisionIDs.contains($0.id) }
            .max { $0.effectiveAt < $1.effectiveAt }
        guard let revision else {
            reasons.append(.pricingRevisionUnavailable)
            return .unavailable(unique(reasons))
        }
        if revision.currencyCode != "USD" { reasons.append(.unsupportedCurrency) }
        for (dimension, quantity) in workload.quantities where quantity > 0 && revision.prices[dimension] == nil {
            reasons.append(.usedDimensionUnpriced)
        }
        guard reasons.isEmpty else { return .unavailable(unique(reasons)) }

        var minimum = Decimal.zero
        var maximum = Decimal.zero
        for (dimension, quantity) in workload.quantities where quantity > 0 {
            guard let price = revision.prices[dimension] else { continue }
            minimum += Decimal(quantity) / Decimal(price.unitsPerPrice) * price.minimum
            maximum += Decimal(quantity) / Decimal(price.unitsPerPrice) * price.maximum
        }
        return .calculated(CalculatedReplacementCostScenario(
            calculatedAt: date,
            original: record.identity,
            replacement: replacement,
            minimumCost: rounded(minimum),
            maximumCost: rounded(maximum),
            currencyCode: revision.currencyCode,
            catalogVersion: catalog.catalogVersion,
            pricingRevisionID: revision.id,
            pricingEffectiveAt: revision.effectiveAt,
            pricingSourceURL: revision.source.url,
            workload: workload,
            omittedDimensions: ModelPriceDimension.allCases.filter { workload.quantities[$0] == nil },
            limitations: [
                "Calculated Cost from the frozen retained token mix and catalog price revision.",
                "Not a provider quote or guarantee of future price.",
                "Does not imply behavioral equivalence, quality parity, or migration compatibility."
            ]
        ))
    }

    private static func unique(_ reasons: [ReplacementCostUnavailableReason]) -> [ReplacementCostUnavailableReason] {
        Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
    }

    private static func rounded(_ value: Decimal) -> Decimal {
        var value = value
        var result = Decimal()
        NSDecimalRound(&result, &value, 6, .plain)
        return result
    }
}

public struct ModelLifecycleRadarItem: Equatable, Sendable {
    public let usage: RetainedModelUsage
    public let lifecycle: ModelLifecycleRecord
    public let scenario: ReplacementCostScenarioResult
}

public enum ModelLifecycleRadar {
    public static func items(
        inventory: [RetainedModelUsage],
        catalog: ModelLifecycleCatalog,
        modifierEvidence: [PricingModifier: PricingModifierEvidence] = [:],
        at date: Date = Date()
    ) -> [ModelLifecycleRadarItem] {
        inventory.compactMap { usage in
            guard let record = ModelCatalogMatcher.match(
                product: usage.identity.product,
                platform: usage.identity.platform,
                modelID: usage.observedModelID,
                in: catalog
            ) else { return nil }
            let workload = FrozenReplacementWorkload(
                periodStart: usage.workloadPeriod.start,
                periodEnd: usage.workloadPeriod.end,
                quantities: [.input: usage.tokenUsage.inputTokens, .output: usage.tokenUsage.outputTokens],
                modifiers: modifierEvidence
            )
            return ModelLifecycleRadarItem(
                usage: usage,
                lifecycle: record,
                scenario: ReplacementCostScenarioCalculator.calculate(record: record, workload: workload, catalog: catalog, at: date)
            )
        }.sorted { lhs, rhs in
            switch (lhs.lifecycle.retirementDate, rhs.lifecycle.retirementDate) {
            case let (left?, right?): left < right
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): lhs.usage.observedModelID < rhs.usage.observedModelID
            }
        }
    }
}

public enum ModelRetirementAlertEvaluator {
    public static let ruleID = UUID(uuidString: "A56AA86D-48B8-4E31-B83D-16C8B70E6E51")!
    public static let defaultLeadTime: TimeInterval = 180 * 24 * 60 * 60

    public static func evaluate(
        items: [ModelLifecycleRadarItem],
        satisfied: Set<AlertThresholdSatisfaction>,
        now: Date,
        leadTime: TimeInterval = defaultLeadTime
    ) -> [AlertEvaluation] {
        guard now.timeIntervalSince1970.isFinite, leadTime.isFinite, leadTime > 0 else { return [] }
        return items.compactMap { item in
            guard let retirement = item.lifecycle.retirementDate,
                  let today = CatalogDate.utcDate(containing: now),
                  retirement > today,
                  retirement.utcBoundary().timeIntervalSince(now) <= leadTime,
                  item.lifecycle.status == .deprecated || item.lifecycle.status == .retired,
                  let identity = try? QuotaWindowIdentity(
                    product: item.lifecycle.identity.product,
                    identifier: "model-retirement|\(item.lifecycle.identity.platform.rawValue)|\(item.lifecycle.identity.modelID)",
                    resetBoundary: retirement.utcBoundary()
                  ) else { return nil }
            let window = AlertWindowIdentity.quota(identity)
            let satisfaction = AlertThresholdSatisfaction(ruleID: ruleID, window: window, threshold: 1)
            guard !satisfied.contains(satisfaction) else { return nil }
            return AlertEvaluation(
                occurrence: AlertOccurrence(ruleID: ruleID, window: window, thresholds: [1]),
                notification: AlertNotification(
                    title: "Model retirement",
                    body: "\(item.usage.observedModelID) on \(item.lifecycle.identity.platform.displayName) has an exact published retirement date of \(retirement.description). Open LimitBar for source details.",
                    threshold: 1
                ),
                findingTraces: []
            )
        }
    }
}

enum ModelLifecycleCatalogJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
