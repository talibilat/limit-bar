import SwiftUI
import LimitBarCore

struct ClaudeRateLimitsView: View {
    @Bindable var model: ClaudeRateLimitsModel
    let insights: [QuotaWindowIdentity: QuotaInsightState]
    let anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    let insightsStorageAvailable: Bool
    let explanation: ClaudeQuotaExplanationState
    let onActionCompleted: () -> Void

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
                    Text("Latest measured interval")
                        .font(.caption.weight(.semibold))
                    Text(explanation.displayText)
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
        switch explanation {
        case let .movement(explanation), let .flat(explanation): value = explanation
        case .unavailable: return nil
        }
        let source = value.sourceVersion.map { "source \($0)" } ?? "source not configured"
        return "\(value.observationIdentityCount) measured observations over \(duration(value.observationSpan)); evidence age \(duration(value.evidenceAge)); \(source); source last verified \(ClaudeCodeOTLPEvidenceAdapter.lastVerified)."
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
        explanation: .unavailable(.insufficientObservations),
        onActionCompleted: {}
    )
        .padding(20)
        .frame(width: 440, height: 400)
}
