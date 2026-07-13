import SwiftUI
import LimitBarCore
import AppKit

struct LimitBarSettingsView: View {
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

    private let customSourceStore = CustomUsageSourceStore()
    @State private var customSources = CustomUsageSourceStore().sources
    @State private var customSourceName = ""
    @State private var customSourceFilePath = ""

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
            Section("Provider Authentication") {
                Text("Secrets are stored only in macOS Keychain. Saved values are never displayed again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProviderSettingsView(settings: $providerSettings)
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

            Section("Custom Usage Sources") {
                Text("Track any tool LimitBar has no built-in support for. Point at a local log file where each line is JSON with timestamp, model, inputTokens, and outputTokens, one line per response - works for Aider, Cursor, Windsurf, or anything else that can write a log line. A source only appears on the Usage tab once its file actually has matching events; nothing shows for tools you don't use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(#"{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}"#)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                TextField("Name (e.g. Aider)", text: $customSourceName)
                HStack {
                    TextField("Log file path", text: $customSourceFilePath)
                    Button("Choose File...") {
                        chooseCustomSourceFile()
                    }
                }
                Button("Add Source") {
                    addCustomSource()
                }
                .disabled(customSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || customSourceFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if customSources.isEmpty {
                    Text("No custom sources configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customSources) { source in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(source.name)
                                Text(source.filePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                removeCustomSource(id: source.id)
                            }
                        }
                    }
                }
            }

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
            currencyCode: currencyCode.trimmingCharacters(in: .whitespacesAndNewlines),
            effectiveAt: effectiveAt
        )
        if pricingStore.add(entry) {
            pricingEntries = pricingStore.entries
        }
    }

    private func addCustomSource() {
        if customSourceStore.add(name: customSourceName, filePath: customSourceFilePath) {
            customSources = customSourceStore.sources
            customSourceName = ""
            customSourceFilePath = ""
        }
    }

    private func removeCustomSource(id: UUID) {
        customSourceStore.remove(id: id)
        customSources = customSourceStore.sources
    }

    private func chooseCustomSourceFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            customSourceFilePath = url.path
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

#Preview {
    LimitBarSettingsView()
}
