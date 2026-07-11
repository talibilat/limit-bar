import SwiftUI
import LimitBarCore
import CryptoKit

struct ProviderSettingsView: View {
    @Binding var settings: [ProviderSettings]

    private let settingsStore = ProviderSettingsStore()
    private let credentialService = CredentialService(store: KeychainCredentialStore())
    private let anthropicRefreshService = AnthropicRefreshService()
    private let openAIRefreshService = OpenAIRefreshService()

    private var stateReconciler: ProviderCredentialStateReconciler {
        ProviderCredentialStateReconciler(credentialService: credentialService)
    }

    @State private var anthropicAPIKey = ""
    @State private var azureAPIKey = ""
    @State private var openAIAdminAPIKey = ""
    @State private var openAIOAuthToken = ""
    @State private var keychainMessage: String?
    @State private var isRefreshingAnthropic = false
    @State private var isRefreshingOpenAI = false

    var body: some View {
        Group {
            ForEach(ProviderKind.orderedCases, id: \.self) { provider in
                DisclosureGroup {
                    if let index = settings.firstIndex(where: { $0.provider == provider }) {
                        providerControls(index: index)
                    }
                } label: {
                    HStack {
                        Text(provider.displayName)
                        Spacer()
                        if let setting = settings.first(where: { $0.provider == provider }) {
                            Text(setting.state.displayText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let keychainMessage {
                Text(keychainMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task {
            var reconciliationFailed = false
            for index in settings.indices {
                let existing = settings[index]
                do {
                    let reconciled = try stateReconciler.reconcile(existing)
                    if reconciled != existing {
                        settings[index] = reconciled
                        persist(index: index)
                    }
                } catch {
                    reconciliationFailed = true
                }
            }
            keychainMessage = reconciliationFailed ? "Could not update Keychain." : nil
        }
    }

    @ViewBuilder
    private func providerControls(index: Int) -> some View {
        Picker("Authentication", selection: authMethodBinding(index: index)) {
            ForEach(ProviderAuthMethod.methods(for: settings[index].provider), id: \.self) { method in
                Text(method.displayText).tag(method)
            }
        }

        switch settings[index].provider {
        case .anthropic:
            anthropicControls(index: index)
        case .azureOpenAI:
            azureControls(index: index)
        case .openAI:
            openAIControls(index: index)
        }
    }

    @ViewBuilder
    private func anthropicControls(index: Int) -> some View {
        if settings[index].authMethod == .anthropicAdminAPIKey {
            SecureField("Admin API key", text: $anthropicAPIKey)
            credentialButtons(secret: anthropicAPIKey, provider: .anthropic, kind: .apiKey)
            Button(isRefreshingAnthropic ? "Refreshing..." : "Validate & Refresh") {
                Task { await refreshAnthropic(index: index) }
            }
            .disabled(settings[index].state == .missing || isRefreshingAnthropic)
        } else {
            Text("OAuth-compatible configuration is ready for a future authorization flow.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func azureControls(index: Int) -> some View {
        TextField("Azure endpoint", text: azureEndpointBinding(index: index))
        SecureField("API key", text: $azureAPIKey)
        HStack {
            credentialButtons(secret: azureAPIKey, provider: .azureOpenAI, kind: .apiKey)
            Button("Save Endpoint") {
                persist(index: index)
            }
            .disabled((settings[index].azureEndpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private func openAIControls(index: Int) -> some View {
        TextField("Organization ID", text: openAIOrganizationBinding(index: index))
        if settings[index].authMethod == .openAIOAuth {
            LabeledContent("OAuth usage access", value: settings[index].openAIOAuthFeasibility.displayText)
            SecureField("OAuth access token", text: $openAIOAuthToken)
            credentialButtons(secret: openAIOAuthToken, provider: .openAI, kind: .accessToken)
        } else {
            SecureField("Admin/platform API key", text: $openAIAdminAPIKey)
            credentialButtons(secret: openAIAdminAPIKey, provider: .openAI, kind: .apiKey)
        }
        Button(isRefreshingOpenAI ? "Refreshing..." : "Validate & Refresh") {
            Task { await refreshOpenAI(index: index) }
        }
        .disabled(settings[index].state == .missing || (settings[index].openAIOrganizationID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRefreshingOpenAI)
    }

    private func credentialButtons(secret: String, provider: ProviderKind, kind: CredentialKind) -> some View {
        HStack {
            Button("Save") {
                saveCredential(secret, provider: provider, kind: kind)
            }
            .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Clear") {
                clearCredential(provider: provider, kind: kind)
            }
        }
    }

    private func authMethodBinding(index: Int) -> Binding<ProviderAuthMethod> {
        Binding(
            get: { settings[index].authMethod },
            set: { method in
                clearSecretField(for: settings[index].provider)
                settings[index].authMethod = method
                settings[index].state = .missing
                settings[index].failureReason = nil
                do {
                    settings[index] = try stateReconciler.reconcile(settings[index], authMethodChanged: true)
                    keychainMessage = nil
                } catch {
                    keychainMessage = "Could not update Keychain."
                }
                persist(index: index)
            }
        )
    }

    private func azureEndpointBinding(index: Int) -> Binding<String> {
        Binding(
            get: { settings[index].azureEndpoint ?? "" },
            set: { settings[index].azureEndpoint = $0 }
        )
    }

    private func openAIOrganizationBinding(index: Int) -> Binding<String> {
        Binding(
            get: { settings[index].openAIOrganizationID ?? "" },
            set: {
                settings[index].openAIOrganizationID = $0
                persist(index: index)
            }
        )
    }

    private func saveCredential(_ secret: String, provider: ProviderKind, kind: CredentialKind) {
        defer { clearSecretField(for: provider) }
        do {
            try credentialService.save(secret, for: CredentialKey(provider: provider, kind: kind))
            updateState(provider: provider, state: .configured)
            keychainMessage = nil
        } catch {
            keychainMessage = "Could not update Keychain."
        }
    }

    private func clearCredential(provider: ProviderKind, kind: CredentialKind) {
        clearSecretField(for: provider)
        do {
            try credentialService.removeCredential(for: CredentialKey(provider: provider, kind: kind))
            updateState(provider: provider, state: .missing)
            keychainMessage = nil
        } catch {
            keychainMessage = "Could not update Keychain."
        }
    }

    private func updateState(provider: ProviderKind, state: ProviderConnectionState) {
        guard let index = settings.firstIndex(where: { $0.provider == provider }) else { return }
        settings[index].state = state
        settings[index].failureReason = nil
        persist(index: index)
    }

    private func persist(index: Int) {
        settings[index].azureEndpoint = settings[index].azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        settings[index].updatedAt = Date()
        settingsStore.update(settings[index])
    }

    private func clearSecretField(for provider: ProviderKind) {
        switch provider {
        case .anthropic:
            anthropicAPIKey = ""
        case .azureOpenAI:
            azureAPIKey = ""
        case .openAI:
            openAIAdminAPIKey = ""
            openAIOAuthToken = ""
        }
    }

    private func refreshAnthropic(index: Int) async {
        isRefreshingAnthropic = true
        defer { isRefreshingAnthropic = false }
        let key = CredentialKey(provider: .anthropic, kind: .apiKey)
        do {
            guard var credentialData = try credentialService.credential(for: key),
                  let apiKey = String(data: credentialData, encoding: .utf8) else {
                settings[index].state = .missing
                settings[index].failureReason = nil
                persist(index: index)
                return
            }
            defer { credentialData.resetBytes(in: credentialData.startIndex..<credentialData.endIndex) }
            let startedMethod = settings[index].authMethod
            let startedFingerprint = Data(SHA256.hash(data: credentialData))
            let result = await anthropicRefreshService.fetch(apiKey: apiKey)
            guard var currentCredential = try credentialService.credential(for: key) else { return }
            defer { currentCredential.resetBytes(in: currentCredential.startIndex..<currentCredential.endIndex) }
            guard settings[index].authMethod == startedMethod,
                  Data(SHA256.hash(data: currentCredential)) == startedFingerprint else {
                return
            }
            let diagnostic = anthropicRefreshService.apply(result)
            settings[index].state = diagnostic.state
            settings[index].failureReason = diagnostic.failureReason
            settings[index].updatedAt = diagnostic.updatedAt
            settingsStore.update(settings[index])
            keychainMessage = nil
        } catch {
            keychainMessage = "Could not update Keychain."
        }
    }

    private func refreshOpenAI(index: Int) async {
        isRefreshingOpenAI = true
        defer { isRefreshingOpenAI = false }
        let method = settings[index].authMethod
        let kind = method.credentialKind
        let key = CredentialKey(provider: .openAI, kind: kind)
        let organization = settings[index].openAIOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            guard !organization.isEmpty,
                  var credentialData = try credentialService.credential(for: key),
                  let credential = String(data: credentialData, encoding: .utf8) else {
                settings[index].state = .missing
                persist(index: index)
                return
            }
            defer { credentialData.resetBytes(in: credentialData.startIndex..<credentialData.endIndex) }
            let fingerprint = Data(SHA256.hash(data: credentialData))
            let result = await openAIRefreshService.fetch(credential: credential, organization: organization, method: method)
            guard var current = try credentialService.credential(for: key) else { return }
            defer { current.resetBytes(in: current.startIndex..<current.endIndex) }
            guard settings[index].authMethod == method,
                  settings[index].openAIOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines) == organization,
                  Data(SHA256.hash(data: current)) == fingerprint else { return }

            switch result {
            case let .supported(refreshResult):
                settings[index].openAIOAuthFeasibility = .supported
                let diagnostic = openAIRefreshService.apply(refreshResult)
                settings[index].state = diagnostic.state
                settings[index].failureReason = diagnostic.failureReason
            case .unsupported:
                settings[index].openAIOAuthFeasibility = .unsupported
                settings[index].state = .unsupported
                settings[index].failureReason = nil
            case .adminRequired:
                settings[index].openAIOAuthFeasibility = .adminCredentialRequired
                settings[index].state = .adminRequired
                settings[index].failureReason = .insufficientPermissions
            case let .failure(reason):
                let diagnostic = openAIRefreshService.apply(.failure(reason))
                settings[index].state = diagnostic.state
                settings[index].failureReason = diagnostic.failureReason
            }
            persist(index: index)
        } catch {
            keychainMessage = "Could not update Keychain."
        }
    }
}
