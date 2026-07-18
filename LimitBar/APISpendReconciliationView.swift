import AppKit
import LimitBarCore
import SwiftUI

extension Notification.Name {
    static let apiSpendReconciliationDidChange = Notification.Name("limitbar.apiSpendReconciliationDidChange")
}

struct APISpendReconciliationView: View {
    @State private var rows: [SpendReconciliationRow] = []
    @State private var revisions: [SpendRevision] = []
    @State private var message: String?
    @State private var csv: SpendCSVArtifact?
    @State private var confirmsDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anthropic API Spend Reconciliation")
                .font(.headline)
            Text("Provider-Reported Cost is authoritative for each exact provider bucket. Observed Local Breakdown uses Calculated Cost only as non-additive explanatory evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                ContentUnavailableView("No Reconciliation", systemImage: "arrow.triangle.2.circlepath", description: Text("Run an explicit Anthropic Validate & Refresh after configuring local pricing and schema v2 project or agent events."))
            } else {
                Table(rows, columns: {
                    TableColumn("Window") { row in Text(row.providerBucket.window.start.formatted(date: .abbreviated, time: .omitted)) }
                    TableColumn("Group") { row in Text(groupLabel(row.providerBucket.dimensions)) }
                    TableColumn("Provider-Reported") { row in Text(money(row.providerBucket.amount, row.providerBucket.currencyCode)) }
                    TableColumn("Attributed Provider-Reported") { row in Text(money(row.attributedProviderReportedCost, row.providerBucket.currencyCode)) }
                    TableColumn("Observed Local Calculated") { row in Text(money(row.observedLocalCalculatedCost, row.providerBucket.currencyCode)) }
                    TableColumn("Unattributed Provider-Reported") { row in Text(money(row.unattributedProviderReportedCost, row.providerBucket.currencyCode)) }
                    TableColumn("Status") { row in
                        VStack(alignment: .leading) {
                            Text(row.status.rawValue.capitalized)
                            if !row.barriers.isEmpty {
                                Text(row.barriers.map(\.rawValue).sorted().joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                })
                .frame(minHeight: 220)
            }

            if let latest = revisions.last {
                LabeledContent("Latest revision", value: "#\(latest.id) at \(latest.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                LabeledContent("Frozen pricing revision", value: latest.conclusion.pricingRevision)
                LabeledContent("Frozen local evidence", value: latest.conclusion.localEvidenceIdentity.map { "\($0.eventCount) events / \($0.evidenceDigest.prefix(12))" } ?? "Unavailable")
                Text("Late provider corrections append a revision and supersede the prior conclusion. They do not rewrite it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Revision History (\(revisions.count))") {
                ForEach(revisions.reversed(), id: \.id) { revision in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Revision #\(revision.id) - \(revision.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption.bold())
                        Text("Pricing \(revision.conclusion.pricingRevision); local evidence \(revision.conclusion.localEvidenceIdentity?.evidenceDigest.prefix(12) ?? "unavailable")")
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(Array(revision.drifts.enumerated()), id: \.offset) { _, drift in
                            Text("\(groupLabel(drift.bucket.dimensions)): provider \(drift.providerReportedChange.description), attributed \(drift.attributedChange.description), local \(drift.observedLocalChange.description), unattributed \(drift.unattributedChange.description) \(drift.bucket.currencyCode)")
                                .font(.caption2)
                        }
                    }
                }
            }

            HStack {
                Button("Preview CSV") { csv = SpendCSVArtifact.make(rows: rows) }
                    .disabled(rows.isEmpty)
                Button("Delete Reconciliation Data", role: .destructive) { confirmsDeletion = true }
                    .disabled(revisions.isEmpty)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(message.hasPrefix("Could not") ? Color.orange : Color.secondary)
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .apiSpendReconciliationDidChange)) { _ in Task { await load() } }
        .sheet(item: $csv) { artifact in CSVPreviewSheet(artifact: artifact) }
        .confirmationDialog("Delete API spend reconciliation revisions?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Reconciliation Data", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes only sanitized reconciliation revisions. Usage, project and agent attribution, provider settings, pricing, and Keychain credentials remain unchanged.")
        }
    }

    private func load() async {
        do {
            let store = try SQLiteAPISpendReconciliationStore.applicationSupportStore()
            let loaded = try store.revisions()
            revisions = loaded
            rows = loaded.last?.conclusion.rows ?? []
            message = nil
        } catch {
            message = "Could not load API spend reconciliation data. Existing data was left unchanged."
        }
    }

    private func deleteAll() {
        do {
            try SQLiteAPISpendReconciliationStore.applicationSupportStore().deleteAll()
            rows = []; revisions = []
            message = "API spend reconciliation data deleted independently."
        } catch { message = "Could not delete API spend reconciliation data." }
    }

    private func groupLabel(_ dimensions: SpendDimensions) -> String {
        [dimensions.model, dimensions.workspaceAlias, dimensions.apiKeyAlias, dimensions.serviceTier, dimensions.tokenClass == .unavailable ? nil : dimensions.tokenClass.rawValue]
            .compactMap { $0 }.joined(separator: " / ").nilIfEmpty ?? "Unmapped provider dimensions"
    }

    private func money(_ amount: Decimal, _ currency: String) -> String { "\(amount.description) \(currency)" }
}

private struct CSVPreviewSheet: View {
    let artifact: SpendCSVArtifact
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CSV Preview").font(.headline)
            Text("Schema v\(SpendCSVArtifact.schemaVersion). Only the fixed allow-listed aliased fields shown below will be saved locally after explicit confirmation.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: .constant(artifact.preview)).font(.system(.caption, design: .monospaced)).frame(minWidth: 760, minHeight: 360)
            HStack {
                Button("Cancel") { dismiss() }
                Button("Save CSV") { save() }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }.padding(20)
    }

    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "anthropic-spend-reconciliation-v1.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try artifact.data.write(to: url, options: .atomic); dismiss() }
        catch { message = "Could not save CSV." }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

extension SpendCSVArtifact: @retroactive Identifiable { public var id: Data { data } }
