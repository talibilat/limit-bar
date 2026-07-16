import SwiftUI
import LimitBarCore

struct RateLimitAnalysisView: View {
    let state: LimitBarState

    private var items: [RateLimitAnalysisItem] {
        claudeItems + codexItems
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    Label("No rate-limit analysis is available yet.", systemImage: "text.magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(items) { item in
                        RateLimitAnalysisCard(item: item)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .task {
            await state.claudeModel.appeared()
            state.claudeActionCompleted()
        }
    }

    private var claudeItems: [RateLimitAnalysisItem] {
        guard state.claudeModel.isPresent else { return [] }

        switch state.claudeModel.state {
        case .loading:
            return [RateLimitAnalysisItem(
                title: "Claude Code",
                summary: "Claude Code rate-limit analysis is loading."
            )]
        case .notConnected:
            return [RateLimitAnalysisItem(
                title: "Claude Code",
                summary: "No Claude Code login was found on this Mac."
            )]
        case .authorizationRequired:
            return [RateLimitAnalysisItem(
                title: "Claude Code",
                summary: "Claude Code needs your permission before LimitBar can read its existing login.",
                detail: "LimitBar performs passive authorization checks first, so macOS is not allowed to show authentication UI in the background. Use the Claude connection flow only when you want macOS to ask for access to the existing Claude Code Keychain item."
            )]
        case let .failed(message):
            return [RateLimitAnalysisItem(
                title: "Claude Code",
                summary: "Claude Code analysis is unavailable: \(message)"
            )]
        case let .loaded(snapshot, subscription):
            let limits = snapshot.displayLimits(forSubscriptionType: subscription)
            guard let busiest = limits.max(by: { $0.percentUsed < $1.percentUsed }) else {
                return [RateLimitAnalysisItem(
                    title: "Claude Code",
                    summary: "Claude Code returned no visible rate-limit windows."
                )]
            }
            let active = limits.first(where: \.isActive)?.displayLabel
            let activeText = active.map { " The active window is \($0)." } ?? ""
            let planText = subscription.map { " Plan: \($0.capitalized)." } ?? ""
            return [RateLimitAnalysisItem(
                title: "Claude Code",
                summary: "Claude Code is at \(displayPercent(busiest.percentUsed)) used in its busiest visible window.",
                detail: "\(busiest.displayLabel) is the busiest visible Claude Code window.\(activeText)\(planText) The snapshot was fetched at \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))."
            )]
        }
    }

    private var codexItems: [RateLimitAnalysisItem] {
        guard let snapshot = state.local.codexSnapshot else {
            return [RateLimitAnalysisItem(
                title: "Codex",
                summary: "No Codex rate-limit snapshot has been found yet.",
                detail: "LimitBar reads Codex quota snapshots from local session logs. Run Codex once on this Mac to give LimitBar a local snapshot to analyze."
            )]
        }

        if snapshot.isBusinessPlan {
            return [RateLimitAnalysisItem(
                title: "Codex",
                summary: "Codex business seats are analyzed as shared credits, not personal quota windows.",
                detail: "Codex business sessions expose company-pool credits instead of personal percentage windows. LimitBar can estimate credit usage from local usage and configured pricing without making a network request."
            )]
        }

        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        guard let busiest = windows.max(by: { $0.percentUsed < $1.percentUsed }) else {
            if let credits = snapshot.credits, credits.hasCredits, let balance = credits.balance {
                return [RateLimitAnalysisItem(
                    title: "Codex",
                    summary: "Codex reports a credit balance of \(balance.description) credits.",
                    detail: "This analysis uses the freshest Codex session log found on this Mac. It does not call a Codex network endpoint."
                )]
            }
            return [RateLimitAnalysisItem(
                title: "Codex",
                summary: "Codex analysis is unavailable because no quota window was reported."
            )]
        }

        return [RateLimitAnalysisItem(
            title: "Codex",
            summary: "Codex is at \(displayPercent(busiest.percentUsed)) used in its busiest local window.",
            detail: "\(busiest.displayLabel) is the busiest Codex window in the latest local session snapshot. LimitBar read it from local logs as of \(snapshot.reportedAt.formatted(date: .omitted, time: .shortened)); no network request was made."
        )]
    }
}

private struct RateLimitAnalysisItem: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    var detail: String?

    var isLong: Bool {
        (detail ?? "").count > 120
    }
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
                .foregroundStyle(.primary)

            if let detail = item.detail {
                if item.isLong {
                    Button("Read analysis") {
                        showsDetail = true
                    }
                    .buttonStyle(.link)
                    .popover(isPresented: $showsDetail) {
                        Text(detail)
                            .font(.callout)
                            .lineSpacing(3)
                            .padding(16)
                            .frame(width: 340, alignment: .leading)
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

private func displayPercent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}
