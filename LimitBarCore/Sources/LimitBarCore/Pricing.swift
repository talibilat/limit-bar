import Foundation

public struct PricingEntry: Codable, Equatable, Sendable {
    public let provider: ProviderKind
    public let modelLabel: String
    public let inputPricePerMillionTokens: Decimal
    public let outputPricePerMillionTokens: Decimal
    public let currencyCode: String
    public let effectiveAt: Date

    public init(
        provider: ProviderKind,
        modelLabel: String,
        inputPricePerMillionTokens: Decimal,
        outputPricePerMillionTokens: Decimal,
        currencyCode: String,
        effectiveAt: Date
    ) {
        self.provider = provider
        self.modelLabel = modelLabel
        self.inputPricePerMillionTokens = inputPricePerMillionTokens
        self.outputPricePerMillionTokens = outputPricePerMillionTokens
        self.currencyCode = currencyCode
        self.effectiveAt = Calendar.current.startOfDay(for: effectiveAt)
    }
}

public struct PricingTable: Codable, Equatable, Sendable {
    public let entries: [PricingEntry]

    public init(entries: [PricingEntry]) {
        self.entries = entries
    }

    public static let empty = PricingTable(entries: [])
    public static let bundledDefaultsVersion = "2026-07-10-unconfigured"
    public static let bundledDefaults = PricingTable(entries: [])

    public func price(for metric: UsageMetric, usageDate: Date) -> PricingEntry? {
        entries
            .filter { entry in
                entry.provider == metric.provider
                    && entry.modelLabel == metric.modelLabel
                    && entry.effectiveAt <= usageDate
            }
            .max { lhs, rhs in lhs.effectiveAt < rhs.effectiveAt }
    }
}

public enum CostCalculator {
    private static let tokenUnit = Decimal(1_000_000)

    public static func cost(for metric: UsageMetric, pricing: PricingTable) -> Cost? {
        if let cost = metric.cost, cost.source == .providerReported {
            return cost
        }

        return estimatedCost(for: metric, pricing: pricing)
    }

    public static func estimatedCost(for metric: UsageMetric, pricing: PricingTable) -> Cost? {
        guard let usageDate = metric.refreshedAt else {
            return nil
        }
        guard let price = pricing.price(for: metric, usageDate: usageDate) else {
            return nil
        }

        let inputCost = Decimal(metric.tokenUsage.inputTokens) / tokenUnit * price.inputPricePerMillionTokens
        let outputCost = Decimal(metric.tokenUsage.outputTokens) / tokenUnit * price.outputPricePerMillionTokens

        return Cost(
            amount: (inputCost + outputCost).rounded(scale: 6),
            currencyCode: price.currencyCode,
            source: .calculatedEstimate
        )
    }
}

private extension Decimal {
    func rounded(scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}
