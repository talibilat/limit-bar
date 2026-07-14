import SwiftUI
import LimitBarCore

struct ClaudeRateLimitsView: View {
    @Bindable var model: ClaudeRateLimitsModel
    let insights: [QuotaWindowIdentity: QuotaInsightState]
    let insightsStorageAvailable: Bool
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
                HStack {
                    Text("No Claude Code login found.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") {
                        Task {
                            await model.refresh()
                            onActionCompleted()
                        }
                    }
                    Button("Connect") {
                        Task {
                            await model.connect()
                            onActionCompleted()
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
                            insightsStorageAvailable: insightsStorageAvailable
                        )
                    }
                }
                .accessibilityIdentifier("claude-loaded-state")

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
        guard limit.scopeDisplayName == nil, let reset = limit.resetsAt,
              let identity = try? QuotaWindowIdentity(
                  product: .claudeCode,
                  identifier: "\(limit.group.rawValue):\(limit.kind)",
                  resetBoundary: reset
              ) else { return nil }
        return insights[identity]
    }
}

#Preview {
    ClaudeRateLimitsView(
        model: ClaudeRateLimitsModel(
            credentials: ClaudeCredentialBroker.shared,
            client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
        ),
        insights: [:],
        insightsStorageAvailable: true,
        onActionCompleted: {}
    )
        .padding(20)
        .frame(width: 440, height: 400)
}
