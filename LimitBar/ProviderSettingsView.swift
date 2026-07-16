import SwiftUI
import LimitBarCore
import CryptoKit

struct ProviderRefreshExecution: Equatable {
    let outcome: ProviderRefreshOutcome
    let affectedWindows: [ExactUsageWindow]

    init(outcome: ProviderRefreshOutcome, windows: CurrentUsageWindows? = nil) {
        self.outcome = outcome
        self.affectedWindows = windows.map { [$0.today, $0.currentWeek, $0.utcBillingWeek] } ?? []
    }

    init(outcome: ProviderRefreshOutcome, affectedWindows: [ExactUsageWindow]) {
        self.outcome = outcome
        self.affectedWindows = affectedWindows
    }
}

extension Notification.Name {
    static let providerRefreshHistoryDidChange = Notification.Name("limitbar.providerRefreshHistoryDidChange")
}

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
            ForEach(settings.map(\.provider), id: \.self) { provider in
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
        case .custom:
            // .custom is configured under Settings > Custom Usage Sources
            // and never appears in ProviderSettings, so this is unreachable.
            EmptyView()
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
                Task { await saveCredential(secret, provider: provider, kind: kind) }
            }
            .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Clear") {
                Task { await clearCredential(provider: provider, kind: kind) }
            }
        }
    }

    private func authMethodBinding(index: Int) -> Binding<ProviderAuthMethod> {
        Binding(
            get: { settings[index].authMethod },
            set: { method in
                Task {
                    await UsageDatabase.shared.advanceProviderConfigurationGeneration(for: settings[index].provider)
                    clearSecretField(for: settings[index].provider)
                    settings[index].authMethod = method
                    settings[index].state = .missing
                    settings[index].failureReason = nil
                    if settings[index].provider == .openAI {
                        settings[index].openAIOAuthFeasibility = .unvalidated
                    }
                    do {
                        settings[index] = try stateReconciler.reconcile(settings[index], authMethodChanged: true)
                        keychainMessage = nil
                    } catch {
                        keychainMessage = "Could not update Keychain."
                    }
                    persist(index: index)
                }
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
            set: { organization in
                Task {
                    await UsageDatabase.shared.mutateProviderConfiguration(for: .openAI) {
                        settings[index].openAIOrganizationID = organization
                        settings[index].openAIOAuthFeasibility = .unvalidated
                        if settings[index].state != .missing {
                            settings[index].state = .configured
                        }
                        settings[index].failureReason = nil
                        persist(index: index)
                    }
                }
            }
        )
    }

    private func saveCredential(_ secret: String, provider: ProviderKind, kind: CredentialKind) async {
        defer { clearSecretField(for: provider) }
        do {
            await UsageDatabase.shared.advanceProviderConfigurationGeneration(for: provider)
            try credentialService.save(secret, for: CredentialKey(provider: provider, kind: kind))
            if provider == .openAI, kind == .accessToken,
               let index = settings.firstIndex(where: { $0.provider == .openAI }) {
                settings[index].openAIOAuthFeasibility = .unvalidated
            }
            updateState(provider: provider, state: .configured)
            keychainMessage = nil
        } catch {
            keychainMessage = "Could not update Keychain."
        }
    }

    private func clearCredential(provider: ProviderKind, kind: CredentialKind) async {
        clearSecretField(for: provider)
        do {
            await UsageDatabase.shared.advanceProviderConfigurationGeneration(for: provider)
            try credentialService.removeCredential(for: CredentialKey(provider: provider, kind: kind))
            if provider == .openAI, kind == .accessToken,
               let index = settings.firstIndex(where: { $0.provider == .openAI }) {
                settings[index].openAIOAuthFeasibility = .unvalidated
            }
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
        case .custom:
            break
        }
    }

    private func refreshAnthropic(index: Int) async {
        isRefreshingAnthropic = true
        defer { isRefreshingAnthropic = false }
        let startedAt = Date()
        let clock = ContinuousClock()
        let startedInstant = clock.now
        let execution = await performAnthropicRefresh(index: index)
        await recordRefresh(
            product: .anthropicAPI,
            outcome: execution.outcome,
            startedAt: startedAt,
            duration: startedInstant.duration(to: clock.now),
            affectedWindows: execution.affectedWindows
        )
    }

    private func performAnthropicRefresh(index: Int) async -> ProviderRefreshExecution {
        let key = CredentialKey(provider: .anthropic, kind: .apiKey)
        var affectedWindows: [ExactUsageWindow] = []
        do {
            guard var credentialData = try credentialService.credential(for: key),
                  let apiKey = String(data: credentialData, encoding: .utf8) else {
                settings[index].state = .missing
                settings[index].failureReason = nil
                persist(index: index)
                return ProviderRefreshExecution(outcome: .failed)
            }
            defer { credentialData.resetBytes(in: credentialData.startIndex..<credentialData.endIndex) }
            let startedMethod = settings[index].authMethod
            let startedFingerprint = Data(SHA256.hash(data: credentialData))
            guard let result = await anthropicRefreshService.fetch(apiKey: apiKey) else {
                guard !Task.isCancelled else { return ProviderRefreshExecution(outcome: .cancelled) }
                settings[index].state = .failed
                settings[index].failureReason = .refreshFailed
                persist(index: index)
                return ProviderRefreshExecution(outcome: .failed)
            }
            let execution = { ProviderRefreshExecution(outcome: $0, windows: result.windows) }
            affectedWindows = execution(.success).affectedWindows
            guard var currentCredential = try credentialService.credential(for: key) else { return execution(.cancelled) }
            defer { currentCredential.resetBytes(in: currentCredential.startIndex..<currentCredential.endIndex) }
            guard settings[index].authMethod == startedMethod,
                  Data(SHA256.hash(data: currentCredential)) == startedFingerprint else {
                return execution(.cancelled)
            }
            let diagnostic = await UsageDatabase.shared.applyAnthropic(
                result.result,
                windows: result.windows,
                expectedGeneration: result.generation
            )
            guard ProviderSettingsPersistenceDecision.evaluate(diagnostic, taskIsCancelled: Task.isCancelled) == .persist else { return execution(.cancelled) }
            guard await UsageDatabase.shared.isProviderConfigurationGenerationCurrent(result.generation, for: .anthropic) else { return execution(.cancelled) }
            settings[index].state = diagnostic.state
            settings[index].failureReason = diagnostic.failureReason
            settings[index].updatedAt = diagnostic.updatedAt
            settingsStore.update(settings[index])
            keychainMessage = nil
            let fetchedOutcome = ProviderRefreshOutcome(usage: result.result.usage, cost: result.result.cost)
            return execution(diagnostic.state == .connected ? fetchedOutcome : diagnostic.failureReason.map(ProviderRefreshOutcome.init(failureReason:)) ?? .failed)
        } catch {
            keychainMessage = "Could not update Keychain."
            return ProviderRefreshExecution(outcome: .failed, affectedWindows: affectedWindows)
        }
    }

    private func refreshOpenAI(index: Int) async {
        isRefreshingOpenAI = true
        defer { isRefreshingOpenAI = false }
        let startedAt = Date()
        let clock = ContinuousClock()
        let startedInstant = clock.now
        let execution = await performOpenAIRefresh(index: index)
        await recordRefresh(
            product: .openAIAPI,
            outcome: execution.outcome,
            startedAt: startedAt,
            duration: startedInstant.duration(to: clock.now),
            affectedWindows: execution.affectedWindows
        )
    }

    private func performOpenAIRefresh(index: Int) async -> ProviderRefreshExecution {
        let method = settings[index].authMethod
        let kind = method.credentialKind
        let key = CredentialKey(provider: .openAI, kind: kind)
        let organization = settings[index].openAIOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var affectedWindows: [ExactUsageWindow] = []
        do {
            guard !organization.isEmpty,
                  var credentialData = try credentialService.credential(for: key),
                  let credential = String(data: credentialData, encoding: .utf8) else {
                settings[index].state = .missing
                persist(index: index)
                return ProviderRefreshExecution(outcome: .failed)
            }
            defer { credentialData.resetBytes(in: credentialData.startIndex..<credentialData.endIndex) }
            let fingerprint = Data(SHA256.hash(data: credentialData))
            guard let batch = await openAIRefreshService.fetch(credential: credential, organization: organization, method: method) else {
                guard !Task.isCancelled else { return ProviderRefreshExecution(outcome: .cancelled) }
                settings[index].state = .failed
                settings[index].failureReason = .refreshFailed
                persist(index: index)
                return ProviderRefreshExecution(outcome: .failed)
            }
            let execution = { ProviderRefreshExecution(outcome: $0, windows: batch.windows) }
            affectedWindows = execution(.success).affectedWindows
            guard var current = try credentialService.credential(for: key) else { return execution(.cancelled) }
            defer { current.resetBytes(in: current.startIndex..<current.endIndex) }
            guard settings[index].authMethod == method,
                  settings[index].openAIOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines) == organization,
                  Data(SHA256.hash(data: current)) == fingerprint else { return execution(.cancelled) }

            let outcome: ProviderRefreshOutcome
            switch batch.result {
            case let .supported(refreshResult):
                let diagnostic = await UsageDatabase.shared.applyOpenAI(
                    refreshResult,
                    windows: batch.windows,
                    expectedGeneration: batch.generation
                )
                guard ProviderSettingsPersistenceDecision.evaluate(diagnostic, taskIsCancelled: Task.isCancelled) == .persist else { return execution(.cancelled) }
                if method == .openAIOAuth {
                    settings[index].openAIOAuthFeasibility = .supported
                }
                settings[index].state = diagnostic.state
                settings[index].failureReason = diagnostic.failureReason
                let fetchedOutcome = ProviderRefreshOutcome(usage: refreshResult.usage, cost: refreshResult.cost)
                outcome = diagnostic.state == .connected ? fetchedOutcome : diagnostic.failureReason.map(ProviderRefreshOutcome.init(failureReason:)) ?? .failed
            case .unsupported:
                let diagnostic = await UsageDatabase.shared.applyOpenAI(.failure(.insufficientPermissions), windows: batch.windows, expectedGeneration: batch.generation)
                guard ProviderSettingsPersistenceDecision.evaluate(diagnostic, taskIsCancelled: Task.isCancelled) == .persist else { return execution(.cancelled) }
                settings[index].openAIOAuthFeasibility = .unsupported
                settings[index].state = .unsupported
                settings[index].failureReason = nil
                outcome = .authenticationFailure
            case .adminRequired:
                let diagnostic = await UsageDatabase.shared.applyOpenAI(.failure(.insufficientPermissions), windows: batch.windows, expectedGeneration: batch.generation)
                guard ProviderSettingsPersistenceDecision.evaluate(diagnostic, taskIsCancelled: Task.isCancelled) == .persist else { return execution(.cancelled) }
                settings[index].openAIOAuthFeasibility = .adminCredentialRequired
                settings[index].state = .adminRequired
                settings[index].failureReason = .insufficientPermissions
                outcome = .authenticationFailure
            case .expired:
                let diagnostic = await UsageDatabase.shared.applyOpenAI(.failure(.expiredCredential), windows: batch.windows, expectedGeneration: batch.generation)
                guard ProviderSettingsPersistenceDecision.evaluate(diagnostic, taskIsCancelled: Task.isCancelled) == .persist else { return execution(.cancelled) }
                settings[index].state = .expired
                settings[index].failureReason = .expiredCredential
                outcome = .authenticationFailure
            case let .failure(reason):
                let diagnostic = await UsageDatabase.shared.applyOpenAI(.failure(reason), windows: batch.windows, expectedGeneration: batch.generation)
                guard ProviderSettingsPersistenceDecision.evaluate(diagnostic, taskIsCancelled: Task.isCancelled) == .persist else { return execution(.cancelled) }
                settings[index].state = diagnostic.state
                settings[index].failureReason = diagnostic.failureReason
                outcome = ProviderRefreshOutcome(failureReason: reason)
            }
            guard await UsageDatabase.shared.isProviderConfigurationGenerationCurrent(batch.generation, for: .openAI) else { return execution(.cancelled) }
            persist(index: index)
            return execution(outcome)
        } catch {
            keychainMessage = "Could not update Keychain."
            return ProviderRefreshExecution(outcome: .failed, affectedWindows: affectedWindows)
        }
    }

    private func recordRefresh(
        product: ProviderRefreshProduct,
        outcome: ProviderRefreshOutcome,
        startedAt: Date,
        duration: Duration,
        affectedWindows: [ExactUsageWindow]
    ) async {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard let entry = try? ProviderRefreshHistoryEntry(
            product: product,
            outcome: outcome,
            startedAt: startedAt,
            duration: seconds,
            affectedWindows: affectedWindows
        ) else { return }
        if await ProviderRefreshHistoryRepository.shared.record(entry) {
            NotificationCenter.default.post(name: .providerRefreshHistoryDidChange, object: nil)
        }
    }
}
