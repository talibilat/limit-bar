import SwiftUI
import LimitBarCore

struct CodexRateLimitsView: View {
    private enum LoadState: Equatable {
        case loading
        case loaded(CodexRateLimitSnapshot)
        case failed(String)
    }

    let metrics: [UsageMetric]
    let pricingTable: PricingTable

    @State private var state = LoadState.loading

    private var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read from your local Codex session logs; no network call is made.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch state {
            case .loading:
                ProgressView("Loading Codex rate limits")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            case let .failed(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            case let .loaded(snapshot):
                if snapshot.isBusinessPlan {
                    businessCreditsSection
                } else {
                    individualPlanSection(snapshot)
                }

                Text("As of \(snapshot.reportedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await load()
        }
    }

    @ViewBuilder
    private var businessCreditsSection: some View {
        let estimate = CodexCreditsEstimator.estimate(from: metrics, pricing: pricingTable)
        VStack(spacing: 10) {
            CreditsUsageRowView(label: "Today", cost: estimate.today)
            CreditsUsageRowView(label: "Current Week", cost: estimate.currentWeek)
        }
        Text("Business plan: company-pool credit usage only. Configure credits pricing in Settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func individualPlanSection(_ snapshot: CodexRateLimitSnapshot) -> some View {
        VStack(spacing: 10) {
            if let primary = snapshot.primary {
                PercentRateLimitRowView(label: primary.displayLabel, percentUsed: primary.percentUsed, severity: .unknown, resetsAt: primary.resetsAt, isActive: false)
            }
            if let secondary = snapshot.secondary {
                PercentRateLimitRowView(label: secondary.displayLabel, percentUsed: secondary.percentUsed, severity: .unknown, resetsAt: secondary.resetsAt, isActive: false)
            }
            if let credits = snapshot.credits, credits.hasCredits, let balance = credits.balance {
                CreditsUsageRowView(label: "Credits balance", cost: Cost(amount: balance, currencyCode: "credits", source: .providerReported))
            }
        }
    }

    private func load() async {
        do {
            let snapshot = try CodexSessionRateLimitReader.latestSnapshot(sessionsDirectory: sessionsDirectory, now: Date())
            state = .loaded(snapshot)
        } catch let failure as CodexRateLimitFailure {
            state = .failed(failure.displayText)
        } catch {
            state = .failed("Codex session data could not be read.")
        }
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
    CodexRateLimitsView(metrics: [], pricingTable: .empty)
        .padding(20)
        .frame(width: 440, height: 300)
}
