import Foundation
import Testing
@testable import LimitBarCore

@Suite("Alert core")
struct AlertCoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("thresholds and preferences validate while rule IDs survive coding")
    func validatedCodablePreferences() throws {
        #expect(PercentageThresholds.suggested.values == [70, 90])
        #expect(throws: AlertValidationError.invalidThreshold) {
            try PercentageThresholds([0, 50])
        }
        #expect(throws: AlertValidationError.invalidBudgetCap) {
            try CostBudgetAlertRule(
                product: .openAIAPI,
                currencyCode: "USD",
                source: .providerReported,
                timeWindow: .today,
                basis: .utcBilling,
                cap: 0,
                thresholds: PercentageThresholds.suggested
            )
        }
        #expect(throws: AlertValidationError.invalidCurrencyCode) {
            try CostBudgetAlertRule(
                product: .openAIAPI,
                currencyCode: "credits",
                source: .calculatedEstimate,
                timeWindow: .today,
                basis: .utcBilling,
                cap: 10,
                thresholds: .suggested
            )
        }

        let id = UUID(uuidString: "AA8DE40F-9802-4AEE-AC63-3D5D1BB5FB56")!
        let preferences = try AlertPreferences(
            quotaRules: [QuotaAlertRule(id: id, product: .claudeCode, thresholds: PercentageThresholds([90, 50, 90]))],
            costBudgetRules: []
        )
        let decoded = try JSONDecoder().decode(AlertPreferences.self, from: JSONEncoder().encode(preferences))

        #expect(decoded == preferences)
        #expect(decoded.quotaRules.first?.id == id)
        #expect(decoded.quotaRules.first?.thresholds.values == [50, 90])
    }

    @Test("provider products distinguish subscriptions from APIs with accurate names")
    func providerProductsAndUsageMapping() {
        #expect(ProviderProduct.claudeCode.displayName == "Claude Code")
        #expect(ProviderProduct.codex.displayName == "Codex")
        #expect(ProviderProduct.anthropicAPI.displayName == "Anthropic API")
        #expect(ProviderProduct.openAIAPI.displayName == "OpenAI API")
        #expect(ProviderProduct.azureOpenAI.displayName == "Azure OpenAI")
        #expect(ProviderProduct(provider: .anthropic) == .anthropicAPI)
        #expect(ProviderProduct(provider: .openAI) == .openAIAPI)
        #expect(ProviderProduct(provider: .azureOpenAI) == .azureOpenAI)
        #expect(ProviderProduct(provider: .custom) == nil)
    }

    @Test("Claude adapter uses stable non-display identities for fresh future-boundary limits")
    func claudeAdapterEligibility() {
        let snapshot = ClaudeRateLimitSnapshot(
            limits: [
                claudeLimit(kind: "session", percent: 71, reset: now.addingTimeInterval(300), active: true),
                claudeLimit(kind: "weekly_model", percent: 80, reset: now.addingTimeInterval(500), scope: "Private model", active: true),
                claudeLimit(kind: "inactive", percent: 90, reset: now.addingTimeInterval(500), active: false),
                claudeLimit(kind: "expired", percent: 99, reset: now, active: true)
            ],
            fetchedAt: now.addingTimeInterval(-30)
        )

        let team = QuotaObservationAdapter.claude(snapshot, subscriptionType: "team", now: now)
        let pro = QuotaObservationAdapter.claude(snapshot, subscriptionType: "pro", now: now)
        let stale = QuotaObservationAdapter.claude(snapshot, subscriptionType: "pro", now: now.addingTimeInterval(901))

        #expect(team.map(\.percentageUsed) == [71])
        #expect(pro.map(\.percentageUsed) == [71, 80])
        #expect(pro.allSatisfy { !$0.identity.identifier.contains("Private model") })
        #expect(stale.isEmpty)
        #expect(pro.allSatisfy { $0.identity.resetBoundary > now })
    }

    @Test("Codex adapter preserves reset identities without fabricating usage windows")
    func codexAdapterEligibility() {
        let snapshot = CodexRateLimitSnapshot(
            planType: "plus",
            primary: CodexRateLimitWindow(percentUsed: 82, windowMinutes: 300, resetsAt: now.addingTimeInterval(300)),
            secondary: CodexRateLimitWindow(percentUsed: .nan, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(600)),
            credits: nil,
            reportedAt: now
        )

        let observations = QuotaObservationAdapter.codex(snapshot, now: now)

        #expect(observations.count == 1)
        #expect(observations.first?.identity.product == .codex)
        #expect(observations.first?.identity.resetBoundary == now.addingTimeInterval(300))
    }

    @Test("level qualification emits highest threshold and satisfies all newly qualified levels")
    func levelQualificationAndOccurrenceBookkeeping() throws {
        let rule = QuotaAlertRule(
            id: UUID(uuidString: "B176E84E-83B6-43D9-BA8E-3187AE21EF1B")!,
            product: .codex,
            thresholds: try PercentageThresholds([50, 75, 90])
        )
        let identity = try QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: now.addingTimeInterval(300))
        let observation = QuotaObservation(identity: identity, percentageUsed: 92, observedAt: now, expiresAt: now.addingTimeInterval(60))
        let preferences = try AlertPreferences(quotaRules: [rule], costBudgetRules: [])

        let first = AlertEvaluator.evaluate(preferences: preferences, quota: [observation], costs: [], satisfied: [], now: now)
        let occurrence = try #require(first.first?.occurrence)
        #expect(first.count == 1)
        #expect(first.first?.notification.threshold == 90)
        #expect(occurrence.thresholds == [50, 75, 90])

        let satisfied = occurrence.thresholds.map { AlertThresholdSatisfaction(ruleID: rule.id, window: occurrence.window, threshold: $0) }
        #expect(AlertEvaluator.evaluate(preferences: preferences, quota: [observation], costs: [], satisfied: Set(satisfied), now: now).isEmpty)
    }

    @Test("evaluator suppresses malformed unhealthy stale inactive and expired quota data")
    func suppressesIneligibleQuotaData() throws {
        let rule = QuotaAlertRule(product: .claudeCode, thresholds: try PercentageThresholds([50]))
        let preferences = try AlertPreferences(quotaRules: [rule], costBudgetRules: [])
        let identity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session", resetBoundary: now.addingTimeInterval(60))
        let observations = [
            QuotaObservation(identity: identity, percentageUsed: .infinity, observedAt: now, expiresAt: now.addingTimeInterval(10)),
            QuotaObservation(identity: identity, percentageUsed: 90, observedAt: now, expiresAt: now.addingTimeInterval(10), isActive: false),
            QuotaObservation(identity: identity, percentageUsed: 90, observedAt: now, expiresAt: now.addingTimeInterval(10), health: .unhealthy),
            QuotaObservation(identity: identity, percentageUsed: 90, observedAt: now.addingTimeInterval(-20), expiresAt: now.addingTimeInterval(-1))
        ]

        #expect(AlertEvaluator.evaluate(preferences: preferences, quota: observations, costs: [], satisfied: [], now: now).isEmpty)
    }

    @Test("cost observations separate sources and currencies with provider API precedence")
    func costObservationAggregation() throws {
        let window = try ExactUsageWindow(
            timeWindow: .today,
            start: now.addingTimeInterval(-100),
            end: now.addingTimeInterval(100),
            basis: .utcBilling
        )
        let api = usageMetric(
            source: .providerAPI,
            window: window,
            model: "api-model",
            tokens: 1_000_000,
            cost: Cost(amount: 8, currencyCode: "USD", source: .providerReported)
        )
        let overlappingLog = usageMetric(source: .builtInLocalLog, window: window, model: "local-model", tokens: 1_000_000)
        let pricing = PricingTable(entries: [
            PricingEntry(provider: .openAI, modelLabel: "api-model", inputPricePerMillionTokens: 4, outputPricePerMillionTokens: 0, currencyCode: "USD", effectiveAt: now.addingTimeInterval(-86_400)),
            PricingEntry(provider: .openAI, modelLabel: "local-model", inputPricePerMillionTokens: 100, outputPricePerMillionTokens: 0, currencyCode: "USD", effectiveAt: now.addingTimeInterval(-86_400))
        ])

        let observations = CostBudgetObservationBuilder.observations(metrics: [api, overlappingLog], pricing: pricing, health: .healthy, now: now)

        #expect(observations.count == 2)
        #expect(observations.allSatisfy { $0.product == .openAIAPI })
        #expect(observations.first { $0.source == .providerReported }?.amount == 8)
        #expect(observations.first { $0.source == .calculatedEstimate }?.amount == 4)
    }

    @Test("zero-token API spend does not suppress calculated local tokens")
    func zeroTokenReportedCostCoexistsWithLocalCalculation() throws {
        let window = try ExactUsageWindow(
            timeWindow: .today,
            start: now.addingTimeInterval(-100),
            end: now.addingTimeInterval(100),
            basis: .utcBilling
        )
        let reported = usageMetric(
            source: .providerAPI,
            window: window,
            model: "api-spend",
            tokens: 0,
            cost: Cost(amount: 12, currencyCode: "USD", source: .providerReported)
        )
        let local = usageMetric(source: .builtInLocalLog, window: window, model: "local-tokens", tokens: 1_000_000)
        let pricing = PricingTable(entries: [
            PricingEntry(provider: .openAI, modelLabel: "local-tokens", inputPricePerMillionTokens: 3, outputPricePerMillionTokens: 0, currencyCode: "USD", effectiveAt: now.addingTimeInterval(-86_400))
        ])

        let observations = CostBudgetObservationBuilder.observations(metrics: [reported, local], pricing: pricing, health: .healthy, now: now)

        #expect(observations.first { $0.source == .providerReported }?.amount == 12)
        #expect(observations.first { $0.source == .calculatedEstimate }?.amount == 3)
    }

    @Test("API token estimates supersede overlapping local token estimates")
    func apiTokensSupersedeLocalTokensForCalculatedBudgets() throws {
        let window = try ExactUsageWindow(
            timeWindow: .today,
            start: now.addingTimeInterval(-100),
            end: now.addingTimeInterval(100),
            basis: .utcBilling
        )
        let api = usageMetric(source: .providerAPI, window: window, model: "api", tokens: 1_000_000)
        let local = usageMetric(source: .builtInLocalLog, window: window, model: "local", tokens: 1_000_000)
        let pricing = PricingTable(entries: [
            PricingEntry(provider: .openAI, modelLabel: "api", inputPricePerMillionTokens: 2, outputPricePerMillionTokens: 0, currencyCode: "USD", effectiveAt: now.addingTimeInterval(-86_400)),
            PricingEntry(provider: .openAI, modelLabel: "local", inputPricePerMillionTokens: 99, outputPricePerMillionTokens: 0, currencyCode: "USD", effectiveAt: now.addingTimeInterval(-86_400))
        ])

        let observations = CostBudgetObservationBuilder.observations(metrics: [api, local], pricing: pricing, health: .healthy, now: now)

        #expect(observations.filter { $0.source == .calculatedEstimate }.map(\.amount) == [2])
    }

    @Test("Decimal aggregate overflow fails the affected measure closed")
    func decimalAggregateOverflowFailsClosed() throws {
        let window = try ExactUsageWindow(
            timeWindow: .today,
            start: now.addingTimeInterval(-100),
            end: now.addingTimeInterval(100),
            basis: .utcBilling
        )
        let first = usageMetric(
            source: .providerAPI,
            window: window,
            model: "first",
            tokens: 0,
            cost: Cost(amount: .greatestFiniteMagnitude, currencyCode: "USD", source: .providerReported)
        )
        let second = usageMetric(
            source: .providerAPI,
            window: window,
            model: "second",
            tokens: 0,
            cost: Cost(amount: .greatestFiniteMagnitude, currencyCode: "USD", source: .providerReported)
        )

        let observations = CostBudgetObservationBuilder.observations(metrics: [first, second], pricing: .empty, health: .healthy, now: now)

        #expect(observations.isEmpty)
    }

    @Test("cost observations require a measurement from the last 24 hours")
    func costObservationExactWindowFreshness() throws {
        let window = try ExactUsageWindow(
            timeWindow: .currentWeek,
            start: now.addingTimeInterval(-100_000),
            end: now.addingTimeInterval(100_000),
            basis: .utcBilling
        )
        let oldProviderCost = UsageMetric(
            provider: .openAI,
            accountLabel: nil,
            projectLabel: nil,
            modelLabel: "provider-cost",
            deploymentLabel: nil,
            provenance: .bounded(source: .providerAPI, window: window),
            tokenUsage: TokenUsage(inputTokens: 0, outputTokens: 0),
            cost: Cost(amount: 20, currencyCode: "USD", source: .providerReported),
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: now.addingTimeInterval(-99_999),
            freshness: .fresh
        )

        let observations = CostBudgetObservationBuilder.observations(
            metrics: [oldProviderCost],
            pricing: .empty,
            health: .healthy,
            now: now
        )

        #expect(observations.isEmpty)

        let recent = CostBudgetObservationBuilder.observations(
            metrics: [oldProviderCost],
            pricing: .empty,
            health: .healthy,
            now: now,
            maximumMeasurementAge: 100_000
        )
        #expect(recent.count == 1)
    }

    @Test("canonical cost identity includes the aggregation version")
    func canonicalWindowIdentityIncludesVersion() throws {
        let first = try ExactUsageWindow(
            timeWindow: .today,
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(60),
            basis: .localCalendar,
            aggregationVersion: 1
        )
        let second = try ExactUsageWindow(
            timeWindow: .today,
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(60),
            basis: .localCalendar,
            aggregationVersion: 2
        )

        #expect(AlertWindowIdentity.cost(first).canonicalIdentifier != AlertWindowIdentity.cost(second).canonicalIdentifier)
    }

    @Test("cost rules require exact matching basis currency and source and produce privacy-safe copy")
    func costEvaluationAndNotificationPrivacy() throws {
        let window = try ExactUsageWindow(timeWindow: .today, start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60), basis: .utcBilling)
        let rule = try CostBudgetAlertRule(
            product: .openAIAPI,
            currencyCode: "usd",
            source: .calculatedEstimate,
            timeWindow: .today,
            basis: .utcBilling,
            cap: Decimal(string: "13.37")!,
            thresholds: PercentageThresholds([50, 80])
        )
        let preferences = try AlertPreferences(quotaRules: [], costBudgetRules: [rule])
        let observation = CostBudgetObservation(product: .openAIAPI, source: .calculatedEstimate, window: window, currencyCode: "USD", amount: 12, observedAt: now)

        let evaluations = AlertEvaluator.evaluate(preferences: preferences, quota: [], costs: [observation], satisfied: [], now: now)
        let notification = try #require(evaluations.first?.notification)

        #expect(notification.threshold == 80)
        #expect(notification.body.contains("Estimated"))
        #expect(notification.body.contains("OpenAI API"))
        #expect(notification.body.contains("USD"))
        #expect(!notification.body.contains("12"))
        #expect(!notification.body.contains("13.37"))
        for privateText in ["account", "project", "model", "source"] {
            #expect(!notification.body.lowercased().contains(privateText))
        }
    }

    @Test("provider-reported notification copy identifies the measure without exposing amounts")
    func providerReportedNotificationPrivacy() throws {
        let window = try ExactUsageWindow(timeWindow: .today, start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60), basis: .utcBilling)
        let rule = try CostBudgetAlertRule(
            product: .anthropicAPI,
            currencyCode: "EUR",
            source: .providerReported,
            timeWindow: .today,
            basis: .utcBilling,
            cap: Decimal(string: "123.45")!,
            thresholds: PercentageThresholds([70])
        )
        let preferences = try AlertPreferences(quotaRules: [], costBudgetRules: [rule])
        let observation = CostBudgetObservation(product: .anthropicAPI, source: .providerReported, window: window, currencyCode: "EUR", amount: 100, observedAt: now)

        let notification = try #require(AlertEvaluator.evaluate(preferences: preferences, quota: [], costs: [observation], satisfied: [], now: now).first?.notification)

        #expect(notification.body.contains("Provider-reported Anthropic API"))
        #expect(notification.body.contains("70%"))
        #expect(notification.body.contains("EUR"))
        #expect(!notification.body.contains("100"))
        #expect(!notification.body.contains("123.45"))
    }

    private func claudeLimit(kind: String, percent: Double, reset: Date?, scope: String? = nil, active: Bool) -> ClaudeRateLimit {
        ClaudeRateLimit(kind: kind, group: .session, percentUsed: percent, severity: .normal, resetsAt: reset, scopeDisplayName: scope, isActive: active)
    }

    private func usageMetric(
        source: UsageMetricSource,
        window: ExactUsageWindow,
        model: String,
        tokens: Int,
        cost: Cost? = nil
    ) -> UsageMetric {
        UsageMetric(
            provider: .openAI,
            accountLabel: "private account",
            projectLabel: "private project",
            modelLabel: model,
            deploymentLabel: nil,
            provenance: .bounded(source: source, window: window),
            tokenUsage: TokenUsage(inputTokens: tokens, outputTokens: 0),
            cost: cost,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: now,
            freshness: .fresh
        )
    }
}
