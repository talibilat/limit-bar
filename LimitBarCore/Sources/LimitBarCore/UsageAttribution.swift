import Foundation

public enum LocalUsageEvidenceKind: Equatable, Sendable {
    case observedLocalBreakdown
}

/// Measured event-level attribution kept separate from its parent Usage Aggregate.
public struct ObservedLocalAttributionBreakdown: Equatable, Sendable {
    public let evidenceKind: LocalUsageEvidenceKind
    public let source: UsageMetricSource
    public let provider: ProviderKind
    public let window: ExactUsageWindow
    public let model: String
    public let deployment: String?
    public let project: CollectorAttribution?
    public let agent: CollectorAttribution?
    public let tokenUsage: TokenUsage
    public let eventIDs: [UUID]

    public init(
        source: UsageMetricSource,
        provider: ProviderKind,
        window: ExactUsageWindow,
        model: String,
        deployment: String?,
        project: CollectorAttribution?,
        agent: CollectorAttribution?,
        tokenUsage: TokenUsage,
        eventIDs: [UUID]
    ) {
        evidenceKind = .observedLocalBreakdown
        self.source = source
        self.provider = provider
        self.window = window
        self.model = model
        self.deployment = deployment
        self.project = project
        self.agent = agent
        self.tokenUsage = tokenUsage
        self.eventIDs = eventIDs
    }
}
