import SwiftUI
import LimitBarCore

struct RateLimitView: View {
    let state: LimitBarState
    let pricingTable: PricingTable

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.claudeModel.isPresent {
                    sectionHeader("Claude")
                    ClaudeRateLimitsView(
                        model: state.claudeModel,
                        insights: state.quotaInsights,
                        anomalies: state.quotaAnomalies,
                        insightsStorageAvailable: state.quotaInsightsStorageAvailable,
                        onActionCompleted: state.claudeActionCompleted
                    )
                }

                if let codexSnapshot = state.local.codexSnapshot {
                    sectionHeader("Codex")
                    CodexRateLimitsView(
                        snapshot: codexSnapshot,
                        metrics: state.local.metrics,
                        pricingTable: pricingTable,
                        insights: state.quotaInsights,
                        anomalies: state.quotaAnomalies,
                        insightsStorageAvailable: state.quotaInsightsStorageAvailable,
                        explanation: state.local.codexExplanation
                    )
                }

                if !state.claudeModel.isPresent && state.local.codexSnapshot == nil {
                    Text("No Claude Code or Codex usage found on this machine yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    RateLimitView(state: .shared, pricingTable: .empty)
        .padding(20)
        .frame(width: 440, height: 600)
}
