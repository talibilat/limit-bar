import SwiftUI
import LimitBarCore

struct RateLimitAnalysisView: View {
    let state: LimitBarState
    let workloadPlanningData: any WorkloadPlanningDataProviding

    @State private var showsInvestigation = false

    init(
        state: LimitBarState,
        workloadPlanningData: (any WorkloadPlanningDataProviding)? = nil
    ) {
        self.state = state
        self.workloadPlanningData = workloadPlanningData ?? LiveWorkloadPlanningData(state: state)
    }

    private var items: [RateLimitAnalysisItem] {
        claudeItems + codexItems + [activityReceiptItem, workloadItem]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Concise findings from measured local evidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Investigate") {
                        showsInvestigation = true
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .accessibilityHint("Opens detailed normalized evidence, methods, and limitations")
                    .accessibilityIdentifier("open-forensic-investigation")
                }

                ForEach(items) { item in
                    RateLimitAnalysisCard(item: item)
                }
            }
        }
        .scrollIndicators(.hidden)
        .task {
            await state.claudeModel.appeared()
            state.claudeActionCompleted()
        }
        .sheet(isPresented: $showsInvestigation) {
            ForensicInvestigationView(
                snapshot: state.investigationPublication,
                statusObservations: state.providerStatusObservations,
                localFailures: state.forensicLocalFailures,
                authentication: state.forensicAuthentication,
                statusSubscriptionEnabled: state.providerStatusSubscription.isEnabled,
                statusCheckInProgress: state.providerStatusCheckInProgress,
                checkProviderStatus: { state.checkProviderStatus() }
            )
        }
    }

    private var claudeItems: [RateLimitAnalysisItem] {
        var result: [RateLimitAnalysisItem] = []
        if case let .loaded(snapshot, subscription) = state.claudeModel.state {
            result += snapshot.displayLimits(forSubscriptionType: subscription).map { limit in
                let identity = QuotaWindowIdentity.claudeCode(limit)
                return quotaItem(
                    id: "claude-\(limit.kind)-\(limit.resetsAt?.timeIntervalSince1970 ?? 0)",
                    title: "Claude Code · \(limit.displayLabel)",
                    insight: identity.flatMap { state.quotaInsights[$0] },
                    anomaly: identity.flatMap { state.quotaAnomalies[$0] },
                    hasExactReset: limit.resetsAt != nil
                )
            }
        } else {
            result.append(RateLimitAnalysisItem(
                id: "claude-unavailable",
                title: "Claude Code",
                summary: "Analysis will appear after a Claude Code rate-limit report is available."
            ))
        }

        let catalog = state.claudeExplanationCatalog
        let selection = catalog.defaultSelection
        let explanation = selection?.state ?? .unavailable(.insufficientObservations)
        let limitations = (selection?.limitations ?? catalog.limitations).map(\.rawValue).joined(separator: ", ")
        result.append(RateLimitAnalysisItem(
            id: "claude-movement",
            title: "Claude Code movement",
            summary: claudeExplanationSummary(explanation),
            detail: "\(explanation.displayText) Method: \(ClaudeQuotaExplanationEngine.methodVersion). Limitations: \(limitations.isEmpty ? "none recorded" : limitations)."
        ))
        return result
    }

    private var codexItems: [RateLimitAnalysisItem] {
        var result: [RateLimitAnalysisItem] = []
        if let snapshot = state.local.codexSnapshot {
            let windows = [("primary", snapshot.primary), ("secondary", snapshot.secondary)]
            result += windows.compactMap { slot, window in
                guard let window else { return nil }
                let identity = QuotaWindowIdentity.codex(slot: slot, window: window)
                return quotaItem(
                    id: "codex-\(slot)-\(window.resetsAt?.timeIntervalSince1970 ?? 0)",
                    title: "Codex · \(window.displayLabel)",
                    insight: identity.flatMap { state.quotaInsights[$0] },
                    anomaly: identity.flatMap { state.quotaAnomalies[$0] },
                    hasExactReset: window.resetsAt != nil
                )
            }
        } else {
            result.append(RateLimitAnalysisItem(
                id: "codex-unavailable",
                title: "Codex",
                summary: "Analysis will appear after a local Codex rate-limit report is found."
            ))
        }

        result.append(RateLimitAnalysisItem(
            id: "codex-movement",
            title: "Codex movement",
            summary: codexExplanationSummary(state.local.codexExplanation),
            detail: "\(state.local.codexExplanation.displayText) Method: \(CodexQuotaExplanationEngine.methodVersion). Adapter: \(CodexRolloutEvidenceAdapter.adapterVersion)."
        ))
        return result
    }

    private var workloadItem: RateLimitAnalysisItem {
        let result = workloadPlanningData.result(workUnits: 10, concurrency: 1, now: Date())
        return RateLimitAnalysisItem(
            id: "planned-workload",
            title: "Planned workload",
            summary: result.summary,
            detail: result.evidence
        )
    }

    private var activityReceiptItem: RateLimitAnalysisItem {
        RateLimitAnalysisItem(
            id: "activity-receipt-debugger",
            title: "Activity Receipt debugger",
            summary: ActivityReceiptPresentation.summary(state.activityDebuggerState),
            detail: ActivityReceiptPresentation.detail(state.activityDebuggerState)
        )
    }

    private func quotaItem(
        id: String,
        title: String,
        insight: QuotaInsightState?,
        anomaly: QuotaAnomalyState?,
        hasExactReset: Bool
    ) -> RateLimitAnalysisItem {
        guard state.quotaInsightsStorageAvailable else {
            return RateLimitAnalysisItem(id: id, title: title, summary: "Analysis is unavailable because local insight storage could not be opened.")
        }
        guard hasExactReset else {
            return RateLimitAnalysisItem(id: id, title: title, summary: "Analysis needs an exact provider-reported reset boundary.")
        }

        return RateLimitAnalysisItem(
            id: id,
            title: title,
            summary: "\(forecastSummary(insight)) \(anomalySummary(anomaly))",
            detail: "\(forecastDetail(insight)) \(anomaly.map(PercentRateLimitPresentation.anomalyDisclosure) ?? "No anomaly result has been published yet.")"
        )
    }

    private func forecastSummary(_ insight: QuotaInsightState?) -> String {
        switch insight {
        case let .qualified(value): "Forecast available from \(value.measuredObservationCount) observations."
        case let .unavailable(value): "Forecast unavailable: \(value.reason.displayText)"
        case nil: "Collecting observations for a forecast."
        }
    }

    private func forecastDetail(_ insight: QuotaInsightState?) -> String {
        guard let insight else { return "At least four distinct observations spanning 15 minutes are required." }
        switch insight {
        case let .qualified(value):
            let burn = PercentRateLimitPresentation.burnRange(value.calculatedBurnPercentPerHour)
            let exhaustion = value.calculatedExhaustionRange.map {
                PercentRateLimitPresentation.exhaustionRange($0)
            } ?? "not projected before reset"
            return "Calculated burn: \(burn). Exhaustion: \(exhaustion). \(PercentRateLimitPresentation.methodDisclosure(insight))"
        case .unavailable:
            return PercentRateLimitPresentation.methodDisclosure(insight)
        }
    }

    private func anomalySummary(_ anomaly: QuotaAnomalyState?) -> String {
        switch anomaly {
        case .finding: "Anomaly found."
        case .noFinding: "No anomaly found."
        case .observedZero: "Observed Zero."
        case let .unavailable(value): "Anomaly unavailable: \(value.reason.rawValue)."
        case nil: "Anomaly check pending."
        }
    }

    private func claudeExplanationSummary(_ explanation: ClaudeQuotaExplanationState) -> String {
        switch explanation {
        case .movement: "Movement analysis is available."
        case .flat: "No percentage movement was measured in the selected interval."
        case let .unavailable(reason): "Movement analysis unavailable: \(reason.displayText)"
        }
    }

    private func codexExplanationSummary(_ explanation: CodexQuotaExplanationState) -> String {
        switch explanation {
        case .available: "A complete local breakdown is available; quota movement remains unattributed."
        case .partial: "A partial local breakdown is available; quota movement remains unattributed."
        case .observedZero: "Observed Zero local activity in the covered interval."
        case let .unavailable(reason): "Movement analysis unavailable: \(reason.displayText)"
        }
    }
}

private struct RateLimitAnalysisItem: Identifiable {
    let id: String
    let title: String
    let summary: String
    var detail: String?

    var presentsDetailInPopover: Bool { (detail ?? "").count > 120 }
}

private struct RateLimitAnalysisCard: View {
    let item: RateLimitAnalysisItem
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.headline)
            Text(item.summary)
                .font(.callout)

            if let detail = item.detail {
                if item.presentsDetailInPopover {
                    Button("Read analysis") { showsDetail = true }
                        .buttonStyle(.link)
                        .popover(isPresented: $showsDetail) {
                            Text(detail)
                                .font(.callout)
                                .lineSpacing(3)
                                .padding(16)
                                .frame(width: 360, alignment: .leading)
                        }
                } else {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary, lineWidth: 1))
    }
}
