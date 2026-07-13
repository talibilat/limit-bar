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

    public var credentialKind: CredentialKind {
        switch self {
        case .anthropicAdminAPIKey, .azureAPIKey, .openAIAdminAPIKey:
            .apiKey
        case .anthropicOAuth, .openAIOAuth:
            .accessToken
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
    case cancelled

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
        case .cancelled:
            "Cancelled"
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
    public var openAIOrganizationID: String?
    public var openAIOAuthFeasibility: OpenAIOAuthFeasibility
    public var state: ProviderConnectionState
    public var failureReason: ProviderFailureReason?
    public var updatedAt: Date

    public init(
        provider: ProviderKind,
        authMethod: ProviderAuthMethod,
        azureEndpoint: String? = nil,
        openAIOrganizationID: String? = nil,
        openAIOAuthFeasibility: OpenAIOAuthFeasibility = .unvalidated,
        state: ProviderConnectionState = .missing,
        failureReason: ProviderFailureReason? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.provider = provider
        self.authMethod = authMethod
        self.azureEndpoint = azureEndpoint
        self.openAIOrganizationID = openAIOrganizationID
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

    public var shouldUpdateSettings: Bool {
        state != .cancelled
    }
}

public enum ProviderSettingsPersistenceDecision: Equatable, Sendable {
    case persist
    case suppress

    public static func evaluate(
        _ diagnostic: ProviderDiagnostic,
        taskIsCancelled: Bool
    ) -> ProviderSettingsPersistenceDecision {
        guard !taskIsCancelled, diagnostic.shouldUpdateSettings else { return .suppress }
        return .persist
    }
}

public enum UsageDatabaseDiagnosticState: String, Codable, Equatable, Sendable {
    case opened
    case unavailable

    public var displayText: String {
        switch self {
        case .opened:
            "SQLite store opened"
        case .unavailable:
            "SQLite store unavailable"
        }
    }
}

public enum LocalImportDiagnosticState: String, Codable, Equatable, Sendable {
    case healthy
    case failed

    public var displayText: String {
        switch self {
        case .healthy:
            "Import healthy"
        case .failed:
            "Import failed"
        }
    }
}

public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public let providerDiagnostics: [ProviderDiagnostic]
    public let usageDatabaseState: UsageDatabaseDiagnosticState
    public let localAcceptedEventCount: Int
    public let localRejectedEventCount: Int
    public let localImportState: LocalImportDiagnosticState

    public init(
        providerDiagnostics: [ProviderDiagnostic],
        usageDatabaseState: UsageDatabaseDiagnosticState,
        localAcceptedEventCount: Int,
        localRejectedEventCount: Int,
        localImportState: LocalImportDiagnosticState
    ) {
        self.providerDiagnostics = providerDiagnostics
        self.usageDatabaseState = usageDatabaseState
        self.localAcceptedEventCount = localAcceptedEventCount
        self.localRejectedEventCount = localRejectedEventCount
        self.localImportState = localImportState
    }
}

public enum ProviderSettingsPersistence {
    public static func encode(_ settings: [ProviderSettings]) throws -> Data {
        try JSONEncoder().encode(normalized(settings))
    }

    public static func decode(_ data: Data?) -> [ProviderSettings] {
        guard let data,
              let decoded = try? JSONDecoder().decode([ProviderSettings].self, from: data) else {
            return ProviderSettings.defaultSettings
        }
        return normalized(decoded)
    }

    private static func normalized(_ settings: [ProviderSettings]) -> [ProviderSettings] {
        let byProvider = Dictionary(settings.map { ($0.provider, $0) }, uniquingKeysWith: { _, latest in latest })
        return ProviderKind.orderedCases.compactMap { provider in
            byProvider[provider] ?? ProviderSettings.defaultSettings.first { $0.provider == provider }
        }
    }
}
