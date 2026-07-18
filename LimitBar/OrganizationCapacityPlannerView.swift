import AppKit
import LimitBarCore
import SwiftUI
import UniformTypeIdentifiers

struct OrganizationPlannerSettingsLink: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Organization Mode") {
            Text("Disabled by default. Uses only manually selected, administrator-reviewed daily aggregate files. It never requests organization API credentials or makes organization network requests.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Team Capacity Planner") { openWindow(id: "team-capacity-planner") }
                .accessibilityIdentifier("open-team-capacity-planner")
        }
    }
}

struct OrganizationCapacityPlannerView: View {
    @State private var settings = OrganizationModeSettingsStore()
    @State private var isEnabled = OrganizationModeSettingsStore().isEnabled
    @State private var acknowledgesGovernanceRisk = false
    @State private var store: SQLiteOrganizationCapacityStore?
    @State private var aggregates: [OrganizationDailyAggregate] = []
    @State private var provenances: [OrganizationImportProvenance] = []
    @State private var diagnostics: OrganizationStorageDiagnostics?
    @State private var retentionDays = 90
    @State private var shiftFraction = 0.25
    @State private var message: String?
    @State private var showsDeleteConfirmation = false
    @State private var deletionRecoveryStage: OrganizationDeletionStage?

    private var summary: OrganizationCapacitySummary? {
        try? OrganizationCapacityCalculator.summary(aggregates: aggregates, provenances: provenances)
    }

    private var scenarios: [OrganizationScheduleShiftScenario] {
        (try? OrganizationCapacityCalculator.scheduleShiftScenarios(aggregates: aggregates, shiftFraction: shiftFraction)) ?? []
    }

    var body: some View {
        Group {
            if isEnabled { planner } else { consent }
        }
        .frame(minWidth: 720, minHeight: 700)
        .task { if isEnabled { loadStore() } }
        .confirmationDialog("Delete all organization data?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Organization Data", role: .destructive) { deleteOrganizationData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This securely deletes organization aggregates, import provenance, SQLite sidecars, and the alias key. Personal usage, quota, alert, credential, settings, and diagnostic state are not changed.")
        }
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Team Capacity Planner", systemImage: "person.3.sequence")
                .font(.largeTitle.bold())
            Text("Validation-first organization mode")
                .font(.title3)
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Organization aggregates can still be employee data. Confirm your organization has approved this local analysis and that the selected file was reviewed by an administrator.")
                    Text("LimitBar rejects direct identifiers and arbitrary fields, aliases team identities before separate database persistence, suppresses cohorts below five, and exposes no individual rankings or drill-down.")
                    Text("No organization API, network request, API credential, prompt, source code, transcript, path, or raw actor identifier is used.")
                    Toggle("I acknowledge the employee-data governance risk and have approval to import administrator-reviewed aggregates.", isOn: $acknowledgesGovernanceRisk)
                        .accessibilityIdentifier("organization-governance-consent")
                }
            }
            HStack {
                Spacer()
                Button("Enable Organization Mode") {
                    if settings.enable(acknowledged: acknowledgesGovernanceRisk) {
                        isEnabled = true
                        loadStore()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!acknowledgesGovernanceRisk)
                .accessibilityIdentifier("enable-organization-mode")
            }
        }
        .padding(32)
    }

    private var planner: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(message.hasPrefix("Could not") || message.hasPrefix("Rejected") ? .orange : .secondary)
                        .accessibilityIdentifier("organization-planner-message")
                }
                capacitySection
                costSection
                scenarioSection
                governanceSection
            }
            .padding(28)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("Team Capacity Planner").font(.largeTitle.bold())
                    Text("Privacy-safe daily distributions from local administrator-reviewed files")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import Daily Aggregates...", action: importFile)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("organization-import")
            }
            Text("No organization API connection or credential exists in this mode. Team identities are irreversibly aliased per installation before persistence; aliases and individual records are never displayed or exported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var capacitySection: some View {
        GroupBox("Supported Capacity Evidence") {
            if aggregates.isEmpty {
                ContentUnavailableView("No Supported Aggregates", systemImage: "chart.bar.xaxis", description: Text("Import a completed UTC daily aggregate file using schema limitbar.organization.daily.v1."))
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else if let summary {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(summary.providers, id: \.providerProduct) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(productName(provider.providerProduct)).font(.headline)
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                                metricRow("Blocked-capacity days", value: provider.blockedCapacityDays.map { "\($0.count)" } ?? "Unsupported by source")
                                metricRow("Daily top-team usage share", value: distribution(provider.dailyTopTeamShare, percent: true))
                                metricRow("Daily team concentration index", value: distribution(provider.dailyConcentrationIndex, percent: false))
                                metricRow("Cache efficiency", value: distribution(provider.cacheEfficiency, percent: true))
                                metricRow("Peak concurrency", value: distribution(provider.peakConcurrency, percent: false))
                                metricRow("Repeated near-exhaustion share", value: distribution(provider.repeatedNearExhaustionShare, percent: true))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Unsafe organization aggregates were rejected before presentation.").foregroundStyle(.orange)
            }
        }
    }

    private var costSection: some View {
        GroupBox("Separate Cost Subjects") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Subscription quota is capacity evidence, not spend. Seat cost and API overflow cost are never summed; Provider-Reported Cost and Calculated Cost remain distinct.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let costs = summary?.providers.flatMap(\.costs) ?? []
                if costs.isEmpty {
                    Text("No supported cost evidence in imported files.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(costs.enumerated()), id: \.offset) { _, cost in
                        LabeledContent(costLabel(cost), value: "\(cost.currency) \(cost.amount.description)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scenarioSection: some View {
        GroupBox("Bounded Schedule-Shift Scenario") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Move \(Int(shiftFraction * 100))% of supported scheduled peak work")
                    Slider(value: $shiftFraction, in: 0...0.5, step: 0.05)
                }
                if !scenarios.isEmpty {
                    ForEach(scenarios, id: \.providerProduct) { scenario in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(productName(scenario.providerProduct)).font(.headline)
                            Text("Plausible blocked-time reduction range: \(scenario.possibleBlockedMinutesReductionLowerBound)-\(scenario.possibleBlockedMinutesReductionUpperBound) minutes across supported observations.")
                            ForEach(scenario.assumptions, id: \.self) { Text("Assumption: \($0)").font(.caption) }
                            Text(scenario.limitation).font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Text("Unavailable. Supported scheduled-peak blocked minutes and off-peak available minutes must both be present.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var governanceSection: some View {
        GroupBox("Organization Data Boundary") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Retention, deletion, migration validation, diagnostics, and export are isolated from all personal LimitBar databases and credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Retention", selection: $retentionDays) {
                    ForEach(SQLiteOrganizationCapacityStore.supportedRetentionDays, id: \.self) { Text("\($0) days").tag($0) }
                }
                .onChange(of: retentionDays) { _, days in setRetention(days) }
                if let diagnostics {
                    LabeledContent("Organization database schema", value: "v\(diagnostics.schemaVersion)")
                    LabeledContent("Imported files retained", value: "\(diagnostics.importCount)")
                    LabeledContent("Daily aggregates retained", value: "\(diagnostics.aggregateCount)")
                    LabeledContent("Cohort threshold", value: "\(OrganizationDailyAggregateImporter.privacyThreshold)")
                    LabeledContent("Suppressed records observed", value: "\(summary?.suppressedRecordCount ?? 0)")
                }
                HStack {
                    Button("Export Distribution Report...", action: exportReport).disabled(aggregates.isEmpty)
                    Button("Delete Organization Data", role: .destructive) { showsDeleteConfirmation = true }
                    if deletionRecoveryStage != nil {
                        Button("Retry Secure Deletion", action: recoverOrganizationDeletion)
                    }
                    Spacer()
                    Button("Disable Organization Mode") {
                        settings.disable()
                        isEnabled = false
                        store = nil
                        aggregates = []
                        provenances = []
                    }
                }
                Text("Activity, tokens, sessions, code output, and tool acceptance are never interpreted as productivity, quality, performance, or developer value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func metricRow(_ title: String, value: String) -> some View {
        GridRow {
            Text(title)
            Text(value).foregroundStyle(value == "Unsupported by source" ? .secondary : .primary)
        }
    }

    private func distribution(_ value: OrganizationMetricDistribution?, percent: Bool) -> String {
        guard let value else { return "Unsupported by source" }
        let scale = percent ? 100.0 : 1.0
        let suffix = percent ? "%" : ""
        return "min \((value.minimum * scale).formatted(.number.precision(.fractionLength(0...2))))\(suffix), median \((value.median * scale).formatted(.number.precision(.fractionLength(0...2))))\(suffix), max \((value.maximum * scale).formatted(.number.precision(.fractionLength(0...2))))\(suffix) (n=\(value.sampleCount))"
    }

    private func costLabel(_ cost: OrganizationCostSummary) -> String {
        let subject = cost.subject == .subscriptionSeatCost ? "Seat cost" : "API overflow cost"
        let provenance = cost.provenance == .providerReported ? "Provider-Reported Cost" : "Calculated Cost"
        let product = cost.providerProduct == .claudeCode ? "Claude Code" : "Codex"
        return "\(product) \(subject) - \(provenance)"
    }

    private func productName(_ product: OrganizationProviderProduct) -> String {
        product == .claudeCode ? "Claude Code" : "Codex"
    }

    private func loadStore() {
        do {
            try settings.withEnabledAccess {}
            let locations = try LimitBarFileLocations.production()
            let coordinator = deletionCoordinator(locations: locations)
            if let pending = coordinator.pendingStage {
                deletionRecoveryStage = pending
                message = "Organization deletion requires recovery before storage can be used. Retry secure deletion; no completion is being claimed."
                return
            }
            let opened = try SQLiteOrganizationCapacityStore.applicationSupportStore()
            store = opened
            deletionRecoveryStage = nil
            retentionDays = try opened.retentionDays()
            refresh(opened)
        } catch {
            message = "Could not open isolated organization storage. Existing data was left unchanged."
        }
    }

    private func refresh(_ opened: SQLiteOrganizationCapacityStore? = nil) {
        guard let opened = opened ?? store else { return }
        do {
            aggregates = try opened.aggregates()
            provenances = try opened.provenances()
            diagnostics = try opened.diagnostics()
        } catch {
            message = "Could not read isolated organization storage. Existing data was left unchanged."
        }
    }

    private func importFile() {
        guard (try? settings.withEnabledAccess({ true })) == true else {
            message = "Organization mode requires explicit governance consent before import."
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let store else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= OrganizationDailyAggregateImporter.maximumFileSize else {
                throw OrganizationCapacityError.malformedFile
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let locations = try LimitBarFileLocations.production()
            let aliaser = try OrganizationTeamAliasKeyFile(url: locations.organizationAliasKey).loadOrCreate()
            let batch = try OrganizationDailyAggregateImporter.importData(data, aliaser: aliaser)
            try store.record(batch)
            refresh(store)
            message = "Imported \(batch.provenance.acceptedRecordCount) daily aggregates; suppressed \(batch.provenance.suppressedRecordCount) records below the cohort threshold."
        } catch OrganizationCapacityError.duplicateImport {
            message = "Rejected duplicate import. No organization data changed."
        } catch OrganizationCapacityError.duplicateRecord {
            message = "Rejected overlapping daily aggregates. No organization data changed."
        } catch {
            message = "Rejected file. It must be an administrator-reviewed, completed UTC daily aggregate using the exact supported schema and no identifying or arbitrary fields."
        }
    }

    private func setRetention(_ days: Int) {
        do {
            try store?.setRetentionDays(days)
            refresh()
            message = "Organization retention updated independently of personal data."
        } catch {
            message = "Could not update organization retention."
        }
    }

    private func exportReport() {
        do {
            let data = try OrganizationCapacityExporter.make(
                aggregates: aggregates,
                provenances: provenances,
                shiftFraction: scenarios.isEmpty ? nil : shiftFraction
            )
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "limitbar-team-capacity-distributions.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            message = "Exported a suppression-safe distribution report with no team aliases or individual records."
        } catch {
            message = "Could not export the organization distribution report."
        }
    }

    private func deleteOrganizationData() {
        do {
            guard let store else { return }
            let locations = try LimitBarFileLocations.production()
            applyDeletionOutcome(deletionCoordinator(locations: locations).delete(using: store))
        } catch {
            message = "Could not start secure organization deletion. No completion is being claimed, and personal LimitBar state was not changed."
        }
    }

    private func recoverOrganizationDeletion() {
        do {
            let locations = try LimitBarFileLocations.production()
            let recoveryStore = try SQLiteOrganizationCapacityStore(path: locations.organizationCapacityDatabase.path)
            applyDeletionOutcome(deletionCoordinator(locations: locations).delete(using: recoveryStore))
        } catch {
            message = "Organization deletion still requires recovery. No completion is being claimed, and personal LimitBar state was not changed."
        }
    }

    private func applyDeletionOutcome(_ outcome: OrganizationDeletionOutcome) {
        switch outcome {
        case .complete:
            store = nil
            aggregates = []
            provenances = []
            diagnostics = nil
            deletionRecoveryStage = nil
            message = "Organization aggregates, import provenance, SQLite sidecars, and alias key were securely deleted. Personal LimitBar state was not changed."
            loadStore()
        case .notStarted:
            message = "Could not start secure organization deletion. Organization data remains available and no completion is being claimed."
        case let .recoveryRequired(stage):
            store = nil
            aggregates = []
            provenances = []
            diagnostics = nil
            deletionRecoveryStage = stage
            message = "Organization deletion partially completed and requires recovery. Retry secure deletion; no completion is being claimed. Personal LimitBar state was not changed."
        }
    }

    private func deletionCoordinator(locations: LimitBarFileLocations) -> OrganizationDataDeletionCoordinator {
        OrganizationDataDeletionCoordinator(
            databaseURL: locations.organizationCapacityDatabase,
            aliasKeyURL: locations.organizationAliasKey,
            markerURL: locations.organizationDeletionMarker
        )
    }
}
