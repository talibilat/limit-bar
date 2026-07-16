public protocol UsageAlertDelivering: Sendable {
    func deliver(_ notification: UsageAlertNotification) async throws
}

public struct UsageAlertEvaluationContext: Sendable {
    public let metrics: [UsageMetric]
    public let enabledRules: Set<UsageAlertRule>

    public init(metrics: [UsageMetric], enabledRules: Set<UsageAlertRule>) {
        self.metrics = metrics
        self.enabledRules = enabledRules
    }
}

public struct UsageAlertCandidate: Equatable, Sendable {
    public let rule: UsageAlertRule
    public let provider: ProviderKind
    public let window: ExactUsageWindow

    public init(rule: UsageAlertRule, provider: ProviderKind, window: ExactUsageWindow) {
        self.rule = rule
        self.provider = provider
        self.window = window
    }
}

// Forecast and anomaly rules can plug in here later. No extension evaluators are installed by default.
public protocol UsageAlertRuleEvaluating: Sendable {
    func candidates(in context: UsageAlertEvaluationContext) -> [UsageAlertCandidate]
}
