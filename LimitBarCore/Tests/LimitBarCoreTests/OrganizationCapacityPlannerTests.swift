import Foundation
import Testing
@testable import LimitBarCore

@Suite("Organization capacity planner")
struct OrganizationCapacityPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_783_468_800) // 2026-07-07 UTC
    private let aliaser = try! OrganizationTeamAliasKey(keyData: Data(repeating: 7, count: 32))

    @Test func acceptsReviewedCompletedDailyAggregatesAndAliasesBeforeReturning() throws {
        let batch = try OrganizationDailyAggregateImporter.importData(validFile(), aliaser: aliaser, now: now)
        #expect(batch.aggregates.count == 2)
        #expect(batch.aggregates.allSatisfy { $0.teamAlias.hasPrefix("team-") })
        #expect(String(data: try JSONEncoder().encode(batch.aggregates), encoding: .utf8)?.contains("11111111-1111-4111-8111-111111111111") == false)
        #expect(batch.provenance.schemaVersion == OrganizationDailyAggregateImporter.schemaVersion)
        #expect(batch.provenance.providerProducts == [.claudeCode])
    }

    @Test(arguments: [
        "email", "name", "api_key_name", "organization_id", "terminal_id", "actor_id", "prompt",
        "code", "transcript", "path", "attributes", "unexpected"
    ])
    func rejectsProhibitedAndUnknownFields(field: String) throws {
        var root = try #require(JSONSerialization.jsonObject(with: validFile()) as? [String: Any])
        var records = try #require(root["records"] as? [[String: Any]])
        records[0][field] = "secret"
        root["records"] = records
        #expect(throws: OrganizationCapacityError.self) {
            try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: aliaser, now: now)
        }
    }

    @Test func rejectsUnknownSchemaMissingReviewPartialDaysAndDuplicateRows() throws {
        for mutation in ["schema", "review", "partial", "duplicate"] {
            var root = try #require(JSONSerialization.jsonObject(with: validFile()) as? [String: Any])
            if mutation == "schema" { root["schema_version"] = "v2" }
            if mutation == "review" { root["administrator_reviewed"] = false }
            if mutation == "partial" {
                var rows = try #require(root["records"] as? [[String: Any]])
                rows[0]["complete_day"] = false
                root["records"] = rows
            }
            if mutation == "duplicate" {
                var rows = try #require(root["records"] as? [[String: Any]])
                rows.append(rows[0])
                root["records"] = rows
            }
            #expect(throws: OrganizationCapacityError.self) {
                try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: aliaser, now: now)
            }
        }
    }

    @Test func rejectsMalformedFutureAndUnsupportedProviderFiles() throws {
        #expect(throws: OrganizationCapacityError.self) {
            try OrganizationDailyAggregateImporter.importData(Data("not-json".utf8), aliaser: aliaser, now: now)
        }
        for mutation in ["future", "provider"] {
            var root = try #require(JSONSerialization.jsonObject(with: validFile()) as? [String: Any])
            var rows = try #require(root["records"] as? [[String: Any]])
            if mutation == "future" { rows[0]["day"] = "2026-07-08" }
            if mutation == "provider" { rows[0]["provider_product"] = "openai_api" }
            root["records"] = rows
            #expect(throws: OrganizationCapacityError.self) {
                try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: aliaser, now: now)
            }
        }
    }

    @Test func suppressesBelowThresholdBeforeAliasingAndKeepsBoundary() throws {
        let spy = AliasSpy()
        var root = try #require(JSONSerialization.jsonObject(with: validFile()) as? [String: Any])
        var rows = try #require(root["records"] as? [[String: Any]])
        rows[0]["cohort_size"] = 4
        rows[0]["quota_eligible_users"] = 4
        rows[0]["repeatedly_near_exhaustion_users"] = 1
        rows[0]["peak_concurrency"] = 4
        rows[1]["cohort_size"] = 5
        root["records"] = rows
        let batch = try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: spy, now: now)
        #expect(batch.aggregates.count == 1)
        #expect(batch.provenance.suppressedRecordCount == 1)
        #expect(spy.identities == ["22222222-2222-4222-8222-222222222222"])
    }

    @Test func outputsDistributionsSeparateCostsAndBoundedScenarioWithoutAliases() throws {
        let batch = try OrganizationDailyAggregateImporter.importData(validFile(), aliaser: aliaser, now: now)
        let summary = try OrganizationCapacityCalculator.summary(aggregates: batch.aggregates, provenances: [batch.provenance])
        let provider = try #require(summary.providers.first)
        #expect(provider.blockedCapacityDays?.count == 1)
        #expect(provider.dailyTopTeamShare?.sampleCount == 1)
        #expect(provider.cacheEfficiency?.sampleCount == 2)
        #expect(provider.costs.map(\.subject) == [.subscriptionSeatCost, .apiOverflowCost])
        let scenario = try #require(try OrganizationCapacityCalculator.scheduleShiftScenario(aggregates: batch.aggregates, shiftFraction: 0.25))
        #expect(scenario.possibleBlockedMinutesReductionLowerBound == 0)
        #expect(scenario.possibleBlockedMinutesReductionUpperBound == 45)
        #expect(scenario.limitation.contains("not a forecast or guarantee"))
        let export = try OrganizationCapacityExporter.make(aggregates: batch.aggregates, provenances: [batch.provenance], shiftFraction: 0.25, generatedAt: now)
        let text = try #require(String(data: export, encoding: .utf8))
        #expect(!text.contains("team-"))
        #expect(!text.contains("11111111-1111-4111-8111-111111111111"))
        #expect(text.contains("subscription_seat_cost"))
        #expect(text.contains("api_overflow_cost"))
    }

    @Test func unsupportedEvidenceDoesNotProduceAnOutput() throws {
        var root = try #require(JSONSerialization.jsonObject(with: validFile()) as? [String: Any])
        var rows = try #require(root["records"] as? [[String: Any]])
        for index in rows.indices {
            rows[index].removeValue(forKey: "cache_read_units")
            rows[index].removeValue(forKey: "uncached_input_units")
            rows[index].removeValue(forKey: "quota_eligible_users")
            rows[index].removeValue(forKey: "repeatedly_near_exhaustion_users")
        }
        root["records"] = rows
        let batch = try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: aliaser, now: now)
        let summary = try OrganizationCapacityCalculator.summary(aggregates: batch.aggregates, provenances: [batch.provenance])
        #expect(summary.providers.first?.cacheEfficiency == nil)
        #expect(summary.providers.first?.repeatedNearExhaustionShare == nil)
    }

    @Test func missingBlockedEvidenceIsUnavailableRatherThanObservedZero() throws {
        var root = try #require(JSONSerialization.jsonObject(with: validFile()) as? [String: Any])
        var rows = try #require(root["records"] as? [[String: Any]])
        for index in rows.indices { rows[index].removeValue(forKey: "blocked_capacity_user_days") }
        root["records"] = rows
        let batch = try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: aliaser, now: now)
        let summary = try OrganizationCapacityCalculator.summary(aggregates: batch.aggregates, provenances: [batch.provenance])
        #expect(summary.providers.first?.blockedCapacityDays == nil)
    }

    @Test func concentrationAndCostsRemainSeparatedByProviderProduct() throws {
        var root = try #require(JSONSerialization.jsonObject(with: validFile()) as? [String: Any])
        var rows = try #require(root["records"] as? [[String: Any]])
        rows[1]["provider_product"] = "codex"
        rows[1]["subscription_seat_cost"] = ["amount": 20, "currency": "USD", "provenance": "provider_reported"]
        rows[1].removeValue(forKey: "api_overflow_cost")
        root["records"] = rows
        let batch = try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: aliaser, now: now)
        let summary = try OrganizationCapacityCalculator.summary(aggregates: batch.aggregates, provenances: [batch.provenance])
        #expect(summary.providers.allSatisfy { $0.dailyTopTeamShare == nil })
        #expect(summary.providers.allSatisfy { $0.cacheEfficiency?.sampleCount == 1 })
        #expect(summary.providers.allSatisfy { $0.peakConcurrency?.sampleCount == 1 })
        #expect(summary.providers.allSatisfy { $0.repeatedNearExhaustionShare?.sampleCount == 1 })
        #expect(summary.providers.allSatisfy { $0.blockedCapacityDays?.count == 1 || $0.blockedCapacityDays?.isEmpty == true })
        let costs = summary.providers.flatMap(\.costs)
        #expect(costs.count == 2)
        #expect(Set(costs.map(\.providerProduct)) == [.claudeCode, .codex])
    }

    @Test func rejectsHumanReadableOrNoncanonicalTeamIdentities() throws {
        for identity in ["platform-team", "john_smith", "11111111-1111-4111-8111-11111111111A", "not-a-uuid"] {
            var root = try #require(JSONSerialization.jsonObject(with: validFile()) as? [String: Any])
            var rows = try #require(root["records"] as? [[String: Any]])
            rows[0]["team_identity"] = identity
            root["records"] = rows
            #expect(throws: OrganizationCapacityError.self) {
                try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: aliaser, now: now)
            }
        }
    }

    @Test func aggregateDecodingCannotBypassCohortThreshold() throws {
        let batch = try OrganizationDailyAggregateImporter.importData(validFile(), aliaser: aliaser, now: now)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch.aggregates[0])) as? [String: Any])
        object["cohortSize"] = 4
        let unsafe = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: OrganizationCapacityError.self) {
            try JSONDecoder().decode(OrganizationDailyAggregate.self, from: unsafe)
        }
        #expect(throws: OrganizationCapacityError.self) {
            try OrganizationDailyAggregate(
                day: Date(timeIntervalSince1970: 1_783_209_600),
                providerProduct: .claudeCode,
                teamAlias: "team-000000000000000000000000",
                cohortSize: 4,
                usageUnits: 1
            )
        }
    }

    @Test func mixedProviderScenarioNeverCombinesEvidence() throws {
        var root = try #require(JSONSerialization.jsonObject(with: validFile()) as? [String: Any])
        var rows = try #require(root["records"] as? [[String: Any]])
        rows[1]["provider_product"] = "codex"
        root["records"] = rows
        let batch = try OrganizationDailyAggregateImporter.importData(JSONSerialization.data(withJSONObject: root), aliaser: aliaser, now: now)
        #expect(try OrganizationCapacityCalculator.scheduleShiftScenario(aggregates: batch.aggregates, shiftFraction: 0.25) == nil)
        let scenarios = try OrganizationCapacityCalculator.scheduleShiftScenarios(aggregates: batch.aggregates, shiftFraction: 0.25)
        #expect(scenarios.map(\.providerProduct) == [.claudeCode, .codex])
        let export = try OrganizationCapacityExporter.make(
            aggregates: batch.aggregates,
            provenances: [batch.provenance],
            shiftFraction: 0.25,
            generatedAt: now
        )
        let exportRoot = try #require(JSONSerialization.jsonObject(with: export) as? [String: Any])
        let exportedSummary = try #require(exportRoot["summary"] as? [String: Any])
        #expect(Set(exportedSummary.keys) == ["acceptedRecordCount", "providers", "suppressedRecordCount"])
        let exportedScenarios = try #require(exportRoot["scenarios"] as? [[String: Any]])
        #expect(Set(exportedScenarios.compactMap { $0["providerProduct"] as? String }) == ["claude_code", "codex"])
    }

    private func validFile() -> Data {
        Data(#"{"schema_version":"limitbar.organization.daily.v1","administrator_reviewed":true,"aggregation_period":"daily","timezone":"UTC","records":[{"day":"2026-07-05","provider_product":"claude_code","team_identity":"11111111-1111-4111-8111-111111111111","cohort_size":8,"complete_day":true,"usage_units":600,"blocked_capacity_user_days":2,"cache_read_units":800,"uncached_input_units":200,"peak_concurrency":4,"quota_eligible_users":8,"repeatedly_near_exhaustion_users":2,"scheduled_peak_blocked_minutes":120,"off_peak_available_minutes":60,"subscription_seat_cost":{"amount":40,"currency":"USD","provenance":"provider_reported"}},{"day":"2026-07-05","provider_product":"claude_code","team_identity":"22222222-2222-4222-8222-222222222222","cohort_size":5,"complete_day":true,"usage_units":400,"blocked_capacity_user_days":0,"cache_read_units":300,"uncached_input_units":300,"peak_concurrency":3,"quota_eligible_users":5,"repeatedly_near_exhaustion_users":1,"scheduled_peak_blocked_minutes":60,"off_peak_available_minutes":40,"api_overflow_cost":{"amount":5,"currency":"USD","provenance":"calculated"}}]}"#.utf8)
    }
}

private final class AliasSpy: OrganizationTeamAliasing, @unchecked Sendable {
    private(set) var identities: [String] = []
    func alias(for teamIdentity: UUID) throws -> String {
        identities.append(teamIdentity.uuidString.lowercased())
        return "team-000000000000000000000000"
    }
}
