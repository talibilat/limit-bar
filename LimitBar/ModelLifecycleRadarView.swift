import AppKit
import LimitBarCore
import SwiftUI

enum ModelLifecycleAlertSettings {
    static let storageKey = "limitbar.modelLifecycle.retirementAlerts"
}

struct ModelLifecycleRadarView: View {
    let state: LimitBarState

    @AppStorage(ModelLifecycleAlertSettings.storageKey) private var retirementAlertsEnabled = false
    @State private var catalog: ModelLifecycleCatalog?
    @State private var inventory: ModelLifecycleInventorySnapshot?
    @State private var catalogMessage: String?

    private var items: [ModelLifecycleRadarItem] {
        guard let catalog, let inventory else { return [] }
        return ModelLifecycleRadar.items(inventory: inventory.models, catalog: catalog)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Model Lifecycle Radar")
                        .font(.title2.weight(.semibold))
                    Text(inventory.map { "Only models measured in the retained \($0.retentionDays)-day period" } ?? "Loading retained model inventory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let catalog { Text(catalog.catalogVersion).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }

            Toggle("Alert on exact published retirement dates", isOn: $retirementAlertsEnabled)
                .accessibilityIdentifier("model-retirement-alerts")
                .onChange(of: retirementAlertsEnabled) { _, enabled in
                    if enabled { evaluateRetirementAlerts() }
                }

            HStack {
                Button("Load Signed Artifact...") { loadCatalogArtifact() }
                    .accessibilityIdentifier("refresh-model-catalog")
                Button("Install Bundled") { installBundledCatalog() }
                Button("Delete Radar Data", role: .destructive) { deleteCatalogData() }
                    .accessibilityIdentifier("delete-model-catalog")
            }
            Text("Load a downloaded signed catalog artifact or install the bundled official-source-derived fixture. No model inventory, token mix, account, project, or workload data is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let catalogMessage {
                Text(catalogMessage)
                    .font(.caption)
                    .foregroundStyle(catalogMessage.hasPrefix("Could not") ? Color.orange : Color.secondary)
            }

            if catalog == nil {
                Label("Install or load a verified catalog to start", systemImage: "scope")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if inventory == nil {
                ProgressView("Reading retained exact aggregates")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Label("No retained measured models match this catalog", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items, id: \.usage.id) { item in
                            ModelLifecycleRadarRow(item: item)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 620)
        .task { loadStoredCatalogAndInventory() }
    }

    private func loadStoredCatalogAndInventory() {
        guard let store = try? ModelLifecycleCatalogStore.production(verifier: BundledModelLifecycleCatalog.verifier) else { return }
        catalog = try? store.latestCatalog()
        refreshInventory()
    }

    private func refreshInventory() {
        guard let catalog else { inventory = nil; return }
        do {
            inventory = try ModelLifecycleInventoryLoader.production().load(catalog: catalog)
            if retirementAlertsEnabled { evaluateRetirementAlerts() }
        } catch {
            inventory = nil
            catalogMessage = "Could not read retained model aggregates. Usage storage was not modified."
        }
    }

    private func installBundledCatalog() {
        do {
            let store = try ModelLifecycleCatalogStore.production(verifier: BundledModelLifecycleCatalog.verifier)
            catalog = try store.recordCatalog(BundledModelLifecycleCatalog.envelope)
            catalogMessage = "Catalog signature verified. No workload data was sent."
            refreshInventory()
        } catch {
            catalogMessage = "Could not verify or store the catalog. Existing Radar data was left unchanged."
        }
    }

    private func loadCatalogArtifact() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let envelope = try ModelCatalogArtifactLoader.load(from: url)
            let store = try ModelLifecycleCatalogStore.production(verifier: BundledModelLifecycleCatalog.verifier)
            catalog = try store.recordCatalog(envelope)
            catalogMessage = "Selected catalog signature and monotonic revision verified. No workload data was sent."
            refreshInventory()
        } catch {
            catalogMessage = "Could not install the selected catalog. Invalid, stale, or rollback artifacts leave existing Radar data unchanged."
        }
    }

    private func deleteCatalogData() {
        do {
            let store = try ModelLifecycleCatalogStore.production(verifier: BundledModelLifecycleCatalog.verifier)
            try store.deleteAll()
            catalog = nil
            inventory = nil
            catalogMessage = "Catalog history and Calculated Cost scenarios deleted. Usage history was not changed."
        } catch {
            catalogMessage = "Could not delete Radar data. Existing data was left unchanged."
        }
    }

    private func evaluateRetirementAlerts() {
        let currentItems = items
        guard !currentItems.isEmpty else { return }
        Task { await state.alertCoordinator.evaluateRetirements(currentItems) }
    }
}

private struct ModelLifecycleRadarRow: View {
    let item: ModelLifecycleRadarItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(item.usage.observedModelID).font(.headline)
                Spacer()
                Text(item.lifecycle.status.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.lifecycle.status == .deprecated || item.lifecycle.status == .retired ? Color.orange : Color.secondary)
            }
            Text(item.lifecycle.identity.platform.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let retirement = item.lifecycle.retirementDate {
                Text("Exact published retirement: \(retirement.description)")
                    .font(.callout.weight(.medium))
            } else if item.lifecycle.status == .deprecated || item.lifecycle.status == .retired {
                Text("Retirement date unavailable for this platform")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let replacement = item.lifecycle.replacement {
                Text("Documented replacement: \(replacement.modelID)")
                    .font(.callout)
            }
            switch item.scenario {
            case let .calculated(scenario):
                Text("Calculated Cost: \(scenario.currencyCode) \(scenario.minimumCost.description) - \(scenario.maximumCost.description)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
            case let .unavailable(reasons):
                Text("Calculated Cost unavailable: \(reasons.first?.displayText ?? "Required pricing evidence is unavailable.")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(reasons.map(\.displayText).joined(separator: "\n"))
            }
            Link("Official lifecycle source", destination: item.lifecycle.lifecycleSource.url)
                .font(.caption)
            ModelReplacementScenarioEditor(item: item)
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ModelReplacementScenarioEditor: View {
    let item: ModelLifecycleRadarItem

    @State private var modifiers: [PricingModifier: PricingModifierEvidence]
    @State private var quantities: [ModelPriceDimension: String]
    @State private var resultMessage: String?

    init(item: ModelLifecycleRadarItem) {
        self.item = item
        _modifiers = State(initialValue: Dictionary(uniqueKeysWithValues: PricingModifier.allCases.map { ($0, .unknown) }))
        _quantities = State(initialValue: [.input: String(item.usage.tokenUsage.inputTokens), .output: String(item.usage.tokenUsage.outputTokens)])
    }

    var body: some View {
        DisclosureGroup("Configure replacement scenario") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Every modifier starts Unknown. Choose Yes or No explicitly; Yes also requires its billable quantities.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if selectedAlternateMode == nil {
                    TextField("Standard or uncached input tokens", text: quantityBinding(for: .input)).textFieldStyle(.roundedBorder)
                    TextField("Standard output tokens", text: quantityBinding(for: .output)).textFieldStyle(.roundedBorder)
                }
                ForEach(PricingModifier.allCases, id: \.self) { modifier in
                    HStack {
                        Text(modifier.displayName)
                        Spacer()
                        Picker(modifier.displayName, selection: binding(for: modifier)) {
                            ForEach([PricingModifierEvidence.unknown, .notUsed, .used], id: \.self) { evidence in
                                Text(evidence.displayName).tag(evidence)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    if modifiers[modifier] == .used {
                        ForEach(modifier.quantityDimensions, id: \.self) { dimension in
                            TextField(dimension.displayName, text: quantityBinding(for: dimension)).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                Button("Calculate And Save Frozen Scenario") { calculateAndSave() }
                    .disabled(modifiers.values.contains(.unknown))
                    .accessibilityIdentifier("calculate-model-replacement-scenario")
                if let resultMessage {
                    Text(resultMessage)
                        .font(.caption)
                        .foregroundStyle(resultMessage.hasPrefix("Calculated Cost saved") ? Color.blue : Color.orange)
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    private func binding(for modifier: PricingModifier) -> Binding<PricingModifierEvidence> {
        Binding(get: { modifiers[modifier] ?? .unknown }, set: { modifiers[modifier] = $0 })
    }

    private func quantityBinding(for dimension: ModelPriceDimension) -> Binding<String> {
        Binding(get: { quantities[dimension] ?? "" }, set: { quantities[dimension] = $0 })
    }

    private func calculateAndSave() {
        guard let store = try? ModelLifecycleCatalogStore.production(verifier: BundledModelLifecycleCatalog.verifier),
              let catalog = try? store.latestCatalog() else {
            resultMessage = "Calculated Cost unavailable: verified catalog storage is unavailable."
            return
        }
        var frozen: [ModelPriceDimension: Int] = [:]
        let alternate = selectedAlternateMode
        for dimension in alternate?.quantityDimensions ?? [.input, .output] {
            if let value = quantities[dimension].flatMap(Int.init) { frozen[dimension] = value }
        }
        for modifier in PricingModifier.allCases where modifiers[modifier] == .used && modifier != alternate {
            for dimension in modifier.quantityDimensions {
                if let value = quantities[dimension].flatMap(Int.init) { frozen[dimension] = value }
            }
        }
        let workload = FrozenReplacementWorkload(
            periodStart: item.usage.workloadPeriod.start,
            periodEnd: item.usage.workloadPeriod.end,
            quantities: frozen,
            modifiers: modifiers
        )
        switch ReplacementCostScenarioCalculator.calculate(record: item.lifecycle, workload: workload, catalog: catalog, at: Date()) {
        case let .calculated(scenario):
            do {
                try store.recordScenario(scenario)
                resultMessage = "Calculated Cost saved: \(scenario.currencyCode) \(scenario.minimumCost.description) - \(scenario.maximumCost.description)."
            } catch {
                resultMessage = "Calculated Cost was complete but could not be persisted."
            }
        case let .unavailable(reasons):
            resultMessage = "Calculated Cost unavailable: \(reasons.map(\.displayText).joined(separator: " "))"
        }
    }

    private var selectedAlternateMode: PricingModifier? {
        [PricingModifier.longContext, .batch, .flex, .priority, .regionalProcessing].first { modifiers[$0] == .used }
    }
}

struct ModelLifecycleRadarCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Radar") {
            Button("Open Model Lifecycle Radar") { openWindow(id: "model-lifecycle-radar") }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }
}
