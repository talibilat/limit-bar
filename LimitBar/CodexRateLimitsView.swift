import SwiftUI
import LimitBarCore

struct CodexRateLimitsView: View {
    let snapshot: CodexRateLimitSnapshot
    let metrics: [UsageMetric]
    let pricingTable: PricingTable
    let insights: [QuotaWindowIdentity: QuotaInsightState]
    let anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    let insightsStorageAvailable: Bool
    let explanation: CodexQuotaExplanationState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read from your local Codex session logs; no network call is made.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if snapshot.isBusinessPlan {
                businessCreditsSection
            } else {
                individualPlanSection(snapshot)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Latest measured interval")
                    .font(.caption.weight(.semibold))
                Text(explanation.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex-quota-explanation")
                Text("Method: \(CodexQuotaExplanationEngine.methodVersion); adapter: \(CodexRolloutEvidenceAdapter.adapterVersion). Local evidence cannot allocate provider-reported percentage movement.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("As of \(snapshot.reportedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var businessCreditsSection: some View {
        let estimate = CodexCreditsEstimator.estimate(from: metrics, pricing: pricingTable)
        VStack(spacing: 10) {
            CreditsUsageRowView(label: "Today", cost: estimate.today)
            CreditsUsageRowView(label: "Current Week", cost: estimate.currentWeek)
        }
        Text("Business plan: company-pool credit usage only. Configure credits pricing in Settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func individualPlanSection(_ snapshot: CodexRateLimitSnapshot) -> some View {
        VStack(spacing: 10) {
            if let primary = snapshot.primary {
                PercentRateLimitRowView(label: primary.displayLabel, percentUsed: primary.percentUsed, severity: .unknown, resetsAt: primary.resetsAt, isActive: false, insight: insight(slot: "primary", window: primary), anomaly: anomaly(slot: "primary", window: primary), insightsStorageAvailable: insightsStorageAvailable)
            }
            if let secondary = snapshot.secondary {
                PercentRateLimitRowView(label: secondary.displayLabel, percentUsed: secondary.percentUsed, severity: .unknown, resetsAt: secondary.resetsAt, isActive: false, insight: insight(slot: "secondary", window: secondary), anomaly: anomaly(slot: "secondary", window: secondary), insightsStorageAvailable: insightsStorageAvailable)
            }
            if let credits = snapshot.credits, credits.hasCredits, let balance = credits.balance {
                CreditsUsageRowView(label: "Credits balance", cost: Cost(amount: balance, currencyCode: "credits", source: .providerReported))
            }
        }
    }

    private func insight(slot: String, window: CodexRateLimitWindow) -> QuotaInsightState? {
        guard let identity = QuotaWindowIdentity.codex(slot: slot, window: window) else { return nil }
        return insights[identity]
    }

    private func anomaly(slot: String, window: CodexRateLimitWindow) -> QuotaAnomalyState? {
        guard let identity = QuotaWindowIdentity.codex(slot: slot, window: window) else { return nil }
        return anomalies[identity]
    }

}

private struct CreditsUsageRowView: View {
    let label: String
    let cost: Cost?

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let cost {
                Text("\(cost.amount.description) credits")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(cost.source == .providerReported ? "Reported" : "Estimated")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No usage")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    CodexRateLimitsView(
        snapshot: CodexRateLimitSnapshot(planType: "plus", primary: CodexRateLimitWindow(percentUsed: 10, windowMinutes: 300, resetsAt: nil), secondary: nil, credits: nil, reportedAt: Date()),
        metrics: [],
        pricingTable: .empty,
        insights: [:],
        anomalies: [:],
        insightsStorageAvailable: true,
        explanation: .unavailable(.insufficientObservations)
    )
        .padding(20)
        .frame(width: 440, height: 300)
}
