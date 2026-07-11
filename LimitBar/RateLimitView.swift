import SwiftUI
import LimitBarCore

struct RateLimitView: View {
    let metrics: [UsageMetric]
    let pricingTable: PricingTable

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Claude")
                ClaudeRateLimitsView()

                sectionHeader("Codex")
                CodexRateLimitsView(metrics: metrics, pricingTable: pricingTable)
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
    RateLimitView(metrics: [], pricingTable: .empty)
        .padding(20)
        .frame(width: 440, height: 600)
}
