import Foundation

public enum BundledModelLifecycleCatalog {
    public static let keyID = "limitbar-catalog-2026-01"

    public static let envelope: SignedModelLifecycleCatalog = {
        let payload = try! ModelLifecycleCatalogJSON.encoder.encode(catalog)
        return SignedModelLifecycleCatalog(
            keyID: keyID,
            payload: payload,
            signature: Data(base64Encoded: "doGbjmn2xryHs+0Th6IfwTEBkU0HJAurudYnPx2V7k1WRfclFcJwpfhcFMPru+fsOZZxPA2AY/BwPl0XyZZoDw==")!
        )
    }()

    public static let verifier = ModelCatalogVerifier(publicKeys: [
        keyID: Data(base64Encoded: "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=")!
    ])

    public static func verifiedCatalog() throws -> ModelLifecycleCatalog { try verifier.verify(envelope) }

    static let catalog: ModelLifecycleCatalog = {
        let retrieved = instant("2026-07-18T17:00:00Z")
        let anthropicLifecycle = source("https://docs.anthropic.com/en/docs/about-claude/model-deprecations", retrieved)
        let anthropicPricing = source("https://docs.anthropic.com/en/docs/about-claude/pricing", retrieved)
        let openAILifecycle = source("https://platform.openai.com/docs/deprecations", retrieved)
        let openAIPricing = source("https://platform.openai.com/docs/pricing", retrieved)

        let opus3 = identity(.anthropicAPI, .anthropicAPI, "claude-3-opus-20240229")
        let opus41 = identity(.anthropicAPI, .anthropicAPI, "claude-opus-4-1-20250805")
        let opus48 = identity(.anthropicAPI, .anthropicAPI, "claude-opus-4-8")
        let sonnet35 = identity(.anthropicAPI, .anthropicAPI, "claude-3-5-sonnet-20240620")
        let sonnet4 = identity(.anthropicAPI, .anthropicAPI, "claude-sonnet-4-20250514")
        let sonnet46 = identity(.anthropicAPI, .anthropicAPI, "claude-sonnet-4-6")
        let gpt40314 = identity(.openAIAPI, .openAIAPI, "gpt-4-0314")
        let gpt51Codex = identity(.openAIAPI, .openAIAPI, "gpt-5.1-codex")
        let gpt5Snapshot = identity(.openAIAPI, .openAIAPI, "gpt-5-2025-08-07")
        let gpt55 = identity(.openAIAPI, .openAIAPI, "gpt-5.5")

        let records = [
            ModelLifecycleRecord(identity: opus3, status: .retired, effectiveAt: instant("2025-06-30T00:00:00Z"), retirementDate: day("2026-01-05"), replacement: opus48, lifecycleSource: anthropicLifecycle, pricingRevisionIDs: ["anthropic-opus-4.8-observed-2026-07-18"]),
            ModelLifecycleRecord(identity: opus41, status: .deprecated, effectiveAt: instant("2026-06-05T00:00:00Z"), retirementDate: day("2026-08-05"), replacement: opus48, lifecycleSource: anthropicLifecycle, pricingRevisionIDs: ["anthropic-opus-4.8-observed-2026-07-18"]),
            ModelLifecycleRecord(identity: opus48, status: .active, effectiveAt: retrieved, retirementDate: nil, replacement: nil, lifecycleSource: anthropicLifecycle, pricingRevisionIDs: ["anthropic-opus-4.8-observed-2026-07-18"]),
            ModelLifecycleRecord(identity: sonnet35, status: .retired, effectiveAt: instant("2025-08-13T00:00:00Z"), retirementDate: day("2025-10-28"), replacement: sonnet46, lifecycleSource: anthropicLifecycle, pricingRevisionIDs: ["anthropic-sonnet-4.6-observed-2026-07-18"]),
            ModelLifecycleRecord(identity: sonnet4, status: .retired, effectiveAt: instant("2026-04-14T00:00:00Z"), retirementDate: day("2026-06-15"), replacement: sonnet46, lifecycleSource: anthropicLifecycle, pricingRevisionIDs: ["anthropic-sonnet-4.6-observed-2026-07-18"]),
            ModelLifecycleRecord(identity: sonnet46, status: .active, effectiveAt: retrieved, retirementDate: nil, replacement: nil, lifecycleSource: anthropicLifecycle, pricingRevisionIDs: ["anthropic-sonnet-4.6-observed-2026-07-18"]),
            ModelLifecycleRecord(identity: gpt40314, status: .retired, effectiveAt: instant("2025-09-26T00:00:00Z"), retirementDate: day("2026-03-26"), replacement: nil, lifecycleSource: openAILifecycle, pricingRevisionIDs: []),
            ModelLifecycleRecord(identity: gpt51Codex, status: .deprecated, effectiveAt: instant("2026-04-22T00:00:00Z"), retirementDate: day("2026-07-23"), replacement: gpt55, lifecycleSource: openAILifecycle, pricingRevisionIDs: ["openai-gpt-5.5-observed-2026-07-18"]),
            ModelLifecycleRecord(identity: gpt5Snapshot, status: .deprecated, effectiveAt: instant("2026-06-11T00:00:00Z"), retirementDate: day("2026-12-11"), replacement: gpt55, lifecycleSource: openAILifecycle, pricingRevisionIDs: ["openai-gpt-5.5-observed-2026-07-18"]),
            ModelLifecycleRecord(identity: gpt55, status: .unspecified, effectiveAt: retrieved, retirementDate: nil, replacement: nil, lifecycleSource: openAILifecycle, pricingRevisionIDs: ["openai-gpt-5.5-observed-2026-07-18"])
        ]
        let pricing = [
            revision("anthropic-opus-4.8-observed-2026-07-18", opus48, retrieved, anthropicPricing, [
                .input: rate(5), .output: rate(25), .cachedInput: rate(0.5),
                .cacheWriteFiveMinute: rate(6.25), .cacheWriteOneHour: rate(10),
                .longContextInput: rate(5), .longContextOutput: rate(25),
                .batchInput: rate(2.5), .batchOutput: rate(12.5),
                .webSearchCall: unit(10, per: 1_000)
            ]),
            revision("anthropic-sonnet-4.6-observed-2026-07-18", sonnet46, retrieved, anthropicPricing, [
                .input: rate(3), .output: rate(15), .cachedInput: rate(0.3),
                .cacheWriteFiveMinute: rate(3.75), .cacheWriteOneHour: rate(6),
                .longContextInput: rate(3), .longContextOutput: rate(15),
                .batchInput: rate(1.5), .batchOutput: rate(7.5),
                .webSearchCall: unit(10, per: 1_000)
            ]),
            revision("openai-gpt-5.5-observed-2026-07-18", gpt55, retrieved, openAIPricing, [
                .input: rate(5), .output: rate(30), .cachedInput: rate(0.5),
                .longContextInput: rate(10), .longContextOutput: rate(45),
                .batchInput: rate(2.5), .batchOutput: rate(15),
                .flexInput: rate(2.5), .flexOutput: rate(15),
                .priorityInput: rate(12.5), .priorityOutput: rate(75),
                .webSearchCall: unit(10, per: 1_000), .fileSearchCall: unit(2.5, per: 1_000)
            ])
        ]
        return ModelLifecycleCatalog(catalogVersion: "2026.07.18.3", publishedAt: retrieved, records: records, pricingRevisions: pricing)
    }()

    private static func identity(_ product: ProviderProduct, _ platform: ModelPlatform, _ model: String) -> CatalogModelIdentity {
        CatalogModelIdentity(product: product, platform: platform, modelID: model)
    }

    private static func source(_ value: String, _ retrievedAt: Date) -> CatalogSourceReference {
        CatalogSourceReference(url: URL(string: value)!, retrievedAt: retrievedAt)
    }

    private static func revision(_ id: String, _ identity: CatalogModelIdentity, _ effectiveAt: Date, _ source: CatalogSourceReference, _ prices: [ModelPriceDimension: ModelUnitPrice]) -> ModelPricingRevision {
        ModelPricingRevision(id: id, identity: identity, effectiveAt: effectiveAt, currencyCode: "USD", prices: prices, source: source)
    }

    private static func rate(_ value: Decimal) -> ModelUnitPrice { unit(value, per: 1_000_000) }
    private static func unit(_ value: Decimal, per units: Int) -> ModelUnitPrice { ModelUnitPrice(minimum: value, maximum: value, unitsPerPrice: units) }
    private static func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private static func day(_ value: String) -> CatalogDate { try! CatalogDate(value) }
}
