import Foundation

public enum ProviderAuthMethod: String, Codable, CaseIterable, Equatable, Sendable {
    case anthropicAdminAPIKey
    case anthropicOAuth
    case azureAPIKey
    case openAIOAuth
    case openAIAdminAPIKey

    public var provider: ProviderKind {
        switch self {
        case .anthropicAdminAPIKey, .anthropicOAuth:
            .anthropic
        case .azureAPIKey:
            .azureOpenAI
        case .openAIOAuth, .openAIAdminAPIKey:
            .openAI
        }
    }

    public var displayText: String {
        switch self {
        case .anthropicAdminAPIKey:
            "Admin API key"
        case .anthropicOAuth, .openAIOAuth:
            "OAuth"
        case .azureAPIKey:
            "API key"
        case .openAIAdminAPIKey:
            "Admin/platform API key"
        }
    }

    public static func methods(for provider: ProviderKind) -> [ProviderAuthMethod] {
        allCases.filter { $0.provider == provider }
    }
}

public enum ProviderConnectionState: String, Codable, CaseIterable, Equatable, Sendable {
    case missing
    case configured
    case connected
    case failed
    case expired
    case unsupported
    case adminRequired

    public var displayText: String {
        switch self {
        case .missing:
            "Missing"
        case .configured:
            "Configured, validation pending"
        case .connected:
            "Connected"
        case .failed:
            "Failed"
        case .expired:
            "Expired"
        case .unsupported:
            "Unsupported"
        case .adminRequired:
            "Admin credential required"
        }
    }
}

public enum OpenAIOAuthFeasibility: String, Codable, CaseIterable, Equatable, Sendable {
    case unvalidated
    case supported
    case unsupported
    case adminCredentialRequired

    public var displayText: String {
        switch self {
        case .unvalidated:
            "Not validated"
        case .supported:
            "Supported"
        case .unsupported:
            "Unsupported"
        case .adminCredentialRequired:
            "Admin credential required"
        }
    }
}

public enum ProviderFailureReason: String, Codable, CaseIterable, Equatable, Sendable {
    case authenticationRejected
    case insufficientPermissions
    case expiredCredential
    case invalidConfiguration
    case networkUnavailable
    case refreshFailed

    public var displayText: String {
        switch self {
        case .authenticationRejected:
            "Authentication rejected"
        case .insufficientPermissions:
            "Insufficient permissions"
        case .expiredCredential:
            "Credential expired"
        case .invalidConfiguration:
            "Invalid configuration"
        case .networkUnavailable:
            "Network unavailable"
        case .refreshFailed:
            "Refresh failed"
        }
    }
}

public struct ProviderSettings: Codable, Equatable, Sendable {
    public let provider: ProviderKind
    public var authMethod: ProviderAuthMethod
    public var azureEndpoint: String?
    public var openAIOAuthFeasibility: OpenAIOAuthFeasibility
    public var state: ProviderConnectionState
    public var failureReason: ProviderFailureReason?
    public var updatedAt: Date

    public init(
        provider: ProviderKind,
        authMethod: ProviderAuthMethod,
        azureEndpoint: String? = nil,
        openAIOAuthFeasibility: OpenAIOAuthFeasibility = .unvalidated,
        state: ProviderConnectionState = .missing,
        failureReason: ProviderFailureReason? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.provider = provider
        self.authMethod = authMethod
        self.azureEndpoint = azureEndpoint
        self.openAIOAuthFeasibility = openAIOAuthFeasibility
        self.state = state
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }

    public static let defaultSettings = [
        ProviderSettings(provider: .anthropic, authMethod: .anthropicAdminAPIKey),
        ProviderSettings(provider: .azureOpenAI, authMethod: .azureAPIKey),
        ProviderSettings(provider: .openAI, authMethod: .openAIOAuth)
    ]
}

public struct ProviderDiagnostic: Codable, Equatable, Sendable {
    public let provider: ProviderKind
    public let state: ProviderConnectionState
    public let failureReason: ProviderFailureReason?
    public let updatedAt: Date

    public init(provider: ProviderKind, state: ProviderConnectionState, failureReason: ProviderFailureReason?, updatedAt: Date) {
        self.provider = provider
        self.state = state
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }

    public init(settings: ProviderSettings) {
        self.init(provider: settings.provider, state: settings.state, failureReason: settings.failureReason, updatedAt: settings.updatedAt)
    }
}

public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public let providerDiagnostics: [ProviderDiagnostic]
    public let usageDatabaseSummary: String
    public let azureAcceptedEventCount: Int
    public let azureRejectedEventCount: Int
    public let azureFailureSummary: String?

    public init(
        providerDiagnostics: [ProviderDiagnostic],
        usageDatabaseSummary: String,
        azureAcceptedEventCount: Int,
        azureRejectedEventCount: Int,
        azureFailureSummary: String?
    ) {
        self.providerDiagnostics = providerDiagnostics
        self.usageDatabaseSummary = usageDatabaseSummary
        self.azureAcceptedEventCount = azureAcceptedEventCount
        self.azureRejectedEventCount = azureRejectedEventCount
        self.azureFailureSummary = azureFailureSummary
    }
}
