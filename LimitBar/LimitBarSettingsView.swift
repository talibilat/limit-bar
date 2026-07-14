import SwiftUI
import LimitBarCore
import AppKit

struct LimitBarSettingsView: View {
    var showsProviderAuthentication = true
    var state = LimitBarState.shared
    private let pricingStore = PricingSettingsStore()
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
    @State private var refreshHistory: [ProviderRefreshProduct: ProviderRefreshHistorySummary] = [:]
    @State private var showsClearRefreshHistoryConfirmation = false
    @State private var refreshHistoryMessage: String?

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
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerRefreshHistoryDidChange)) { _ in
            Task { refreshHistory = await ProviderRefreshHistoryRepository.shared.summaries() }
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
                    }
                }
                .accessibilityIdentifier("custom-source-choose-file")
            }
            Button("Add Source") {
                if store.add(name: name, filePath: filePath) {
                    sources = store.sources
                    name = ""
                    filePath = ""
                }
            }
            .accessibilityIdentifier("custom-source-add")
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
