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
    var showsAnalysis = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.isBusinessPlan {
                businessCreditsSection
            } else {
                individualPlanSection(snapshot)
            }

            if showsAnalysis {
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
            }

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
    }

    @ViewBuilder
    private func individualPlanSection(_ snapshot: CodexRateLimitSnapshot) -> some View {
        VStack(spacing: 10) {
            if let primary = snapshot.primary {
                PercentRateLimitRowView(label: primary.displayLabel, percentUsed: primary.percentUsed, severity: .unknown, resetsAt: primary.resetsAt, isActive: false, insight: insight(slot: "primary", window: primary), anomaly: anomaly(slot: "primary", window: primary), insightsStorageAvailable: insightsStorageAvailable, showsAnalysis: showsAnalysis)
            }
            if let secondary = snapshot.secondary {
                PercentRateLimitRowView(label: secondary.displayLabel, percentUsed: secondary.percentUsed, severity: .unknown, resetsAt: secondary.resetsAt, isActive: false, insight: insight(slot: "secondary", window: secondary), anomaly: anomaly(slot: "secondary", window: secondary), insightsStorageAvailable: insightsStorageAvailable, showsAnalysis: showsAnalysis)
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

@MainActor
@Observable
final class LiveLimitsModel {
    static let shared = LiveLimitsModel()
    private(set) var states: [LiveProvider: LiveLimitsState] = [:]
    private(set) var isRefreshing = false

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for provider in LiveProvider.allCases where states[provider] == nil {
            states[provider] = .loading
        }
        await withTaskGroup(of: (LiveProvider, LiveLimitsState).self) { group in
            for provider in LiveProvider.allCases {
                group.addTask { (provider, await LiveProviderLimits.fetch(provider)) }
            }
            for await (provider, state) in group {
                states[provider] = state
            }
        }
    }

    func runWhileVisible() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(60))
        }
    }
}

struct LiveLimitsSectionView: View {
    let provider: LiveProvider
    let state: LiveLimitsState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(provider.displayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if case let .loaded(_, plan, fetchedAt) = state {
                    Text([plan.map { "Plan: \($0)" }, "Fetched \(fetchedAt.formatted(date: .omitted, time: .shortened))"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .unavailable(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if provider == .codex {
                    Button("Log in to Codex Again") { CodexLoginLauncher.openLogin() }
                        .controlSize(.small)
                }
            case .loaded(let groups, _, _):
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if let title = group.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group.windows) { window in
                            PercentRateLimitRowView(
                                label: window.label,
                                percentUsed: window.usedPercent,
                                severity: .unknown,
                                resetsAt: window.resetsAt,
                                isActive: false,
                                insight: nil,
                                anomaly: nil,
                                insightsStorageAvailable: false,
                                showsAnalysis: false
                            )
                        }
                    }
                }
            }
        }
    }
}
