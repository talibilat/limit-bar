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

                PlannedWorkloadView()
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

private struct PlannedWorkloadView: View {
    @State private var product = ProviderProduct.codex
    @State private var workUnits = 10

    private var assessment: WorkloadPlanningState {
        let plan = try! PlannedWorkload(
            product: product,
            kind: .codingAgentOperations,
            quotaWindowKind: .session,
            executionMode: .interactive,
            concurrency: 1,
            workUnits: workUnits,
            adapterVersion: "unsupported-live-v0",
            clientVersion: "unsupported-live-v0"
        )
        return WorkloadPlanning.assess(
            plan,
            historicalRuns: [],
            currentEvidence: nil,
            now: Date()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan workload")
                .font(.headline)
                .accessibilityIdentifier("planned-workload-title")
            Text("Describe coding-agent operations without prompts, code, paths, or responses.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Provider product", selection: $product) {
                Text("Claude Code").tag(ProviderProduct.claudeCode)
                Text("Codex").tag(ProviderProduct.codex)
            }
            .pickerStyle(.segmented)

            Stepper("Completed operations: \(workUnits)", value: $workUnits, in: 1...10_000)
                .accessibilityIdentifier("planned-workload-units")

            if case let .unavailable(value) = assessment {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assessment unavailable")
                        .font(.subheadline.weight(.semibold))
                    Text("No measured completed runs are available from a supported adapter, so LimitBar did not estimate quota or completion.")
                    Text("Method: \(value.metadata.comparabilityMethod.rawValue); requires \(value.metadata.minimumComparableRuns) compatible runs. Current adapters do not establish completed-run boundaries or provider weighting.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("planned-workload-outcome")
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    RateLimitView(state: .shared, pricingTable: .empty)
        .padding(20)
        .frame(width: 440, height: 600)
}
