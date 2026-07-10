import SwiftUI
import LimitBarCore

struct LimitBarSettingsView: View {
    private let storeHealth = StoredUsageMetrics.loadFromApplicationSupport().health
    private let pricingStore = PricingSettingsStore()

    @State private var provider = ProviderKind.openAI
    @State private var modelLabel = "gpt-5.1-codex"
    @State private var inputPrice = ""
    @State private var outputPrice = ""
    @State private var currencyCode = "USD"
    @State private var effectiveAt = Date()
    @State private var pricingEntries = PricingSettingsStore().entries

    private var canSavePricing: Bool {
        guard let input = Decimal(string: inputPrice), let output = Decimal(string: outputPrice) else {
            return false
        }

        return !modelLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && input >= 0
            && output >= 0
    }

    var body: some View {
        Form {
            Section("Setup") {
                Text("Provider settings will be configured in a later issue.")
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Usage database", value: storeHealth.message)
            }

            Section("Pricing") {
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
        .frame(width: 520, height: 520)
    }

    private func savePricing() {
        guard canSavePricing, let input = Decimal(string: inputPrice), let output = Decimal(string: outputPrice) else {
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
}

#Preview {
    LimitBarSettingsView()
}
