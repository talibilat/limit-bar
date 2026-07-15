import Foundation

public enum LocalUsageEvidenceKind: Equatable, Sendable {
    case observedLocalBreakdown
}

public enum InferredQuotaAllocationValidationError: Error, Equatable {
    case invalidAllocation
}

public enum InferredQuotaAllocationMethod: String, Codable, Equatable, Hashable, Sendable {
    case temporalProportionalV1 = "temporal_proportional_v1"
}

public enum InferredQuotaAllocationLimitation: String, Codable, Equatable, Hashable, Sendable {
    case temporalCorrelationOnly = "temporal_correlation_only"
    case providerWeightingUnknown = "provider_weighting_unknown"
    case noCausalAttribution = "no_causal_attribution"
}

public struct InferredQuotaAllocation: Codable, Equatable, Sendable {
    public let percent: Double
    public let method: InferredQuotaAllocationMethod
    public let limitations: [InferredQuotaAllocationLimitation]

    public init(percent: Double, method: InferredQuotaAllocationMethod, limitations: [InferredQuotaAllocationLimitation]) throws {
        guard percent.isFinite, (0...100).contains(percent),
              !limitations.isEmpty else {
            throw InferredQuotaAllocationValidationError.invalidAllocation
        }
        self.percent = percent
        self.method = method
        self.limitations = Array(Set(limitations)).sorted { $0.rawValue < $1.rawValue }
    }
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
    public let observedAt: Date

    public init(
        source: UsageMetricSource,
        provider: ProviderKind,
        window: ExactUsageWindow,
        model: String,
        deployment: String?,
        project: CollectorAttribution?,
        agent: CollectorAttribution?,
        tokenUsage: TokenUsage,
        eventIDs: [UUID],
        observedAt: Date
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
        self.observedAt = observedAt
    }
}
