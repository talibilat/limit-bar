import SwiftUI
import LimitBarCore
import CryptoKit

enum InvestigationPublicationState: Equatable {
    case available
    case partial
    case loading
    case empty
    case unavailable
    case error

    var label: String {
        switch self {
        case .available: "Available"
        case .partial: "Partial evidence"
        case .loading: "Loading - prior coherent publication retained when available"
        case .empty: "Empty range - no normalized quota evidence"
        case .unavailable: "Unavailable - normalized quota evidence is not available"
        case .error: "Error - the last coherent investigation remains unchanged"
        }
    }
}

struct InvestigationFindingPresentation: Equatable {
    let status: String
    let summary: String
    let details: String
}

struct InvestigationRecord: Identifiable, Equatable {
    let id: String
    let identity: QuotaWindowIdentity?
    let resetBoundary: Date?
    let start: Date
    let end: Date
    let authoritativeTotal: String
    let localBreakdown: String
    let unattributed: String
    let forecast: InvestigationFindingPresentation
    let anomaly: InvestigationFindingPresentation
    let version: String
    let limitations: String
    let traces: String
    let freshness: String
    let isGap: Bool
    let isObservedZero: Bool
    var exportMovement: DiagnosticEvidenceMovement? = nil
    var exportLocalTokenCount: Int64? = nil
    var exportLocalSessionCount: Int? = nil
    var exportAllocation: DiagnosticEvidenceAllocation? = nil
    var exportForecast: DiagnosticEvidenceForecast? = nil
    var exportAnomaly: DiagnosticEvidenceAnomaly? = nil
    var exportVersions: [DiagnosticEvidenceVersion] = []
    var exportLimitations: [DiagnosticEvidenceLimitation] = []
}

struct InvestigationProductEvidence: Identifiable, Equatable {
    var id: ProviderProduct { product }
    let product: ProviderProduct
    let records: [InvestigationRecord]
}

struct ForensicInvestigationSnapshot: Equatable {
    let generation: UInt64?
    let pendingGeneration: UInt64?
    let publicationState: InvestigationPublicationState
    let publishedAt: Date
    let products: [InvestigationProductEvidence]
    let apiEvidenceNotice: String
    let message: String?

    init(
        generation: UInt64? = nil,
        pendingGeneration: UInt64? = nil,
        publicationState: InvestigationPublicationState,
        publishedAt: Date,
        products: [InvestigationProductEvidence],
        apiEvidenceNotice: String,
        message: String?
    ) {
        self.generation = generation
        self.pendingGeneration = pendingGeneration
        self.publicationState = publicationState
        self.publishedAt = publishedAt
        self.products = products
        self.apiEvidenceNotice = apiEvidenceNotice
        self.message = message
    }

    var supportedProducts: [ProviderProduct] { products.map(\.product) }

    static func empty(publishedAt: Date, generation: UInt64? = nil) -> Self {
        Self(
            generation: generation,
            publicationState: .empty,
            publishedAt: publishedAt,
            products: [],
            apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary,
            message: "Select a later range after LimitBar has collected normalized quota observations."
        )
    }

    func loading(pendingGeneration: UInt64?) -> Self {
        Self(
            generation: generation,
            pendingGeneration: pendingGeneration,
            publicationState: .loading,
            publishedAt: publishedAt,
            products: products,
            apiEvidenceNotice: apiEvidenceNotice,
            message: products.isEmpty
                ? "Waiting for the first coherent publication. Partial refresh results are not shown."
                : "Loading a newer generation. The prior coherent generation remains visible and is marked retained."
        )
    }

    func failed(pendingGeneration: UInt64?) -> Self {
        Self(
            generation: generation,
            pendingGeneration: pendingGeneration,
            publicationState: .error,
            publishedAt: publishedAt,
            products: products,
            apiEvidenceNotice: apiEvidenceNotice,
            message: products.isEmpty
                ? "No coherent investigation has been published. Missing values are not treated as zero."
                : "The newer generation failed. The prior coherent generation remains visible and is marked retained."
        )
    }
}

enum ForensicInvestigationPresentation {
    static func forecast(_ state: QuotaInsightState?) -> InvestigationFindingPresentation {
        guard let state else {
            return InvestigationFindingPresentation(status: "Unavailable", summary: "Forecast unavailable", details: "No forecast finding was published for this exact quota window.")
        }
        switch state {
        case let .qualified(value):
            let exhaustion = value.calculatedExhaustionRange.map {
                "Calculated exhaustion range \(exact($0.lowerBound)) to \(exact($0.upperBound)), before the Reported reset"
            } ?? "Calculated exhaustion is not projected before the Reported reset"
            return InvestigationFindingPresentation(
                status: "Qualified",
                summary: "Calculated burn \(PercentRateLimitPresentation.burnRange(value.calculatedBurnPercentPerHour)). \(exhaustion).",
                details: "\(value.measuredObservationCount) Measured observations over \(duration(value.measuredSpan)); evidence age \(duration(value.evidenceAge)); latest \(exact(value.latestObservationAt)); method \(value.forecastMethod.rawValue); qualification qualified; traces \(traceList(value.inputObservationIdentities)); interpretation \(value.interpretationVersions.map(\.rawValue).joined(separator: ", ")); method limitations: \(forecastLimitations(value.forecastMethod))."
            )
        case let .unavailable(value):
            return InvestigationFindingPresentation(
                status: "Unavailable",
                summary: "Unavailable - no point estimate is shown.",
                details: "Reason \(value.reason.rawValue); \(value.measuredObservationCount) Measured observations over \(duration(value.measuredSpan)); evidence age \(value.evidenceAge.map(duration) ?? "unavailable"); method \(value.forecastMethod.rawValue); qualification unavailable; traces \(traceList(value.inputObservationIdentities)); interpretation \(value.interpretationVersions.map(\.rawValue).joined(separator: ", ")); method limitations: \(forecastLimitations(value.forecastMethod))."
            )
        }
    }

    static func anomaly(_ state: QuotaAnomalyState?) -> InvestigationFindingPresentation {
        guard let state else {
            return InvestigationFindingPresentation(status: "Unavailable", summary: "Anomaly analysis unavailable", details: "No anomaly result was published for this exact quota window.")
        }
        switch state {
        case let .finding(value):
            return anomalyPresentation(
                status: "Finding",
                summary: "Calculated higher movement: \(decimal(value.calculatedCurrentValue)) versus baseline median \(decimal(value.calculatedBaselineMedian)); score \(decimal(value.calculatedRatio))x; unattributed.",
                metadata: value.metadata
            )
        case let .noFinding(value):
            return anomalyPresentation(
                status: "No finding",
                summary: "Qualified analysis found no anomaly. Calculated current value \(decimal(value.calculatedCurrentValue)); baseline median \(decimal(value.calculatedBaselineMedian)).",
                metadata: value.metadata
            )
        case let .observedZero(value):
            return anomalyPresentation(
                status: "Observed Zero",
                summary: "Observed Zero - trustworthy Measured inputs produced a Calculated zero current value. This is not a Gap.",
                metadata: value.metadata
            )
        case let .unavailable(value):
            let status = value.reason == .gap ? "Unavailable - Gap" : "Unavailable"
            return anomalyPresentation(
                status: status,
                summary: "Analysis unavailable: \(value.reason.rawValue). No numerical finding is shown.",
                metadata: value.metadata
            )
        }
    }

    private static func anomalyPresentation(status: String, summary: String, metadata: QuotaAnomalyResultMetadata) -> InvestigationFindingPresentation {
        let current = metadata.currentPeriod.map(period) ?? "current period unavailable"
        let baseline = metadata.baselinePeriod.map(period) ?? "baseline period unavailable"
        let versions = metadata.evidenceVersions.map {
            "adapter \($0.adapter.rawValue), client \($0.client.rawValue), provider format \($0.providerFormat.rawValue)"
        }.joined(separator: "; ")
        return InvestigationFindingPresentation(
            status: status,
            summary: summary,
            details: "Current \(current); trailing baseline \(baseline); method \(metadata.method.rawValue); qualification \(metadata.qualification.rawValue); traces \(traceList(metadata.inputObservationIdentities)); evidence versions \(versions.isEmpty ? "unavailable" : versions); limitations \(metadata.limitations.map(\.rawValue).joined(separator: ", "))."
        )
    }

    private static func period(_ value: QuotaAnomalyPeriod) -> String {
        "\(exact(value.start)) to \(exact(value.end)) (\(value.inclusionRule.rawValue))"
    }

    static func exact(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }

    static func intersects(start: Date, end: Date, rangeStart: Date, rangeEnd: Date) -> Bool {
        end > rangeStart && start < rangeEnd
    }

    static func privacyTrace(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func traceList(_ values: [QuotaObservationIdentity]) -> String {
        values.isEmpty ? "unavailable" : values.map { String($0.digest.prefix(12)) }.joined(separator: ", ")
    }

    private static func forecastLimitations(_ method: QuotaForecastMethod) -> String {
        switch method {
        case .pairwisePositiveSlopeInterquartileV2:
            "provider capacity and weighting are unknown; the interquartile range is not a probability interval; future workload and unobserved activity are unknown; qualification is validated against a frozen synthetic replay that does not establish real-user representativeness or empirical forecast quality"
        case .pairwisePositiveSlopeInterquartileV1:
            "legacy method scope; provider capacity and weighting are unknown; the calculated range is not a probability interval and has no current empirical quality claim"
        }
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private static func decimal(_ value: Double) -> String { String(format: "%.2f", value) }
}

struct ForensicInvestigationInput {
    let generation: UInt64?
    let publishedAt: Date
    let codexSnapshot: CodexRateLimitSnapshot?
    let codexExplanation: CodexQuotaExplanationState
    let codexExplanationRetained: Bool
    let claudeExplanationCatalog: ClaudeQuotaExplanationCatalog
    let forecasts: [QuotaWindowIdentity: QuotaInsightState]
    let anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    let storageAvailable: Bool
    let storeOpen: Bool
}

enum ForensicInvestigationAssembler {
    static func make(_ input: ForensicInvestigationInput) -> ForensicInvestigationSnapshot {
        var products: [InvestigationProductEvidence] = []
        var claudeRecords = input.claudeExplanationCatalog.selections.map {
            claudeRecord($0, forecasts: input.forecasts, anomalies: input.anomalies)
        }
        claudeRecords += analyticsOnlyRecords(
            product: .claudeCode,
            excluding: Set(claudeRecords.compactMap(\.identity)),
            forecasts: input.forecasts,
            anomalies: input.anomalies
        )
        if !claudeRecords.isEmpty {
            products.append(InvestigationProductEvidence(
                product: .claudeCode,
                records: claudeRecords.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            ))
        }
        var codexRecords: [InvestigationRecord] = []
        if let record = codexRecord(
            input.codexExplanation,
            retained: input.codexExplanationRetained,
            snapshot: input.codexSnapshot,
            forecasts: input.forecasts,
            anomalies: input.anomalies
        ) { codexRecords.append(record) }
        codexRecords += analyticsOnlyRecords(
            product: .codex,
            excluding: Set(codexRecords.compactMap(\.identity)),
            forecasts: input.forecasts,
            anomalies: input.anomalies
        )
        if !codexRecords.isEmpty {
            products.append(InvestigationProductEvidence(
                product: .codex,
                records: codexRecords.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            ))
        }
        guard !products.isEmpty else {
            if !input.storageAvailable || !input.storeOpen {
                return ForensicInvestigationSnapshot(
                    generation: input.generation,
                    publicationState: .error,
                    publishedAt: input.publishedAt,
                    products: [],
                    apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary,
                    message: "Normalized quota evidence could not be loaded. Existing concise status rows remain independent and no missing value is treated as zero."
                )
            }
            return .empty(publishedAt: input.publishedAt, generation: input.generation)
        }
        let partial = products.flatMap(\.records).contains { $0.isGap || $0.forecast.status == "Unavailable" || $0.anomaly.status.hasPrefix("Unavailable") }
        return ForensicInvestigationSnapshot(
            generation: input.generation,
            publicationState: partial ? .partial : .available,
            publishedAt: input.publishedAt,
            products: products,
            apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary,
            message: partial ? "Independent qualified sections remain available; unavailable sections are not presented as zero." : nil
        )
    }

    private static func analyticsOnlyRecords(
        product: ProviderProduct,
        excluding: Set<QuotaWindowIdentity>,
        forecasts: [QuotaWindowIdentity: QuotaInsightState],
        anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    ) -> [InvestigationRecord] {
        let identities = Set(forecasts.keys.filter { $0.product == product } + anomalies.keys.filter { $0.product == product })
        return identities.subtracting(excluding).compactMap { identity in
            guard let interval = analyticsInterval(forecast: forecasts[identity], anomaly: anomalies[identity]) else { return nil }
            let record = InvestigationRecord(
                id: "analytics-\(identity.product.rawValue)-\(identity.identifier)-\(identity.resetBoundary.timeIntervalSince1970)",
                identity: identity,
                resetBoundary: identity.resetBoundary,
                start: interval.start,
                end: interval.end,
                authoritativeTotal: "Authoritative quota observations exist, but a comparable movement total is unavailable for this exact range.",
                localBreakdown: "Observed Local Breakdown unavailable. This is a Gap, not Observed Zero.",
                unattributed: "Unattributed: no local activity is assigned to the authoritative quota observations.",
                forecast: ForensicInvestigationPresentation.forecast(forecasts[identity]),
                anomaly: ForensicInvestigationPresentation.anomaly(anomalies[identity]),
                version: "Explanation adapter/client version unavailable - no explanation interval was published. Analytics versions remain in their finding details.",
                limitations: "Movement cannot be calculated safely from this published finding alone. No interpolation, allocation, or exact movement is inferred.",
                traces: "Bounded analytics traces are listed in the forecast and anomaly findings.",
                freshness: "Current generation analytics; source freshness follows the displayed evidence age.",
                isGap: true,
                isObservedZero: false
            )
            return exporting(
                record,
                movement: nil,
                localTokenCount: nil,
                localSessionCount: nil,
                allocation: nil,
                forecast: forecasts[identity],
                anomaly: anomalies[identity],
                adapterVersion: nil,
                clientVersion: nil
            )
        }
    }

    private static func analyticsInterval(forecast: QuotaInsightState?, anomaly: QuotaAnomalyState?) -> DateInterval? {
        if let forecast {
            switch forecast {
            case let .qualified(value):
                let start = value.latestObservationAt.addingTimeInterval(-value.measuredSpan)
                if start < value.latestObservationAt { return DateInterval(start: start, end: value.latestObservationAt) }
            case let .unavailable(value):
                if let createdAt = value.createdAt, let age = value.evidenceAge {
                    let end = createdAt.addingTimeInterval(-age)
                    let start = end.addingTimeInterval(-value.measuredSpan)
                    if start < end { return DateInterval(start: start, end: end) }
                }
            }
        }
        let metadata: QuotaAnomalyResultMetadata? = switch anomaly {
        case let .finding(value): value.metadata
        case let .noFinding(value): value.metadata
        case let .observedZero(value): value.metadata
        case let .unavailable(value): value.metadata
        case nil: nil
        }
        if let start = metadata?.baselinePeriod?.start ?? metadata?.currentPeriod?.start,
           let end = metadata?.currentPeriod?.end ?? metadata?.baselinePeriod?.end,
           start < end {
            return DateInterval(start: start, end: end)
        }
        return nil
    }

    private static func claudeRecord(
        _ selection: ClaudeQuotaExplanationSelection,
        forecasts: [QuotaWindowIdentity: QuotaInsightState],
        anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    ) -> InvestigationRecord {
        let value: ClaudeQuotaExplanation?
        switch selection.state {
        case let .movement(item), let .flat(item): value = item
        case .unavailable: value = nil
        }
        let local: String
        let observedZero: Bool
        if let value {
            switch value.attribution {
            case let .partial(breakdown):
                local = "Measured Observed Local Breakdown: \(breakdown.inputTokens) input, \(breakdown.outputTokens) output, \(breakdown.cacheReadTokens) cache-read, and \(breakdown.cacheCreationTokens) cache-creation tokens; \(breakdown.sessionCount) privacy-safe sessions; models \(breakdown.modelCounts.keys.sorted().joined(separator: ", ")). Not added to the provider total."
                observedZero = false
            case .observedZero:
                local = "Measured Observed Zero local activity with complete supported evidence coverage. This is not a Gap."
                observedZero = true
            case let .unavailable(reason):
                local = "Observed Local Breakdown unavailable: \(reason.rawValue). This is a Gap, not zero usage."
                observedZero = false
            }
        } else {
            local = "Observed Local Breakdown unavailable because the interval cannot be compared safely. This is a Gap, not zero usage."
            observedZero = false
        }
        let movement = value.map { "Reported percentage observations; Calculated movement: \($0.reportedQuotaMovementPercent.formatted()) percentage points." }
            ?? "Reported percentage observations unavailable: \(selection.state.displayText)"
        let limitations = selection.limitations.map(\.rawValue).joined(separator: ", ")
        let record = InvestigationRecord(
            id: selection.interval.id,
            identity: selection.interval.identity,
            resetBoundary: selection.interval.identity.resetBoundary,
            start: selection.interval.intervalStart,
            end: selection.interval.intervalEnd,
            authoritativeTotal: movement,
            localBreakdown: local,
            unattributed: allocationText(value?.inferredAllocation),
            forecast: ForensicInvestigationPresentation.forecast(forecasts[selection.interval.identity]),
            anomaly: ForensicInvestigationPresentation.anomaly(anomalies[selection.interval.identity]),
            version: "Explanation method \(value?.methodVersion ?? ClaudeQuotaExplanationEngine.methodVersion); source adapter \(value?.sourceAdapterVersion ?? ClaudeCodeOTLPEvidenceAdapter.adapterVersion); source/client version \(value?.sourceVersion ?? "unavailable - not captured").",
            limitations: "Limitations: \(limitations.isEmpty ? "none recorded" : limitations). Exact source traces: \(value?.observationIdentityCount ?? 0) Reported observations and \(value?.evidenceIdentityCount ?? 0) Measured evidence items; observation span \(value.map { ForensicInvestigationPresentation.duration($0.observationSpan) } ?? "unavailable"); evidence age \(value.map { ForensicInvestigationPresentation.duration($0.evidenceAge) } ?? "unavailable").",
            traces: explanationTraces(observations: value?.observationIdentities ?? [], evidence: value?.evidenceIdentities ?? []),
            freshness: value.map { "Source evidence age \(ForensicInvestigationPresentation.duration($0.evidenceAge)); \($0.lifecycle.rawValue) exact window." } ?? "Source freshness unavailable.",
            isGap: value == nil || value.map { if case .unavailable = $0.attribution { true } else { false } } == true,
            isObservedZero: observedZero
        )
        return exporting(
            record,
            movement: value.flatMap { try? DiagnosticEvidenceMovement(value: $0.reportedQuotaMovementPercent, unit: .percentagePoints, provenance: .calculated) },
            localTokenCount: value.flatMap { explanation in
                guard case let .partial(breakdown) = explanation.attribution else { return nil }
                let values = [breakdown.inputTokens, breakdown.outputTokens, breakdown.cacheReadTokens, breakdown.cacheCreationTokens]
                var total: Int64 = 0
                for value in values {
                    let result = total.addingReportingOverflow(value)
                    guard !result.overflow else { return nil }
                    total = result.partialValue
                }
                return total
            },
            localSessionCount: value.flatMap {
                if case let .partial(breakdown) = $0.attribution { return breakdown.sessionCount }
                return nil
            },
            allocation: value?.inferredAllocation,
            forecast: forecasts[selection.interval.identity],
            anomaly: anomalies[selection.interval.identity],
            adapterVersion: value?.sourceAdapterVersion ?? ClaudeCodeOTLPEvidenceAdapter.adapterVersion,
            clientVersion: value?.sourceVersion
        )
    }

    private static func codexRecord(
        _ explanation: CodexQuotaExplanationState,
        retained: Bool,
        snapshot: CodexRateLimitSnapshot?,
        forecasts: [QuotaWindowIdentity: QuotaInsightState],
        anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    ) -> InvestigationRecord? {
        let value: CodexQuotaExplanation?
        let zero: CodexQuotaObservedZero?
        switch explanation {
        case let .available(item), let .partial(item): value = item; zero = nil
        case let .observedZero(item): value = nil; zero = item
        case .unavailable: value = nil; zero = nil
        }
        let reset = value?.quotaResetBoundary ?? zero?.quotaResetBoundary
        _ = snapshot // Snapshot evidence must never substitute an identity omitted by legacy findings.
        let identity = value?.quotaWindowIdentity ?? zero?.quotaWindowIdentity
        let start = value?.intervalStart ?? zero?.intervalStart
        let end = value?.intervalEnd ?? zero?.intervalEnd
        guard let start, let end, start < end else { return nil }
        let observedZero = zero != nil
        let local = value.map {
            let tokens = $0.observedLocalBreakdown.tokens
            return "Measured Observed Local Breakdown: \(tokens.total) tokens across \($0.observedLocalBreakdown.sessionCount) privacy-safe sessions; input \(tokens.input), cached input \(tokens.cachedInput), output \(tokens.output), reasoning output \(tokens.reasoningOutput). Not added to the provider total."
        } ?? (observedZero
            ? "Measured Observed Zero local activity with complete supported evidence coverage. This is not a Gap."
            : "Observed Local Breakdown unavailable. This is a Gap, not zero usage.")
        let record = InvestigationRecord(
            id: "codex-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)",
            identity: identity,
            resetBoundary: reset,
            start: start,
            end: end,
            authoritativeTotal: value.map { "Measured local quota observations; Calculated movement: \($0.calculatedQuotaMovementPercent.formatted()) percentage points." }
                ?? zero.map { "Measured local quota observations; Calculated movement: \($0.calculatedQuotaMovementPercent.formatted()) percentage points." }
                ?? "Measured local quota observations unavailable: \(explanation.displayText)",
            localBreakdown: local,
            unattributed: allocationText(value?.inferredAllocation),
            forecast: ForensicInvestigationPresentation.forecast(identity.flatMap { forecasts[$0] }),
            anomaly: ForensicInvestigationPresentation.anomaly(identity.flatMap { anomalies[$0] }),
            version: "Explanation method \(CodexQuotaExplanationEngine.methodVersion); adapter \(value?.adapterVersion ?? CodexRolloutEvidenceAdapter.adapterVersion); client version unavailable - not captured.",
            limitations: value.map { "Exact source traces: \($0.observationIdentityCount) Measured quota observations and \($0.evidenceIdentityCount) Measured evidence items; barriers \($0.barriers.map(\.rawValue).joined(separator: ", ")). Local token activity cannot be converted to provider quota percentage." } ?? "No comparable explanation interval. Local token activity cannot be converted to provider quota percentage.",
            traces: explanationTraces(observations: value?.observationIdentities ?? zero?.observationIdentities ?? [], evidence: value?.evidenceIdentities ?? zero?.evidenceIdentities ?? []),
            freshness: retained ? "Retained/stale explanation from an earlier publication; not fresh evidence for this generation." : "Fresh explanation from this coherent generation.",
            isGap: value == nil && zero == nil,
            isObservedZero: observedZero
        )
        return exporting(
            record,
            movement: (value?.calculatedQuotaMovementPercent ?? zero?.calculatedQuotaMovementPercent).flatMap {
                try? DiagnosticEvidenceMovement(value: $0, unit: .percentagePoints, provenance: .calculated)
            },
            localTokenCount: value?.observedLocalBreakdown.tokens.total,
            localSessionCount: value?.observedLocalBreakdown.sessionCount,
            allocation: value?.inferredAllocation,
            forecast: identity.flatMap { forecasts[$0] },
            anomaly: identity.flatMap { anomalies[$0] },
            adapterVersion: value?.adapterVersion ?? CodexRolloutEvidenceAdapter.adapterVersion,
            clientVersion: nil
        )
    }

    private static func explanationTraces(observations: [QuotaObservationIdentity], evidence: [String]) -> String {
        let observationTraces = observations.map { String($0.digest.prefix(12)) }
        let evidenceTraces = evidence.map(ForensicInvestigationPresentation.privacyTrace)
        return "Privacy-safe bounded traces - observations: \(observationTraces.isEmpty ? "unavailable" : observationTraces.joined(separator: ", ")); local evidence: \(evidenceTraces.isEmpty ? "unavailable" : evidenceTraces.joined(separator: ", "))."
    }

    private static func allocationText(_ allocation: InferredQuotaAllocation?) -> String {
        guard let allocation else {
            return "Unattributed: provider movement is not allocated to local activity and no causal claim is made."
        }
        return "Inferred allocation: \(allocation.percent.formatted())%; method \(allocation.method.rawValue); limitations \(allocation.limitations.map(\.rawValue).joined(separator: ", ")). Remaining movement is Unattributed and no causal claim is made."
    }

    private static func exporting(
        _ source: InvestigationRecord,
        movement: DiagnosticEvidenceMovement?,
        localTokenCount: Int64?,
        localSessionCount: Int?,
        allocation: InferredQuotaAllocation?,
        forecast: QuotaInsightState?,
        anomaly: QuotaAnomalyState?,
        adapterVersion: String?,
        clientVersion: String?
    ) -> InvestigationRecord {
        var record = source
        record.exportMovement = movement
        record.exportLocalTokenCount = localTokenCount
        record.exportLocalSessionCount = localSessionCount
        record.exportAllocation = allocation.flatMap {
            try? DiagnosticEvidenceAllocation(
                percent: $0.percent,
                method: .temporalProportionalV1,
                qualification: .qualified,
                limitations: $0.limitations.compactMap { limitation in
                    switch limitation {
                    case .temporalCorrelationOnly, .noCausalAttribution: .noCausalAttribution
                    case .providerWeightingUnknown: .providerWeightingUnknown
                    }
                }
            )
        }
        record.exportForecast = diagnosticForecast(forecast)
        record.exportAnomaly = diagnosticAnomaly(anomaly)
        record.exportVersions = [
            adapterVersion.flatMap { try? DiagnosticEvidenceVersion(kind: .adapter, value: $0) },
            clientVersion.flatMap { try? DiagnosticEvidenceVersion(kind: .client, value: $0) },
        ].compactMap { $0 }
        record.exportLimitations = [.providerWeightingUnknown, .noCausalAttribution, .fixtureValidationOnly]
        return record
    }

    private static func diagnosticForecast(_ state: QuotaInsightState?) -> DiagnosticEvidenceForecast? {
        switch state {
        case let .qualified(value):
            return try? DiagnosticEvidenceForecast(
                status: .available,
                method: forecastMethod(value.forecastMethod),
                qualification: .qualified,
                unavailableReason: nil,
                observationCount: value.measuredObservationCount,
                observationSpanSeconds: boundedSeconds(value.measuredSpan),
                evidenceAgeSeconds: boundedSeconds(value.evidenceAge),
                range: try DiagnosticEvidenceRange(lower: value.calculatedBurnPercentPerHour.lower, upper: value.calculatedBurnPercentPerHour.upper, unit: .percentPerHour, provenance: .calculated),
                resetInteraction: value.calculatedExhaustionRange == nil ? .notProjectedBeforeReset : .beforeReportedReset,
                limitations: [.providerWeightingUnknown, .probabilityNotEstablished, .futureWorkloadUnknown, .fixtureValidationOnly]
            )
        case let .unavailable(value):
            return try? DiagnosticEvidenceForecast(
                status: .unavailable,
                method: forecastMethod(value.forecastMethod),
                qualification: .unavailable,
                unavailableReason: forecastReason(value.reason),
                observationCount: value.measuredObservationCount,
                observationSpanSeconds: boundedSeconds(value.measuredSpan),
                evidenceAgeSeconds: value.evidenceAge.map(boundedSeconds),
                range: nil,
                resetInteraction: .unavailable,
                limitations: [.providerWeightingUnknown, .probabilityNotEstablished, .futureWorkloadUnknown, .fixtureValidationOnly]
            )
        case nil:
            return nil
        }
    }

    private static func diagnosticAnomaly(_ state: QuotaAnomalyState?) -> DiagnosticEvidenceAnomaly? {
        guard let state else { return nil }
        let metadata: QuotaAnomalyResultMetadata
        let status: DiagnosticEvidenceState
        let current: Double?
        let baseline: Double?
        let result: Double?
        switch state {
        case let .finding(value):
            metadata = value.metadata; status = .available; current = value.calculatedCurrentValue; baseline = value.calculatedBaselineMedian; result = value.calculatedRatio
        case let .noFinding(value):
            metadata = value.metadata; status = .noFinding; current = value.calculatedCurrentValue; baseline = value.calculatedBaselineMedian; result = value.calculatedRatio
        case let .observedZero(value):
            metadata = value.metadata; status = .observedZero; current = value.calculatedCurrentValue; baseline = median(value.calculatedBaselineValues); result = nil
        case let .unavailable(value):
            return try? DiagnosticEvidenceAnomaly(
                status: .unavailable,
                method: .trailingMedianRatioV1,
                qualification: .unavailable,
                unavailableReason: anomalyReason(value.reason),
                currentPeriod: nil,
                baselinePeriod: nil,
                measuredInputCount: min(10_000, value.metadata.inputObservationIdentities.count),
                currentValue: nil,
                baselineValue: nil,
                result: nil,
                limitations: [.noCausalAttribution, .fixtureValidationOnly]
            )
        }
        return try? DiagnosticEvidenceAnomaly(
            status: status,
            method: .trailingMedianRatioV1,
            qualification: metadata.qualification == .qualified ? .qualified : .unavailable,
            unavailableReason: nil,
            currentPeriod: metadata.currentPeriod.flatMap { try? DiagnosticEvidencePeriod(start: $0.start, end: $0.end) },
            baselinePeriod: metadata.baselinePeriod.flatMap { try? DiagnosticEvidencePeriod(start: $0.start, end: $0.end) },
            measuredInputCount: min(10_000, metadata.inputObservationIdentities.count),
            currentValue: current.flatMap { try? DiagnosticEvidenceValue(value: $0, unit: .percentagePoints, provenance: .calculated) },
            baselineValue: baseline.flatMap { try? DiagnosticEvidenceValue(value: $0, unit: .percentagePoints, provenance: .calculated) },
            result: result.flatMap { try? DiagnosticEvidenceValue(value: $0, unit: .ratio, provenance: .calculated) },
            limitations: [.noCausalAttribution, .fixtureValidationOnly]
        )
    }

    private static func forecastMethod(_ method: QuotaForecastMethod) -> DiagnosticEvidenceForecastMethod {
        switch method {
        case .pairwisePositiveSlopeInterquartileV1: .pairwisePositiveSlopeInterquartileV1
        case .pairwisePositiveSlopeInterquartileV2: .pairwisePositiveSlopeInterquartileV2
        }
    }

    private static func forecastReason(_ reason: QuotaInsightUnavailableReason) -> DiagnosticForecastUnavailableReason {
        switch reason {
        case .insufficientObservations: .insufficientObservations
        case .insufficientSpan: .insufficientSpan
        case .staleEvidence: .staleEvidence
        case .resetOrExpired: .resetOrExpired
        case .counterDecreased: .counterDecreased
        case .noPositiveBurn: .noPositiveBurn
        case .conflictingObservations: .conflictingObservations
        case .incompatibleEvidence: .incompatibleEvidence
        case .invalidEvaluation: .invalidEvaluation
        }
    }

    private static func anomalyReason(_ reason: QuotaAnomalyUnavailableReason) -> DiagnosticAnomalyUnavailableReason {
        switch reason {
        case .invalidEvaluation: .invalidEvaluation
        case .insufficientObservations: .insufficientObservations
        case .insufficientBaseline: .insufficientBaseline
        case .insufficientSpan: .insufficientSpan
        case .staleEvidence: .staleEvidence
        case .resetOrExpired: .resetOrExpired
        case .incompatibleEvidence: .incompatibleEvidence
        case .conflictingObservations: .conflictingObservations
        case .counterDecreased: .counterDecreased
        case .gap: .gap
        case .unstableBaseline: .unstableBaseline
        case .missingDenominator: .missingDenominator
        case .zeroDenominator: .zeroDenominator
        case .staleDenominator: .staleDenominator
        case .partialDenominatorCoverage: .partialDenominatorCoverage
        case .incompatibleDenominator: .incompatibleDenominator
        }
    }

    private static func boundedSeconds(_ value: TimeInterval) -> Int {
        min(2_592_000, max(0, Int(value.rounded())))
    }

    private static func median(_ values: [Double]) -> Double? {
        let ordered = values.filter(\.isFinite).sorted()
        guard !ordered.isEmpty else { return nil }
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2) ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle]
    }
}

enum QuotaEvidenceReportBuilder {
    static func make(
        snapshot: ForensicInvestigationSnapshot,
        product: ProviderProduct,
        rangeStart: Date,
        rangeEnd: Date
    ) throws -> DiagnosticQuotaEvidenceReport {
        let selected = snapshot.products.first { $0.product == product }?.records.filter {
            ForensicInvestigationPresentation.intersects(start: $0.start, end: $0.end, rangeStart: rangeStart, rangeEnd: rangeEnd)
        }.sorted { ($0.start, $0.end, $0.id) > ($1.start, $1.end, $1.id) } ?? []
        let records = try selected.prefix(DiagnosticExport.maximumQuotaEvidenceInputRecords).map { record in
            let forecast = try record.exportForecast ?? unavailableForecast()
            let anomaly = try record.exportAnomaly ?? unavailableAnomaly()
            let versions = record.exportVersions.isEmpty
                ? [try DiagnosticEvidenceVersion(kind: .adapter, value: "unavailable")]
                : record.exportVersions
            return try DiagnosticQuotaEvidenceRecord(
                traceReference: ForensicInvestigationPresentation.privacyTrace(record.id),
                intervalStart: record.start,
                intervalEnd: record.end,
                resetBoundary: record.resetBoundary,
                movement: record.exportMovement,
                localBreakdown: record.isObservedZero ? .observedZero : (record.isGap ? .gap : .available),
                localTokenCount: record.exportLocalTokenCount,
                localSessionCount: record.exportLocalSessionCount,
                unattributedRemainder: try remainder(movement: record.exportMovement, allocation: record.exportAllocation),
                inferredAllocation: record.exportAllocation,
                forecast: forecast,
                anomaly: anomaly,
                interpretation: product == .claudeCode ? .claudeProviderReportV1 : .codexLocalReportV1,
                versions: versions,
                limitations: record.exportLimitations.isEmpty ? [.noCausalAttribution] : record.exportLimitations
            )
        }
        return try DiagnosticQuotaEvidenceReport(
            selectedProduct: product == .claudeCode ? .claudeCode : .codex,
            selectedRange: DiagnosticEvidenceSelection(start: rangeStart, end: rangeEnd, basis: .gregorianUTC),
            publicationGeneration: snapshot.generation,
            publicationTime: snapshot.publishedAt,
            apiProviderEvidence: .unavailable,
            records: records,
            totalMatchingRecordCount: selected.count
        )
    }

    private static func remainder(movement: DiagnosticEvidenceMovement?, allocation: DiagnosticEvidenceAllocation?) throws -> DiagnosticEvidenceRemainder {
        guard let movement else {
            return try DiagnosticEvidenceRemainder(availability: .unavailable, value: nil, provenance: nil, method: nil, unavailableReason: .movementUnavailable, limitations: [.noCausalAttribution])
        }
        guard let allocation else {
            return try DiagnosticEvidenceRemainder(availability: .available, value: movement.value, provenance: .calculated, method: nil, unavailableReason: nil, limitations: [.noCausalAttribution])
        }
        let value = movement.value * (1 - allocation.percent / 100)
        guard value.isFinite, value >= 0 else {
            return try DiagnosticEvidenceRemainder(availability: .unavailable, value: nil, provenance: nil, method: nil, unavailableReason: .unsafeCalculation, limitations: [.noCausalAttribution, .providerWeightingUnknown])
        }
        return try DiagnosticEvidenceRemainder(availability: .available, value: value, provenance: .inferred, method: allocation.method, unavailableReason: nil, limitations: allocation.limitations)
    }

    private static func unavailableForecast() throws -> DiagnosticEvidenceForecast {
        try DiagnosticEvidenceForecast(status: .unavailable, method: .notPublished, qualification: .unavailable, unavailableReason: .notPublished, observationCount: 0, observationSpanSeconds: 0, evidenceAgeSeconds: nil, range: nil, resetInteraction: .unavailable, limitations: [.providerWeightingUnknown])
    }

    private static func unavailableAnomaly() throws -> DiagnosticEvidenceAnomaly {
        try DiagnosticEvidenceAnomaly(status: .unavailable, method: .notPublished, qualification: .unavailable, unavailableReason: .notPublished, currentPeriod: nil, baselinePeriod: nil, measuredInputCount: 0, currentValue: nil, baselineValue: nil, result: nil, limitations: [.noCausalAttribution])
    }
}

struct ForensicInvestigationView: View {
    let snapshot: ForensicInvestigationSnapshot
    let reduceMotionOverride: Bool?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedProduct: ProviderProduct?
    @State private var rangeStart: Date
    @State private var rangeEnd: Date

    init(snapshot: ForensicInvestigationSnapshot, reduceMotionOverride: Bool? = nil) {
        self.snapshot = snapshot
        self.reduceMotionOverride = reduceMotionOverride
        let records = snapshot.products.flatMap(\.records)
        _selectedProduct = State(initialValue: snapshot.supportedProducts.first)
        _rangeStart = State(initialValue: records.map(\.start).min() ?? snapshot.publishedAt.addingTimeInterval(-3_600))
        _rangeEnd = State(initialValue: records.map(\.end).max() ?? snapshot.publishedAt)
    }

    private var evidence: InvestigationProductEvidence? {
        snapshot.products.first { $0.product == selectedProduct }
    }

    private var records: [InvestigationRecord] {
        evidence?.records.filter {
            ForensicInvestigationPresentation.intersects(start: $0.start, end: $0.end, rangeStart: rangeStart, rangeEnd: rangeEnd)
        }.sorted { ($0.start, $0.end) < ($1.start, $1.end) } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    publicationState
                    controls
                    Text("Selected exact range: \(ForensicInvestigationPresentation.exact(rangeStart)) to \(ForensicInvestigationPresentation.exact(rangeEnd)); half-open [start, end); Gregorian calendar; UTC basis.")
                        .font(.caption)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("investigation-selected-range")
                    if snapshot.supportedProducts.isEmpty {
                        emptyState
                    } else if rangeStart >= rangeEnd {
                        stateCard("Invalid exact range", detail: "The exact start must be earlier than the exact end. No evidence is compared.")
                    } else if records.isEmpty {
                        stateCard("Empty selected range", detail: "No normalized quota evidence intersects this exact range. This is not Observed Zero.")
                    } else {
                        timeline
                        attribution
                    }
                    stateCard("API product evidence", detail: snapshot.apiEvidenceNotice, detailIdentifier: "investigation-api-unavailable")
                    Text("Coherent publication generation \(snapshot.generation.map(String.init) ?? "retained"); published \(ForensicInvestigationPresentation.exact(snapshot.publishedAt)).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 420, idealWidth: 760, minHeight: 520, idealHeight: 760)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .animation((reduceMotionOverride ?? reduceMotion) ? nil : .easeInOut(duration: 0.15), value: selectedProduct)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Forensic Quota Investigation").font(.title2.weight(.semibold))
                Text("Trace normalized evidence, methods, and limitations").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var publicationState: some View {
        stateCard(snapshot.publicationState.label, detail: snapshot.message, titleIdentifier: "investigation-publication-state")
    }

    @ViewBuilder
    private var controls: some View {
        if !snapshot.supportedProducts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Provider product", selection: $selectedProduct) {
                    ForEach(snapshot.supportedProducts, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .accessibilityIdentifier("investigation-product")
                ViewThatFits(in: .horizontal) {
                    HStack { rangePickers }
                    VStack(alignment: .leading) { rangePickers }
                }
                Text("Exact range basis: Gregorian calendar, UTC. Exact timestamps remain visible below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("investigation-range-basis")
                Button("Use latest evidence interval") {
                    guard let latest = evidence?.records.max(by: { $0.end < $1.end }) else { return }
                    rangeStart = latest.start
                    rangeEnd = latest.end
                }
                .accessibilityIdentifier("investigation-latest-range")
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private var rangePickers: some View {
        DatePicker("Exact start", selection: $rangeStart)
            .accessibilityIdentifier("investigation-range-start")
        DatePicker("Exact end", selection: $rangeEnd)
            .accessibilityIdentifier("investigation-range-end")
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chronological evidence").font(.headline)
            ForEach(records) { record in
                recordCard(record)
            }
        }
    }

    private func recordCard(_ record: InvestigationRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(ForensicInvestigationPresentation.exact(record.start)) to \(ForensicInvestigationPresentation.exact(record.end))")
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)
            if let reset = record.resetBoundary {
                Label("Reported reset: \(ForensicInvestigationPresentation.exact(reset)). Trend ends at this boundary; no line crosses the reset.", systemImage: "arrow.counterclockwise.circle")
                    .accessibilityIdentifier("investigation-reset")
            } else {
                Label("Reset unavailable - no exact reset marker is inferred.", systemImage: "questionmark.circle")
                    .accessibilityIdentifier("investigation-reset-unavailable")
            }
            evidenceLine(record.authoritativeTotal, id: "investigation-authoritative-total")
            evidenceLine(record.localBreakdown, id: "investigation-local-breakdown")
            evidenceLine(record.unattributed, id: "investigation-unattributed")
            if record.isObservedZero {
                evidenceLine("Observed Zero is trustworthy zero-valued evidence and is not a Gap.", id: "investigation-observed-zero")
            }
            if record.isGap {
                evidenceLine("Gap - no trustworthy comparable evidence covers this part of the selected range. No zero or interpolation is drawn.", id: "investigation-gap")
            }
            finding("Forecast", record.forecast, id: "investigation-forecast")
            finding("Anomaly", record.anomaly, id: "investigation-anomaly")
            evidenceLine(record.version, id: "investigation-version")
            evidenceLine(record.freshness, id: "investigation-freshness")
            evidenceLine(record.traces, id: "investigation-traces")
            Text(record.limitations).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(14)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var attribution: some View {
        if evidence != nil {
            stateCard(
                "Product-explicit attribution dimensions unavailable",
                detail: "Schema v2 records Provider identity but not provider product. Generic Anthropic API or OpenAI API project, agent, model, session, operation, and tool dimensions are not mapped to Claude Code or Codex subscription evidence.",
                detailIdentifier: "investigation-attribution-unavailable"
            )
        }
    }

    private var emptyState: some View {
        stateCard("No supported provider product evidence", detail: "Claude Code and Codex appear only after normalized quota evidence with exact reported boundaries exists. API products are not substituted.")
    }

    private func finding(_ title: String, _ value: InvestigationFindingPresentation, id: String) -> some View {
        Text("\(title): \(value.status). \(value.summary) \(value.details)")
        .font(.caption)
        .textSelection(.enabled)
        .accessibilityIdentifier(id)
    }

    private func evidenceLine(_ text: String, id: String) -> some View {
        Text(text)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier(id)
    }

    private func stateCard(_ title: String, detail: String?, titleIdentifier: String? = nil, detailIdentifier: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .optionalAccessibilityIdentifier(titleIdentifier)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .optionalAccessibilityIdentifier(detailIdentifier)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
