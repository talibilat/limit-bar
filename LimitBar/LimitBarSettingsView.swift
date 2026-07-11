import SwiftUI
import LimitBarCore
import AppKit

struct LimitBarSettingsView: View {
    private let pricingStore = PricingSettingsStore()
    private let azureJSONLPath = (try? AzureUsageEventImporter.usageEventsURL().path) ?? "Unavailable"

    @State private var storedMetrics: StoredUsageMetricsSnapshot?
    @State private var providerSettings = ProviderSettingsStore().settings
    @State private var provider = ProviderKind.openAI
    @State private var modelLabel = "gpt-5.1-codex"
    @State private var inputPrice = ""
    @State private var outputPrice = ""
    @State private var currencyCode = "USD"
    @State private var effectiveAt = Date()
    @State private var pricingEntries = PricingSettingsStore().entries
    @State private var azureRevealMessage: String?

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
                    LabeledContent("Azure JSONL imported", value: "\(storedMetrics.azureImport.validEventCount)")
                    LabeledContent("Azure malformed events", value: "\(storedMetrics.azureImport.malformedEventCount)")
                    if storedMetrics.azureImport.failureMessage != nil {
                        LabeledContent("Azure import status", value: AzureImportDiagnosticState.failed.displayText)
                    }
                    ForEach(storedMetrics.azureImport.malformedEvents, id: \.lineNumber) { event in
                        Text("Line \(event.lineNumber): \(event.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Loading diagnostics")
                }
            }

            Section("Azure OpenAI Integration") {
                Text("Append confirmed response usage events to this local JSONL file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(azureJSONLPath)
                    .font(.caption)
                    .textSelection(.enabled)
                Button("Reveal JSONL in Finder") {
                    revealAzureJSONLPath()
                }
                if let azureRevealMessage {
                    Text(azureRevealMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
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
            storedMetrics = await StoredUsageMetricsLoader.shared.loadFromApplicationSupport()
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

    private func revealAzureJSONLPath() {
        guard let url = try? AzureUsageEventImporter.usageEventsURL() else {
            azureRevealMessage = "Could not resolve the Azure JSONL path."
            return
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            azureRevealMessage = nil
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(directory)
            }
        } catch {
            azureRevealMessage = "Could not create the Azure JSONL directory."
        }
    }
}

#Preview {
    LimitBarSettingsView()
}
