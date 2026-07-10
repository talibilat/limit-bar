import SwiftUI
import LimitBarCore

struct MonitoringPopoverView: View {
    @State private var selectedWindow = TimeWindow.defaultSelection
    @State private var metrics: [UsageMetric] = []
    @State private var storeHealth = UsageStoreHealth(isOpen: false, message: "Loading SQLite store")

    private var cards: [ProviderUsageCard] {
        ProviderUsageCard.cards(from: metrics, timeWindow: selectedWindow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Picker("Time window", selection: $selectedWindow) {
                ForEach(TimeWindow.allCases, id: \.self) { window in
                    Text(window.displayName).tag(window)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(cards, id: \.provider) { card in
                        ProviderUsageCardView(card: card, selectedWindow: selectedWindow)
                    }
                }
            }
            .scrollIndicators(.hidden)

            Divider()

            HStack {
                Text("Demo data only. Provider integrations arrive in later issues.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                SettingsLink {
                    Text("Settings")
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 540, alignment: .topLeading)
        .task {
            loadStoredMetrics()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LimitBar")
                .font(.title2.weight(.semibold))
            Text("Confirmed demo usage by provider")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(storeHealth.message)
                .font(.caption)
                .foregroundStyle(storeHealth.isOpen ? Color.secondary : Color.orange)
        }
    }

    private func loadStoredMetrics() {
        let snapshot = StoredUsageMetrics.loadFromApplicationSupport()
        metrics = snapshot.metrics
        storeHealth = snapshot.health
    }
}

private struct ProviderUsageCardView: View {
    let card: ProviderUsageCard
    let selectedWindow: TimeWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.provider.displayName)
                    .font(.headline)
                Spacer()
                Text(card.isEmpty ? "Empty" : "Demo")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if card.isEmpty {
                Text("No usage for \(selectedWindow.displayName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(card.metrics.enumerated()), id: \.offset) { _, metric in
                        MetricRowView(metric: metric)
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
}

private struct MetricRowView: View {
    let metric: UsageMetric

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

            HStack(spacing: 8) {
                TokenPill(title: "In", value: metric.tokenUsage.inputTokens)
                TokenPill(title: "Out", value: metric.tokenUsage.outputTokens)
                TokenPill(title: "Total", value: metric.tokenUsage.totalTokens)
            }

            Text(metric.limitStatus.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
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
