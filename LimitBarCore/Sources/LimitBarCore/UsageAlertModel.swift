import Foundation

public enum UsageAlertRateThreshold: Int, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case seventyPercent = 70
    case ninetyPercent = 90
}

public struct UsageAlertCostThreshold: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable {
        case invalidAmount
        case invalidCurrencyCode
    }

    public let amount: Decimal
    public let currencyCode: String
    public let source: CostSource

    public init(amount: Decimal, currencyCode: String, source: CostSource) throws {
        guard UsageAlertValidation.isPositiveFinite(amount) else {
            throw ValidationError.invalidAmount
        }
        guard let currencyCode = UsageAlertValidation.normalizedCurrencyCode(currencyCode) else {
            throw ValidationError.invalidCurrencyCode
        }

        self.amount = amount
        self.currencyCode = currencyCode
        self.source = source
    }
}

public enum UsageAlertRule: Codable, Equatable, Hashable, Sendable {
    case rateLimit(provider: ProviderKind, threshold: UsageAlertRateThreshold)
    case cost(provider: ProviderKind, threshold: UsageAlertCostThreshold)
    case extensionRule(namespace: String, identifier: String)
}

public struct UsageAlertNotification: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct UsageAlert: Equatable, Sendable {
    public let rule: UsageAlertRule
    public let provider: ProviderKind
    public let window: ExactUsageWindow
    public let notification: UsageAlertNotification

    init(rule: UsageAlertRule, provider: ProviderKind, window: ExactUsageWindow) {
        self.rule = rule
        self.provider = provider
        self.window = window
        self.notification = Self.notification(for: rule, provider: provider)
    }

    private static func notification(for rule: UsageAlertRule, provider: ProviderKind) -> UsageAlertNotification {
        let title = "\(provider.displayName) usage alert"
        switch rule {
        case let .rateLimit(_, threshold):
            return UsageAlertNotification(
                title: title,
                body: "Rate limit reached \(threshold.rawValue)%."
            )
        case let .cost(_, threshold):
            return UsageAlertNotification(
                title: title,
                body: "Cost reached \(threshold.currencyCode) \(NSDecimalNumber(decimal: threshold.amount).stringValue)."
            )
        case .extensionRule:
            return UsageAlertNotification(title: title, body: "Usage threshold reached.")
        }
    }
}

public struct UsageAlertState: Codable, Equatable, Sendable {
    var delivered: Set<UsageAlertDeduplicationKey>

    public init() {
        delivered = []
    }
}

struct UsageAlertDeduplicationKey: Codable, Equatable, Hashable, Sendable {
    let rule: UsageAlertRule
    let window: ExactUsageWindow
}

enum UsageAlertValidation {
    static func normalizedCurrencyCode(_ value: String) -> String? {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.utf8.count == 3, code.utf8.allSatisfy({ (65...90).contains($0) }) else {
            return nil
        }
        return code
    }

    static func isPositiveFinite(_ value: Decimal) -> Bool {
        var value = value
        return !NSDecimalIsNotANumber(&value) && value > 0
    }

    static func isNonnegativeFinite(_ value: Decimal) -> Bool {
        var value = value
        return !NSDecimalIsNotANumber(&value) && value >= 0
    }
}
