import Foundation
import Testing
@testable import LimitBarCore

@Suite("Pricing")
struct PricingTests {
    @Test("calculates cost from input and output token prices")
    func calculatesCostFromInputAndOutputTokenPrices() throws {
        let metric = usage(inputTokens: 1_000_000, outputTokens: 500_000)
        let table = PricingTable(entries: [price(input: decimal("3.00"), output: decimal("15.00"))])

        let cost = try #require(CostCalculator.cost(for: metric, pricing: table))

        #expect(cost.amount == decimal("10.50"))
        #expect(cost.currencyCode == "USD")
        #expect(cost.source == .calculatedEstimate)
    }

    @Test("prefers provider reported cost")
    func prefersProviderReportedCost() throws {
        let reported = Cost(amount: decimal("2.25"), currencyCode: "USD", source: .providerReported)
        let metric = usage(cost: reported)
        let table = PricingTable(entries: [price(input: decimal("99"), output: decimal("99"))])

        #expect(CostCalculator.cost(for: metric, pricing: table) == reported)
    }

    @Test("selects latest effective pricing at usage time")
    func selectsLatestEffectivePricingAtUsageTime() throws {
        let metric = usage(refreshedAt: date(2026, 7, 10), inputTokens: 1_000_000, outputTokens: 0)
        let table = PricingTable(entries: [
            price(input: decimal("3.00"), output: decimal("1.00"), effectiveAt: date(2026, 1, 1)),
            price(input: decimal("4.00"), output: decimal("1.00"), effectiveAt: date(2026, 7, 1)),
            price(input: decimal("5.00"), output: decimal("1.00"), effectiveAt: date(2026, 8, 1))
        ])

        let cost = try #require(CostCalculator.cost(for: metric, pricing: table))

        #expect(cost.amount == decimal("4.00"))
    }

    @Test("missing pricing does not produce fake cost")
    func missingPricingDoesNotProduceFakeCost() {
        let metric = usage(modelLabel: "unknown-model")
        let table = PricingTable(entries: [price(modelLabel: "known-model", input: decimal("1"), output: decimal("1"))])

        #expect(CostCalculator.cost(for: metric, pricing: table) == nil)
    }

    @Test("cost source labels stay stable")
    func costSourceLabelsStayStable() {
        #expect(CostSource.providerReported.displayLabel == "Provider reported")
        #expect(CostSource.calculatedEstimate.displayLabel == "Calculated estimate")
    }

    private func usage(
        provider: ProviderKind = .openAI,
        modelLabel: String = "gpt-5.1-codex",
        refreshedAt: Date = Date(timeIntervalSince1970: 1_783_728_000),
        inputTokens: Int = 1_000,
        outputTokens: Int = 1_000,
        cost: Cost? = nil
    ) -> UsageMetric {
        UsageMetric(
            provider: provider,
            accountLabel: nil,
            projectLabel: nil,
            modelLabel: modelLabel,
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens),
            cost: cost,
            limitStatus: .unsupportedByProviderAPI,
            refreshedAt: refreshedAt,
            freshness: .fresh
        )
    }

    private func price(
        provider: ProviderKind = .openAI,
        modelLabel: String = "gpt-5.1-codex",
        input: Decimal,
        output: Decimal,
        effectiveAt: Date = Date(timeIntervalSince1970: 0)
    ) -> PricingEntry {
        PricingEntry(
            provider: provider,
            modelLabel: modelLabel,
            inputPricePerMillionTokens: input,
            outputPricePerMillionTokens: output,
            currencyCode: "USD",
            effectiveAt: effectiveAt
        )
    }

    private func decimal(_ string: String) -> Decimal {
        Decimal(string: string)!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: year, month: month, day: day))!
    }
}
