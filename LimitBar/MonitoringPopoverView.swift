import SwiftUI
import LimitBarCore
import Charts

struct MonitoringPopoverView: View {
    let state: LimitBarState
    private enum PopoverTab: String, CaseIterable {
        case rateLimit
        case analysis
        case usage
        case history

        var displayName: String {
            switch self {
            case .rateLimit:
                "Rate Limit"
            case .analysis:
                "Analysis"
            case .usage:
                "Usage"
            case .history:
                "History"
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
            case .analysis:
                RateLimitAnalysisView(state: state)
            case .usage:
                usageTab
            case .history:
                HistoricalUsageView(snapshot: state.local.history)
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
                .accessibilityIdentifier("settings-action")
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
                .accessibilityIdentifier("app-title")
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

private struct HistoricalUsageView: View {
    let snapshot: HistoricalUsageSnapshot

    private var presentation: HistoricalUsageChartPresentation {
        HistoricalUsageChartPresentation(dailyBuckets: snapshot.dailyBuckets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last \(presentation.buckets.count) days")
                .font(.headline)

            if !snapshot.health.isOpen {
                Text(snapshot.health.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if presentation.points.isEmpty {
                Label("No observed usage in this range", systemImage: "chart.bar.xaxis")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(presentation.buckets, id: \.period) { bucket in
                        PointMark(
                            x: .value("Date", presentation.dateLabel(for: bucket.period)),
                            y: .value("Tokens", 0)
                        )
                        .opacity(0)
                    }
                    ForEach(presentation.points) { point in
                        BarMark(
                            x: .value("Date", point.dateLabel),
                            y: .value("Tokens", point.totalTokens),
                            width: .ratio(0.9)
                        )
                        .foregroundStyle(point.isProvisional ? Color.accentColor.opacity(0.45) : Color.accentColor)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: presentation.dateLabels) { _ in
                        AxisValueLabel()
                            .font(.system(size: 8))
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) ?? value.as(Double.self).map(Int.init) {
                                Text(HistoricalUsageChartPresentation.compactTokenCount(tokens))
                            }
                        }
                    }
                }
                .chartYAxisLabel("Tokens")
                .chartXScale(range: .plotDimension(startPadding: 2, endPadding: 2))
                .frame(height: 190)
                .accessibilityIdentifier("historical-usage-chart")
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(presentation.buckets.reversed().enumerated()), id: \.offset) { _, bucket in
                        HistoricalUsageBucketRow(bucket: bucket)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct HistoricalUsagePoint: Identifiable {
    let id: HistoricalUsageTrendPeriod
    let start: Date
    let totalTokens: Int
    let isProvisional: Bool
    let dateLabel: String

    init?(bucket: HistoricalUsageTrendBucket, dateLabel: String) {
        guard case let .observed(observations) = bucket.value else { return nil }
        id = bucket.period
        start = bucket.period.window.start
        guard let preferredTotalTokens = bucket.preferredTotalTokens else { return nil }
        totalTokens = preferredTotalTokens
        isProvisional = observations.contains { $0.lifecycle == .provisional }
        self.dateLabel = dateLabel
    }
}

struct HistoricalUsageChartPresentation {
    let buckets: [HistoricalUsageTrendBucket]
    let points: [HistoricalUsagePoint]
    let domain: ClosedRange<Date>?
    let dateLabels: [String]

    init(dailyBuckets: [HistoricalUsageTrendBucket]) {
        let unique = dailyBuckets.reduce(into: [String: HistoricalUsageTrendBucket]()) { result, bucket in
            let label = Self.dateLabel(for: bucket.period)
            if let current = result[label] {
                result[label] = Self.preferred(current, bucket)
            } else {
                result[label] = bucket
            }
        }
        let selected = Array(unique.values.sorted { $0.period.window.start < $1.period.window.start }.suffix(15))
        buckets = selected
        let labels = selected.map { Self.dateLabel(for: $0.period) }
        dateLabels = labels
        let plotted = zip(selected, labels).compactMap { bucket, label in
            HistoricalUsagePoint(bucket: bucket, dateLabel: label)
        }
        points = plotted
        domain = selected.first.flatMap { first in
            selected.last.map { last in first.period.window.start...last.period.window.end }
        }
    }

    func dateLabel(for period: HistoricalUsageTrendPeriod) -> String {
        Self.dateLabel(for: period)
    }

    private static func dateLabel(for period: HistoricalUsageTrendPeriod) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        formatter.timeZone = TimeZone(identifier: period.timeZoneIdentifier)
        return formatter.string(from: period.window.start)
    }

    private static func preferred(
        _ first: HistoricalUsageTrendBucket,
        _ second: HistoricalUsageTrendBucket
    ) -> HistoricalUsageTrendBucket {
        let firstDate = newestObservationDate(in: first)
        let secondDate = newestObservationDate(in: second)
        if firstDate != secondDate { return secondDate > firstDate ? second : first }
        return second.period.window.start > first.period.window.start ? second : first
    }

    private static func newestObservationDate(in bucket: HistoricalUsageTrendBucket) -> Date {
        guard case let .observed(observations) = bucket.value else { return .distantPast }
        return observations.map(\.recordedAt).max() ?? .distantPast
    }

    static func compactTokenCount(_ value: Int) -> String {
        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000_000, "T"),
            (1_000_000_000, "B"),
            (1_000_000, "M")
        ]
        guard let unit = units.first(where: { Double(value) >= $0.threshold }) else {
            return value.formatted()
        }
        let scaled = Double(value) / unit.threshold
        let text = scaled.rounded() == scaled
            ? String(format: "%.0f", scaled)
            : String(format: "%.1f", scaled)
        return text + unit.suffix
    }
}

private struct HistoricalUsageBucketRow: View {
    let bucket: HistoricalUsageTrendBucket

    private var periodText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: bucket.period.timeZoneIdentifier)
        return formatter.string(from: bucket.period.window.start)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(periodText)
                .font(.caption.weight(.medium))
            Text(bucket.period.timeZoneIdentifier)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            switch bucket.value {
            case .gap:
                Text("Unavailable")
                    .foregroundStyle(.secondary)
            case let .observed(observations):
                VStack(alignment: .trailing, spacing: 2) {
                    if let totalTokens = bucket.preferredTotalTokens {
                        Text("\(HistoricalUsageChartPresentation.compactTokenCount(totalTokens)) tokens")
                            .monospacedDigit()
                            .help("\(totalTokens.formatted()) tokens")
                    } else {
                        Text("Token total unavailable")
                            .foregroundStyle(.orange)
                    }
                    ForEach(historicalCostLabels(bucket.preferredCostObservations), id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if observations.contains(where: { $0.lifecycle == .provisional }) {
                        Text("In progress")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .font(.caption)
        .padding(8)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private func historicalCostLabels(_ observations: [HistoricalUsageTrendObservation]) -> [String] {
    let costs = observations.compactMap { observation -> HistoricalCostValue? in
        if let cost = observation.sample.providerReportedCost {
            return HistoricalCostValue(cost: cost, provenance: "Provider reported")
        }
        if let cost = observation.sample.calculatedCost?.cost {
            return HistoricalCostValue(cost: cost, provenance: "Calculated")
        }
        return nil
    }
    let grouped = Dictionary(grouping: costs) {
        HistoricalCostKey(currency: $0.cost.currencyCode.uppercased(), provenance: $0.provenance)
    }
    return grouped.keys.sorted { ($0.currency, $0.provenance) < ($1.currency, $1.provenance) }.map { key in
        let total = grouped[key, default: []].reduce(Decimal.zero) { $0 + $1.cost.amount }
        return "\(key.currency) \(total.description) · \(key.provenance)"
    }
}

private struct HistoricalCostValue {
    let cost: Cost
    let provenance: String
}

private struct HistoricalCostKey: Hashable {
    let currency: String
    let provenance: String
}

private struct UTCBillingWeekView: View {
    let presentation: UTCBillingWeekPresentation
    let pricingTable: PricingTable

    private var intervalText: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
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
            Text(HistoricalUsageChartPresentation.compactTokenCount(value))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .help(value.formatted())
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
