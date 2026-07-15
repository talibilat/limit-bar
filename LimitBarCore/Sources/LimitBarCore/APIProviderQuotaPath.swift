public enum APIProviderQuotaUnavailableReason: String, Codable, Equatable, Sendable {
    case noDocumentedSafeAcquisition = "no_documented_safe_acquisition"
    case noAbsoluteProviderReportedResetBoundary = "no_absolute_provider_reported_reset_boundary"
    case noDocumentedConsumptionWindowBoundary = "no_documented_consumption_window_boundary"
}

public enum APIProviderQuotaPathAvailability: Equatable, Sendable {
    case unavailable(APIProviderQuotaUnavailableReason)

    public static let fixedUnavailableSummary =
        "API-provider quota evidence is unavailable: no documented source currently provides both safely acquirable quota consumption and an exact provider-reported reset boundary."
}

public extension ProviderProduct {
    var apiQuotaPathAvailability: APIProviderQuotaPathAvailability? {
        switch self {
        case .anthropicAPI:
            .unavailable(.noDocumentedSafeAcquisition)
        case .openAIAPI:
            .unavailable(.noAbsoluteProviderReportedResetBoundary)
        case .azureOpenAI:
            .unavailable(.noDocumentedConsumptionWindowBoundary)
        case .claudeCode, .codex:
            nil
        }
    }
}
