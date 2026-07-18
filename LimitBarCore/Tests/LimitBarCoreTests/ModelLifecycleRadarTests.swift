import Foundation
import CryptoKit
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("Model lifecycle radar")
struct ModelLifecycleRadarTests {
    @Test("bundled catalog has a valid signature and official provenance")
    func bundledCatalogSignature() throws {
        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let opusRetirement = try CatalogDate("2026-08-05")

        #expect(catalog.catalogVersion == "2026.07.18.3")
        #expect(catalog.records.contains { $0.status == .active })
        #expect(catalog.records.contains { $0.status == .deprecated && $0.retirementDate == opusRetirement })
        #expect(catalog.records.contains { $0.status == .retired && $0.replacement != nil })
        #expect(catalog.records.allSatisfy { $0.identity.platform == .anthropicAPI || $0.identity.platform == .openAIAPI })
    }

    @Test("bundled facts match official pages retrieved 2026-07-18")
    func bundledOfficialFacts() throws {
        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let august5 = try CatalogDate("2026-08-05")
        let june15 = try CatalogDate("2026-06-15")
        let july23 = try CatalogDate("2026-07-23")
        let march26 = try CatalogDate("2026-03-26")
        let opus41 = try #require(ModelCatalogMatcher.match(product: .anthropicAPI, platform: .anthropicAPI, modelID: "claude-opus-4-1-20250805", in: catalog))
        #expect(opus41.status == .deprecated)
        #expect(opus41.retirementDate == august5)
        #expect(opus41.replacement?.modelID == "claude-opus-4-8")

        let sonnet4 = try #require(ModelCatalogMatcher.match(product: .anthropicAPI, platform: .anthropicAPI, modelID: "claude-sonnet-4-20250514", in: catalog))
        #expect(sonnet4.status == .retired)
        #expect(sonnet4.retirementDate == june15)
        #expect(sonnet4.replacement?.modelID == "claude-sonnet-4-6")

        let codex = try #require(ModelCatalogMatcher.match(product: .openAIAPI, platform: .openAIAPI, modelID: "gpt-5.1-codex", in: catalog))
        #expect(codex.status == .deprecated)
        #expect(codex.retirementDate == july23)
        #expect(codex.replacement?.modelID == "gpt-5.5")

        let gpt4 = try #require(ModelCatalogMatcher.match(product: .openAIAPI, platform: .openAIAPI, modelID: "gpt-4-0314", in: catalog))
        #expect(gpt4.status == .retired)
        #expect(gpt4.retirementDate == march26)
        #expect(gpt4.replacement == nil)

        let gpt55 = try #require(ModelCatalogMatcher.match(product: .openAIAPI, platform: .openAIAPI, modelID: "gpt-5.5", in: catalog))
        #expect(gpt55.status == .unspecified)
        let gpt55Price = try #require(catalog.pricingRevisions.first { $0.identity == gpt55.identity })
        #expect(gpt55Price.prices[.input]?.minimum == 5)
        #expect(gpt55Price.prices[.output]?.minimum == 30)
    }

    @Test("catalog rejects tampering, unknown keys, schemas, currencies, and platform mappings")
    func catalogFailsClosed() throws {
        let envelope = BundledModelLifecycleCatalog.envelope
        var tampered = envelope.payload
        tampered[0] ^= 1
        #expect(throws: ModelCatalogValidationError.invalidSignature) {
            try BundledModelLifecycleCatalog.verifier.verify(.init(keyID: envelope.keyID, payload: tampered, signature: envelope.signature))
        }
        #expect(throws: ModelCatalogValidationError.unknownSigningKey) {
            try BundledModelLifecycleCatalog.verifier.verify(.init(keyID: "unknown", payload: envelope.payload, signature: envelope.signature))
        }

        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let unsupported = ModelLifecycleCatalog(schemaVersion: 99, catalogVersion: catalog.catalogVersion, publishedAt: catalog.publishedAt, records: catalog.records, pricingRevisions: catalog.pricingRevisions)
        #expect(throws: ModelCatalogValidationError.unsupportedSchema(99)) { try ModelCatalogVerifier.validate(unsupported) }

        let invalidPlatform = ModelLifecycleRecord(
            identity: .init(product: .openAIAPI, platform: .amazonBedrock, modelID: "gpt-impossible"),
            status: .active,
            effectiveAt: catalog.publishedAt,
            retirementDate: nil,
            replacement: nil,
            lifecycleSource: catalog.records[0].lifecycleSource,
            pricingRevisionIDs: []
        )
        let invalid = ModelLifecycleCatalog(catalogVersion: "2026.07.18.3", publishedAt: catalog.publishedAt, records: [invalidPlatform], pricingRevisions: [])
        #expect(throws: ModelCatalogValidationError.invalidIdentity) { try ModelCatalogVerifier.validate(invalid) }
    }

    @Test("matching is exact for identifiers, aliases, products, and platforms")
    func exactAdversarialMatching() throws {
        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let exact = ModelCatalogMatcher.match(product: .openAIAPI, platform: .openAIAPI, modelID: "gpt-5.1-codex", in: catalog)

        #expect(exact?.identity.modelID == "gpt-5.1-codex")
        #expect(ModelCatalogMatcher.match(product: .openAIAPI, platform: .openAIAPI, modelID: "gpt-5.1-codex-extra", in: catalog) == nil)
        #expect(ModelCatalogMatcher.match(product: .openAIAPI, platform: .openAIAPI, modelID: "GPT-5.1-CODEX", in: catalog) == nil)
        #expect(ModelCatalogMatcher.match(product: .azureOpenAI, platform: .azureOpenAI, modelID: "gpt-5.1-codex", in: catalog) == nil)
        #expect(ModelCatalogMatcher.match(product: .anthropicAPI, platform: .amazonBedrock, modelID: "claude-3-5-sonnet-20240620", in: catalog) == nil)
    }

    @Test("retained inventory contains only positive measured exact matches in the selected period")
    func retainedUsedInventory() throws {
        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let path = try inventoryDatabase(retentionDays: 90)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try insertDaily(path: path, id: "exact", model: "gpt-5.1-codex", start: "2026-07-10T00:00:00Z", input: 10, output: 2)
        try insertDaily(path: path, id: "near-prefix", model: "gpt-5.1-codex-extra", start: "2026-07-10T00:00:00Z", input: 99, output: 0)
        try insertDaily(path: path, id: "zero", model: "gpt-5-2025-08-07", start: "2026-07-10T00:00:00Z", input: 0, output: 0)

        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let snapshot = try ModelLifecycleInventoryLoader(path: path).load(catalog: catalog, now: date("2026-07-18T18:00:00Z"))
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(snapshot.retentionDays == 90)
        #expect(snapshot.models.map(\.observedModelID) == ["gpt-5.1-codex"])
        #expect(snapshot.models[0].tokenUsage.totalTokens == 12)
        #expect(after == before)
    }

    @Test("retained exact aggregates supplement uncovered full-retention daily periods without duplicating coverage")
    func retainedExactAggregateInventory() throws {
        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let path = try inventoryDatabase(retentionDays: 365)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try insertDaily(path: path, id: "daily", model: "gpt-5.1-codex", start: "2026-01-02T00:00:00Z", input: 100, output: 0)
        try insertExact(path: path, id: "uncovered", model: "gpt-5.1-codex", start: "2026-01-01T00:00:00Z", input: 7, output: 3)
        try insertExact(path: path, id: "covered", model: "gpt-5.1-codex", start: "2026-01-02T00:00:00Z", input: 50, output: 0)
        try insertExact(path: path, id: "expired", model: "gpt-5.1-codex", start: "2025-01-01T00:00:00Z", input: 500, output: 0)

        let snapshot = try ModelLifecycleInventoryLoader(path: path).load(catalog: catalog, now: date("2026-07-18T18:00:00Z"))
        #expect(snapshot.retentionDays == 365)
        #expect(snapshot.models.count == 1)
        #expect(snapshot.models[0].tokenUsage == TokenUsage(inputTokens: 107, outputTokens: 3))
    }

    @Test("source calendar dates encode without local timezone conversion")
    func sourceCalendarDateSemantics() throws {
        let value = try CatalogDate("2026-08-05")
        let data = try ModelLifecycleCatalogJSON.encoder.encode(value)
        #expect(String(decoding: data, as: UTF8.self) == "\"2026-08-05\"")
        #expect(try ModelLifecycleCatalogJSON.decoder.decode(CatalogDate.self, from: data) == value)
        #expect(value.description == "2026-08-05")
        #expect(value.utcBoundary() == date("2026-08-05T00:00:00Z"))
    }

    @Test("calculated replacement cost requires every modifier and freezes provenance")
    func completeCalculatedCost() throws {
        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let record = try #require(ModelCatalogMatcher.match(product: .openAIAPI, platform: .openAIAPI, modelID: "gpt-5.1-codex", in: catalog))
        let modifiers = Dictionary(uniqueKeysWithValues: PricingModifier.allCases.map { ($0, PricingModifierEvidence.notUsed) })
        let workload = FrozenReplacementWorkload(
            periodStart: date("2026-07-01T00:00:00Z"),
            periodEnd: date("2026-07-02T00:00:00Z"),
            quantities: [.input: 1_000_000, .output: 500_000],
            modifiers: modifiers
        )

        guard case let .calculated(scenario) = ReplacementCostScenarioCalculator.calculate(record: record, workload: workload, catalog: catalog, at: date("2026-07-18T18:00:00Z")) else {
            Issue.record("Expected a complete Calculated Cost scenario")
            return
        }
        #expect(scenario.minimumCost == 20)
        #expect(scenario.maximumCost == 20)
        #expect(scenario.catalogVersion == catalog.catalogVersion)
        #expect(scenario.pricingRevisionID == "openai-gpt-5.5-observed-2026-07-18")
        #expect(scenario.workload == workload)
        #expect(scenario.limitations.joined().contains("Not a provider quote"))
    }

    @Test("all unknown modifiers and used unpriced dimensions are explicit")
    func unavailableReasons() throws {
        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let record = try #require(ModelCatalogMatcher.match(product: .openAIAPI, platform: .openAIAPI, modelID: "gpt-5.1-codex", in: catalog))
        let unknown = FrozenReplacementWorkload(
            periodStart: date("2026-07-01T00:00:00Z"),
            periodEnd: date("2026-07-02T00:00:00Z"),
            quantities: [.input: 10, .output: 1],
            modifiers: [:]
        )
        guard case let .unavailable(reasons) = ReplacementCostScenarioCalculator.calculate(record: record, workload: unknown, catalog: catalog, at: date("2026-07-18T18:00:00Z")) else {
            Issue.record("Unknown modifiers must fail closed")
            return
        }
        #expect(Set(reasons).isSuperset(of: Set([
            .cacheUseUnknown, .longContextUseUnknown, .batchUseUnknown, .flexUseUnknown,
            .priorityUseUnknown, .serviceTierUnknown, .regionalProcessingUnknown,
            .toolUseUnknown, .containerUseUnknown
        ])))

        var modifiers = Dictionary(uniqueKeysWithValues: PricingModifier.allCases.map { ($0, PricingModifierEvidence.notUsed) })
        modifiers[.containers] = .used
        let toolWorkload = FrozenReplacementWorkload(
            periodStart: unknown.periodStart,
            periodEnd: unknown.periodEnd,
            quantities: [.input: 10, .output: 1, .containerSession: 1],
            modifiers: modifiers
        )
        #expect(ReplacementCostScenarioCalculator.calculate(record: record, workload: toolWorkload, catalog: catalog, at: date("2026-07-18T18:00:00Z")) == .unavailable([.usedDimensionUnpriced]))

        for modifier in PricingModifier.allCases {
            var evidence = Dictionary(uniqueKeysWithValues: PricingModifier.allCases.map { ($0, PricingModifierEvidence.notUsed) })
            evidence[modifier] = .used
            let missingUsedQuantity = FrozenReplacementWorkload(
                periodStart: unknown.periodStart,
                periodEnd: unknown.periodEnd,
                quantities: [.input: 10, .output: 1],
                modifiers: evidence
            )
            #expect(ReplacementCostScenarioCalculator.calculate(record: record, workload: missingUsedQuantity, catalog: catalog, at: date("2026-07-18T18:00:00Z")) == .unavailable([.usedDimensionUnpriced]))
        }
    }

    @Test("retirement alerts require an exact future date and deduplicate through the delivery identity")
    func exactRetirementAlerts() throws {
        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let record = try #require(ModelCatalogMatcher.match(product: .anthropicAPI, platform: .anthropicAPI, modelID: "claude-opus-4-1-20250805", in: catalog))
        let usage = RetainedModelUsage(
            identity: record.identity,
            observedModelID: "claude-opus-4-1-20250805",
            workloadPeriod: DateInterval(start: date("2026-07-17T00:00:00Z"), end: date("2026-07-18T00:00:00Z")),
            tokenUsage: TokenUsage(inputTokens: 1, outputTokens: 1)
        )
        let item = ModelLifecycleRadar.items(inventory: [usage], catalog: catalog, at: date("2026-07-18T12:00:00Z")).first!
        let alerts = ModelRetirementAlertEvaluator.evaluate(items: [item], satisfied: [], now: date("2026-07-18T12:00:00Z"))

        #expect(alerts.count == 1)
        #expect(alerts[0].notification.body.contains("exact published retirement date"))
        let satisfaction = AlertThresholdSatisfaction(ruleID: ModelRetirementAlertEvaluator.ruleID, window: alerts[0].occurrence.window, threshold: 1)
        #expect(ModelRetirementAlertEvaluator.evaluate(items: [item], satisfied: [satisfaction], now: date("2026-07-18T12:00:00Z")).isEmpty)

        let changedRecord = ModelLifecycleRecord(
            identity: record.identity,
            aliases: record.aliases,
            status: record.status,
            effectiveAt: record.effectiveAt,
            retirementDate: try CatalogDate("2026-08-06"),
            replacement: record.replacement,
            lifecycleSource: record.lifecycleSource,
            pricingRevisionIDs: record.pricingRevisionIDs
        )
        let changedItem = ModelLifecycleRadarItem(usage: usage, lifecycle: changedRecord, scenario: item.scenario)
        let changedAlert = try #require(ModelRetirementAlertEvaluator.evaluate(items: [changedItem], satisfied: [satisfaction], now: date("2026-07-18T12:00:00Z")).first)
        #expect(changedAlert.occurrence.window != alerts[0].occurrence.window)
        #expect(ModelRetirementAlertEvaluator.evaluate(items: [], satisfied: [], now: date("2026-07-18T12:00:00Z")).isEmpty)

        let missingDate = try #require(ModelCatalogMatcher.match(product: .anthropicAPI, platform: .anthropicAPI, modelID: "claude-opus-4-8", in: catalog))
        let missingItem = ModelLifecycleRadarItem(usage: usage, lifecycle: missingDate, scenario: .unavailable([.noDocumentedReplacement]))
        #expect(ModelRetirementAlertEvaluator.evaluate(items: [missingItem], satisfied: [], now: date("2026-07-18T12:00:00Z")).isEmpty)
    }

    @Test("explicit refresh request contains no local context")
    func refreshPrivacy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ModelLifecycleCatalogStore(fileURL: directory.appendingPathComponent("catalog.json"), verifier: BundledModelLifecycleCatalog.verifier)
        let encoded = try ModelLifecycleCatalogJSON.encoder.encode(BundledModelLifecycleCatalog.envelope)
        let transport = RecordingCatalogTransport(response: .init(data: encoded, statusCode: 200))
        let service = ModelCatalogRefreshService(endpoint: URL(string: "https://example.invalid/catalog.json")!, transport: transport, store: store)

        _ = try await service.refresh()
        let request = await transport.request
        #expect(request?.httpMethod == "GET")
        #expect(request?.httpBody == nil)
        #expect(request?.url?.query == nil)
        let serialized = String(data: request?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!serialized.contains("model"))
        #expect(!serialized.contains("token"))
        #expect(!serialized.contains("account"))
        #expect(!serialized.contains("project"))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("selected signed artifacts load locally and symbolic links fail closed")
    func selectedArtifactLoading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("catalog.json")
        try ModelLifecycleCatalogJSON.encoder.encode(BundledModelLifecycleCatalog.envelope).write(to: artifact)
        #expect(try ModelCatalogArtifactLoader.load(from: artifact) == BundledModelLifecycleCatalog.envelope)

        let link = directory.appendingPathComponent("catalog-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: artifact)
        #expect(throws: ModelCatalogArtifactError.invalidFile) { try ModelCatalogArtifactLoader.load(from: link) }
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("validly signed catalog rollbacks are rejected without replacing current state")
    func monotonicCatalogInstallation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ModelLifecycleCatalogStore(fileURL: directory.appendingPathComponent("catalog.json"), verifier: BundledModelLifecycleCatalog.verifier)
        let current = try store.recordCatalog(BundledModelLifecycleCatalog.envelope)

        let lowerVersion = ModelLifecycleCatalog(
            catalogVersion: "2026.07.18.1",
            publishedAt: current.publishedAt.addingTimeInterval(1),
            records: current.records,
            pricingRevisions: current.pricingRevisions
        )
        #expect(throws: ModelCatalogValidationError.rollbackCatalogVersion) { try store.recordCatalog(signed(lowerVersion)) }

        let olderPublication = ModelLifecycleCatalog(
            catalogVersion: "2026.07.18.4",
            publishedAt: current.publishedAt,
            records: current.records,
            pricingRevisions: current.pricingRevisions
        )
        #expect(throws: ModelCatalogValidationError.rollbackPublication) { try store.recordCatalog(signed(olderPublication)) }

        var changedPricing = current.pricingRevisions
        let first = changedPricing.removeFirst()
        changedPricing.insert(ModelPricingRevision(
            id: first.id,
            identity: first.identity,
            effectiveAt: first.effectiveAt.addingTimeInterval(1),
            currencyCode: first.currencyCode,
            prices: first.prices,
            source: first.source
        ), at: 0)
        let changedRevision = ModelLifecycleCatalog(
            catalogVersion: "2026.07.18.4",
            publishedAt: current.publishedAt.addingTimeInterval(2),
            records: current.records,
            pricingRevisions: changedPricing
        )
        #expect(throws: ModelCatalogValidationError.rollbackPricingRevision) { try store.recordCatalog(signed(changedRevision)) }
        #expect(try store.latestCatalog() == current)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("catalog and scenario persistence is bounded and independently deletable")
    func boundedPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("catalog.json")
        let store = ModelLifecycleCatalogStore(fileURL: file, verifier: BundledModelLifecycleCatalog.verifier)
        for _ in 0..<8 { _ = try store.recordCatalog(BundledModelLifecycleCatalog.envelope) }
        #expect(try store.catalogHistory().count == 1)

        let scenario = try calculatedScenario()
        let incomplete = CalculatedReplacementCostScenario(
            calculatedAt: scenario.calculatedAt,
            original: scenario.original,
            replacement: scenario.replacement,
            minimumCost: scenario.minimumCost,
            maximumCost: scenario.maximumCost,
            currencyCode: scenario.currencyCode,
            catalogVersion: scenario.catalogVersion,
            pricingRevisionID: scenario.pricingRevisionID,
            pricingEffectiveAt: scenario.pricingEffectiveAt,
            pricingSourceURL: scenario.pricingSourceURL,
            workload: FrozenReplacementWorkload(
                periodStart: scenario.workload.periodStart,
                periodEnd: scenario.workload.periodEnd,
                quantities: scenario.workload.quantities,
                modifiers: [:]
            ),
            omittedDimensions: scenario.omittedDimensions,
            limitations: scenario.limitations
        )
        #expect(throws: ModelLifecycleCatalogStoreError.invalidScenario) { try store.recordScenario(incomplete) }
        for offset in 0..<510 {
            let value = CalculatedReplacementCostScenario(
                calculatedAt: scenario.calculatedAt.addingTimeInterval(Double(offset)),
                original: scenario.original,
                replacement: scenario.replacement,
                minimumCost: scenario.minimumCost,
                maximumCost: scenario.maximumCost,
                currencyCode: scenario.currencyCode,
                catalogVersion: scenario.catalogVersion,
                pricingRevisionID: scenario.pricingRevisionID,
                pricingEffectiveAt: scenario.pricingEffectiveAt,
                pricingSourceURL: scenario.pricingSourceURL,
                workload: scenario.workload,
                omittedDimensions: scenario.omittedDimensions,
                limitations: scenario.limitations
            )
            try store.recordScenario(value, now: value.calculatedAt)
        }
        #expect(try store.scenarios(now: scenario.calculatedAt.addingTimeInterval(509)).count == 500)
        try store.deleteAll()
        #expect(try store.catalogHistory().isEmpty)
        #expect(try store.scenarios().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("schema zero migrates verified catalogs and unknown schemas are preserved")
    func persistenceMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("catalog.json")
        let envelopeData = try ModelLifecycleCatalogJSON.encoder.encode(BundledModelLifecycleCatalog.envelope)
        let envelopeObject = try JSONSerialization.jsonObject(with: envelopeData)
        let legacy = try JSONSerialization.data(withJSONObject: ["schemaVersion": 0, "catalogs": [envelopeObject]], options: [.sortedKeys])
        try legacy.write(to: file)
        let store = ModelLifecycleCatalogStore(fileURL: file, verifier: BundledModelLifecycleCatalog.verifier)

        #expect(try store.latestCatalog()?.catalogVersion == "2026.07.18.3")
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(migrated?["schemaVersion"] as? Int == 1)

        let unsupported = try JSONSerialization.data(withJSONObject: ["schemaVersion": 999, "catalogs": [], "scenarios": []], options: [.sortedKeys])
        try unsupported.write(to: file)
        #expect(throws: ModelLifecycleCatalogStoreError.unsupportedSchema(999)) { try store.latestCatalog() }
        #expect(try Data(contentsOf: file) == unsupported)
        try? FileManager.default.removeItem(at: directory)
    }

    private func calculatedScenario() throws -> CalculatedReplacementCostScenario {
        let catalog = try BundledModelLifecycleCatalog.verifiedCatalog()
        let record = try #require(ModelCatalogMatcher.match(product: .openAIAPI, platform: .openAIAPI, modelID: "gpt-5.1-codex", in: catalog))
        let workload = FrozenReplacementWorkload(
            periodStart: date("2026-07-01T00:00:00Z"),
            periodEnd: date("2026-07-02T00:00:00Z"),
            quantities: [.input: 1, .output: 1],
            modifiers: Dictionary(uniqueKeysWithValues: PricingModifier.allCases.map { ($0, .notUsed) })
        )
        guard case let .calculated(value) = ReplacementCostScenarioCalculator.calculate(record: record, workload: workload, catalog: catalog, at: date("2026-07-18T18:00:00Z")) else {
            throw TestError.missingScenario
        }
        return value
    }

    private func inventoryDatabase(retentionDays: Int) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try execute(path: path, sql: """
        CREATE TABLE historical_usage_settings (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        INSERT INTO historical_usage_settings VALUES ('retention_days', \(retentionDays));
        CREATE TABLE historical_usage_observations (
            observation_id TEXT PRIMARY KEY,
            supersedes_observation_id TEXT,
            provider TEXT NOT NULL,
            source_kind TEXT NOT NULL,
            coverage_kind TEXT NOT NULL,
            coverage_model TEXT,
            period_kind TEXT NOT NULL,
            period_start REAL NOT NULL,
            period_end REAL NOT NULL,
            time_zone_identifier TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL
        );
        CREATE TABLE historical_six_hour_aggregates (
            aggregate_id TEXT PRIMARY KEY,
            supersedes_aggregate_id TEXT,
            provider TEXT NOT NULL,
            coverage_kind TEXT NOT NULL,
            coverage_model TEXT NOT NULL,
            period_start REAL NOT NULL,
            period_end REAL NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL
        );
        """)
        return path
    }

    private func insertDaily(path: String, id: String, model: String, start: String, input: Int, output: Int) throws {
        let startDate = date(start)
        try execute(path: path, sql: """
        INSERT INTO historical_usage_observations VALUES (
            '\(id)', NULL, 'openAI', 'providerAPI', 'model', '\(model)', 'today',
            \(startDate.timeIntervalSince1970), \(startDate.addingTimeInterval(86_400).timeIntervalSince1970),
            'UTC', \(input), \(output)
        );
        """)
    }

    private func insertExact(path: String, id: String, model: String, start: String, input: Int, output: Int) throws {
        let startDate = date(start)
        try execute(path: path, sql: """
        INSERT INTO historical_six_hour_aggregates VALUES (
            '\(id)', NULL, 'openAI', 'model', '\(model)',
            \(startDate.timeIntervalSince1970), \(startDate.addingTimeInterval(21_600).timeIntervalSince1970),
            \(input), \(output)
        );
        """)
    }

    private func execute(path: String, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw TestError.sqlite }
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func signed(_ catalog: ModelLifecycleCatalog) throws -> SignedModelLifecycleCatalog {
        let payload = try ModelLifecycleCatalogJSON.encoder.encode(catalog)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))
        return SignedModelLifecycleCatalog(keyID: BundledModelLifecycleCatalog.keyID, payload: payload, signature: try key.signature(for: payload))
    }
    private enum TestError: Error { case missingScenario, sqlite }
}

private actor RecordingCatalogTransport: ModelCatalogTransport {
    private(set) var request: URLRequest?
    let response: ModelCatalogHTTPResponse

    init(response: ModelCatalogHTTPResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> ModelCatalogHTTPResponse {
        self.request = request
        return response
    }
}
