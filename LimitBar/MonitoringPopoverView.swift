import SwiftUI
import LimitBarCore

struct MonitoringPopoverView: View {
    private enum PopoverTab: String, CaseIterable {
        case usage
        case claudeLimits

        var displayName: String {
            switch self {
            case .usage:
                "Usage"
            case .claudeLimits:
                "Claude Limits"
            }
        }
    }

    @State private var selectedTab = PopoverTab.usage
    @State private var selectedWindow = TimeWindow.defaultSelection
    @State private var metrics: [UsageMetric] = []
    @State private var storeHealth = UsageStoreHealth(isOpen: false, message: "Loading SQLite store")
    @State private var localImport = LocalUsageImportResult.empty(fileURL: URL(fileURLWithPath: ""))
    @AppStorage(PricingSettingsStore.storageKey) private var pricingJSON = PricingSettingsStore.defaultJSON
    @State private var providerSettings = ProviderSettingsStore().settings

    private var cards: [ProviderUsageCard] {
        ProviderUsageCard.cards(from: metrics, timeWindow: selectedWindow)
    }

    private var pricingTable: PricingTable {
        PricingSettingsStore.table(from: pricingJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Picker("Tab", selection: $selectedTab) {
                ForEach(PopoverTab.allCases, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .usage:
                usageTab
            case .claudeLimits:
                ClaudeRateLimitsView()
            }

            HStack {
                if selectedTab == .usage {
                    Text(localImportStatusText)
                        .font(.footnote)
                        .foregroundStyle(localImport.failureMessage == nil && localImport.malformedEventCount == 0 ? Color.secondary : Color.orange)
                }

                Spacer()

                SettingsLink {
                    Text("Settings")
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 600, alignment: .topLeading)
        .task {
            await loadStoredMetrics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerSettingsDidChange)) { _ in
            providerSettings = ProviderSettingsStore().settings
            Task { await loadStoredMetrics() }
        }
    }

    @ViewBuilder
    private var usageTab: some View {
        Picker("Time window", selection: $selectedWindow) {
            ForEach(TimeWindow.allCases, id: \.self) { window in
                Text(window.displayName).tag(window)
            }
        }
        .pickerStyle(.segmented)

        ScrollView {
            VStack(spacing: 12) {
                ForEach(cards, id: \.provider) { card in
                    ProviderUsageCardView(card: card, selectedWindow: selectedWindow, pricingTable: pricingTable, providerState: providerSettings.first { $0.provider == card.provider }?.state)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LimitBar")
                .font(.title2.weight(.semibold))
            Text("Confirmed usage across connected providers")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !storeHealth.isOpen {
                Text(storeHealth.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var localImportStatusText: String {
        if localImport.failureMessage != nil {
            return "Local events: Import failed"
        }
        return "Local events: \(localImport.validEventCount) imported, \(localImport.malformedEventCount) malformed"
    }

    private func loadStoredMetrics() async {
        let snapshot = await StoredUsageMetricsLoader.shared.loadFromApplicationSupport()
        metrics = snapshot.metrics
        storeHealth = snapshot.health
        localImport = snapshot.localImport
        providerSettings = ProviderSettingsStore().settings
    }
}

private struct ProviderUsageCardView: View {
    let card: ProviderUsageCard
    let selectedWindow: TimeWindow
    let pricingTable: PricingTable
    let providerState: ProviderConnectionState?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.provider.displayName)
                    .font(.headline)
                Spacer()
                Text(badgeText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if card.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                if providerState == .unsupported || providerState == .adminRequired || providerState == .expired || providerState == .failed {
                    Text(providerState?.displayText ?? "Unavailable")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                VStack(spacing: 10) {
                    ForEach(Array(card.metrics.enumerated()), id: \.offset) { _, metric in
                        MetricRowView(metric: metric, pricingTable: pricingTable)
                    }
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private var emptyMessage: String {
        if providerState == .unsupported || providerState == .adminRequired || providerState == .expired || providerState == .failed {
            return providerState?.displayText ?? "Unsupported"
        }
        return "No usage for \(selectedWindow.displayName)."
    }

    private var badgeText: String {
        if card.metrics.contains(where: { $0.freshness.isStale }) { return "Stale" }
        if let providerState, providerState != .missing { return providerState.displayText }
        return card.isEmpty ? "Not configured" : "Confirmed"
    }
}

private struct MetricRowView: View {
    let metric: UsageMetric
    let pricingTable: PricingTable

    private var cost: Cost? {
        CostCalculator.cost(for: metric, pricing: pricingTable)
    }

    private var metadata: String {
        [
            metric.accountLabel,
            metric.projectLabel,
            metric.deploymentLabel.map { "Deployment: \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric.modelLabel)
                    .font(.subheadline.weight(.semibold))
                if metric.freshness.isStale {
                    Text("Stale")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.14), in: Capsule())
                }
                Spacer()
            }

            if !metadata.isEmpty {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if metric.tokenUsage.totalTokens > 0 {
                HStack(spacing: 8) {
                    TokenPill(title: "In", value: metric.tokenUsage.inputTokens)
                    TokenPill(title: "Out", value: metric.tokenUsage.outputTokens)
                    TokenPill(title: "Total", value: metric.tokenUsage.totalTokens)
                }
            }

            Text(metric.limitStatus.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let cost {
                Text("\(cost.currencyCode) \(cost.amount.description) · \(cost.source.displayLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(cost.source == .providerReported ? Color.secondary : Color.blue)
            }
        }
        .padding(10)
        .background(metric.freshness.isStale ? .orange.opacity(0.08) : .secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TokenPill: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview {
    MonitoringPopoverView()
}
