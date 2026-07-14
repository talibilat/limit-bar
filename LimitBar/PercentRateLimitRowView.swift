import SwiftUI
import LimitBarCore

// Shared by the Claude and Codex sections of the Rate Limit tab so both
// providers' percentage-based windows render identically.
struct PercentRateLimitRowView: View {
    let label: String
    let percentUsed: Double
    let severity: ClaudeRateLimitSeverity
    let resetsAt: Date?
    let isActive: Bool
    let insight: QuotaInsightState?
    let insightsStorageAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                if isActive {
                    Text("Active")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text("\(Int(max(0, 100 - percentUsed).rounded(.down)))% left")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(usageColor)
            }

            ProgressView(value: min(percentUsed, 100), total: 100)
                .tint(usageColor)

            HStack {
                Text(PercentRateLimitPresentation.percentageUsed(percentUsed))
                Spacer()
                if let resetsAt {
                    Text("Resets \(RateLimitTimeFormatting.remainingText(now: Date(), resetsAt: resetsAt))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            insightText
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var insightText: some View {
        if !insightsStorageAvailable {
            Text("Quota insights unavailable: local storage could not be opened.")
                .foregroundStyle(.orange)
        } else if resetsAt == nil {
            Text("Quota insights unavailable: an exact reported reset is required.")
        } else if let insight {
            switch insight {
            case let .unavailable(reason, count, span):
                Text("Measured: \(count) observations over \(duration(span)). Calculated: \(reason.displayText.lowercased()).")
            case let .qualified(finding):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measured: \(finding.measuredObservationCount) observations over \(duration(finding.measuredSpan)).")
                    Text(calculatedText(finding))
                }
            }
        } else {
            Text("Measured: collecting observations. Calculated findings unavailable.")
        }
    }

    private func calculatedText(_ finding: QualifiedQuotaInsight) -> String {
        let burn = finding.calculatedBurnPercentPerHour
        let range = String(format: "%.1f-%.1f%% per hour", burn.lower, burn.upper)
        guard let exhaustion = finding.calculatedExhaustionRange else {
            return "Calculated: recent burn \(range); exhaustion not projected before reset."
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Calculated: recent burn \(range); exhaustion range \(formatter.string(from: exhaustion.lowerBound))-\(formatter.string(from: exhaustion.upperBound))."
    }

    private func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private var usageColor: Color {
        if severity == .exceeded || percentUsed >= 90 {
            return .red
        }
        if severity == .warning || percentUsed >= 70 {
            return .yellow
        }
        return .green
    }
}

enum PercentRateLimitPresentation {
    static func percentageUsed(_ percentage: Double) -> String {
        "Measured: \(Int(percentage.rounded()))% used"
    }
}
