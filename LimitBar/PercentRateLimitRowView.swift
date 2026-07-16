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
    let anomaly: QuotaAnomalyState?
    let insightsStorageAvailable: Bool
    var showsAnalysis = true

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

            if showsAnalysis {
                insightText
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let anomaly {
                    Text(PercentRateLimitPresentation.anomalyDisclosure(anomaly))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("quota-anomaly-disclosure")
                }
            }
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
            case let .unavailable(finding):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measured: \(finding.measuredObservationCount) observations over \(duration(finding.measuredSpan)).")
                    Text(PercentRateLimitPresentation.methodDisclosure(insight))
                        .accessibilityIdentifier("quota-insight-method")
                        .accessibilityLabel(PercentRateLimitPresentation.methodDisclosure(insight))
                        .accessibilityValue(PercentRateLimitPresentation.methodDisclosure(insight))
                }
            case let .qualified(finding):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measured: \(finding.measuredObservationCount) observations over \(duration(finding.measuredSpan)).")
                    Text(PercentRateLimitPresentation.methodDisclosure(insight))
                        .accessibilityIdentifier("quota-insight-method")
                        .accessibilityLabel(PercentRateLimitPresentation.methodDisclosure(insight))
                        .accessibilityValue(PercentRateLimitPresentation.methodDisclosure(insight))
                    Text(calculatedText(finding))
                }
            }
        } else {
            Text("Measured: collecting observations. Calculated findings unavailable.")
        }
    }

    private func calculatedText(_ finding: QualifiedQuotaInsight) -> String {
        let burn = finding.calculatedBurnPercentPerHour
        let range = PercentRateLimitPresentation.burnRange(burn)
        guard let exhaustion = finding.calculatedExhaustionRange else {
            return "Calculated: recent burn \(range); exhaustion not projected before reset."
        }
        return "Calculated: recent burn \(range); exhaustion range \(PercentRateLimitPresentation.exhaustionRange(exhaustion))."
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

    static func methodDisclosure(_ insight: QuotaInsightState) -> String {
        switch insight {
        case let .qualified(finding):
            "Calculated \(finding.forecastMethod.rawValue) qualified; provider weighting is unknown."
        case let .unavailable(finding):
            "Calculated \(finding.forecastMethod.rawValue) unavailable: \(finding.reason.displayText.lowercased())."
        }
    }

    static func anomalyDisclosure(_ state: QuotaAnomalyState) -> String {
        switch state {
        case let .finding(finding):
            return "Calculated anomaly qualified using \(finding.metadata.method.rawValue). \(limitationDisclosure(finding.metadata.limitations))"
        case let .noFinding(finding):
            return "Calculated anomaly check qualified using \(finding.metadata.method.rawValue); no anomaly found. \(limitationDisclosure(finding.metadata.limitations))"
        case let .observedZero(finding):
            return "Calculated anomaly check qualified using \(finding.metadata.method.rawValue); Observed Zero. \(limitationDisclosure(finding.metadata.limitations))"
        case let .unavailable(finding):
            return "Anomaly analysis unavailable using \(finding.metadata.method.rawValue): \(finding.reason.rawValue). \(limitationDisclosure(finding.metadata.limitations))"
        }
    }

    static func burnRange(_ range: QuotaInsightRange) -> String {
        "\(burnBound(range.lower))-\(burnBound(range.upper))% per hour"
    }

    static func exhaustionRange(
        _ range: ClosedRange<Date>,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if calendar.isDate(range.lowerBound, inSameDayAs: range.upperBound) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        }
        return "\(formatter.string(from: range.lowerBound))-\(formatter.string(from: range.upperBound))"
    }

    private static func burnBound(_ value: Double) -> String {
        if value > 0, value < 0.005 { return "<0.01" }
        return value < 1 ? String(format: "%.2f", value) : String(format: "%.1f", value)
    }

    private static func limitationDisclosure(_ limitations: [QuotaAnomalyLimitation]) -> String {
        guard !limitations.isEmpty else { return "No recorded limitations." }
        let labels = limitations.map { limitation in
            switch limitation {
            case .providerWeightingUnknown: "Provider weighting unknown"
            case .noCausalAttribution: "No causal attribution"
            case .syntheticFixtureValidationOnly: "Method validated with synthetic fixtures only"
            case .incompatibleAdapterVersion: "Incompatible adapter version"
            case .incompatibleClientVersion: "Incompatible client version"
            case .incompatibleProviderFormatVersion: "Incompatible provider format version"
            case .supersededEvidenceExcluded: "Superseded evidence excluded"
            }
        }
        return "Limitations: \(labels.joined(separator: "; "))."
    }
}
