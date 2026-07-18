import CryptoKit
import Foundation

public enum SpendDimensionDisposition: Equatable, Sendable {
    case alias(String)
    case omit
}

/// Raw provider identities exist only while an explicit response is sanitized.
public struct SpendDimensionPolicy: Sendable {
    public let workspace: @Sendable (String) -> SpendDimensionDisposition
    public let apiKey: @Sendable (String) -> SpendDimensionDisposition

    public init(
        workspace: @escaping @Sendable (String) -> SpendDimensionDisposition = { _ in .omit },
        apiKey: @escaping @Sendable (String) -> SpendDimensionDisposition = { _ in .omit }
    ) {
        self.workspace = workspace
        self.apiKey = apiKey
    }

    public static let omitProviderIdentities = SpendDimensionPolicy()

    public init(workspaceAliases: SpendIdentityAliasMap, apiKeyAliases: SpendIdentityAliasMap) {
        workspace = { workspaceAliases.disposition(for: $0) }
        apiKey = { apiKeyAliases.disposition(for: $0) }
    }
}

public struct SpendIdentityAliasMap: Equatable, Sendable {
    private let aliases: [String: String]

    public init(_ aliases: [String: String]) throws {
        guard aliases.count <= 1_000 else { throw APISpendReconciliationError.invalidAlias }
        var validated: [String: String] = [:]
        for (raw, alias) in aliases {
            guard !raw.isEmpty, raw.utf8.count <= 256,
                  let safe = AnthropicSpendReportImporter.safeAlias(alias),
                  !Self.isRawDerived(alias: safe, raw: raw) else {
                throw APISpendReconciliationError.invalidAlias
            }
            validated[raw] = safe
        }
        self.aliases = validated
    }

    public func disposition(for rawIdentity: String) -> SpendDimensionDisposition {
        aliases[rawIdentity].map(SpendDimensionDisposition.alias) ?? .omit
    }

    private static func isRawDerived(alias: String, raw: String) -> Bool {
        let normalizedAlias = alias.lowercased().filter { $0.isLetter || $0.isNumber }
        let normalizedRaw = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !normalizedAlias.isEmpty else { return true }
        if normalizedAlias == normalizedRaw || normalizedAlias.contains(normalizedRaw) { return true }
        let components = raw.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 }
        return components.contains { normalizedAlias == $0 || normalizedAlias.contains($0) }
            || (normalizedRaw.count >= 6 && normalizedAlias.contains(String(normalizedRaw.suffix(6))))
    }
}

public enum SpendTokenClass: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case uncachedInput, cacheReadInput, cacheCreation5m, cacheCreation1h, output, unavailable
}

public struct SpendDimensions: Codable, Equatable, Hashable, Sendable {
    public let workspaceAlias: String?
    public let apiKeyAlias: String?
    public let model: String?
    public let serviceTier: String?
    public let tokenClass: SpendTokenClass
    public let costDescription: String?
    public let workspaceIdentityOmitted: Bool
    public let apiKeyIdentityOmitted: Bool

    private enum CodingKeys: String, CodingKey {
        case workspaceAlias, apiKeyAlias, model, serviceTier, tokenClass, costDescription
        case workspaceIdentityOmitted, apiKeyIdentityOmitted
    }

    public init(workspaceAlias: String? = nil, apiKeyAlias: String? = nil, model: String? = nil, serviceTier: String? = nil, tokenClass: SpendTokenClass = .unavailable, costDescription: String? = nil, workspaceIdentityOmitted: Bool = false, apiKeyIdentityOmitted: Bool = false) {
        self.workspaceAlias = workspaceAlias
        self.apiKeyAlias = apiKeyAlias
        self.model = model
        self.serviceTier = serviceTier
        self.tokenClass = tokenClass
        self.costDescription = costDescription
        self.workspaceIdentityOmitted = workspaceIdentityOmitted
        self.apiKeyIdentityOmitted = apiKeyIdentityOmitted
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workspaceAlias: try values.decodeIfPresent(String.self, forKey: .workspaceAlias),
            apiKeyAlias: try values.decodeIfPresent(String.self, forKey: .apiKeyAlias),
            model: try values.decodeIfPresent(String.self, forKey: .model),
            serviceTier: try values.decodeIfPresent(String.self, forKey: .serviceTier),
            tokenClass: try values.decode(SpendTokenClass.self, forKey: .tokenClass),
            costDescription: try values.decodeIfPresent(String.self, forKey: .costDescription),
            workspaceIdentityOmitted: try values.decodeIfPresent(Bool.self, forKey: .workspaceIdentityOmitted) ?? false,
            apiKeyIdentityOmitted: try values.decodeIfPresent(Bool.self, forKey: .apiKeyIdentityOmitted) ?? false
        )
    }
}

public struct ProviderReportedSpendBucket: Codable, Equatable, Hashable, Sendable {
    public let provider: ProviderKind
    public let window: ExactUsageWindow
    public let currencyCode: String
    public let amount: Decimal
    public let dimensions: SpendDimensions

    public init(provider: ProviderKind, window: ExactUsageWindow, currencyCode: String, amount: Decimal, dimensions: SpendDimensions) throws {
        let currency = currencyCode.uppercased()
        guard provider == .anthropic, amount.isFinite, amount >= 0,
              currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            throw APISpendReconciliationError.invalidProviderBucket
        }
        self.provider = provider
        self.window = window
        self.currencyCode = currency
        self.amount = amount
        self.dimensions = dimensions
    }
}

public struct ObservedLocalSpendBreakdown: Equatable, Sendable {
    public let provider: ProviderKind
    public let window: ExactUsageWindow
    public let calculatedCost: Cost
    public let dimensions: SpendDimensions
    public let project: CollectorAttribution?
    public let agent: CollectorAttribution?
    public let eventIDs: [UUID]

    public init(provider: ProviderKind, window: ExactUsageWindow, calculatedCost: Cost, dimensions: SpendDimensions, project: CollectorAttribution?, agent: CollectorAttribution?, eventIDs: [UUID] = []) throws {
        guard calculatedCost.source == .calculatedEstimate, calculatedCost.amount.isFinite, calculatedCost.amount >= 0 else {
            throw APISpendReconciliationError.invalidLocalBreakdown
        }
        self.provider = provider
        self.window = window
        self.calculatedCost = calculatedCost
        self.dimensions = dimensions
        self.project = project
        self.agent = agent
        self.eventIDs = eventIDs.sorted { $0.uuidString < $1.uuidString }
    }

    public static func priced(_ breakdowns: [ObservedLocalAttributionBreakdown], pricing: PricingTable) -> [ObservedLocalSpendBreakdown] {
        breakdowns.compactMap { value in
            let metric = UsageMetric(
                provider: value.provider,
                accountLabel: nil,
                projectLabel: nil,
                modelLabel: value.model,
                deploymentLabel: value.deployment,
                provenance: .bounded(source: value.source, window: value.window),
                tokenUsage: value.tokenUsage,
                cost: nil,
                limitStatus: .unavailable,
                refreshedAt: value.observedAt,
                freshness: .fresh
            )
            guard let cost = CostCalculator.estimatedCost(for: metric, pricing: pricing, usageDate: value.window.start) else { return nil }
            return try? ObservedLocalSpendBreakdown(
                provider: value.provider,
                window: value.window,
                calculatedCost: cost,
                dimensions: SpendDimensions(
                    workspaceAlias: value.project.map { $0.label ?? $0.id },
                    apiKeyAlias: value.agent.map { $0.label ?? $0.id },
                    model: value.model
                ),
                project: value.project,
                agent: value.agent,
                eventIDs: value.eventIDs
            )
        }
    }
}

public enum SpendCompatibilityBarrier: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case providerProduct, exactWindow, currency, model, serviceTier, tokenSemantics, identityMapping, incompleteProviderDimensions, localPricingUnavailable, legacyConclusionUnavailable
}

public enum SpendReconciliationStatus: String, Codable, Equatable, Sendable {
    case reconciled, partial, unattributed, incompatible
}

public struct SpendReconciliationRow: Codable, Equatable, Sendable {
    public let providerBucket: ProviderReportedSpendBucket
    public let attributedProviderReportedCost: Decimal
    public let observedLocalCalculatedCost: Decimal
    public let unattributedProviderReportedCost: Decimal
    public let projects: [String]
    public let agents: [String]
    public let status: SpendReconciliationStatus
    public let barriers: Set<SpendCompatibilityBarrier>
}

public struct LocalSpendEvidenceIdentity: Codable, Equatable, Sendable {
    public let sourceRevision: String
    public let evidenceDigest: String
    public let eventCount: Int

    public init(sourceRevision: String, evidenceDigest: String, eventCount: Int) throws {
        guard sourceRevision.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              evidenceDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              eventCount > 0 else { throw APISpendReconciliationError.invalidConclusion }
        self.sourceRevision = sourceRevision
        self.evidenceDigest = evidenceDigest
        self.eventCount = eventCount
    }

    public static func make(sourceRevision: String, breakdowns: [ObservedLocalSpendBreakdown]) -> LocalSpendEvidenceIdentity? {
        guard sourceRevision.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        let eventIDs = Array(Set(breakdowns.flatMap(\.eventIDs))).sorted { $0.uuidString < $1.uuidString }
        guard !eventIDs.isEmpty else { return nil }
        var value = sourceRevision
        for breakdown in breakdowns.sorted(by: { ($0.window.start, $0.dimensions.model ?? "", $0.project?.id ?? "", $0.agent?.id ?? "") < ($1.window.start, $1.dimensions.model ?? "", $1.project?.id ?? "", $1.agent?.id ?? "") }) {
            value += "|\(breakdown.window.start.timeIntervalSince1970)|\(breakdown.window.end.timeIntervalSince1970)|\(breakdown.provider.rawValue)|\(breakdown.dimensions.model ?? "")|\(breakdown.project?.id ?? "")|\(breakdown.agent?.id ?? "")|\(breakdown.calculatedCost.amount)|\(breakdown.calculatedCost.currencyCode)"
        }
        value += "|" + eventIDs.map(\.uuidString).joined(separator: "|")
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return try? LocalSpendEvidenceIdentity(sourceRevision: sourceRevision, evidenceDigest: digest, eventCount: eventIDs.count)
    }

    public static func make(sourceRevision: String, breakdowns: [ObservedLocalAttributionBreakdown]) -> LocalSpendEvidenceIdentity? {
        guard sourceRevision.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        let eventIDs = Array(Set(breakdowns.flatMap(\.eventIDs))).sorted { $0.uuidString < $1.uuidString }
        guard !eventIDs.isEmpty else { return nil }
        let facts = breakdowns.sorted { ($0.window.start, $0.model, $0.project?.id ?? "", $0.agent?.id ?? "") < ($1.window.start, $1.model, $1.project?.id ?? "", $1.agent?.id ?? "") }.map {
            "\($0.window.start.timeIntervalSince1970)|\($0.window.end.timeIntervalSince1970)|\($0.provider.rawValue)|\($0.model)|\($0.project?.id ?? "")|\($0.agent?.id ?? "")|\($0.tokenUsage.inputTokens)|\($0.tokenUsage.outputTokens)"
        }
        let value = ([sourceRevision] + facts + eventIDs.map(\.uuidString)).joined(separator: "|")
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return try? LocalSpendEvidenceIdentity(sourceRevision: sourceRevision, evidenceDigest: digest, eventCount: eventIDs.count)
    }
}

public struct SpendReconciliationConclusion: Codable, Equatable, Sendable {
    public let providerBuckets: [ProviderReportedSpendBucket]
    public let rows: [SpendReconciliationRow]
    public let pricingRevision: String
    public let localEvidenceIdentity: LocalSpendEvidenceIdentity?

    public init(providerBuckets: [ProviderReportedSpendBucket], rows: [SpendReconciliationRow], pricingRevision: String, localEvidenceIdentity: LocalSpendEvidenceIdentity?) throws {
        guard !providerBuckets.isEmpty, !rows.isEmpty, !pricingRevision.isEmpty, pricingRevision.utf8.count <= 128 else {
            throw APISpendReconciliationError.invalidConclusion
        }
        self.providerBuckets = providerBuckets
        self.rows = rows
        self.pricingRevision = pricingRevision
        self.localEvidenceIdentity = localEvidenceIdentity
    }
}

extension SpendReconciliationRow: Identifiable {
    public var id: ProviderReportedSpendBucket { providerBucket }
}

public enum APISpendReconciliationError: Error, Equatable {
    case malformedResponse, invalidProviderBucket, invalidLocalBreakdown, duplicateBucket, invalidAlias, invalidConclusion, exportFailed
}

public enum AnthropicSpendRefreshResult: Equatable, Sendable {
    case success([ProviderReportedSpendBucket])
    case failure(ProviderFailureReason)
    case cancelled
}

public enum AnthropicSpendReportImporter {
    private struct Response: Decodable { let data: [Bucket] }
    private struct Bucket: Decodable {
        let startingAt: String
        let endingAt: String
        let results: [Row]
        enum CodingKeys: String, CodingKey { case startingAt = "starting_at", endingAt = "ending_at", results }
    }
    private struct Row: Decodable {
        let amount: String
        let currency: String
        let workspaceID: String?
        let apiKeyID: String?
        let model: String?
        let serviceTier: String?
        let tokenClass: String?
        let description: String?
        let organizationID: String?
        enum CodingKeys: String, CodingKey {
            case amount, currency, model, description
            case workspaceID = "workspace_id"
            case apiKeyID = "api_key_id"
            case serviceTier = "service_tier"
            case tokenClass = "token_class"
            case organizationID = "organization_id"
        }
    }

    public static func `import`(_ data: Data, policy: SpendDimensionPolicy) throws -> [ProviderReportedSpendBucket] {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw APISpendReconciliationError.malformedResponse }
        let formatter = ISO8601DateFormatter()
        var result: [ProviderReportedSpendBucket] = []
        var identities = Set<String>()
        for bucket in response.data {
            guard let start = formatter.date(from: bucket.startingAt), let end = formatter.date(from: bucket.endingAt),
                  end.timeIntervalSince(start) == 86_400,
                  isUTCMidnight(start), isUTCMidnight(end),
                  let window = try? ExactUsageWindow(timeWindow: .today, start: start, end: end, basis: .utcBilling) else {
                throw APISpendReconciliationError.malformedResponse
            }
            for row in bucket.results {
                guard let cents = Decimal(string: row.amount), cents.isFinite, cents >= 0 else { throw APISpendReconciliationError.malformedResponse }
                let workspace = try alias(row.workspaceID, using: policy.workspace)
                let apiKey = try alias(row.apiKeyID, using: policy.apiKey)
                let dimensions = SpendDimensions(
                    workspaceAlias: workspace,
                    apiKeyAlias: apiKey,
                    model: safeLabel(row.model),
                    serviceTier: safeLabel(row.serviceTier),
                    tokenClass: SpendTokenClass(rawValue: row.tokenClass ?? "") ?? .unavailable,
                    costDescription: safeLabel(row.description),
                    workspaceIdentityOmitted: row.workspaceID != nil && workspace == nil,
                    apiKeyIdentityOmitted: row.apiKeyID != nil && apiKey == nil
                )
                let value = try ProviderReportedSpendBucket(provider: .anthropic, window: window, currencyCode: row.currency, amount: cents / 100, dimensions: dimensions)
                let fingerprint = try fingerprint(value)
                guard identities.insert(fingerprint).inserted else { throw APISpendReconciliationError.duplicateBucket }
                result.append(value)
            }
        }
        return result.sorted { (try? fingerprint($0)) ?? "" < (try? fingerprint($1)) ?? "" }
    }

    public static func fingerprint(_ bucket: ProviderReportedSpendBucket) throws -> String {
        struct Identity: Encodable {
            let provider: ProviderKind
            let window: ExactUsageWindow
            let currencyCode: String
            let dimensions: SpendDimensions
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = Identity(provider: bucket.provider, window: bucket.window, currencyCode: bucket.currencyCode, dimensions: bucket.dimensions)
        let digest = SHA256.hash(data: try encoder.encode(identity))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func alias(_ raw: String?, using disposition: @Sendable (String) -> SpendDimensionDisposition) throws -> String? {
        guard let raw else { return nil }
        switch disposition(raw) {
        case .omit: return nil
        case let .alias(value):
            guard let safe = safeAlias(value),
                  (try? SpendIdentityAliasMap([raw: safe])) != nil else { throw APISpendReconciliationError.invalidAlias }
            return safe
        }
    }

    static func safeAlias(_ value: String) -> String? {
        guard let safe = safeLabel(value), safe.utf8.count <= 64 else { return nil }
        return safe
    }

    private static func safeLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    private static func isUTCMidnight(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return components.hour == 0 && components.minute == 0 && components.second == 0
    }
}

public enum APISpendReconciler {
    public static func reconcile(provider buckets: [ProviderReportedSpendBucket], local: [ObservedLocalSpendBreakdown], hasUnpricedLocalEvidence: Bool = false) -> [SpendReconciliationRow] {
        aggregateProviderBuckets(buckets).map { bucket in
            let sameProvider = local.filter { $0.provider == bucket.provider }
            let sameWindow = sameProvider.filter { $0.window == bucket.window }
            let sameCurrency = sameWindow.filter { $0.calculatedCost.currencyCode.uppercased() == bucket.currencyCode }
            let canAttribute = bucket.dimensions.model != nil
                && !bucket.dimensions.workspaceIdentityOmitted
                && !bucket.dimensions.apiKeyIdentityOmitted
            let compatible = canAttribute ? sameCurrency.filter { dimensionsMatch(bucket.dimensions, $0.dimensions) } : []
            var barriers = Set<SpendCompatibilityBarrier>()
            if sameProvider.isEmpty, !local.isEmpty { barriers.insert(.providerProduct) }
            if sameWindow.isEmpty, !sameProvider.isEmpty { barriers.insert(.exactWindow) }
            if sameCurrency.isEmpty, !sameWindow.isEmpty { barriers.insert(.currency) }
            if compatible.isEmpty, !sameCurrency.isEmpty {
                if let model = bucket.dimensions.model, !sameCurrency.contains(where: { $0.dimensions.model == model }) { barriers.insert(.model) }
                if let tier = bucket.dimensions.serviceTier, !sameCurrency.contains(where: { $0.dimensions.serviceTier == tier }) { barriers.insert(.serviceTier) }
                if bucket.dimensions.tokenClass != .unavailable, !sameCurrency.contains(where: { $0.dimensions.tokenClass == bucket.dimensions.tokenClass }) { barriers.insert(.tokenSemantics) }
                if let alias = bucket.dimensions.workspaceAlias, !sameCurrency.contains(where: { $0.dimensions.workspaceAlias == alias }) { barriers.insert(.identityMapping) }
                if let alias = bucket.dimensions.apiKeyAlias, !sameCurrency.contains(where: { $0.dimensions.apiKeyAlias == alias }) { barriers.insert(.identityMapping) }
            }
            if bucket.dimensions.model == nil { barriers.insert(.incompleteProviderDimensions) }
            if bucket.dimensions.workspaceIdentityOmitted || bucket.dimensions.apiKeyIdentityOmitted { barriers.insert(.identityMapping) }
            if compatible.isEmpty, hasUnpricedLocalEvidence { barriers.insert(.localPricingUnavailable) }
            let localCost = compatible.reduce(Decimal.zero) { $0 + $1.calculatedCost.amount }
            let attributed = min(bucket.amount, localCost)
            let unattributed = max(0, bucket.amount - attributed)
            let status: SpendReconciliationStatus
            if !barriers.isEmpty && compatible.isEmpty { status = barriers == [.incompleteProviderDimensions] ? .unattributed : .incompatible }
            else if attributed == 0 { status = .unattributed }
            else if unattributed > 0 || localCost != bucket.amount { status = .partial }
            else { status = .reconciled }
            return SpendReconciliationRow(
                providerBucket: bucket,
                attributedProviderReportedCost: attributed,
                observedLocalCalculatedCost: localCost,
                unattributedProviderReportedCost: unattributed,
                projects: labels(compatible.compactMap(\.project)),
                agents: labels(compatible.compactMap(\.agent)),
                status: status,
                barriers: barriers
            )
        }
    }

    public static func conclude(provider buckets: [ProviderReportedSpendBucket], local: [ObservedLocalSpendBreakdown], pricingRevision: String, localEvidenceIdentity: LocalSpendEvidenceIdentity?, hasUnpricedLocalEvidence: Bool = false) throws -> SpendReconciliationConclusion {
        try SpendReconciliationConclusion(
            providerBuckets: buckets,
            rows: reconcile(provider: buckets, local: local, hasUnpricedLocalEvidence: hasUnpricedLocalEvidence),
            pricingRevision: pricingRevision,
            localEvidenceIdentity: localEvidenceIdentity
        )
    }

    private static func dimensionsMatch(_ provider: SpendDimensions, _ local: SpendDimensions) -> Bool {
        provider.model == local.model
            && provider.serviceTier == local.serviceTier
            && provider.tokenClass == local.tokenClass
            && provider.workspaceAlias == local.workspaceAlias
            && provider.apiKeyAlias == local.apiKeyAlias
    }

    private static func aggregateProviderBuckets(_ buckets: [ProviderReportedSpendBucket]) -> [ProviderReportedSpendBucket] {
        struct Key: Hashable {
            let provider: ProviderKind; let window: ExactUsageWindow; let currency: String
            let workspace: String?; let apiKey: String?; let model: String?; let tier: String?; let token: SpendTokenClass
            let workspaceOmitted: Bool; let apiKeyOmitted: Bool
        }
        let grouped = Dictionary(grouping: buckets) { bucket in
            Key(provider: bucket.provider, window: bucket.window, currency: bucket.currencyCode, workspace: bucket.dimensions.workspaceAlias, apiKey: bucket.dimensions.apiKeyAlias, model: bucket.dimensions.model, tier: bucket.dimensions.serviceTier, token: bucket.dimensions.tokenClass, workspaceOmitted: bucket.dimensions.workspaceIdentityOmitted, apiKeyOmitted: bucket.dimensions.apiKeyIdentityOmitted)
        }
        return grouped.compactMap { key, values in
            let amount = values.reduce(Decimal.zero) { $0 + $1.amount }
            guard amount.isFinite else { return nil }
            let descriptions = Set(values.compactMap(\.dimensions.costDescription))
            let dimensions = SpendDimensions(workspaceAlias: key.workspace, apiKeyAlias: key.apiKey, model: key.model, serviceTier: key.tier, tokenClass: key.token, costDescription: descriptions.count == 1 ? descriptions.first : nil, workspaceIdentityOmitted: key.workspaceOmitted, apiKeyIdentityOmitted: key.apiKeyOmitted)
            return try? ProviderReportedSpendBucket(provider: key.provider, window: key.window, currencyCode: key.currency, amount: amount, dimensions: dimensions)
        }.sorted { ((try? AnthropicSpendReportImporter.fingerprint($0)) ?? "") < ((try? AnthropicSpendReportImporter.fingerprint($1)) ?? "") }
    }
    private static func labels(_ values: [CollectorAttribution]) -> [String] {
        Array(Set(values.map { $0.label ?? $0.id })).sorted()
    }
}

public struct SpendCSVArtifact: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let allowedColumns = ["schema_version", "provider_product", "window_start", "window_end", "currency", "workspace_alias", "workspace_mapping", "api_key_alias", "api_key_mapping", "model", "service_tier", "token_class", "provider_reported_cost", "attributed_provider_reported_cost", "observed_local_calculated_cost", "unattributed_provider_reported_cost", "status", "barriers"]
    public let data: Data
    public var preview: String { String(decoding: data, as: UTF8.self) }

    public static func make(rows: [SpendReconciliationRow]) -> SpendCSVArtifact {
        let formatter = ISO8601DateFormatter()
        let lines = [allowedColumns.joined(separator: ",")] + rows.map { row in
            let bucket = row.providerBucket
            return [
                String(schemaVersion), bucket.provider.rawValue, formatter.string(from: bucket.window.start), formatter.string(from: bucket.window.end), bucket.currencyCode,
                bucket.dimensions.workspaceAlias ?? "", bucket.dimensions.workspaceIdentityOmitted ? "omitted" : (bucket.dimensions.workspaceAlias == nil ? "unavailable" : "aliased"),
                bucket.dimensions.apiKeyAlias ?? "", bucket.dimensions.apiKeyIdentityOmitted ? "omitted" : (bucket.dimensions.apiKeyAlias == nil ? "unavailable" : "aliased"),
                bucket.dimensions.model ?? "", bucket.dimensions.serviceTier ?? "", bucket.dimensions.tokenClass.rawValue,
                bucket.amount.description, row.attributedProviderReportedCost.description, row.observedLocalCalculatedCost.description, row.unattributedProviderReportedCost.description,
                row.status.rawValue, row.barriers.map(\.rawValue).sorted().joined(separator: "|")
            ].map(csv).joined(separator: ",")
        }
        return SpendCSVArtifact(data: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func csv(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}
