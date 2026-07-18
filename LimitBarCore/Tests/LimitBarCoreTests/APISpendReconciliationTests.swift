import Foundation
import SQLite3
import Testing
@testable import LimitBarCore

@Suite("API spend reconciliation")
struct APISpendReconciliationTests {
    private let rawWorkspace = "wrk_user_private_91"
    private let rawKey = "sk-ant-admin-private"
    private let rawOrganization = "org_private_42"

    @Test("organization reconciliation uses the explicit credentialed Anthropic seam and grouped exact-day request")
    func explicitProviderSeam() async throws {
        let http = UsageProviderRecordingHTTPClient(response: HTTPResponse(statusCode: 200, data: fixture(amounts: ["1200"])))
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_783_036_800), duration: 86_400)
        let result = await AnthropicAdminClient(httpClient: http).fetchSpendReconciliation(apiKey: "admin-secret", interval: interval)
        let request = try #require(await http.requests.last)
        guard case let .success(buckets) = result else {
            Issue.record("Expected sanitized success")
            return
        }
        #expect(buckets.count == 1)
        #expect(buckets[0].dimensions.workspaceAlias == nil)
        #expect(request.url.path == "/v1/organizations/cost_report")
        #expect(request.headers["x-api-key"] == "admin-secret")
        #expect(request.url.absoluteString.contains("bucket_width=1d"))
        for dimension in ["workspace_id", "api_key_id", "model"] {
            #expect(request.url.absoluteString.contains(dimension))
        }
        for unsupported in ["service_tier", "token_class", "description"] { #expect(!request.url.absoluteString.contains(unsupported)) }
        #expect(!String(describing: result).contains("admin-secret"))
        #expect(!String(describing: result).contains(rawWorkspace))
    }

    @Test("organization reconciliation maps authentication failure and cancellation without exposing responses")
    func providerSeamFailures() async {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86_400)
        let rejected = await AnthropicAdminClient(httpClient: UsageProviderRecordingHTTPClient(response: HTTPResponse(statusCode: 401, data: Data("private provider response".utf8))))
            .fetchSpendReconciliation(apiKey: "admin-secret", interval: interval)
        let cancelled = await AnthropicAdminClient(httpClient: UsageProviderRecordingHTTPClient(error: CancellationError()))
            .fetchSpendReconciliation(apiKey: "admin-secret", interval: interval)
        #expect(rejected == .failure(.authenticationRejected))
        #expect(cancelled == .cancelled)
        #expect(!String(describing: rejected).contains("private provider response"))
        #expect(!String(describing: cancelled).contains("admin-secret"))
    }

    @Test("Anthropic organization fixture aliases or omits identities before persistence")
    func fixtureSanitization() throws {
        let data = fixture(amounts: ["1200"])
        let buckets = try AnthropicSpendReportImporter.import(data, policy: SpendDimensionPolicy(
            workspace: { _ in .alias("Workspace Blue") },
            apiKey: { _ in .alias("Batch Key") }
        ))

        #expect(buckets.count == 1)
        #expect(buckets[0].amount == 12)
        #expect(buckets[0].currencyCode == "USD")
        #expect(buckets[0].dimensions.workspaceAlias == "Workspace Blue")
        #expect(buckets[0].dimensions.apiKeyAlias == "Batch Key")
        #expect(buckets[0].dimensions.model == "claude-sonnet-4")

        let omitted = try AnthropicSpendReportImporter.import(data, policy: .omitProviderIdentities)
        #expect(omitted[0].dimensions.workspaceAlias == nil)
        #expect(omitted[0].dimensions.apiKeyAlias == nil)
        #expect(omitted[0].dimensions.workspaceIdentityOmitted)
        #expect(omitted[0].dimensions.apiKeyIdentityOmitted)
        let encoded = String(decoding: try JSONEncoder().encode(omitted), as: UTF8.self)
        for prohibited in [rawWorkspace, rawKey, rawOrganization] { #expect(!encoded.contains(prohibited)) }
    }

    @Test("schema v2 project and agent evidence remains non-additive and exposes partial attribution")
    func partialReconciliation() throws {
        let bucket = try #require(try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: SpendDimensionPolicy(
            workspace: { _ in .alias("Billing") }, apiKey: { _ in .alias("Batch Key") }
        )).first)
        let event = try CollectorSchemaV2.decode(Data(#"{"schemaVersion":2,"eventID":"00000000-0000-0000-0000-000000000050","provider":"anthropic","timestamp":"2026-07-01T12:00:00Z","model":"claude-sonnet-4","inputTokens":1000000,"outputTokens":0,"projectID":"billing","projectLabel":"Billing","agentID":"batch-key","agentLabel":"Batch Key"}"#.utf8))
        let measured = ObservedLocalAttributionBreakdown(
            source: .builtInLocalLog, provider: .anthropic, window: bucket.window, model: event.model, deployment: nil,
            project: event.project, agent: event.agent, tokenUsage: TokenUsage(inputTokens: event.inputTokens, outputTokens: event.outputTokens),
            eventIDs: [event.eventID], observedAt: event.timestamp
        )
        let pricing = PricingTable(entries: [PricingEntry(provider: .anthropic, modelLabel: event.model, inputPricePerMillionTokens: 8, outputPricePerMillionTokens: 24, currencyCode: "USD", effectiveAt: bucket.window.start.addingTimeInterval(-86_400))])
        var local = try #require(ObservedLocalSpendBreakdown.priced([measured], pricing: pricing).first)
        local = try ObservedLocalSpendBreakdown(provider: local.provider, window: local.window, calculatedCost: local.calculatedCost, dimensions: SpendDimensions(workspaceAlias: local.dimensions.workspaceAlias, apiKeyAlias: local.dimensions.apiKeyAlias, model: local.dimensions.model, serviceTier: "standard", tokenClass: .uncachedInput), project: local.project, agent: local.agent)

        let row = try #require(APISpendReconciler.reconcile(provider: [bucket], local: [local]).first)
        #expect(row.attributedProviderReportedCost == 8)
        #expect(row.observedLocalCalculatedCost == 8)
        #expect(row.unattributedProviderReportedCost == 4)
        #expect(row.providerBucket.amount == 12)
        #expect(row.status == .partial)
        #expect(row.projects == ["Billing"])
        #expect(row.agents == ["Batch Key"])
        #expect(row.providerBucket.amount != row.providerBucket.amount + row.observedLocalCalculatedCost)
    }

    @Test("incompatible windows currencies products models tiers token classes and mappings remain explicit and unattributed")
    func incompatibilities() throws {
        let bucket = try #require(try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: SpendDimensionPolicy(
            workspace: { _ in .alias("Workspace Blue") }, apiKey: { _ in .alias("Batch Key") }
        )).first)
        let wrongWindow = try ExactUsageWindow(timeWindow: .today, start: bucket.window.start.addingTimeInterval(86_400), end: bucket.window.end.addingTimeInterval(86_400), basis: .utcBilling)
        let local = try ObservedLocalSpendBreakdown(
            provider: .openAI,
            window: wrongWindow,
            calculatedCost: Cost(amount: 12, currencyCode: "EUR", source: .calculatedEstimate),
            dimensions: SpendDimensions(workspaceAlias: "Other", apiKeyAlias: "Other", model: "other", serviceTier: "batch", tokenClass: .output),
            project: nil, agent: nil
        )
        let row = try #require(APISpendReconciler.reconcile(provider: [bucket], local: [local]).first)
        #expect(row.status == .incompatible)
        #expect(row.unattributedProviderReportedCost == 12)
        #expect(row.barriers.contains(.providerProduct))

        let sameProvider = try ObservedLocalSpendBreakdown(provider: .anthropic, window: wrongWindow, calculatedCost: local.calculatedCost, dimensions: local.dimensions, project: nil, agent: nil)
        let windowRow = try #require(APISpendReconciler.reconcile(provider: [bucket], local: [sameProvider]).first)
        #expect(windowRow.barriers.contains(.exactWindow))
    }

    @Test("late revisions append supersession and visible drift while retention and deletion are independent")
    func revisionsRetentionDeletion() throws {
        let store = try SQLiteAPISpendReconciliationStore.inMemory(maximumRevisions: 2, retention: 100)
        let first = try store.record(conclusion(try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: .omitProviderIdentities)), now: Date(timeIntervalSince1970: 1000))
        let second = try store.record(conclusion(try AnthropicSpendReportImporter.import(fixture(amounts: ["1500"]), policy: .omitProviderIdentities)), now: Date(timeIntervalSince1970: 1010))
        _ = try store.record(conclusion(try AnthropicSpendReportImporter.import(fixture(amounts: ["1800"]), policy: .omitProviderIdentities)), now: Date(timeIntervalSince1970: 1020))
        let revisions = try store.revisions(now: Date(timeIntervalSince1970: 1020))
        #expect(revisions.count == 2)
        #expect(second.supersedesRevisionID == first.id)
        #expect(second.drifts.map(\.providerReportedChange) == [3])
        try store.deleteAll()
        #expect(try store.revisions(now: Date(timeIntervalSince1970: 1020)).isEmpty)
    }

    @Test("duplicate buckets and unknown schemas fail closed")
    func duplicateAndUnknownSchema() throws {
        #expect(throws: APISpendReconciliationError.duplicateBucket) {
            try AnthropicSpendReportImporter.import(fixture(amounts: ["1200", "1500"]), policy: .omitProviderIdentities)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version = 99; CREATE TABLE alien(value TEXT);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(throws: APISpendStoreError.unknownSchema) { try SQLiteAPISpendReconciliationStore(path: url.path) }
    }

    @Test("drift remains bucketed and never sums currencies")
    func driftDoesNotSumCurrencies() throws {
        let store = try SQLiteAPISpendReconciliationStore.inMemory()
        let usd = try #require(try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: .omitProviderIdentities).first)
        let eur = try ProviderReportedSpendBucket(provider: .anthropic, window: usd.window, currencyCode: "EUR", amount: 5, dimensions: usd.dimensions)
        _ = try store.record(conclusion([usd, eur]), now: Date(timeIntervalSince1970: 1000))
        let correctedUSD = try ProviderReportedSpendBucket(provider: .anthropic, window: usd.window, currencyCode: "USD", amount: 15, dimensions: usd.dimensions)
        let revision = try store.record(conclusion([correctedUSD]), now: Date(timeIntervalSince1970: 1010))
        #expect(revision.drifts.map { ($0.providerReportedChange, $0.bucket.currencyCode) }.contains { $0 == (3, "USD") })
        #expect(revision.drifts.map { ($0.providerReportedChange, $0.bucket.currencyCode) }.contains { $0 == (-5, "EUR") })
        #expect(revision.drifts.count == 2)
    }

    @Test("v1 persistence migrates and retains sanitized revisions")
    func migration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let schema = "CREATE TABLE spend_revisions (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at REAL NOT NULL, provider TEXT NOT NULL CHECK(provider = 'anthropic'), payload BLOB NOT NULL, supersedes_id INTEGER, drift TEXT NOT NULL, FOREIGN KEY(supersedes_id) REFERENCES spend_revisions(id)); CREATE INDEX spend_revisions_retention ON spend_revisions(recorded_at, id); PRAGMA user_version = 1;"
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        let legacyBuckets = try AnthropicSpendReportImporter.import(fixture(amounts: ["900"]), policy: .omitProviderIdentities)
        let payload = try JSONEncoder().encode(legacyBuckets)
        var insert: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "INSERT INTO spend_revisions (recorded_at, provider, payload, supersedes_id, drift) VALUES (900, 'anthropic', ?, NULL, '0');", -1, &insert, nil) == SQLITE_OK)
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(insert, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(insert) == SQLITE_DONE)
        sqlite3_finalize(insert)
        sqlite3_close(db)

        let store = try SQLiteAPISpendReconciliationStore(path: url.path)
        let migrated = try store.revisions(now: Date(timeIntervalSince1970: 1000))
        #expect(migrated.count == 1)
        #expect(migrated[0].conclusion.pricingRevision == "legacy-unavailable")
        #expect(migrated[0].conclusion.rows.allSatisfy { $0.barriers == [.legacyConclusionUnavailable] })
        _ = try store.record(conclusion(try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: .omitProviderIdentities)), now: Date(timeIntervalSince1970: 1000))
        #expect(try store.revisions(now: Date(timeIntervalSince1970: 1000)).count == 2)
    }

    @Test("CSV preview equals saved bytes and contains only versioned allow-listed aliases")
    func csvPrivacy() throws {
        let bucket = try #require(try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: SpendDimensionPolicy(
            workspace: { _ in .alias("Workspace Blue") }, apiKey: { _ in .alias("Batch Key") }
        )).first)
        let row = try #require(APISpendReconciler.reconcile(provider: [bucket], local: []).first)
        let artifact = SpendCSVArtifact.make(rows: [row])
        #expect(Data(artifact.preview.utf8) == artifact.data)
        #expect(artifact.preview.components(separatedBy: "\n")[0] == SpendCSVArtifact.allowedColumns.joined(separator: ","))
        #expect(artifact.preview.contains("Workspace Blue"))
        for prohibited in [rawWorkspace, rawKey, rawOrganization, "prompt", "response", "credential"] { #expect(!artifact.preview.contains(prohibited)) }
    }

    @Test("sanitized persistence has prohibited-content sentinels")
    func persistencePrivacySentinel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteAPISpendReconciliationStore(path: url.path)
        let buckets = try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: SpendDimensionPolicy(
            workspaceAliases: try SpendIdentityAliasMap([rawWorkspace: "Billing"]),
            apiKeyAliases: try SpendIdentityAliasMap([rawKey: "Batch Key"])
        ))
        _ = try store.record(conclusion(buckets), now: Date(timeIntervalSince1970: 2_000_000_000))
        let bytes = try Data(contentsOf: url)
        for prohibited in [rawWorkspace, rawKey, rawOrganization, "raw_payload", "prompt", "response"] {
            #expect(!bytes.contains(Data(prohibited.utf8)))
        }
        #expect(bytes.contains(Data("Billing".utf8)))
    }

    @Test("isolated active-source loader derives exact UTC-day evidence without local-calendar windows")
    func productionUTCEventEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-events.jsonl")
        let event = #"{"schemaVersion":2,"eventID":"00000000-0000-0000-0000-000000000051","provider":"anthropic","timestamp":"2026-07-01T01:00:00Z","model":"claude-sonnet-4","inputTokens":100,"outputTokens":20,"projectID":"billing","projectLabel":"Billing","agentID":"batch","agentLabel":"Batch"}"#
        try Data((event + "\n").utf8).write(to: file)
        let result = try APISpendLocalEvidenceLoader.loadActiveSource(fileURL: file, now: try #require(ISO8601DateFormatter().date(from: "2026-07-02T12:00:00Z")))
        let utc = try #require(result.breakdowns.first)
        let expectedStart = try #require(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
        let expectedEnd = try #require(ISO8601DateFormatter().date(from: "2026-07-02T00:00:00Z"))
        #expect(utc.window.basis == .utcBilling)
        #expect(utc.window.start == expectedStart)
        #expect(utc.window.end == expectedEnd)
        #expect(result.breakdowns.allSatisfy { $0.window.basis == .utcBilling })
    }

    @Test("isolated loader uses secure regular-file boundaries and rejects event conflicts")
    func isolatedLoaderSecurityAndConflicts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-events.jsonl")
        let link = directory.appendingPathComponent("linked-events.jsonl")
        let first = #"{"schemaVersion":2,"eventID":"00000000-0000-0000-0000-000000000052","provider":"anthropic","timestamp":"2026-07-01T01:00:00Z","model":"claude-sonnet-4","inputTokens":100,"outputTokens":20,"projectID":"billing"}"#
        try Data((first + "\n" + first + "\n").utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: APISpendLocalEvidenceError.unavailable) { try APISpendLocalEvidenceLoader.loadActiveSource(fileURL: link) }

        let duplicate = try APISpendLocalEvidenceLoader.loadActiveSource(fileURL: file, now: Date(timeIntervalSince1970: 2_000_000_000))
        #expect(duplicate.breakdowns.first?.tokenUsage == TokenUsage(inputTokens: 100, outputTokens: 20))
        #expect(duplicate.breakdowns.first?.eventIDs.count == 1)
        #expect(duplicate.sourceRevision.count == 64)

        let conflict = first.replacingOccurrences(of: "\"inputTokens\":100", with: "\"inputTokens\":101")
        try Data((first + "\n" + conflict + "\n").utf8).write(to: file)
        #expect(throws: APISpendLocalEvidenceError.eventIDConflict) {
            try APISpendLocalEvidenceLoader.loadActiveSource(fileURL: file, now: Date(timeIntervalSince1970: 2_000_000_000))
        }
    }

    @Test("isolated loader fails closed on malformed schema v2 and ignores other schemas")
    func isolatedLoaderSchemaBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-events.jsonl")
        let v1 = #"{"schemaVersion":1,"eventID":"00000000-0000-0000-0000-000000000053","provider":"anthropic","timestamp":"2026-07-01T01:00:00Z","model":"claude-sonnet-4","inputTokens":100,"outputTokens":20}"#
        try Data((v1 + "\n").utf8).write(to: file)
        #expect(try APISpendLocalEvidenceLoader.loadActiveSource(fileURL: file).breakdowns.isEmpty)
        let malformedV2 = #"{"schemaVersion":2,"eventID":"not-a-uuid","provider":"anthropic","timestamp":"2026-07-01T01:00:00Z","model":"claude-sonnet-4","inputTokens":100,"outputTokens":20,"projectID":"billing"}"#
        try Data((malformedV2 + "\n").utf8).write(to: file)
        #expect(throws: APISpendLocalEvidenceError.malformedSchemaV2Event) { try APISpendLocalEvidenceLoader.loadActiveSource(fileURL: file) }
    }

    @Test("provider-only tier and token class remain unmatched without explicit local evidence")
    func providerOnlyDimensionsRemainUnattributed() throws {
        let bucket = try #require(try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: SpendDimensionPolicy(workspace: { _ in .alias("Billing") }, apiKey: { _ in .alias("Batch") })).first)
        let local = try ObservedLocalSpendBreakdown(provider: .anthropic, window: bucket.window, calculatedCost: Cost(amount: 8, currencyCode: "USD", source: .calculatedEstimate), dimensions: SpendDimensions(workspaceAlias: "Billing", apiKeyAlias: "Batch", model: "claude-sonnet-4"), project: nil, agent: nil)
        let row = try #require(APISpendReconciler.reconcile(provider: [bucket], local: [local]).first)
        #expect(row.attributedProviderReportedCost == 0)
        #expect(row.unattributedProviderReportedCost == 12)
        #expect(row.barriers.contains(.serviceTier))
        #expect(row.barriers.contains(.tokenSemantics))
    }

    @Test("one local amount is consumed once after compatible authoritative buckets aggregate")
    func localAmountIsNotReused() throws {
        let window = try ExactUsageWindow(timeWindow: .today, start: try #require(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")), end: try #require(ISO8601DateFormatter().date(from: "2026-07-02T00:00:00Z")), basis: .utcBilling)
        let first = try ProviderReportedSpendBucket(provider: .anthropic, window: window, currencyCode: "USD", amount: 5, dimensions: SpendDimensions(model: "claude-sonnet-4", costDescription: "input"))
        let second = try ProviderReportedSpendBucket(provider: .anthropic, window: window, currencyCode: "USD", amount: 7, dimensions: SpendDimensions(model: "claude-sonnet-4", costDescription: "output"))
        let local = try ObservedLocalSpendBreakdown(provider: .anthropic, window: window, calculatedCost: Cost(amount: 8, currencyCode: "USD", source: .calculatedEstimate), dimensions: SpendDimensions(model: "claude-sonnet-4"), project: nil, agent: nil)
        let rows = APISpendReconciler.reconcile(provider: [first, second], local: [local])
        #expect(rows.count == 1)
        #expect(rows[0].providerBucket.amount == 12)
        #expect(rows[0].observedLocalCalculatedCost == 8)
        #expect(rows[0].attributedProviderReportedCost == 8)
        #expect(rows[0].unattributedProviderReportedCost == 4)
    }

    @Test("alias maps are per raw identity and reject raw-derived aliases")
    func perIdentityAliases() throws {
        let map = try SpendIdentityAliasMap([rawWorkspace: "Billing"])
        #expect(map.disposition(for: rawWorkspace) == .alias("Billing"))
        #expect(map.disposition(for: "wrk_unmapped_2") == .omit)
        #expect(throws: APISpendReconciliationError.invalidAlias) { try SpendIdentityAliasMap([rawWorkspace: rawWorkspace]) }
        #expect(throws: APISpendReconciliationError.invalidAlias) { try SpendIdentityAliasMap([rawWorkspace: "private"]) }
    }

    @Test("stored conclusions freeze pricing local identity rows and conclusion drift")
    func frozenConclusions() throws {
        let buckets = try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: .omitProviderIdentities)
        let identity = try LocalSpendEvidenceIdentity(sourceRevision: String(repeating: "a", count: 64), evidenceDigest: String(repeating: "b", count: 64), eventCount: 1)
        let first = try conclusion(buckets, pricingRevision: "pricing-a", identity: identity)
        let store = try SQLiteAPISpendReconciliationStore.inMemory()
        _ = try store.record(first, now: Date(timeIntervalSince1970: 1000))
        let revisedBuckets = try AnthropicSpendReportImporter.import(fixture(amounts: ["1500"]), policy: .omitProviderIdentities)
        let second = try conclusion(revisedBuckets, pricingRevision: "pricing-b")
        let revision = try store.record(second, now: Date(timeIntervalSince1970: 1010))
        let loaded = try store.revisions(now: Date(timeIntervalSince1970: 1010))
        #expect(loaded[0].conclusion == first)
        #expect(loaded[0].conclusion.pricingRevision == "pricing-a")
        #expect(loaded[0].conclusion.localEvidenceIdentity == identity)
        #expect(revision.drifts.first?.providerReportedChange == 3)
        #expect(revision.drifts.first?.unattributedChange == 3)
    }

    @Test("lookalike migration schemas are rejected before mutation")
    func adversarialMigrationFingerprints() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let lookalike = "CREATE TABLE spend_revisions (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at REAL NOT NULL, provider TEXT NOT NULL, payload BLOB NOT NULL, supersedes_id INTEGER, drift TEXT NOT NULL); CREATE INDEX spend_revisions_retention ON spend_revisions(id, recorded_at); PRAGMA user_version = 1;"
        #expect(sqlite3_exec(db, lookalike, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        #expect(throws: APISpendStoreError.unknownSchema) { try SQLiteAPISpendReconciliationStore(path: url.path) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("v2 lookalike is rejected before migration")
    func adversarialV2Fingerprint() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let lookalike = "CREATE TABLE spend_revisions (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at REAL NOT NULL, provider TEXT NOT NULL CHECK(provider = 'anthropic'), payload BLOB NOT NULL, supersedes_id INTEGER, drift TEXT NOT NULL, drift_json BLOB NOT NULL, refresh_status TEXT NOT NULL, FOREIGN KEY(supersedes_id) REFERENCES spend_revisions(id)); CREATE INDEX spend_revisions_retention ON spend_revisions(recorded_at, id); PRAGMA user_version = 2;"
        #expect(sqlite3_exec(db, lookalike, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        #expect(throws: APISpendStoreError.unknownSchema) { try SQLiteAPISpendReconciliationStore(path: url.path) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("canonical v2 fingerprint migrates transactionally")
    func canonicalV2Migration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let schema = "CREATE TABLE spend_revisions (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at REAL NOT NULL, provider TEXT NOT NULL CHECK(provider = 'anthropic'), payload BLOB NOT NULL, supersedes_id INTEGER, drift TEXT NOT NULL, drift_json BLOB NOT NULL, refresh_status TEXT NOT NULL CHECK(refresh_status IN ('complete')), FOREIGN KEY(supersedes_id) REFERENCES spend_revisions(id)); CREATE INDEX spend_revisions_retention ON spend_revisions(recorded_at, id); PRAGMA user_version = 2;"
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = try SQLiteAPISpendReconciliationStore(path: url.path)
        let buckets = try AnthropicSpendReportImporter.import(fixture(amounts: ["1200"]), policy: .omitProviderIdentities)
        _ = try store.record(conclusion(buckets), now: Date(timeIntervalSince1970: 1000))
        #expect(try store.revisions(now: Date(timeIntervalSince1970: 1000)).count == 1)
    }

    private func fixture(amounts: [String]) -> Data {
        let rows = amounts.map { amount in
            #"{"amount":"\#(amount)","currency":"usd","workspace_id":"\#(rawWorkspace)","api_key_id":"\#(rawKey)","organization_id":"\#(rawOrganization)","model":"claude-sonnet-4","service_tier":"standard","token_class":"uncachedInput","description":"messages"}"#
        }.joined(separator: ",")
        return Data(#"{"data":[{"starting_at":"2026-07-01T00:00:00Z","ending_at":"2026-07-02T00:00:00Z","results":[\#(rows)]}],"has_more":false}"#.utf8)
    }

    private func conclusion(_ buckets: [ProviderReportedSpendBucket], local: [ObservedLocalSpendBreakdown] = [], pricingRevision: String = "test-pricing-v1", identity: LocalSpendEvidenceIdentity? = nil) throws -> SpendReconciliationConclusion {
        try APISpendReconciler.conclude(provider: buckets, local: local, pricingRevision: pricingRevision, localEvidenceIdentity: identity)
    }
}
