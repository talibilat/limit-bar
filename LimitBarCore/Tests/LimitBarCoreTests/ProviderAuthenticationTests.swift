import Foundation
import Testing
@testable import LimitBarCore

@Suite("Provider authentication")
struct ProviderAuthenticationTests {
    @Test("auth methods belong to their provider")
    func authMethodsBelongToTheirProvider() {
        #expect(ProviderAuthMethod.anthropicAdminAPIKey.provider == .anthropic)
        #expect(ProviderAuthMethod.anthropicOAuth.provider == .anthropic)
        #expect(ProviderAuthMethod.azureAPIKey.provider == .azureOpenAI)
        #expect(ProviderAuthMethod.openAIOAuth.provider == .openAI)
        #expect(ProviderAuthMethod.openAIAdminAPIKey.provider == .openAI)
    }

    @Test("provider defaults stay ordered and unvalidated")
    func providerDefaultsStayOrderedAndUnvalidated() {
        let settings = ProviderSettings.defaultSettings

        #expect(settings.map(\.provider) == ProviderKind.orderedCases)
        #expect(settings.map(\.state) == [.missing, .missing, .missing])
        #expect(settings[0].authMethod == .anthropicAdminAPIKey)
        #expect(settings[1].authMethod == .azureAPIKey)
        #expect(settings[2].authMethod == .openAIOAuth)
        #expect(settings[2].openAIOAuthFeasibility == .unvalidated)
    }

    @Test("connection and feasibility labels stay honest")
    func connectionAndFeasibilityLabelsStayHonest() {
        #expect(ProviderConnectionState.missing.displayText == "Missing")
        #expect(ProviderConnectionState.configured.displayText == "Configured, validation pending")
        #expect(ProviderConnectionState.connected.displayText == "Connected")
        #expect(ProviderConnectionState.failed.displayText == "Failed")
        #expect(ProviderConnectionState.expired.displayText == "Expired")
        #expect(ProviderConnectionState.unsupported.displayText == "Unsupported")
        #expect(ProviderConnectionState.adminRequired.displayText == "Admin credential required")
        #expect(OpenAIOAuthFeasibility.unvalidated.displayText == "Not validated")
        #expect(OpenAIOAuthFeasibility.supported.displayText == "Supported")
        #expect(OpenAIOAuthFeasibility.unsupported.displayText == "Unsupported")
        #expect(OpenAIOAuthFeasibility.adminCredentialRequired.displayText == "Admin credential required")
    }

    @Test("safe failure reasons have fixed summaries")
    func safeFailureReasonsHaveFixedSummaries() {
        #expect(ProviderFailureReason.authenticationRejected.displayText == "Authentication rejected")
        #expect(ProviderFailureReason.insufficientPermissions.displayText == "Insufficient permissions")
        #expect(ProviderFailureReason.expiredCredential.displayText == "Credential expired")
        #expect(ProviderFailureReason.invalidConfiguration.displayText == "Invalid configuration")
        #expect(ProviderFailureReason.networkUnavailable.displayText == "Network unavailable")
        #expect(ProviderFailureReason.refreshFailed.displayText == "Refresh failed")
    }

    @Test("diagnostics encoding excludes secret and content fields")
    func diagnosticsEncodingExcludesSecretAndContentFields() throws {
        let secretSentinel = "super-secret-value"
        let report = DiagnosticsReport(
            providerDiagnostics: [
                ProviderDiagnostic(
                    provider: .anthropic,
                    state: .failed,
                    failureReason: .authenticationRejected,
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ],
            usageDatabaseSummary: "SQLite store opened",
            azureAcceptedEventCount: 3,
            azureRejectedEventCount: 1,
            azureFailureSummary: nil
        )

        let json = try #require(String(data: JSONEncoder().encode(report), encoding: .utf8))
        #expect(json.contains("anthropic"))
        #expect(json.contains("authenticationRejected"))
        #expect(!json.contains(secretSentinel))
        for forbidden in ["apiKey", "accessToken", "refreshToken", "prompt", "response", "requestBody", "terminalOutput", "sourceCode", "rawProviderResponse"] {
            #expect(!json.contains(forbidden))
        }
    }
}
