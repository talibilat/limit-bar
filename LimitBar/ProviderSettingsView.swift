import SwiftUI
import LimitBarCore
import CryptoKit
import AppKit

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

// MARK: - Accounts page

struct AccountsSettingsPage: View {
    private struct SheetTarget: Identifiable {
        let provider: ProviderKind
        var id: String { provider.rawValue }
    }

    let state: LimitBarState
    let openSection: (SettingsSection) -> Void

    @State private var accounts = ProviderAccountsModel()
    @State private var claudeLogin = ClaudeLoginController()
    @State private var claudeTask: Task<Void, Never>?
    @State private var refreshHistory: [ProviderRefreshProduct: ProviderRefreshHistorySummary] = [:]
    @State private var sheetTarget: SheetTarget?
    @State private var disconnectTarget: ProviderKind?
    private var live = LiveLimitsModel.shared

    init(state: LimitBarState, openSection: @escaping (SettingsSection) -> Void) {
        self.state = state
        self.openSection = openSection
    }

    var body: some View {
        SettingsPage(title: "Accounts", subtitle: "Connect the accounts LimitBar reads limits and usage from. Keys are kept only in your macOS Keychain and are never shown again after saving.") {
            VStack(alignment: .leading, spacing: 8) {
                SettingsGroup("Subscriptions", caption: "Read from logins on this Mac") {
                    claudeRow
                    ForEach(LiveProvider.allCases, id: \.self) { provider in
                        Divider()
                        liveRow(provider)
                    }
                }
                Text("LimitBar never stores these logins. To disconnect one, sign out in that tool.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                SettingsMessage(claudeLogin.message)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsGroup("API accounts", caption: "For exact usage and spend") {
                    ForEach(Array(ProviderAccountsModel.providers.enumerated()), id: \.element) { offset, provider in
                        if offset > 0 { Divider() }
                        apiRow(provider)
                    }
                }
                SettingsMessage(accounts.message)
            }

            Button {
                openSection(.sources)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cylinder.split.1x2")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Other tools (Aider, Windsurf…)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Track them from local log files in Sources & Pricing")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(SettingsPalette.cardInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(SettingsPalette.buttonBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Label("Diagnostics, alerts and exports never include keys, tokens or account labels.", systemImage: "lock")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .task {
            accounts.reconcile()
            refreshHistory = await ProviderRefreshHistoryRepository.shared.summaries()
        }
        .task {
            if state.claudeModel.state == .loading {
                await state.claudeModel.appeared()
                state.claudeActionCompleted()
            }
        }
        .task {
            if live.states.isEmpty {
                await live.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerRefreshHistoryDidChange)) { _ in
            Task { refreshHistory = await ProviderRefreshHistoryRepository.shared.summaries() }
        }
        .onDisappear { claudeTask?.cancel() }
        .sheet(item: $sheetTarget) { target in
            AccountSheet(
                provider: target.provider,
                accounts: accounts,
                refreshSummary: target.provider.refreshProduct.flatMap { refreshHistory[$0] },
                onDisconnect: {
                    sheetTarget = nil
                    disconnectTarget = target.provider
                }
            )
        }
        .alert(
            "Disconnect \(disconnectTarget?.displayName ?? "account")?",
            isPresented: Binding(get: { disconnectTarget != nil }, set: { if !$0 { disconnectTarget = nil } }),
            presenting: disconnectTarget
        ) { provider in
            Button("Disconnect", role: .destructive) {
                Task { await accounts.disconnect(provider) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text("This removes the saved \(accounts.setting(for: provider)?.authMethod.displayText ?? "credential") from your Keychain. Usage already collected, alert rules and other settings stay on this Mac. You can connect again at any time.")
        }
    }

    // MARK: Claude Code

    private var claudeRow: some View {
        let model = state.claudeModel
        return accountRow(monogram: "CC", name: "Claude Code", status: claudeStatus, detail: claudeDetail) {
            if claudeLogin.isLoggingIn {
                ProgressView().controlSize(.small)
                Button("Cancel Sign-In") { claudeTask?.cancel() }
                    .buttonStyle(SettingsButtonStyle(.normal))
                    .accessibilityIdentifier("settings-claude-cancel-login")
            } else {
                switch model.state {
                case .loading:
                    ProgressView().controlSize(.small)
                case .notConnected:
                    Button("Sign In…") { runClaude { await claudeLogin.signIn(model: model) } }
                        .buttonStyle(SettingsButtonStyle(.primary))
                case .authorizationRequired:
                    Button(model.isRefreshing ? "Connecting…" : "Connect") { runClaude { await model.connect() } }
                        .buttonStyle(SettingsButtonStyle(.primary))
                        .disabled(model.isRefreshing)
                case .loaded, .failed:
                    Button(model.isRefreshing ? "Refreshing…" : "Refresh") { runClaude { await model.refresh() } }
                        .buttonStyle(SettingsButtonStyle(.normal))
                        .disabled(model.isRefreshing)
                    Button("Sign In Again") { runClaude { await claudeLogin.signIn(model: model) } }
                        .buttonStyle(SettingsButtonStyle(.normal))
                }
            }
        }
    }

    private var claudeStatus: (String, SettingsTone) {
        switch state.claudeModel.state {
        case .loading: ("Checking", .info)
        case .notConnected: ("Not connected", .neutral)
        case .authorizationRequired: ("Needs authorization", .warning)
        case .loaded: ("Connected", .positive)
        case .failed: ("Unavailable", .warning)
        }
    }

    private var claudeDetail: String {
        switch state.claudeModel.state {
        case .loading:
            "Looking for a Claude Code login…"
        case .notConnected:
            "No Claude Code login found. Sign in through Claude in your browser."
        case .authorizationRequired:
            "Allow LimitBar to read your Claude Code login in Keychain."
        case let .loaded(snapshot, subscription):
            (["Claude Code login"]
                + [subscription.map { "Plan: \($0.capitalized)" }].compactMap { $0 }
                + ["Fetched \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"])
                .joined(separator: " · ")
        case let .failed(message):
            message
        }
    }

    private func runClaude(_ action: @escaping @MainActor () async -> Void) {
        claudeTask?.cancel()
        claudeTask = Task {
            await action()
            guard !Task.isCancelled else { return }
            state.claudeActionCompleted()
        }
    }

    // MARK: Live subscriptions

    private func liveRow(_ provider: LiveProvider) -> some View {
        let liveState = live.states[provider]
        let status: (String, SettingsTone)
        let detail: String
        switch liveState {
        case nil, .loading:
            status = ("Checking", .info)
            detail = "Reading \(provider.displayName) limits…"
        case let .loaded(_, plan, fetchedAt):
            status = ("Connected", .positive)
            detail = ([provider.sourceDescription] + [plan.map { "Plan: \($0)" }].compactMap { $0 }
                + ["Fetched \(fetchedAt.formatted(date: .omitted, time: .shortened))"])
                .joined(separator: " · ")
        case let .unavailable(message):
            status = ("Not connected", .neutral)
            detail = message
        }
        return accountRow(monogram: provider.monogram, name: provider.displayName, status: status, detail: detail) {
            Button(live.isRefreshing ? "Refreshing…" : "Refresh") {
                Task { await live.refresh() }
            }
            .buttonStyle(SettingsButtonStyle(.normal))
            .disabled(live.isRefreshing)
            switch provider {
            case .codex:
                Button("Log In Again") { CodexLoginLauncher.openLogin() }
                    .buttonStyle(SettingsButtonStyle(.normal))
                    .accessibilityIdentifier("codex-relogin")
            case .cursor, .antigravity:
                if let appURL = provider.installedAppURL {
                    Button("Open \(provider.displayName)") {
                        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                    }
                    .buttonStyle(SettingsButtonStyle(.normal))
                }
            }
        }
    }

    // MARK: API accounts

    private func apiRow(_ provider: ProviderKind) -> some View {
        let setting = accounts.setting(for: provider)
        let connectionState = setting?.state ?? .missing
        return accountRow(
            monogram: provider.monogram,
            name: provider.displayName,
            status: (connectionState.pillText, connectionState.tone),
            detail: apiDetail(provider, setting: setting)
        ) {
            switch connectionState {
            case .missing:
                Button("Connect…") { sheetTarget = SheetTarget(provider: provider) }
                    .buttonStyle(SettingsButtonStyle(.primary))
            case .connected, .configured, .cancelled:
                Button("Update…") { sheetTarget = SheetTarget(provider: provider) }
                    .buttonStyle(SettingsButtonStyle(.normal))
                refreshButton(provider)
                Button("Disconnect") { disconnectTarget = provider }
                    .buttonStyle(SettingsButtonStyle(.danger))
            case .failed, .expired, .unsupported, .adminRequired:
                Button("Update Key…") { sheetTarget = SheetTarget(provider: provider) }
                    .buttonStyle(SettingsButtonStyle(.primary))
                refreshButton(provider)
                Button("Disconnect") { disconnectTarget = provider }
                    .buttonStyle(SettingsButtonStyle(.danger))
            }
        }
    }

    @ViewBuilder
    private func refreshButton(_ provider: ProviderKind) -> some View {
        if accounts.canRefresh(provider) {
            Button(accounts.isRefreshing(provider) ? "Refreshing…" : "Validate & Refresh") {
                Task { await accounts.refresh(provider) }
            }
            .buttonStyle(SettingsButtonStyle(.normal))
            .disabled(accounts.isRefreshing(provider))
        }
    }

    private func apiDetail(_ provider: ProviderKind, setting: ProviderSettings?) -> String {
        guard let setting else { return "Unavailable" }
        var parts = [setting.authMethod.displayText]
        switch provider {
        case .azureOpenAI:
            let endpoint = setting.azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            parts.append(endpoint.isEmpty ? "No endpoint set" : (URL(string: endpoint)?.host ?? endpoint))
        case .openAI:
            let organization = setting.openAIOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if setting.state == .missing {
                return "Admin API key or OAuth token · needs your Organization ID"
            }
            parts.append(organization.isEmpty ? "Organization ID needed" : "Org \(organization)")
        case .anthropic, .custom:
            break
        }
        if let reason = setting.failureReason {
            parts.append(reason.displayText)
        } else if let product = provider.refreshProduct, setting.state != .missing {
            parts.append("Last refresh: \(ProviderRefreshHistoryStatusText.latest(refreshHistory[product]?.latest))")
        }
        return parts.joined(separator: " · ")
    }

    private func accountRow<Actions: View>(
        monogram: String,
        name: String,
        status: (String, SettingsTone),
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            ProviderMonogram(text: monogram)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                    StatusPill(text: status.0, tone: status.1)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                actions()
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Update account sheet

struct AccountSheet: View {
    let provider: ProviderKind
    let accounts: ProviderAccountsModel
    let refreshSummary: ProviderRefreshHistorySummary?
    let onDisconnect: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authMethod: ProviderAuthMethod
    @State private var secret = ""
    @State private var azureEndpoint: String
    @State private var organizationID: String
    @State private var workspaceAliases = ""
    @State private var apiKeyAliases = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(provider: ProviderKind, accounts: ProviderAccountsModel, refreshSummary: ProviderRefreshHistorySummary?, onDisconnect: @escaping () -> Void) {
        self.provider = provider
        self.accounts = accounts
        self.refreshSummary = refreshSummary
        self.onDisconnect = onDisconnect
        let setting = accounts.setting(for: provider)
        _authMethod = State(initialValue: setting?.authMethod ?? ProviderAuthMethod.methods(for: provider)[0])
        _azureEndpoint = State(initialValue: setting?.azureEndpoint ?? "")
        _organizationID = State(initialValue: setting?.openAIOrganizationID ?? "")
    }

    private var setting: ProviderSettings? { accounts.setting(for: provider) }
    private var isConnected: Bool { (setting?.state ?? .missing) != .missing }
    private var methodChanged: Bool { authMethod != setting?.authMethod }
    private var supportsSecretEntry: Bool { authMethod != .anthropicOAuth }

    private var canSave: Bool {
        guard !isSaving else { return false }
        let hasSecret = !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch provider {
        case .azureOpenAI:
            let hasEndpoint = !azureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasEndpoint && (hasSecret || isConnected)
        case .openAI:
            let hasOrganization = !organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasOrganization && (hasSecret || (isConnected && !methodChanged))
        case .anthropic:
            return supportsSecretEntry && (hasSecret || (isConnected && !methodChanged))
        case .custom:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProviderMonogram(text: provider.monogram, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName)
                        .font(.system(size: 16, weight: .bold))
                    Text(isConnected ? "Update how LimitBar connects to this account" : "Connect this account to LimitBar")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: (setting?.state ?? .missing).pillText, tone: (setting?.state ?? .missing).tone)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                let methods = ProviderAuthMethod.methods(for: provider)
                if methods.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Authentication")
                            .font(.system(size: 12, weight: .semibold))
                        Picker("Authentication", selection: $authMethod) {
                            ForEach(methods, id: \.self) { method in
                                Text(method.displayText).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 280)
                    }
                }

                if provider == .azureOpenAI {
                    SettingsField("Azure endpoint") {
                        TextField("https://your-resource.openai.azure.com", text: $azureEndpoint)
                            .labelsHidden()
                    }
                }

                if provider == .openAI {
                    SettingsField("Organization ID") {
                        TextField("org-…", text: $organizationID)
                            .labelsHidden()
                    }
                }

                if supportsSecretEntry {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(authMethod == .openAIOAuth ? "OAuth access token" : authMethod.displayText)
                            .font(.system(size: 12, weight: .semibold))
                        SecureField(isConnected ? "Enter a new key to replace the saved one" : "Paste the key", text: $secret)
                            .labelsHidden()
                        Label(
                            isConnected ? "A key is saved in Keychain. It is never displayed again." : "Saved only in your macOS Keychain. It is never displayed again.",
                            systemImage: "lock"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    SettingsNote(systemImage: "info.circle", text: "OAuth sign-in for the Anthropic API isn't available yet. Use an Admin API key to read usage and spend.")
                }

                if provider == .anthropic && supportsSecretEntry {
                    VStack(alignment: .leading, spacing: 10) {
                        (Text("Labels for breakdowns ").font(.system(size: 12, weight: .semibold))
                            + Text("· optional").font(.system(size: 12)).foregroundColor(.secondary))
                        SettingsField("Workspace → project label") {
                            TextField("raw=project alias; …", text: $workspaceAliases)
                                .labelsHidden()
                        }
                        SettingsField("API key → agent label") {
                            TextField("raw=agent alias; …", text: $apiKeyAliases)
                                .labelsHidden()
                        }
                        Text("Used only for this refresh. Unmapped identities are left out, and labels that copy the raw ID are rejected.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(SettingsPalette.cardInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(SettingsPalette.border))
                }

                if provider.refreshProduct != nil, isConnected {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Latest refresh").foregroundStyle(.secondary)
                            Text(ProviderRefreshHistoryStatusText.latest(refreshSummary?.latest))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Last full success").foregroundStyle(.secondary)
                            Text(ProviderRefreshHistoryStatusText.lastFullSuccess(refreshSummary?.lastFullSuccess))
                        }
                    }
                    .font(.system(size: 12))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTone.warning.foreground)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            HStack(spacing: 8) {
                if isConnected {
                    Button("Disconnect") { onDisconnect() }
                        .buttonStyle(SettingsButtonStyle(.danger))
                }
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { dismiss() }
                    .buttonStyle(SettingsButtonStyle(.normal))
                    .keyboardShortcut(.cancelAction)
                Button(provider.refreshProduct == nil ? "Save" : "Validate & Save") {
                    Task { await save() }
                }
                .buttonStyle(SettingsButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(SettingsPalette.cardInset)
        }
        .font(.system(size: 13))
        .frame(width: 540)
        .background(SettingsPalette.card)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        if methodChanged {
            await accounts.setAuthMethod(authMethod, for: provider)
        }
        switch provider {
        case .azureOpenAI:
            accounts.setAzureEndpoint(azureEndpoint)
        case .openAI where organizationID != (setting?.openAIOrganizationID ?? ""):
            await accounts.setOrganizationID(organizationID)
        default:
            break
        }
        if !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let saved = await accounts.saveCredential(secret, for: provider)
            secret = ""
            guard saved else {
                errorMessage = "Could not save the key to Keychain."
                return
            }
        }
        if accounts.canRefresh(provider) {
            await accounts.refresh(provider, workspaceAliases: workspaceAliases, apiKeyAliases: apiKeyAliases)
            workspaceAliases = ""
            apiKeyAliases = ""
        }
        dismiss()
    }
}

// MARK: - Model

@MainActor
@Observable
final class ProviderAccountsModel {
    static let providers: [ProviderKind] = [.anthropic, .azureOpenAI, .openAI]

    private(set) var settings: [ProviderSettings]
    private(set) var message: String?
    private var refreshing: Set<ProviderKind> = []

    private let settingsStore = ProviderSettingsStore()
    private let credentialService = CredentialService(store: KeychainCredentialStore())
    private let anthropicRefreshService = AnthropicRefreshService()
    private let openAIRefreshService = OpenAIRefreshService()

    private var stateReconciler: ProviderCredentialStateReconciler {
        ProviderCredentialStateReconciler(credentialService: credentialService)
    }

    init() {
        settings = settingsStore.settings
    }

    func setting(for provider: ProviderKind) -> ProviderSettings? {
        settings.first { $0.provider == provider }
    }

    func isRefreshing(_ provider: ProviderKind) -> Bool {
        refreshing.contains(provider)
    }

    func canRefresh(_ provider: ProviderKind) -> Bool {
        guard let setting = setting(for: provider), setting.state != .missing else { return false }
        switch provider {
        case .anthropic:
            return setting.authMethod == .anthropicAdminAPIKey
        case .openAI:
            return !(setting.openAIOrganizationID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .azureOpenAI, .custom:
            return false
        }
    }

    func reconcile() {
        settings = settingsStore.settings
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
        message = reconciliationFailed ? "Could not update Keychain." : nil
    }

    func setAuthMethod(_ method: ProviderAuthMethod, for provider: ProviderKind) async {
        guard let index = index(of: provider) else { return }
        await UsageDatabase.shared.advanceProviderConfigurationGeneration(for: provider)
        settings[index].authMethod = method
        settings[index].state = .missing
        settings[index].failureReason = nil
        if provider == .openAI {
            settings[index].openAIOAuthFeasibility = .unvalidated
        }
        do {
            settings[index] = try stateReconciler.reconcile(settings[index], authMethodChanged: true)
            message = nil
        } catch {
            message = "Could not update Keychain."
        }
        persist(index: index)
    }

    func setAzureEndpoint(_ endpoint: String) {
        guard let index = index(of: .azureOpenAI) else { return }
        settings[index].azureEndpoint = endpoint
        persist(index: index)
    }

    func setOrganizationID(_ organization: String) async {
        guard let index = index(of: .openAI) else { return }
        await UsageDatabase.shared.mutateProviderConfiguration(for: .openAI) {
            settings[index].openAIOrganizationID = organization.trimmingCharacters(in: .whitespacesAndNewlines)
            settings[index].openAIOAuthFeasibility = .unvalidated
            if settings[index].state != .missing {
                settings[index].state = .configured
            }
            settings[index].failureReason = nil
            persist(index: index)
        }
    }

    func saveCredential(_ secret: String, for provider: ProviderKind) async -> Bool {
        guard let index = index(of: provider) else { return false }
        let kind = settings[index].authMethod.credentialKind
        do {
            await UsageDatabase.shared.advanceProviderConfigurationGeneration(for: provider)
            try credentialService.save(secret, for: CredentialKey(provider: provider, kind: kind))
            if provider == .openAI, kind == .accessToken {
                settings[index].openAIOAuthFeasibility = .unvalidated
            }
            updateState(index: index, state: .configured)
            message = nil
            return true
        } catch {
            message = "Could not update Keychain."
            return false
        }
    }

    func disconnect(_ provider: ProviderKind) async {
        guard let index = index(of: provider) else { return }
        let kind = settings[index].authMethod.credentialKind
        do {
            await UsageDatabase.shared.advanceProviderConfigurationGeneration(for: provider)
            try credentialService.removeCredential(for: CredentialKey(provider: provider, kind: kind))
            if provider == .openAI, kind == .accessToken {
                settings[index].openAIOAuthFeasibility = .unvalidated
            }
            updateState(index: index, state: .missing)
            message = nil
        } catch {
            message = "Could not update Keychain."
        }
    }

    func refresh(_ provider: ProviderKind, workspaceAliases: String = "", apiKeyAliases: String = "") async {
        guard let index = index(of: provider), !refreshing.contains(provider) else { return }
        let product: ProviderRefreshProduct
        switch provider {
        case .anthropic: product = .anthropicAPI
        case .openAI: product = .openAIAPI
        case .azureOpenAI, .custom: return
        }
        refreshing.insert(provider)
        defer { refreshing.remove(provider) }
        let startedAt = Date()
        let clock = ContinuousClock()
        let startedInstant = clock.now
        let execution = provider == .anthropic
            ? await performAnthropicRefresh(index: index, workspaceAliases: workspaceAliases, apiKeyAliases: apiKeyAliases)
            : await performOpenAIRefresh(index: index)
        await recordRefresh(
            product: product,
            outcome: execution.outcome,
            startedAt: startedAt,
            duration: startedInstant.duration(to: clock.now),
            affectedWindows: execution.affectedWindows
        )
    }

    private func index(of provider: ProviderKind) -> Int? {
        settings.firstIndex { $0.provider == provider }
    }

    private func updateState(index: Int, state: ProviderConnectionState) {
        settings[index].state = state
        settings[index].failureReason = nil
        persist(index: index)
    }

    private func persist(index: Int) {
        settings[index].azureEndpoint = settings[index].azureEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        settings[index].updatedAt = Date()
        settingsStore.update(settings[index])
    }

    private func performAnthropicRefresh(index: Int, workspaceAliases: String, apiKeyAliases: String) async -> ProviderRefreshExecution {
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
            let workspaceAliasMap = try aliasMap(workspaceAliases)
            let apiKeyAliasMap = try aliasMap(apiKeyAliases)
            guard let result = await anthropicRefreshService.fetch(apiKey: apiKey, workspaceAliases: workspaceAliasMap, apiKeyAliases: apiKeyAliasMap) else {
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
            var reconciliationMessage: String?
            if case let .success(buckets) = result.reconciliation, !buckets.isEmpty {
                do {
                    let evidence = try APISpendLocalEvidenceLoader.loadActiveSource()
                    let rawLocal = evidence.breakdowns.filter { breakdown in
                        breakdown.provider == .anthropic && buckets.contains { $0.window == breakdown.window }
                    }
                    let pricingStore = PricingSettingsStore()
                    let local = ObservedLocalSpendBreakdown.priced(rawLocal, pricing: pricingStore.pricingTable)
                    let evidenceIdentity = LocalSpendEvidenceIdentity.make(sourceRevision: evidence.sourceRevision, breakdowns: rawLocal)
                    let conclusion = try APISpendReconciler.conclude(
                        provider: buckets,
                        local: local,
                        pricingRevision: pricingStore.revision,
                        localEvidenceIdentity: evidenceIdentity,
                        hasUnpricedLocalEvidence: rawLocal.count > local.count
                    )
                    let store = try SQLiteAPISpendReconciliationStore.applicationSupportStore()
                    try store.record(conclusion)
                    NotificationCenter.default.post(name: .apiSpendReconciliationDidChange, object: nil)
                } catch {
                    reconciliationMessage = "Provider usage refreshed, but reconciliation storage was unavailable. Prior reconciliation data was left unchanged."
                }
            } else if case .failure = result.reconciliation {
                reconciliationMessage = "Provider usage refreshed, but grouped reconciliation was unavailable. Prior reconciliation data was left unchanged."
            }
            settings[index].state = diagnostic.state
            settings[index].failureReason = diagnostic.failureReason
            settings[index].updatedAt = diagnostic.updatedAt
            settingsStore.update(settings[index])
            message = reconciliationMessage
            let fetchedOutcome = ProviderRefreshOutcome(usage: result.result.usage, cost: result.result.cost)
            return execution(diagnostic.state == .connected ? fetchedOutcome : diagnostic.failureReason.map(ProviderRefreshOutcome.init(failureReason:)) ?? .failed)
        } catch APISpendReconciliationError.invalidAlias {
            message = "Label mappings are invalid. No reconciliation request was made."
            return ProviderRefreshExecution(outcome: .failed, affectedWindows: affectedWindows)
        } catch {
            message = "Could not update Keychain."
            return ProviderRefreshExecution(outcome: .failed, affectedWindows: affectedWindows)
        }
    }

    private func aliasMap(_ text: String) throws -> SpendIdentityAliasMap {
        let entries = text.split(separator: ";", omittingEmptySubsequences: true)
        var mappings: [String: String] = [:]
        for entry in entries {
            let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw APISpendReconciliationError.invalidAlias }
            let raw = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let alias = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard mappings[raw] == nil else { throw APISpendReconciliationError.invalidAlias }
            mappings[raw] = alias
        }
        return try SpendIdentityAliasMap(mappings)
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
            message = "Could not update Keychain."
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

// MARK: - Presentation helpers

private extension ProviderKind {
    var monogram: String {
        switch self {
        case .anthropic: "A"
        case .azureOpenAI: "Az"
        case .openAI: "O"
        case .custom: "C"
        }
    }

    var refreshProduct: ProviderRefreshProduct? {
        switch self {
        case .anthropic: .anthropicAPI
        case .openAI: .openAIAPI
        case .azureOpenAI, .custom: nil
        }
    }
}

private extension LiveProvider {
    var monogram: String {
        switch self {
        case .codex: "Cx"
        case .cursor: "Cu"
        case .antigravity: "Ag"
        }
    }

    var sourceDescription: String {
        switch self {
        case .codex: "Codex CLI login"
        case .cursor: "Cursor login"
        case .antigravity: "Antigravity sign-in"
        }
    }

    var installedAppURL: URL? {
        let url = URL(fileURLWithPath: "/Applications/\(displayName).app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

extension ProviderConnectionState {
    var pillText: String {
        switch self {
        case .missing: "Not connected"
        case .configured: "Not validated"
        case .connected: "Connected"
        case .failed: "Refresh failed"
        case .expired: "Credential expired"
        case .unsupported: "Unsupported"
        case .adminRequired: "Admin key needed"
        case .cancelled: "Cancelled"
        }
    }

    var tone: SettingsTone {
        switch self {
        case .connected: .positive
        case .missing, .cancelled: .neutral
        case .configured: .info
        case .failed, .expired, .unsupported, .adminRequired: .warning
        }
    }
}
