import SwiftUI
import LimitBarCore

struct ClaudeRateLimitsView: View {
    private enum LoadState: Equatable {
        case loading
        case loaded(ClaudeRateLimitSnapshot, subscription: String?)
        case failed(String)
    }

    @State private var state = LoadState.loading
    @State private var isRefreshing = false

    private let client = ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Uses your existing Claude Code login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isRefreshing ? "Refreshing..." : "Refresh") {
                    Task { await refresh() }
                }
                .disabled(isRefreshing)
            }

            switch state {
            case .loading:
                ProgressView("Loading Claude rate limits")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            case let .failed(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            case let .loaded(snapshot, subscription):
                let displayed = snapshot.displayLimits(forSubscriptionType: subscription)
                VStack(spacing: 10) {
                    ForEach(Array(displayed.enumerated()), id: \.offset) { _, limit in
                        PercentRateLimitRowView(
                            label: limit.displayLabel,
                            percentUsed: limit.percentUsed,
                            severity: limit.severity,
                            resetsAt: limit.resetsAt,
                            isActive: limit.isActive
                        )
                    }
                }

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
            await refresh()
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let credential: ClaudeCodeOAuthCredential
        switch ClaudeCodeCredentialReader.read() {
        case let .found(found):
            credential = found
        case .notFound:
            state = .failed("No Claude Code login found. Sign in with the claude CLI first.")
            return
        case .accessDenied:
            state = .failed("Keychain access to the Claude Code login was denied.")
            return
        }

        switch await client.fetchRateLimits(accessToken: credential.accessToken) {
        case let .success(snapshot):
            state = .loaded(snapshot, subscription: credential.subscriptionType)
        case let .failure(failure):
            if failure == .expiredLogin, credential.isExpired() {
                state = .failed("Claude login expired. Open Claude Code to refresh it.")
            } else {
                state = .failed(failure.displayText)
            }
        }
    }
}

#Preview {
    ClaudeRateLimitsView()
        .padding(20)
        .frame(width: 440, height: 400)
}
