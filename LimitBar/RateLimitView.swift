import SwiftUI
import LimitBarCore

struct RateLimitView: View {
    let metrics: [UsageMetric]
    let pricingTable: PricingTable

    @State private var isClaudePresent = true
    @State private var isCodexPresent = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isClaudePresent {
                    sectionHeader("Claude")
                    ClaudeRateLimitsView(isPresent: $isClaudePresent)
                }

                if isCodexPresent {
                    sectionHeader("Codex")
                    CodexRateLimitsView(metrics: metrics, pricingTable: pricingTable, isPresent: $isCodexPresent)
                }

                if !isClaudePresent && !isCodexPresent {
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
    RateLimitView(metrics: [], pricingTable: .empty)
        .padding(20)
        .frame(width: 440, height: 600)
}
