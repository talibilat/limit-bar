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

        // .custom has no credential or auth method of its own (configured as
        // a local file in Settings instead), so it has no default entry here.
        #expect(settings.map(\.provider) == [.anthropic, .azureOpenAI, .openAI])
        #expect(settings.map(\.state) == [.missing, .missing, .missing])
        #expect(settings[0].authMethod == .anthropicAdminAPIKey)
        #expect(settings[1].authMethod == .azureAPIKey)
        #expect(settings[2].authMethod == .openAIOAuth)
        #expect(settings[2].openAIOAuthFeasibility == .unvalidated)
    }

    @Test("connection and feasibility labels stay honest")
    func connectionAndFeasibilityLabelsStayHonest() {
        #expect(ProviderConnectionState.missing.displayText == "Not configured")
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
            usageDatabaseState: .opened,
            localAcceptedEventCount: 3,
            localRejectedEventCount: 1,
            localImportState: .healthy
        )

        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(json.contains("anthropic"))
        #expect(json.contains("authenticationRejected"))
        #expect(!json.contains(secretSentinel))
        for forbidden in ["apiKey", "accessToken", "refreshToken", "prompt", "response", "requestBody", "terminalOutput", "sourceCode", "rawProviderResponse"] {
            #expect(!json.contains(forbidden))
        }
    }

    @Test("cancelled diagnostics are non-failures and do not update UI settings")
    func cancelledDiagnosticsAreSuppressible() {
        let diagnostic = ProviderDiagnostic(
            provider: .openAI,
            state: .cancelled,
            failureReason: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(diagnostic.state.displayText == "Cancelled")
        #expect(!diagnostic.shouldUpdateSettings)
    }

    @Test("settings persistence decision suppresses diagnostic and task cancellation")
    func settingsPersistenceDecisionSuppressesCancellation() {
        let connected = ProviderDiagnostic(provider: .openAI, state: .connected, failureReason: nil, updatedAt: Date())
        let failed = ProviderDiagnostic(provider: .openAI, state: .failed, failureReason: .refreshFailed, updatedAt: Date())
        let cancelled = ProviderDiagnostic(provider: .openAI, state: .cancelled, failureReason: nil, updatedAt: Date())

        #expect(ProviderSettingsPersistenceDecision.evaluate(connected, taskIsCancelled: false) == .persist)
        #expect(ProviderSettingsPersistenceDecision.evaluate(failed, taskIsCancelled: false) == .persist)
        #expect(ProviderSettingsPersistenceDecision.evaluate(cancelled, taskIsCancelled: false) == .suppress)
        #expect(ProviderSettingsPersistenceDecision.evaluate(connected, taskIsCancelled: true) == .suppress)
    }

    @Test("diagnostic health states have fixed summaries")
    func diagnosticHealthStatesHaveFixedSummaries() {
        #expect(UsageDatabaseDiagnosticState.opened.displayText == "SQLite store opened")
        #expect(UsageDatabaseDiagnosticState.unavailable.displayText == "SQLite store unavailable")
        #expect(LocalImportDiagnosticState.healthy.displayText == "Import healthy")
        #expect(LocalImportDiagnosticState.failed.displayText == "Import failed")
    }

    @Test("provider settings persistence normalizes and excludes secret fields")
    func providerSettingsPersistenceNormalizesAndExcludesSecretFields() throws {
        var duplicate = ProviderSettings.defaultSettings[0]
        duplicate.state = .connected
        let encoded = try ProviderSettingsPersistence.encode([ProviderSettings.defaultSettings[2], ProviderSettings.defaultSettings[0], duplicate])
        let decoded = ProviderSettingsPersistence.decode(encoded)

        #expect(decoded.map(\.provider) == [.anthropic, .azureOpenAI, .openAI])
        #expect(decoded[0].state == .connected)
        let json = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["apiKey", "accessToken", "refreshToken", "secret", "rawProviderResponse"] {
            #expect(!json.contains(forbidden))
        }
        #expect(ProviderSettingsPersistence.decode(Data("invalid".utf8)) == ProviderSettings.defaultSettings)
    }
}
