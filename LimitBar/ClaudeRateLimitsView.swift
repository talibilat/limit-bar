import SwiftUI
import LimitBarCore

struct ClaudeRateLimitsView: View {
    @Bindable var model: ClaudeRateLimitsModel
    let insights: [QuotaWindowIdentity: QuotaInsightState]
    let anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    let insightsStorageAvailable: Bool
    let explanationCatalog: ClaudeQuotaExplanationCatalog
    let onActionCompleted: () -> Void
    @State private var selectedIntervalID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Uses your existing Claude Code login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.isRefreshing ? "Refreshing..." : "Refresh") {
                    Task {
                        await model.refresh()
                        onActionCompleted()
                    }
                }
                .disabled(model.isRefreshing)
            }

            switch model.state {
            case .loading:
                ProgressView("Loading Claude rate limits")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            case .notConnected:
                VStack(alignment: .leading, spacing: 8) {
                    Text("No active Claude Code login found. Run Claude Code and enter /login, then check again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Link("Open login instructions", destination: ClaudeLoginHelp.url)
                            .accessibilityIdentifier("claude-login-help")
                        Spacer()
                        Button("Check Again") {
                            Task {
                                await model.refresh()
                                onActionCompleted()
                            }
                        }
                    }
                }
            case let .failed(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            case .authorizationRequired:
                HStack {
                    Text("Authorize LimitBar to read your Claude Code login.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("claude-authorization-required")
                    Spacer()
                    Link("Login instructions", destination: ClaudeLoginHelp.url)
                        .accessibilityIdentifier("claude-login-help")
                    Button(model.isRefreshing ? "Connecting..." : "Connect") {
                        Task {
                            await model.connect()
                            onActionCompleted()
                        }
                    }
                    .disabled(model.isRefreshing)
                    .accessibilityIdentifier("claude-connect")
                }
            case let .loaded(snapshot, subscription):
                let displayed = snapshot.displayLimits(forSubscriptionType: subscription)
                VStack(spacing: 10) {
                    ForEach(Array(displayed.enumerated()), id: \.offset) { _, limit in
                        PercentRateLimitRowView(
                            label: limit.displayLabel,
                            percentUsed: limit.percentUsed,
                            severity: limit.severity,
                            resetsAt: limit.resetsAt,
                            isActive: limit.isActive,
                            insight: insight(for: limit),
                            anomaly: anomaly(for: limit),
                            insightsStorageAvailable: insightsStorageAvailable
                        )
                    }
                }
                .accessibilityIdentifier("claude-loaded-state")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code quota movement")
                        .font(.caption.weight(.semibold))
                    if explanationCatalog.intervals.count > 1 {
                        Picker("Exact interval", selection: intervalSelection) {
                            ForEach(explanationCatalog.intervals, id: \.id) { interval in
                                Text(intervalLabel(interval)).tag(Optional(interval.id))
                            }
                        }
                        .accessibilityIdentifier("claude-explanation-interval")
                    }
                    if let selectedSelection {
                        Text(intervalTraceText(selectedSelection))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("claude-explanation-trace")
                    }
                    Text(selectedExplanation.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("claude-quota-explanation")
                    Text("Method: \(ClaudeQuotaExplanationEngine.methodVersion); source adapter: \(ClaudeCodeOTLPEvidenceAdapter.adapterVersion). Tokens are never converted to quota percentage.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let metadata = explanationMetadata {
                        Text(metadata)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack {
                    if let subscription {
                        Text("Plan: \(subscription.capitalized)")
                    }
                    Spacer()
                    Text("Fetched \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .task {
            await model.appeared()
            onActionCompleted()
        }
        .onChange(of: explanationCatalog.defaultSelectionID, initial: true) { _, defaultID in
            if selectedIntervalID.flatMap({ explanationCatalog.selection(id: $0) }) == nil {
                selectedIntervalID = defaultID
            }
        }
    }

    private func insight(for limit: ClaudeRateLimit) -> QuotaInsightState? {
        guard let identity = QuotaWindowIdentity.claudeCode(limit) else { return nil }
        return insights[identity]
    }

    private func anomaly(for limit: ClaudeRateLimit) -> QuotaAnomalyState? {
        guard let identity = QuotaWindowIdentity.claudeCode(limit) else { return nil }
        return anomalies[identity]
    }

    private var explanationMetadata: String? {
        let value: ClaudeQuotaExplanation
        switch selectedExplanation {
        case let .movement(explanation), let .flat(explanation): value = explanation
        case .unavailable:
            let limitations = (selectedSelection?.limitations ?? explanationCatalog.limitations).map(\.rawValue).joined(separator: ", ")
            return "Production source unavailable; limitations: \(limitations); manual signed acceptance unavailable. No generic Anthropic API fallback."
        }
        let source = value.sourceVersion.map { "source \($0)" } ?? "source not configured"
        let limitations = selectedSelection?.limitations.map(\.rawValue).joined(separator: ", ") ?? "none"
        return "Reported inputs: \(value.observationIdentityCount); calculated method: \(value.methodVersion); measured evidence trace: \(value.evidenceIdentityCount); evidence age \(duration(value.evidenceAge)); \(source); limitations: \(limitations); manual acceptance unavailable; source last verified \(ClaudeCodeOTLPEvidenceAdapter.lastVerified)."
    }

    private var selectedSelection: ClaudeQuotaExplanationSelection? {
        explanationCatalog.selection(id: selectedIntervalID) ?? explanationCatalog.defaultSelection
    }

    private var selectedExplanation: ClaudeQuotaExplanationState {
        selectedSelection?.state ?? .unavailable(.insufficientObservations)
    }

    private var intervalSelection: Binding<String?> {
        Binding(get: { selectedIntervalID ?? explanationCatalog.defaultSelectionID }, set: { selectedIntervalID = $0 })
    }

    private func intervalLabel(_ interval: ClaudeQuotaExplanationInterval) -> String {
        let status = interval.lifecycle == .active ? "Active" : "Completed"
        return "\(status) · \(interval.intervalStart.formatted(date: .abbreviated, time: .shortened)) to \(interval.intervalEnd.formatted(date: .abbreviated, time: .shortened))"
    }

    private func intervalTraceText(_ selection: ClaudeQuotaExplanationSelection) -> String {
        let evidenceCount: Int
        switch selection.state {
        case let .movement(value), let .flat(value): evidenceCount = value.evidenceIdentityCount
        case .unavailable: evidenceCount = 0
        }
        return "Exact selected interval: \(selection.interval.intervalStart.formatted(date: .abbreviated, time: .standard)) to \(selection.interval.intervalEnd.formatted(date: .abbreviated, time: .standard)); interval trace: \(selection.interval.id); Reported observation traces: 2; Measured evidence traces: \(evidenceCount); Calculated method: \(ClaudeQuotaExplanationEngine.methodVersion); provenance: Reported percentages, Calculated movement, Measured local breakdown when available."
    }

    private func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}

enum ClaudeLoginHelp {
    static let url = URL(string: "https://code.claude.com/docs/en/iam#log-in-to-claude-code")!
}

#Preview {
    ClaudeRateLimitsView(
        model: ClaudeRateLimitsModel(
            credentials: ClaudeCredentialBroker.shared,
            client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
        ),
        insights: [:],
        anomalies: [:],
        insightsStorageAvailable: true,
        explanationCatalog: .empty,
        onActionCompleted: {}
    )
        .padding(20)
        .frame(width: 440, height: 400)
}
