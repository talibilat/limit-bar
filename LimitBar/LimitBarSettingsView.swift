import SwiftUI
import LimitBarCore
import AppKit

struct LimitBarSettingsView: View {
    var showsProviderAuthentication = true
    var state = LimitBarState.shared
    private let pricingStore = PricingSettingsStore()
    private let localRefreshSettingsStore = LocalRefreshSettingsStore()
    private let localEventsPath = (try? LocalUsageEventImporter.usageEventsURL().path) ?? "Unavailable"

    @State private var storedMetrics: StoredUsageMetricsSnapshot?
    @State private var providerSettings = ProviderSettingsStore().settings
    @State private var provider = ProviderKind.openAI
    @State private var modelLabel = "gpt-5.1-codex"
    @State private var inputPrice = ""
    @State private var outputPrice = ""
    @State private var currencyCode = "USD"
    @State private var effectiveAt = Date()
    @State private var pricingEntries = PricingSettingsStore().entries
    @State private var localEventsRevealMessage: String?
    @State private var databaseRecoveryMessage: String?
    @State private var confirmsCleanDatabase = false
    @State private var historyRetention = HistoricalUsageRetention.default
    @State private var showsDeleteHistoryConfirmation = false
    @State private var historyMessage: String?
    @State private var localRefreshCadence = LocalRefreshSettingsStore().cadence
    @State private var refreshHistory: [ProviderRefreshProduct: ProviderRefreshHistorySummary] = [:]
    @State private var showsClearRefreshHistoryConfirmation = false
    @State private var refreshHistoryMessage: String?
    @State private var showsDeleteQuotaConfirmation = false
    @State private var quotaDeletionMessage: String?
    @State private var showsDeleteCodexExplanationsConfirmation = false
    @State private var codexExplanationDeletionMessage: String?
    @State private var showsDeleteClaudeExplanationsConfirmation = false
    @State private var claudeExplanationDeletionMessage: String?
    @State private var showsDeleteAttributionConfirmation = false
    @State private var attributionDeletionMessage: String?
    @State private var statusSubscriptionEnabled = false
    @State private var providerStatusMessage: String?

    private var canSavePricing: Bool {
        guard let input = PricingSettingsStore.strictDecimal(from: inputPrice),
              let output = PricingSettingsStore.strictDecimal(from: outputPrice) else {
            return false
        }

        return !modelLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && input >= 0
            && output >= 0
    }

    var body: some View {
        Form {
            AlertSettingsView(store: state.alertSettingsStore, coordinator: state.alertCoordinator)

            if showsProviderAuthentication {
                Section("Provider Authentication") {
                    Text("Secrets are stored only in macOS Keychain. Saved values are never displayed again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProviderSettingsView(settings: $providerSettings)
                }
            }

            Section("Diagnostics") {
                Text("Diagnostics contain structured status only, never credentials or raw provider responses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(providerSettings, id: \.provider) { setting in
                    LabeledContent(setting.provider.displayName) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(setting.state.displayText)
                            if let reason = setting.failureReason {
                                Text(reason.displayText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let storedMetrics {
                    LabeledContent("Usage database", value: storedMetrics.health.message)
                    if !storedMetrics.health.isOpen {
                        Text("The existing database has been left unchanged. Retry with this or a newer LimitBar version before creating a clean database.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            HStack {
                                Button("Retry") {
                                    retryDatabase()
                                }
                                Button("Open Recovery Guide") {
                                    openRecoveryGuide()
                                }
                            }
                            HStack {
                                Button("Reveal Database Folder") {
                                    revealDatabaseFolder()
                                }
                                Button("Create Clean Database", role: .destructive) {
                                    confirmsCleanDatabase = true
                                }
                            }
                        }
                    }
                    if let databaseRecoveryMessage {
                        Text(databaseRecoveryMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Local events imported", value: "\(storedMetrics.localImport.validEventCount)")
                    LabeledContent("Local malformed events", value: "\(storedMetrics.localImport.malformedEventCount)")
                    if storedMetrics.localImport.failureMessage != nil {
                        LabeledContent("Local import status", value: LocalImportDiagnosticState.failed.displayText)
                    }
                    ForEach(storedMetrics.localImport.malformedEvents, id: \.lineNumber) { event in
                        Text("Line \(event.lineNumber): \(event.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Loading diagnostics")
                }
            }

            DiagnosticExportSection(state: state)

            OrganizationPlannerSettingsLink()

            ActivityReceiptSettingsSection(state: state)

            Section("API Spend Reconciliation") {
                APISpendReconciliationView()
            }

            RecoveryInboxSection(model: state.recoveryInbox)

            Section("Quota Observations") {
                Text("Measured Claude Code and Codex percentages are retained locally for up to 30 days and 500 observations per Quota window and Exact boundary. They contain no prompts, code, tokens, projects, agents, models, or account labels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Deleting retained observations does not alter current provider or Codex session reports. A report that remains available can be measured again on a later refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete Quota Observations", role: .destructive) {
                    showsDeleteQuotaConfirmation = true
                }
                if let quotaDeletionMessage {
                    Text(quotaDeletionMessage)
                        .font(.caption)
                        .foregroundStyle(quotaDeletionMessage.hasPrefix("Could not") ? Color.orange : Color.secondary)
                }
            }

            Section("Codex Explanations") {
                Text("Codex explanation findings are retained locally in bounded normalized form so the latest compatible explanation can survive relaunch. They contain no raw JSONL lines, prompts, code, paths, model labels, project labels, or local session digests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Deleting these findings does not alter current usage, quota observations, settings, credentials, alert rules, or notification delivery history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete Codex Explanations", role: .destructive) {
                    showsDeleteCodexExplanationsConfirmation = true
                }
                .accessibilityIdentifier("delete-codex-explanations")
                if let codexExplanationDeletionMessage {
                    Text(codexExplanationDeletionMessage)
                        .font(.caption)
                        .foregroundStyle(codexExplanationDeletionMessage.hasPrefix("Could not") ? Color.orange : Color.secondary)
                }
            }

            Section("Claude Code Explanations") {
                Text("Claude Code explanation findings retain only normalized measured movement, provenance, method metadata, and privacy-safe Observed Local Breakdown totals. Raw OTLP payloads, account labels, prompts, code, responses, terminal output, credentials, and paths are never retained.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Deleting these findings does not alter quota observations, current provider reports, settings, credentials, alert rules, or notification delivery history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete Claude Code Explanations", role: .destructive) {
                    showsDeleteClaudeExplanationsConfirmation = true
                }
                .accessibilityIdentifier("delete-claude-explanations")
                if let claudeExplanationDeletionMessage {
                    Text(claudeExplanationDeletionMessage)
                        .font(.caption)
                        .foregroundStyle(claudeExplanationDeletionMessage.hasPrefix("Could not") ? Color.orange : Color.secondary)
                }
            }

            Section("Project And Agent Attribution") {
                Text("Measured project and agent breakdowns are retained locally in bounded normalized form. Parent usage totals and source files remain separate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Deleting attribution does not change current parent usage, settings, credentials, alert rules, or notification delivery history. Unchanged sources remain suppressed after refresh and relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete Project And Agent Attribution", role: .destructive) {
                    showsDeleteAttributionConfirmation = true
                }
                .accessibilityIdentifier("delete-project-agent-attribution")
                if let attributionDeletionMessage {
                    Text(attributionDeletionMessage)
                        .font(.caption)
                        .foregroundStyle(attributionDeletionMessage.hasPrefix("Could not") ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("project-agent-attribution-deletion-message")
                }
            }

            Section("Provider Refresh History") {
                Text("Only explicit Anthropic API and OpenAI API usage and cost refreshes are retained. Failed or cancelled refreshes leave prior measurements unchanged, so those values may be stale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ProviderRefreshProduct.allCases, id: \.self) { product in
                    let summary = refreshHistory[product]
                    LabeledContent("\(product.displayName) latest", value: ProviderRefreshHistoryStatusText.latest(summary?.latest))
                    LabeledContent("\(product.displayName) last full success", value: ProviderRefreshHistoryStatusText.lastFullSuccess(summary?.lastFullSuccess))
                }
                Button("Clear Provider Refresh History", role: .destructive) {
                    showsClearRefreshHistoryConfirmation = true
                }
                .accessibilityIdentifier("clear-provider-refresh-history")
                if let refreshHistoryMessage {
                    Text(refreshHistoryMessage)
                        .font(.caption)
                        .foregroundStyle(refreshHistoryMessage.hasPrefix("Could not") ? Color.orange : Color.secondary)
                }
            }

            Section("Local Usage Events") {
                Text("Confirmed usage events for Anthropic, Azure OpenAI, and OpenAI are imported from this local JSONL file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(localEventsPath)
                    .font(.caption)
                    .textSelection(.enabled)
                Button("Reveal JSONL in Finder") {
                    revealLocalEventsPath()
                }
                if let localEventsRevealMessage {
                    Text(localEventsRevealMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Official Provider Status") {
                Text("Checks use only the public Anthropic and OpenAI status endpoints. No credentials, cookies, account labels, local failures, quota evidence, client identifiers, or other local context are sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Check every six hours", isOn: $statusSubscriptionEnabled)
                    .accessibilityIdentifier("provider-status-subscription")
                    .onChange(of: statusSubscriptionEnabled) { _, enabled in
                        state.setProviderStatusSubscription(enabled: enabled)
                    }
                Text("Disabled by default. This low-frequency subscription is separate from Local Refresh and explicit provider refreshes. Status observations are retained locally for at most 14 days and 96 checks; arbitrary incident prose is never retained.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete Provider Status History", role: .destructive) {
                    providerStatusMessage = state.deleteProviderStatusHistory()
                        ? "Provider status history deleted. Quota, failures, authentication, settings, and credentials were not changed."
                        : "Could not delete provider status history."
                }
                .accessibilityIdentifier("delete-provider-status-history")
                if let providerStatusMessage {
                    Text(providerStatusMessage)
                        .font(.caption)
                        .foregroundStyle(providerStatusMessage.hasPrefix("Could not") ? Color.orange : Color.secondary)
                }
            }

            Section("Local Refresh") {
                Text("Choose how often LimitBar imports Local Usage Events and Custom Usage Sources, reads its SQLite snapshot, and scans local Codex sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Cadence", selection: $localRefreshCadence) {
                    ForEach(LocalRefreshCadence.allCases, id: \.self) { cadence in
                        Text(cadence.displayName).tag(cadence)
                    }
                }
                .onChange(of: localRefreshCadence) { _, cadence in
                    localRefreshSettingsStore.cadence = cadence
                }
                Text("Shorter intervals show local changes sooner and do more background file and database work. Longer intervals may use less power but delay updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("This setting never schedules provider API requests or macOS Keychain checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Historical Usage") {
                Text("Normalized daily and weekly aggregates stay on this Mac. Raw prompts, responses, code, and provider payloads are never retained for charts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Retention", selection: $historyRetention) {
                    ForEach(HistoricalUsageRetention.allCases, id: \.rawValue) { retention in
                        Text(retention.displayName).tag(retention)
                    }
                }
                .onChange(of: historyRetention) { _, retention in
                    Task {
                        if await UsageDatabase.shared.setHistoricalRetention(retention) {
                            historyMessage = "Retention updated."
                            NotificationCenter.default.post(name: .historicalUsageDidChange, object: nil)
                        } else {
                            historyMessage = "Could not update historical retention."
                        }
                    }
                }
                Button("Delete Historical Usage", role: .destructive) {
                    showsDeleteHistoryConfirmation = true
                }
                .accessibilityIdentifier("delete-historical-usage")
                if let historyMessage {
                    Text(historyMessage)
                        .font(.caption)
                        .foregroundStyle(historyMessage.hasPrefix("Could not") ? Color.orange : Color.secondary)
                }
            }

            CustomUsageSourcesSection()

            Section("Pricing") {
                Text("Manual prices are used only when a provider does not report spend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Bundled table", value: PricingTable.bundledDefaultsVersion)

                Picker("Provider", selection: $provider) {
                    ForEach(ProviderKind.orderedCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                TextField("Model", text: $modelLabel)
                TextField("Input $/1M", text: $inputPrice)
                TextField("Output $/1M", text: $outputPrice)
                TextField("Currency", text: $currencyCode)
                DatePicker("Effective", selection: $effectiveAt, displayedComponents: .date)

                Button("Save Pricing") {
                    savePricing()
                }
                .disabled(!canSavePricing)

                if pricingEntries.isEmpty {
                    Text("No pricing configured. Calculated costs stay hidden until prices are saved.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(pricingEntries.enumerated()), id: \.offset) { _, entry in
                        Text("\(entry.provider.displayName) · \(entry.modelLabel) · In \(entry.inputPricePerMillionTokens.description) / Out \(entry.outputPricePerMillionTokens.description) \(entry.currencyCode)")
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620, height: 720)
        .task {
            storedMetrics = await UsageDatabase.shared.snapshot()
            historyRetention = await UsageDatabase.shared.historicalRetention()
            refreshHistory = await ProviderRefreshHistoryRepository.shared.summaries()
            statusSubscriptionEnabled = state.providerStatusSubscription.isEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerRefreshHistoryDidChange)) { _ in
            Task { refreshHistory = await ProviderRefreshHistoryRepository.shared.summaries() }
        }
        .confirmationDialog(
            "Delete all quota observations?",
            isPresented: $showsDeleteQuotaConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Quota Observations", role: .destructive) {
                Task {
                    quotaDeletionMessage = await state.deleteQuotaObservations()
                        ? "Retained quota observations deleted. Current reports may be observed again on a later refresh."
                        : "Could not delete quota observations."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes retained quota history and calculated findings only. Current reports remain available and may be observed again on a later refresh. Alert rules and delivery state, settings, credentials, and usage remain unchanged.")
        }
        .confirmationDialog(
            "Delete retained Codex explanations?",
            isPresented: $showsDeleteCodexExplanationsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Codex Explanations", role: .destructive) {
                Task {
                    codexExplanationDeletionMessage = await state.deleteCodexExplanations()
                        ? "Codex explanation findings deleted. Current usage, quota observations, settings, credentials, alert rules, and delivery history were not changed."
                        : "Could not delete Codex explanation findings."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes retained Codex explanation findings only. It does not remove current usage, quota observations, settings, credentials, alert rules, or notification delivery history.")
        }
        .confirmationDialog(
            "Delete retained Claude Code explanations?",
            isPresented: $showsDeleteClaudeExplanationsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Claude Code Explanations", role: .destructive) {
                Task {
                    claudeExplanationDeletionMessage = await state.deleteClaudeExplanations()
                        ? "Claude Code explanation findings deleted. Quota observations, reports, settings, credentials, alert rules, and delivery history were not changed."
                        : "Could not delete Claude Code explanation findings."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes retained Claude Code explanation findings only. It does not remove quota observations, current reports, settings, credentials, alert rules, or notification delivery history.")
        }
        .confirmationDialog(
            "Delete retained project and agent attribution?",
            isPresented: $showsDeleteAttributionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Attribution", role: .destructive) {
                Task {
                    let succeeded = await state.deleteProjectAgentAttribution()
                    attributionDeletionMessage = AttributionEvidenceDeletionPresentation.message(succeeded: succeeded)
                    if succeeded {
                        storedMetrics = await UsageDatabase.shared.snapshot()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes retained project and agent breakdowns only. Current parent usage, source files, settings, credentials, alert rules, and notification delivery history remain unchanged.")
        }
        .confirmationDialog(
            "Clear provider refresh history?",
            isPresented: $showsClearRefreshHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Refresh History", role: .destructive) {
                Task {
                    if await ProviderRefreshHistoryRepository.shared.deleteAll() {
                        refreshHistory = [:]
                        refreshHistoryMessage = "Provider refresh history cleared. Usage, settings, and credentials were not changed."
                    } else {
                        refreshHistoryMessage = "Could not clear provider refresh history."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes refresh outcomes only. Current and historical usage, provider settings, and Keychain credentials remain unchanged.")
        }
        .confirmationDialog(
            "Delete all historical usage?",
            isPresented: $showsDeleteHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete History", role: .destructive) {
                Task {
                    if await UsageDatabase.shared.deleteHistoricalUsage() {
                        state.clearHistoricalUsage()
                        historyMessage = "Historical usage deleted. Source files and current usage were not changed."
                    } else {
                        historyMessage = "Could not delete historical usage."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes retained aggregates only. Settings, credentials, current usage, and source JSONL files remain unchanged.")
        }
        .confirmationDialog(
            "Archive the existing usage database and create a clean one?",
            isPresented: $confirmsCleanDatabase,
            titleVisibility: .visible
        ) {
            Button("Archive and Create Clean Database", role: .destructive) {
                createCleanDatabase()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Metrics that cannot be reimported remain only in the local Recovery folder. Settings and Keychain credentials are not changed.")
        }
    }

    private func savePricing() {
        guard canSavePricing,
              let input = PricingSettingsStore.strictDecimal(from: inputPrice),
              let output = PricingSettingsStore.strictDecimal(from: outputPrice) else {
            return
        }

        let entry = PricingEntry(
            provider: provider,
            modelLabel: modelLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            inputPricePerMillionTokens: input,
            outputPricePerMillionTokens: output,
            currencyCode: currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            effectiveAt: effectiveAt
        )
        if pricingStore.add(entry) {
            pricingEntries = pricingStore.entries
        }
    }

    private func revealLocalEventsPath() {
        guard let url = try? LocalUsageEventImporter.usageEventsURL() else {
            localEventsRevealMessage = "Could not resolve the local events path."
            return
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            localEventsRevealMessage = nil
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(directory)
            }
        } catch {
            localEventsRevealMessage = "Could not create the local events directory."
        }
    }

    private func retryDatabase() {
        Task {
            storedMetrics = await UsageDatabase.shared.snapshot()
            databaseRecoveryMessage = storedMetrics?.health.isOpen == true
                ? "The usage database opened successfully."
                : "The usage database is still unavailable."
        }
    }

    private func openRecoveryGuide() {
        guard let url = URL(string: "https://github.com/talibilat/limit-bar/blob/main/docs/MIGRATIONS_AND_RECOVERY.md") else { return }
        if !NSWorkspace.shared.open(url) {
            databaseRecoveryMessage = "Could not open the recovery guide."
        }
    }

    private func revealDatabaseFolder() {
        Task {
            do {
                let directory = try await UsageDatabase.shared.databaseDirectoryURL()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                databaseRecoveryMessage = NSWorkspace.shared.open(directory)
                    ? nil
                    : "Could not reveal the usage database folder."
            } catch {
                databaseRecoveryMessage = "Could not reveal the usage database folder."
            }
        }
    }

    private func createCleanDatabase() {
        Task {
            do {
                let archive = try await UsageDatabase.shared.createCleanDatabaseRecovery()
                storedMetrics = await UsageDatabase.shared.snapshot()
                databaseRecoveryMessage = "The original database was retained in \(archive.lastPathComponent)."
            } catch {
                databaseRecoveryMessage = "Could not create a clean database. The original database was not intentionally deleted."
            }
        }
    }
}

enum AttributionEvidenceDeletionPresentation {
    static func message(succeeded: Bool) -> String {
        succeeded
            ? "Project and agent attribution deleted. Parent usage, source files, settings, credentials, alert rules, and delivery history were not changed."
            : "Could not delete project and agent attribution. Existing attribution was left available."
    }
}

enum ProviderRefreshHistoryStatusText {
    static func latest(_ entry: ProviderRefreshHistoryEntry?) -> String {
        guard let entry else { return "No explicit refresh recorded" }
        return "\(outcome(entry.outcome)) \(entry.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    static func lastFullSuccess(_ entry: ProviderRefreshHistoryEntry?) -> String {
        guard let entry else { return "No full success recorded" }
        return entry.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func outcome(_ outcome: ProviderRefreshOutcome) -> String {
        switch outcome {
        case .success: "Succeeded"
        case .partialFailure: "Partially failed"
        case .cancelled: "Cancelled"
        case .authenticationFailure: "Authentication failed"
        case .networkFailure: "Network failed"
        case .failed: "Failed"
        }
    }
}

struct CustomUsageSourcesSection: View {
    private let store: CustomUsageSourceStore
    private let chooseFile: () -> String?

    @State private var sources: [CustomUsageSource]
    @State private var name = ""
    @State private var filePath = ""
    @State private var validationMessage: String?

    init(
        store: CustomUsageSourceStore = CustomUsageSourceStore(),
        chooseFile: @escaping () -> String? = CustomUsageSourcesSection.chooseFileWithPanel
    ) {
        self.store = store
        self.chooseFile = chooseFile
        _sources = State(initialValue: store.sources)
    }

    var body: some View {
        Section("Custom Usage Sources") {
            Text("Track any tool LimitBar has no built-in support for. Point at a local log file where each line is JSON with timestamp, model, inputTokens, and outputTokens, one line per response - works for Aider, Cursor, Windsurf, or anything else that can write a log line. A source only appears on the Usage tab once its file actually has matching events; nothing shows for tools you don't use.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(#"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}"#)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            TextField("Name (e.g. Aider)", text: $name)
                .accessibilityIdentifier("custom-source-name")
            HStack {
                TextField("Log file path", text: $filePath)
                    .accessibilityIdentifier("custom-source-path")
                Button("Choose File...") {
                    if let selectedPath = chooseFile() {
                        filePath = selectedPath
                        validationMessage = nil
                    }
                }
                .accessibilityIdentifier("custom-source-choose-file")
            }
            Button("Add Source") {
                if store.add(name: name, filePath: filePath) {
                    sources = store.sources
                    name = ""
                    filePath = ""
                    validationMessage = nil
                } else {
                    validationMessage = "Choose a readable regular JSONL file. Symbolic links are not accepted."
                }
            }
            .accessibilityIdentifier("custom-source-add")
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("custom-source-validation")
            }

            if sources.isEmpty {
                Text("No custom sources configured.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("custom-sources-empty")
            } else {
                ForEach(sources) { source in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(source.name)
                            Text(source.filePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") {
                            store.remove(id: source.id)
                            sources = store.sources
                        }
                        .accessibilityIdentifier("custom-source-remove")
                    }
                    .accessibilityIdentifier("custom-source-row")
                }
            }
        }
    }

    private static func chooseFileWithPanel() -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

#Preview {
    LimitBarSettingsView(state: .shared)
}
