public enum APIProviderQuotaUnavailableReason: String, Codable, Equatable, Hashable, Sendable {
    case noDocumentedSafeAcquisitionForWorkloadEvidence = "no_documented_safe_acquisition_for_workload_evidence"
    case noDocumentedReadSourceForQuotaConsumption = "no_documented_read_source_for_quota_consumption"
    case noDocumentedProviderQuotaWindowBoundary = "no_documented_provider_quota_window_boundary"
}

public enum APIProviderQuotaPathAvailability: Equatable, Sendable {
    case unavailable(Set<APIProviderQuotaUnavailableReason>)

    public static let fixedUnavailableSummary =
        "API-provider quota evidence is unavailable: no documented source currently provides safely acquirable quota consumption in an exact provider-defined Quota window with a reported boundary."
}

public extension ProviderProduct {
    var apiQuotaPathAvailability: APIProviderQuotaPathAvailability? {
        let unmetCriteria: Set<APIProviderQuotaUnavailableReason> = [
            .noDocumentedSafeAcquisitionForWorkloadEvidence,
            .noDocumentedReadSourceForQuotaConsumption,
            .noDocumentedProviderQuotaWindowBoundary,
        ]
        return switch self {
        case .anthropicAPI, .openAIAPI, .azureOpenAI:
            .unavailable(unmetCriteria)
        case .claudeCode, .codex:
            nil
        }
    }
}
