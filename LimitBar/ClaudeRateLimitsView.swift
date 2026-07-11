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
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(snapshot.limits.enumerated()), id: \.offset) { _, limit in
                            RateLimitRowView(limit: limit)
                        }
                    }
                }
                .scrollIndicators(.hidden)

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

            Spacer(minLength: 0)
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

private struct RateLimitRowView: View {
    let limit: ClaudeRateLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.displayLabel)
                    .font(.subheadline.weight(.semibold))
                if limit.isActive {
                    Text("Active")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text("\(Int(limit.percentRemaining.rounded(.down)))% left")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(usageColor)
            }

            ProgressView(value: min(limit.percentUsed, 100), total: 100)
                .tint(usageColor)

            HStack {
                Text("\(Int(limit.percentUsed.rounded()))% used")
                Spacer()
                if let resetsAt = limit.resetsAt {
                    Text("Resets \(resetsAt.formatted(date: .abbreviated, time: .standard))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var usageColor: Color {
        if limit.severity == .exceeded || limit.percentUsed >= 90 {
            return .red
        }
        if limit.severity == .warning || limit.percentUsed >= 70 {
            return .yellow
        }
        return .green
    }
}

#Preview {
    ClaudeRateLimitsView()
        .padding(20)
        .frame(width: 440, height: 400)
}
