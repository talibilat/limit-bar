import SwiftUI
import LimitBarCore

struct RateLimitView: View {
    let state: LimitBarState
    let pricingTable: PricingTable
    let workloadPlanningData: any WorkloadPlanningDataProviding

    init(
        state: LimitBarState,
        pricingTable: PricingTable,
        workloadPlanningData: (any WorkloadPlanningDataProviding)? = nil
    ) {
        self.state = state
        self.pricingTable = pricingTable
        self.workloadPlanningData = workloadPlanningData ?? LiveWorkloadPlanningData(state: state)
    }

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
                        explanationCatalog: state.claudeExplanationCatalog,
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

                PlannedWorkloadView(data: workloadPlanningData)
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

struct WorkloadPlanningInputSupport: Equatable {
    let product: ProviderProduct
    let kind: PlannedWorkloadKind
    let concurrency: ClosedRange<Int>
    let workUnits: ClosedRange<Int>
}

enum WorkloadPlanningSurfaceStatus: Equatable {
    case available
    case indeterminate
    case unavailable
}

struct WorkloadPlanningSurfaceResult: Equatable {
    let status: WorkloadPlanningSurfaceStatus
    let title: String
    let summary: String
    let evidence: String
}

@MainActor
protocol WorkloadPlanningDataProviding {
    var inputSupport: WorkloadPlanningInputSupport? { get }
    func result(workUnits: Int, concurrency: Int, now: Date) -> WorkloadPlanningSurfaceResult
}

@MainActor
struct LiveWorkloadPlanningData: WorkloadPlanningDataProviding {
    let state: LimitBarState
    let completedRuns: any CompletedWorkloadRunProviding

    init(
        state: LimitBarState,
        completedRuns: any CompletedWorkloadRunProviding = UnsupportedCompletedWorkloadRunProvider()
    ) {
        self.state = state
        self.completedRuns = completedRuns
    }

    var inputSupport: WorkloadPlanningInputSupport? {
        completedRuns.support().map {
            WorkloadPlanningInputSupport(product: $0.product, kind: $0.kind, concurrency: 1...64, workUnits: 1...10_000)
        }
    }

    func result(workUnits: Int, concurrency: Int, now: Date) -> WorkloadPlanningSurfaceResult {
        guard let support = completedRuns.support() else {
            return WorkloadPlanningSurfaceResult(WorkloadPlanning.unavailableForUnsupportedAdapter(
                currentEvidence: nil,
                now: now
            ))
        }
        let current = Self.currentEvidence(
            for: support,
            codexSnapshot: state.local.codexSnapshot,
            claudeSnapshot: {
                guard case let .loaded(snapshot, _) = state.claudeModel.state else { return nil }
                return snapshot
            }(),
            forecasts: state.quotaInsights
        )
        guard let plan = try? PlannedWorkload(
                  product: support.product,
                  kind: support.kind,
                  quotaWindowKind: support.quotaWindowKind,
                  executionMode: support.executionMode,
                  concurrency: concurrency,
                  workUnits: workUnits,
                  source: support.source,
                  adapterVersion: support.adapterVersion,
                  clientVersion: support.clientVersion,
                  providerFormatVersion: support.providerFormatVersion
              ) else {
            return WorkloadPlanningSurfaceResult(WorkloadPlanning.unavailableForUnsupportedAdapter(
                currentEvidence: current,
                now: now
            ))
        }
        return WorkloadPlanningSurfaceResult(WorkloadPlanning.assess(
            plan,
            historicalRuns: completedRuns.historicalRuns(),
            currentEvidence: current,
            now: now
        ))
    }

    static func currentEvidence(
        for support: CompletedWorkloadRunSupport?,
        codexSnapshot: CodexRateLimitSnapshot?,
        claudeSnapshot: ClaudeRateLimitSnapshot?,
        forecasts: [QuotaWindowIdentity: QuotaInsightState]
    ) -> CurrentWorkloadQuotaEvidence? {
        guard let support else { return nil }
        switch support.product {
        case .codex:
            guard let snapshot = codexSnapshot else { return nil }
            for observation in MeasuredQuotaObservationAdapter.codex(snapshot).reversed() {
                if let forecast = forecasts[observation.identity] {
                    return CurrentWorkloadQuotaEvidence(latestObservation: observation, forecast: forecast)
                }
            }
        case .claudeCode:
            guard let snapshot = claudeSnapshot else { return nil }
            for observation in MeasuredQuotaObservationAdapter.claude(snapshot).reversed() {
                if let forecast = forecasts[observation.identity] {
                    return CurrentWorkloadQuotaEvidence(latestObservation: observation, forecast: forecast)
                }
            }
        case .anthropicAPI, .openAIAPI, .azureOpenAI:
            return nil
        }
        return nil
    }
}

extension WorkloadPlanningSurfaceResult {
    init(_ state: WorkloadPlanningState) {
        switch state {
        case let .available(value):
            status = .available
            title = "Assessment available"
            summary = "Calculated requirement \(Self.percentRange(value.requirementPercent)); current measured availability \(Self.percent(value.currentEvidence.availablePercent))."
            evidence = "\(Self.interaction(value.currentEvidence.boundaryInteraction)); \(value.sample.includedRevisionIdentities.count) compatible runs; method \(value.metadata.comparabilityMethod.rawValue). Options require your action."
        case let .indeterminate(value):
            status = .indeterminate
            title = "Assessment indeterminate"
            summary = "Calculated requirement \(Self.percentRange(value.requirementPercent)) overlaps current quota or boundary evidence."
            evidence = "Reason: \(value.reason.rawValue); \(Self.interaction(value.currentEvidence.boundaryInteraction)); \(value.sample.includedRevisionIdentities.count) compatible runs; no completion claim."
        case let .unavailable(value):
            status = .unavailable
            title = "Assessment unavailable"
            summary = value.reason == .unsupportedHistoricalRunAdapter
                ? "No supported adapter records measured completed runs, so LimitBar did not estimate quota or completion."
                : "Planning evidence is unavailable: \(value.reason.rawValue)."
            let current = value.currentEvidence.map {
                "Current forecast \($0.forecastQualification.rawValue) using \($0.forecastMethod.rawValue); exact reset \($0.identity.resetBoundary.formatted(date: .abbreviated, time: .shortened))."
            } ?? "No compatible current quota evidence."
            evidence = "\(current) Method \(value.metadata.comparabilityMethod.rawValue); requires \(value.metadata.minimumComparableRuns) compatible runs."
        }
    }

    private static func percentRange(_ range: QuotaInsightRange) -> String {
        "\(percent(range.lower))-\(percent(range.upper))"
    }

    private static func percent(_ value: Double) -> String {
        String(format: value.rounded() == value ? "%.0f%%" : "%.1f%%", value)
    }

    private static func interaction(_ value: WorkloadQuotaBoundaryInteraction?) -> String {
        switch value {
        case .exhaustionExpectedFirst: "calculated exhaustion expected before reported reset"
        case .resetExpectedFirst: "reported reset expected before calculated exhaustion"
        case .indeterminateOverlap: "calculated exhaustion overlaps reported reset"
        case nil: "reset interaction unavailable"
        }
    }
}

struct PlannedWorkloadView: View {
    let data: any WorkloadPlanningDataProviding
    @State private var workUnits = 10
    @State private var concurrency = 1

    var renderedResult: WorkloadPlanningSurfaceResult {
        data.result(workUnits: workUnits, concurrency: concurrency, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan workload")
                .font(.headline)
                .accessibilityIdentifier("planned-workload-title")
            Text("Uses only bounded operation counts and measured evidence, never prompts, code, paths, or responses.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let support = data.inputSupport {
                Text("\(support.product.displayName) coding-agent operations")
                    .font(.subheadline.weight(.medium))
                Stepper("Operations: \(workUnits)", value: $workUnits, in: support.workUnits)
                    .accessibilityIdentifier("planned-workload-units")
                Stepper("Concurrency: \(concurrency)", value: $concurrency, in: support.concurrency)
                    .accessibilityIdentifier("planned-workload-concurrency")
            }

            let result = renderedResult
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                Text(result.summary)
                Text(result.evidence)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("planned-workload-outcome")
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
