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
                Text("\(Int(percentUsed.rounded()))% used")
                Spacer()
                if let resetsAt {
                    Text("Resets \(RateLimitTimeFormatting.remainingText(now: Date(), resetsAt: resetsAt))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
