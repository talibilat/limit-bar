import SwiftUI
import LimitBarCore

struct MonitoringPopoverView: View {
    let state: LimitBarState
    private enum PopoverTab: String, CaseIterable {
        case rateLimit
        case usage

        var displayName: String {
            switch self {
            case .rateLimit:
                "Rate Limit"
            case .usage:
                "Usage"
            }
        }
    }

    @State private var selectedTab = PopoverTab.rateLimit
    @State private var selectedWindow = TimeWindow.defaultSelection
    @AppStorage(PricingSettingsStore.storageKey) private var pricingJSON = PricingSettingsStore.defaultJSON

    private var cards: [ProviderUsageCard] {
        let configured = Set(state.providerSettings.filter { $0.state != .missing }.map(\.provider))
        return ProviderUsageCard.cards(from: state.local.metrics, timeWindow: selectedWindow, configuredProviders: configured)
    }

    private var pricingTable: PricingTable {
        PricingSettingsStore.table(from: pricingJSON)
    }

    private var utcBillingWeek: UTCBillingWeekPresentation? {
        UTCBillingWeekPresentation.from(metrics: state.local.metrics)
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
            case .rateLimit:
                RateLimitView(state: state, pricingTable: pricingTable)
            case .usage:
                usageTab
            }

            HStack {
                if selectedTab == .usage {
                    Text(localImportStatusText + customImportStatusText)
                        .font(.footnote)
                        .foregroundStyle(state.local.localImport.failureMessage == nil && state.local.localImport.malformedEventCount == 0 && state.local.customImportFailures == 0 && state.local.customRejectedLines == 0 ? Color.secondary : Color.orange)
                }

                Spacer()

                SettingsLink {
                    Text("Settings")
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 600, alignment: .topLeading)
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
                    ProviderUsageCardView(card: card, selectedWindow: selectedWindow, pricingTable: pricingTable, providerState: state.providerSettings.first { $0.provider == card.provider }?.state)
                }
                if let utcBillingWeek {
                    UTCBillingWeekView(presentation: utcBillingWeek, pricingTable: pricingTable)
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
            if !state.local.storeHealth.isOpen {
                Text(state.local.storeHealth.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var localImportStatusText: String {
        if state.local.localImport.failureMessage != nil {
            return "Local events: Import failed"
        }
        return "Local events: \(state.local.localImport.validEventCount) imported, \(state.local.localImport.malformedEventCount) malformed"
    }

    private var customImportStatusText: String {
        var parts: [String] = []
        if state.local.customImportFailures > 0 { parts.append("\(state.local.customImportFailures) failed") }
        if state.local.customRejectedLines > 0 { parts.append("\(state.local.customRejectedLines) malformed") }
        return parts.isEmpty ? "" : " · Custom sources: " + parts.joined(separator: ", ")
    }

}

private struct UTCBillingWeekView: View {
    let presentation: UTCBillingWeekPresentation
    let pricingTable: PricingTable

    private var intervalText: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: presentation.interval.start)) - \(formatter.string(from: presentation.interval.end)) UTC"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.title)
                .font(.headline)
            Text(intervalText)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(presentation.metrics.enumerated()), id: \.offset) { _, metric in
                MetricRowView(metric: metric, pricingTable: pricingTable)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary, lineWidth: 1))
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

            if metric.showsLimitStatus {
                Text(metric.limitStatus.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
    MonitoringPopoverView(state: .shared)
}
