import SwiftUI
import LimitBarCore

struct ProviderSettingsView: View {
    @Binding var settings: [ProviderSettings]

    private let settingsStore = ProviderSettingsStore()
    private let credentialService = CredentialService(store: KeychainCredentialStore())

    @State private var anthropicAPIKey = ""
    @State private var azureAPIKey = ""
    @State private var openAIAdminAPIKey = ""
    @State private var keychainMessage: String?

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
            for index in settings.indices where settings[index].state == .missing || settings[index].state == .configured {
                refreshCredentialState(index: index)
                persist(index: index)
            }
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
        if settings[index].authMethod == .openAIOAuth {
            LabeledContent("OAuth usage access", value: settings[index].openAIOAuthFeasibility.displayText)
            Text("Usage access remains unconnected until issue #9 validates the required scopes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            SecureField("Admin/platform API key", text: $openAIAdminAPIKey)
            credentialButtons(secret: openAIAdminAPIKey, provider: .openAI, kind: .apiKey)
        }
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
                settings[index].authMethod = method
                settings[index].failureReason = nil
                refreshCredentialState(index: index)
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

    private func refreshCredentialState(index: Int) {
        guard let kind = requiredCredentialKind(for: settings[index].authMethod) else {
            settings[index].state = .missing
            return
        }
        do {
            let key = CredentialKey(provider: settings[index].provider, kind: kind)
            settings[index].state = try credentialService.hasCredential(for: key) ? .configured : .missing
            keychainMessage = nil
        } catch {
            keychainMessage = "Could not update Keychain."
        }
    }

    private func requiredCredentialKind(for method: ProviderAuthMethod) -> CredentialKind? {
        switch method {
        case .anthropicAdminAPIKey, .azureAPIKey, .openAIAdminAPIKey:
            .apiKey
        case .anthropicOAuth, .openAIOAuth:
            nil
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
        }
    }
}
