import SwiftUI
import LimitBarCore
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case accounts
    case alerts
    case sources
    case data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .alerts: "Alerts"
        case .sources: "Sources & Pricing"
        case .data: "Data & Privacy"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .accounts: "person.crop.circle"
        case .alerts: "bell"
        case .sources: "cylinder.split.1x2"
        case .data: "hand.raised"
        }
    }
}

struct LimitBarSettingsView: View {
    var state = LimitBarState.shared
    @State private var section: SettingsSection = .accounts

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                page
                    .padding(.horizontal, 30)
                    .padding(.vertical, 26)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(SettingsPalette.window)
        }
        .frame(width: 880, height: 720)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(SettingsPalette.monogram, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("LimitBar")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 18)

            ForEach(SettingsSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .foregroundStyle(section == item ? Color.white : Color.primary)
                        .background(
                            section == item ? SettingsPalette.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-section-\(item.rawValue)")
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(SettingsPalette.sidebar)
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .general:
            GeneralSettingsPage(state: state)
        case .accounts:
            AccountsSettingsPage(state: state, openSection: { section = $0 })
        case .alerts:
            AlertSettingsView(store: state.alertSettingsStore, coordinator: state.alertCoordinator)
        case .sources:
            SourcesSettingsPage()
        case .data:
            DataPrivacySettingsPage(state: state)
        }
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    let state: LimitBarState
    private let localRefreshSettingsStore = LocalRefreshSettingsStore()

    @State private var localRefreshCadence = LocalRefreshSettingsStore().cadence
    @State private var statusSubscriptionEnabled = false
    @State private var showsDeleteStatusConfirmation = false
    @State private var providerStatusMessage: String?

    var body: some View {
        SettingsPage(title: "General", subtitle: "How often LimitBar checks this Mac, and whether it watches provider status pages.") {
            SettingsGroup("Local refresh") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        SettingsRowText(
                            title: "Check for local changes",
                            detail: "Imports local usage events and custom sources, and scans Codex sessions."
                        )
                        Picker("Refresh interval", selection: $localRefreshCadence) {
                            ForEach(LocalRefreshCadence.allCases, id: \.self) { cadence in
                                Text("\(cadence.rawValue) sec").tag(cadence)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                        .accessibilityIdentifier("local-refresh-cadence")
                    }
                    SettingsNote(systemImage: "info.circle", text: "Shorter intervals show changes sooner but do more background work. This never calls provider APIs or reads your Keychain.")
                }
                .padding(16)
            }
            .onChange(of: localRefreshCadence) { _, cadence in
                localRefreshSettingsStore.cadence = cadence
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsGroup("Start limit windows automatically", caption: "Runs while LimitBar is open") {
                    ForEach(Array(WindowStarterProduct.allCases.enumerated()), id: \.element) { offset, product in
                        if offset > 0 { Divider() }
                        windowStarterRow(product)
                    }
                }
                Text("One minute after a 5-hour or weekly limit resets, LimitBar sends \u{201C}.\u{201D} through the tool's CLI so the next window starts straight away. If no 5-hour window is running, it sends one now. Each message uses a tiny part of your limit.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup("Official provider status") {
                SettingsRow {
                    SettingsRowText(
                        title: "Check Anthropic and OpenAI status every six hours",
                        detail: "Uses only the public status pages. Nothing about you, your accounts or your usage is sent."
                    )
                    Toggle("Check provider status every six hours", isOn: $statusSubscriptionEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityIdentifier("provider-status-subscription")
                }
                Divider()
                SettingsRow {
                    SettingsRowText(title: "Status history", detail: "Kept for up to 14 days (96 checks)", emphasized: false)
                    Button("Delete History…") { showsDeleteStatusConfirmation = true }
                        .buttonStyle(SettingsButtonStyle(.danger))
                        .accessibilityIdentifier("delete-provider-status-history")
                }
            }
            .onChange(of: statusSubscriptionEnabled) { _, enabled in
                guard enabled != state.providerStatusSubscription.isEnabled else { return }
                state.setProviderStatusSubscription(enabled: enabled)
            }
            SettingsMessage(providerStatusMessage)
        }
        .task {
            statusSubscriptionEnabled = state.providerStatusSubscription.isEnabled
        }
        .confirmationDialog("Delete provider status history?", isPresented: $showsDeleteStatusConfirmation, titleVisibility: .visible) {
            Button("Delete History", role: .destructive) {
                providerStatusMessage = state.deleteProviderStatusHistory()
                    ? "Provider status history deleted. Quota, failures, authentication, settings, and credentials were not changed."
                    : "Could not delete provider status history."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes retained status observations only.")
        }
    }

    private func windowStarterRow(_ product: WindowStarterProduct) -> some View {
        let starter = state.windowStarter
        return SettingsRow {
            SettingsRowText(title: product.displayName, detail: windowStarterDetail(product))
            Toggle("Start \(product.displayName) windows automatically", isOn: Binding(
                get: { starter.isEnabled(product) },
                set: { starter.setEnabled($0, for: product) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityIdentifier("window-starter-\(product.rawValue)")
        }
    }

    private func windowStarterDetail(_ product: WindowStarterProduct) -> String {
        let starter = state.windowStarter
        let status = starter.status(product)
        var parts: [String] = []
        if !starter.isEnabled(product) {
            parts.append("Off")
        } else if status.isSending {
            parts.append("Sending now…")
        } else if let note = status.note {
            parts.append(note)
        } else if let nextAt = status.nextAt {
            parts.append("Next: \(nextAt.formatted(date: Calendar.current.isDateInToday(nextAt) ? .omitted : .abbreviated, time: .shortened))")
        } else {
            parts.append("Reading reset times…")
        }
        if let lastSentAt = status.lastAttemptAt ?? status.lastSentAt {
            let outcome = status.lastSucceeded == false ? "failed" : "sent"
            parts.append("Last \(outcome) \(lastSentAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Sources & Pricing

struct SourcesSettingsPage: View {
    private let pricingStore = PricingSettingsStore()
    private let localEventsPath = (try? LocalUsageEventImporter.usageEventsURL().path) ?? "Unavailable"

    @State private var storedMetrics: StoredUsageMetricsSnapshot?
    @State private var localEventsRevealMessage: String?
    @State private var provider = ProviderKind.openAI
    @State private var modelLabel = "gpt-5.1-codex"
    @State private var inputPrice = ""
    @State private var outputPrice = ""
    @State private var currencyCode = "USD"
    @State private var effectiveAt = Date()
    @State private var pricingEntries = PricingSettingsStore().entries
    @State private var pricingMessage: String?

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
        SettingsPage(title: "Sources & Pricing", subtitle: "Local files LimitBar imports usage from, and prices used when a provider doesn't report spend.") {
            SettingsGroup("Local usage events") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Anthropic, Azure OpenAI and OpenAI events are imported from")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(localEventsPath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(importSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Reveal in Finder") { revealLocalEventsPath() }
                        .buttonStyle(SettingsButtonStyle(.normal))
                }
            }
            SettingsMessage(localEventsRevealMessage)

            CustomUsageSourcesSection()

            SettingsGroup("Pricing", caption: "Bundled table: \(PricingTable.bundledDefaultsVersion)") {
                if pricingEntries.isEmpty {
                    Text("No prices yet. Calculated costs stay hidden until you add one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                        GridRow {
                            ForEach(["Provider", "Model", "Input / 1M", "Output / 1M", "Effective"], id: \.self) { header in
                                Text(header)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                        ForEach(Array(pricingEntries.enumerated()), id: \.offset) { _, entry in
                            Divider()
                            GridRow {
                                Text(entry.provider.displayName)
                                Text(entry.modelLabel)
                                    .font(.system(size: 12, design: .monospaced))
                                Text("\(entry.inputPricePerMillionTokens.description) \(entry.currencyCode)")
                                Text("\(entry.outputPricePerMillionTokens.description) \(entry.currencyCode)")
                                Text(entry.effectiveAt.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 16)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add a price")
                        .font(.system(size: 12, weight: .semibold))
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            SettingsField("Provider") {
                                Picker("Provider", selection: $provider) {
                                    ForEach(ProviderKind.orderedCases.filter { $0 != .custom }, id: \.self) { provider in
                                        Text(provider.displayName).tag(provider)
                                    }
                                }
                                .labelsHidden()
                            }
                            SettingsField("Model") {
                                TextField("Model", text: $modelLabel)
                                    .labelsHidden()
                            }
                            SettingsField("Effective from") {
                                DatePicker("Effective from", selection: $effectiveAt, displayedComponents: .date)
                                    .labelsHidden()
                            }
                        }
                        GridRow {
                            SettingsField("Input $ / 1M tokens") {
                                TextField("0.00", text: $inputPrice)
                                    .labelsHidden()
                            }
                            SettingsField("Output $ / 1M tokens") {
                                TextField("0.00", text: $outputPrice)
                                    .labelsHidden()
                            }
                            SettingsField("Currency") {
                                TextField("USD", text: $currencyCode)
                                    .labelsHidden()
                            }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    HStack {
                        SettingsMessage(pricingMessage)
                        Spacer()
                        Button("Save Price") { savePricing() }
                            .buttonStyle(SettingsButtonStyle(.primary))
                            .disabled(!canSavePricing)
                    }
                }
                .padding(16)
                .background(SettingsPalette.cardInset)
            }
        }
        .task {
            storedMetrics = await UsageDatabase.shared.snapshot()
        }
    }

    private var importSummary: String {
        guard let storedMetrics else { return "Reading import status…" }
        let imported = storedMetrics.localImport.validEventCount.formatted()
        let malformed = storedMetrics.localImport.malformedEventCount.formatted()
        return "\(imported) imported · \(malformed) malformed"
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
            inputPrice = ""
            outputPrice = ""
            pricingMessage = nil
        } else {
            pricingMessage = "Could not save this price."
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
        SettingsGroup("Custom usage sources", caption: "For tools without built-in support") {
            if sources.isEmpty {
                Text("No custom sources yet. A source shows on the Usage tab once its file has matching events.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .accessibilityIdentifier("custom-sources-empty")
                Divider()
            } else {
                ForEach(sources) { source in
                    HStack(spacing: 12) {
                        ProviderMonogram(text: String(source.name.prefix(2)), size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.system(size: 13, weight: .semibold))
                            Text(source.filePath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Remove") {
                            store.remove(id: source.id)
                            sources = store.sources
                        }
                        .buttonStyle(SettingsButtonStyle(.danger))
                        .accessibilityIdentifier("custom-source-remove")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("custom-source-row")
                    Divider()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Add a source")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    TextField("Name (e.g. Cursor)", text: $name)
                        .frame(width: 170)
                        .accessibilityIdentifier("custom-source-name")
                    TextField("Log file path", text: $filePath)
                        .accessibilityIdentifier("custom-source-path")
                    Button("Choose File…") {
                        if let selectedPath = chooseFile() {
                            filePath = selectedPath
                            validationMessage = nil
                        }
                    }
                    .buttonStyle(SettingsButtonStyle(.normal))
                    .accessibilityIdentifier("custom-source-choose-file")
                    Button("Add") { addSource() }
                        .buttonStyle(SettingsButtonStyle(.primary))
                        .accessibilityIdentifier("custom-source-add")
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .textFieldStyle(.roundedBorder)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("custom-source-validation")
                }

                DisclosureGroup("Log format: one JSON line per response") {
                    Text(#"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}"#)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.top, 6)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(SettingsPalette.cardInset)
        }
    }

    private func addSource() {
        if store.add(name: name, filePath: filePath) {
            sources = store.sources
            name = ""
            filePath = ""
            validationMessage = nil
        } else {
            validationMessage = "Choose a readable regular JSONL file. Symbolic links are not accepted."
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

// MARK: - Data & Privacy

struct DataPrivacySettingsPage: View {
    let state: LimitBarState

    private enum Deletion: String, Identifiable {
        case history, quota, claudeExplanations, codexExplanations, attribution, refreshHistory, statusHistory
        var id: String { rawValue }
    }

    @State private var storedMetrics: StoredUsageMetricsSnapshot?
    @State private var historyRetention = HistoricalUsageRetention.default
    @State private var retentionLoaded = false
    @State private var refreshHistory: [ProviderRefreshProduct: ProviderRefreshHistorySummary] = [:]
    @State private var pendingDeletion: Deletion?
    @State private var messages: [Deletion: String] = [:]
    @State private var historyMessage: String?
    @State private var databaseRecoveryMessage: String?
    @State private var confirmsCleanDatabase = false
    @State private var showsDiagnosticExport = false

    var body: some View {
        SettingsPage(title: "Data & Privacy", subtitle: "Everything here is stored only on this Mac and never includes prompts, code or keys. Deleting it doesn't touch your accounts, keys or settings.") {
            SettingsGroup("Usage history") {
                SettingsRow {
                    SettingsRowText(title: "Keep history for", detail: "Daily and weekly totals used for charts")
                    Picker("Keep history for", selection: $historyRetention) {
                        ForEach(HistoricalUsageRetention.allCases, id: \.rawValue) { retention in
                            Text(retention.displayName).tag(retention)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                Divider()
                deletionRow(.history, title: "Historical usage", detail: nil, button: "Delete…", identifier: "delete-historical-usage")
            }
            .onChange(of: historyRetention) { _, retention in
                guard retentionLoaded else { return }
                Task {
                    if await UsageDatabase.shared.setHistoricalRetention(retention) {
                        historyMessage = "Retention updated."
                        NotificationCenter.default.post(name: .historicalUsageDidChange, object: nil)
                    } else {
                        historyMessage = "Could not update historical retention."
                    }
                }
            }
            SettingsMessage(historyMessage ?? messages[.history])

            SettingsGroup("Saved findings", caption: "Each can be deleted on its own") {
                deletionRow(.quota, title: "Quota observations", detail: "Measured Claude Code and Codex percentages · up to 30 days", button: "Delete…", identifier: "delete-quota-observations")
                Divider()
                deletionRow(.claudeExplanations, title: "Claude Code explanations", detail: "Why quota moved, as normalised totals", button: "Delete…", identifier: "delete-claude-explanations")
                Divider()
                deletionRow(.codexExplanations, title: "Codex explanations", detail: "Latest explanation, kept across relaunch", button: "Delete…", identifier: "delete-codex-explanations")
                Divider()
                deletionRow(.attribution, title: "Project and agent attribution", detail: "Per-project and per-agent breakdowns", button: "Delete…", identifier: "delete-project-agent-attribution")
                Divider()
                deletionRow(.refreshHistory, title: "API refresh history", detail: refreshHistorySummary, button: "Clear…", identifier: "clear-provider-refresh-history")
                Divider()
                deletionRow(.statusHistory, title: "Provider status history", detail: "Up to 14 days · see General", button: "Delete…", identifier: "delete-provider-status-history")
            }
            SettingsMessage(messages[.quota])
            SettingsMessage(messages[.claudeExplanations])
            SettingsMessage(messages[.codexExplanations])
            SettingsMessage(messages[.attribution])
                .accessibilityIdentifier("project-agent-attribution-deletion-message")
            SettingsMessage(messages[.refreshHistory])
            SettingsMessage(messages[.statusHistory])

            SettingsGroup("Diagnostics") {
                Grid(alignment: .leading, horizontalSpacing: 12) {
                    GridRow {
                        diagnosticValue("Usage database") {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(databaseIsOpen ? SettingsTone.positive.foreground : SettingsTone.warning.foreground)
                                    .frame(width: 7, height: 7)
                                Text(storedMetrics?.health.message ?? "Checking…")
                            }
                        }
                        diagnosticValue("Local events imported") {
                            Text(storedMetrics.map { $0.localImport.validEventCount.formatted() } ?? "–")
                        }
                        diagnosticValue("Malformed lines") {
                            Text(storedMetrics.map { $0.localImport.malformedEventCount.formatted() } ?? "–")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Divider()
                if let storedMetrics, !storedMetrics.health.isOpen {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The existing database was left unchanged. Retry with this or a newer LimitBar version before creating a clean database.")
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTone.warning.foreground)
                        HStack(spacing: 8) {
                            Button("Retry") { retryDatabase() }
                                .buttonStyle(SettingsButtonStyle(.normal))
                            Button("Create Clean Database…") { confirmsCleanDatabase = true }
                                .buttonStyle(SettingsButtonStyle(.danger))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    Divider()
                }
                HStack(spacing: 8) {
                    Button("Export Diagnostics…") { showsDiagnosticExport = true }
                        .buttonStyle(SettingsButtonStyle(.normal))
                    Button("Reveal Database Folder") { revealDatabaseFolder() }
                        .buttonStyle(SettingsButtonStyle(.normal))
                    Spacer()
                    Link("Recovery guide", destination: Self.recoveryGuideURL)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            Text("If the database can't open, Retry and Create Clean Database appear here. The original is always kept.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            SettingsMessage(databaseRecoveryMessage)
        }
        .task {
            storedMetrics = await UsageDatabase.shared.snapshot()
            historyRetention = await UsageDatabase.shared.historicalRetention()
            refreshHistory = await ProviderRefreshHistoryRepository.shared.summaries()
            retentionLoaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerRefreshHistoryDidChange)) { _ in
            Task { refreshHistory = await ProviderRefreshHistoryRepository.shared.summaries() }
        }
        .confirmationDialog(
            pendingDeletion.map(confirmationTitle) ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button(deletion == .refreshHistory ? "Clear" : "Delete", role: .destructive) {
                Task { await perform(deletion) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(confirmationMessage(deletion))
        }
        .confirmationDialog(
            "Archive the existing usage database and create a clean one?",
            isPresented: $confirmsCleanDatabase,
            titleVisibility: .visible
        ) {
            Button("Archive and Create Clean Database", role: .destructive) { createCleanDatabase() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Metrics that cannot be reimported remain only in the local Recovery folder. Settings and Keychain credentials are not changed.")
        }
        .sheet(isPresented: $showsDiagnosticExport) {
            VStack(spacing: 0) {
                Form {
                    DiagnosticExportSection(state: state)
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showsDiagnosticExport = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
            .frame(width: 620, height: 640)
        }
    }

    private static let recoveryGuideURL = URL(string: "https://github.com/talibilat/limit-bar/blob/main/docs/MIGRATIONS_AND_RECOVERY.md")!

    private var databaseIsOpen: Bool { storedMetrics?.health.isOpen ?? true }

    private var refreshHistorySummary: String {
        ProviderRefreshProduct.allCases.map { product in
            "\(product.displayName): \(ProviderRefreshHistoryStatusText.latest(refreshHistory[product]?.latest))"
        }
        .joined(separator: " · ")
    }

    private func deletionRow(_ deletion: Deletion, title: String, detail: String?, button: String, identifier: String) -> some View {
        SettingsRow(verticalPadding: 12) {
            SettingsRowText(title: title, detail: detail, emphasized: false)
            Button(button) { pendingDeletion = deletion }
                .buttonStyle(SettingsButtonStyle(.danger))
                .accessibilityIdentifier(identifier)
        }
    }

    private func diagnosticValue<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            value()
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmationTitle(_ deletion: Deletion) -> String {
        switch deletion {
        case .history: "Delete all historical usage?"
        case .quota: "Delete all quota observations?"
        case .claudeExplanations: "Delete retained Claude Code explanations?"
        case .codexExplanations: "Delete retained Codex explanations?"
        case .attribution: "Delete retained project and agent attribution?"
        case .refreshHistory: "Clear provider refresh history?"
        case .statusHistory: "Delete provider status history?"
        }
    }

    private func confirmationMessage(_ deletion: Deletion) -> String {
        switch deletion {
        case .history:
            "This removes retained aggregates only. Settings, credentials, current usage, and source JSONL files remain unchanged."
        case .quota:
            "This removes retained quota history and calculated findings only. Current reports remain available and may be observed again on a later refresh. Alert rules and delivery state, settings, credentials, and usage remain unchanged."
        case .claudeExplanations:
            "This removes retained Claude Code explanation findings only. It does not remove quota observations, current reports, settings, credentials, alert rules, or notification delivery history."
        case .codexExplanations:
            "This removes retained Codex explanation findings only. It does not remove current usage, quota observations, settings, credentials, alert rules, or notification delivery history."
        case .attribution:
            "This removes retained project and agent breakdowns only. Current parent usage, source files, settings, credentials, alert rules, and notification delivery history remain unchanged."
        case .refreshHistory:
            "This removes refresh outcomes only. Current and historical usage, provider settings, and Keychain credentials remain unchanged."
        case .statusHistory:
            "This removes retained status observations only."
        }
    }

    private func perform(_ deletion: Deletion) async {
        switch deletion {
        case .history:
            historyMessage = nil
            if await UsageDatabase.shared.deleteHistoricalUsage() {
                state.clearHistoricalUsage()
                messages[.history] = "Historical usage deleted. Source files and current usage were not changed."
            } else {
                messages[.history] = "Could not delete historical usage."
            }
        case .quota:
            messages[.quota] = await state.deleteQuotaObservations()
                ? "Retained quota observations deleted. Current reports may be observed again on a later refresh."
                : "Could not delete quota observations."
        case .claudeExplanations:
            messages[.claudeExplanations] = await state.deleteClaudeExplanations()
                ? "Claude Code explanation findings deleted. Quota observations, reports, settings, credentials, alert rules, and delivery history were not changed."
                : "Could not delete Claude Code explanation findings."
        case .codexExplanations:
            messages[.codexExplanations] = await state.deleteCodexExplanations()
                ? "Codex explanation findings deleted. Current usage, quota observations, settings, credentials, alert rules, and delivery history were not changed."
                : "Could not delete Codex explanation findings."
        case .attribution:
            let succeeded = await state.deleteProjectAgentAttribution()
            messages[.attribution] = AttributionEvidenceDeletionPresentation.message(succeeded: succeeded)
            if succeeded {
                storedMetrics = await UsageDatabase.shared.snapshot()
            }
        case .refreshHistory:
            if await ProviderRefreshHistoryRepository.shared.deleteAll() {
                refreshHistory = [:]
                messages[.refreshHistory] = "Provider refresh history cleared. Usage, settings, and credentials were not changed."
            } else {
                messages[.refreshHistory] = "Could not clear provider refresh history."
            }
        case .statusHistory:
            messages[.statusHistory] = state.deleteProviderStatusHistory()
                ? "Provider status history deleted. Quota, failures, authentication, settings, and credentials were not changed."
                : "Could not delete provider status history."
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

// MARK: - Shared building blocks

enum SettingsPalette {
    static let window = adaptive(light: 0xF5F5F7, dark: 0x1C1C1E)
    static let sidebar = adaptive(light: 0xECECEF, dark: 0x232326)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let cardInset = adaptive(light: 0xF7F7F9, dark: 0x262629)
    static let border = adaptive(light: 0xDCDCE1, dark: 0x38383C)
    static let field = adaptive(light: 0xF0F0F3, dark: 0x1F1F22)
    static let monogram = adaptive(light: 0xE6E6EA, dark: 0x3A3A3E)
    static let button = adaptive(light: 0xFFFFFF, dark: 0x3A3A3E)
    static let buttonBorder = adaptive(light: 0xC9C9CF, dark: 0x4A4A4F)
    static let dangerText = adaptive(light: 0xC9372C, dark: 0xFF7A70)
    static let dangerBorder = adaptive(light: 0xF0B9B4, dark: 0x5C3431)
    static let accent = Color(nsColor: NSColor(hex: 0x1366D6))

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum SettingsTone {
    case positive, warning, neutral, info

    var foreground: Color {
        switch self {
        case .positive: SettingsPalette.adaptive(light: 0x1F8A3B, dark: 0x5BE37A)
        case .warning: SettingsPalette.adaptive(light: 0xB25E00, dark: 0xFFB340)
        case .neutral: SettingsPalette.adaptive(light: 0x5C5C63, dark: 0xC7C7CC)
        case .info: SettingsPalette.adaptive(light: 0x1366D6, dark: 0x6EB2FF)
        }
    }

    var background: Color {
        switch self {
        case .positive: SettingsPalette.adaptive(light: 0xDDF3E3, dark: 0x1E3A27)
        case .warning: SettingsPalette.adaptive(light: 0xFCEBD5, dark: 0x43301A)
        case .neutral: SettingsPalette.adaptive(light: 0xEBEBEF, dark: 0x34343A)
        case .info: SettingsPalette.adaptive(light: 0xDDEAFB, dark: 0x1B2F4A)
        }
    }
}

struct SettingsPage<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            content
        }
        .font(.system(size: 13))
    }
}

extension SettingsPage where Trailing == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let content: Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let caption {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                content
            }
            .background(SettingsPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsPalette.border)
            )
        }
    }
}

struct SettingsRow<Content: View>: View {
    var verticalPadding: CGFloat = 14
    @ViewBuilder let content: Content

    init(verticalPadding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 16) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, verticalPadding)
    }
}

struct SettingsRowText: View {
    let title: String
    var detail: String?
    var emphasized = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsNote: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(SettingsPalette.cardInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SettingsMessage: View {
    let text: String?

    init(_ text: String?) {
        self.text = text
    }

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(text.hasPrefix("Could not") ? SettingsTone.warning.foreground : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusPill: View {
    let text: String
    let tone: SettingsTone

    var body: some View {
        HStack(spacing: 5) {
            if tone == .neutral {
                Circle()
                    .strokeBorder(tone.foreground, lineWidth: 1)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(tone.foreground)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(tone.background, in: Capsule())
    }
}

struct ProviderMonogram: View {
    let text: String
    var size: CGFloat = 36

    var body: some View {
        Text(text)
            .font(.system(size: size > 36 ? 14 : 13, weight: .bold))
            .frame(width: size, height: size)
            .background(SettingsPalette.monogram, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, danger, destroy }

    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    init(_ kind: Kind) {
        self.kind = kind
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(border)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .normal: .primary
        case .primary, .destroy: .white
        case .danger: SettingsPalette.dangerText
        }
    }

    private var background: Color {
        switch kind {
        case .normal: SettingsPalette.button
        case .primary: SettingsPalette.accent
        case .danger: .clear
        case .destroy: Color(nsColor: NSColor(hex: 0xC9372C))
        }
    }

    private var border: Color {
        switch kind {
        case .normal: SettingsPalette.buttonBorder
        case .primary: SettingsPalette.accent
        case .danger: SettingsPalette.dangerBorder
        case .destroy: Color(nsColor: NSColor(hex: 0xC9372C))
        }
    }
}

#Preview {
    LimitBarSettingsView(state: .shared)
}

enum CodexLoginLauncher {
    @MainActor
    static func openLogin() {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("limitbar-codex-login.command")
        let contents = """
        #!/bin/zsh
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        codex login
        echo
        echo "Done. You can close this window."
        """
        do {
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
}
