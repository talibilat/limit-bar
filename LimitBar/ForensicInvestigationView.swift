import SwiftUI
import LimitBarCore

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
        case .loading: "Loading - no coherent investigation published yet"
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
    let identity: QuotaWindowIdentity
    let start: Date
    let end: Date
    let authoritativeTotal: String
    let localBreakdown: String
    let unattributed: String
    let forecast: InvestigationFindingPresentation
    let anomaly: InvestigationFindingPresentation
    let version: String
    let limitations: String
    let isGap: Bool
    let isObservedZero: Bool
}

struct InvestigationAttribution: Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
    let summary: String
}

struct InvestigationProductEvidence: Identifiable, Equatable {
    var id: ProviderProduct { product }
    let product: ProviderProduct
    let records: [InvestigationRecord]
    let attributions: [InvestigationAttribution]
}

struct ForensicInvestigationSnapshot: Equatable {
    let publicationState: InvestigationPublicationState
    let publishedAt: Date
    let products: [InvestigationProductEvidence]
    let apiEvidenceNotice: String
    let message: String?

    var supportedProducts: [ProviderProduct] { products.map(\.product) }

    static func empty(publishedAt: Date) -> Self {
        Self(
            publicationState: .empty,
            publishedAt: publishedAt,
            products: [],
            apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary,
            message: "Select a later range after LimitBar has collected normalized quota observations."
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
                details: "\(value.measuredObservationCount) Measured observations over \(duration(value.measuredSpan)); evidence age \(duration(value.evidenceAge)); latest \(exact(value.latestObservationAt)); method \(value.forecastMethod.rawValue); qualification qualified; \(value.inputObservationIdentities.count) bounded observation traces; interpretation \(value.interpretationVersions.map(\.rawValue).joined(separator: ", "))."
            )
        case let .unavailable(value):
            return InvestigationFindingPresentation(
                status: "Unavailable",
                summary: "Unavailable - no point estimate is shown.",
                details: "Reason \(value.reason.rawValue); \(value.measuredObservationCount) Measured observations over \(duration(value.measuredSpan)); evidence age \(value.evidenceAge.map(duration) ?? "unavailable"); method \(value.forecastMethod.rawValue); qualification unavailable; \(value.inputObservationIdentities.count) bounded observation traces; interpretation \(value.interpretationVersions.map(\.rawValue).joined(separator: ", "))."
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
            details: "Current \(current); trailing baseline \(baseline); method \(metadata.method.rawValue); qualification \(metadata.qualification.rawValue); \(metadata.inputObservationIdentities.count) bounded Measured inputs; evidence versions \(versions.isEmpty ? "unavailable" : versions); limitations \(metadata.limitations.map(\.rawValue).joined(separator: ", "))."
        )
    }

    private static func period(_ value: QuotaAnomalyPeriod) -> String {
        "\(exact(value.start)) to \(exact(value.end)) (\(value.inclusionRule.rawValue))"
    }

    static func exact(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private static func decimal(_ value: Double) -> String { String(format: "%.2f", value) }
}

@MainActor
enum ForensicInvestigationAssembler {
    static func make(state: LimitBarState, now: Date = Date()) -> ForensicInvestigationSnapshot {
        var products: [InvestigationProductEvidence] = []
        var claudeRecords = state.claudeExplanationCatalog.selections.map {
            claudeRecord($0, forecasts: state.quotaInsights, anomalies: state.quotaAnomalies)
        }
        claudeRecords += analyticsOnlyRecords(
            product: .claudeCode,
            excluding: Set(claudeRecords.map(\.identity)),
            forecasts: state.quotaInsights,
            anomalies: state.quotaAnomalies
        )
        if !claudeRecords.isEmpty {
            products.append(InvestigationProductEvidence(
                product: .claudeCode,
                records: claudeRecords.sorted { ($0.start, $0.end) < ($1.start, $1.end) },
                attributions: attributions(state.local.attributionBreakdowns, provider: .anthropic)
            ))
        }
        var codexRecords: [InvestigationRecord] = []
        if let record = codexRecord(
            state.local.codexExplanation,
            snapshot: state.local.codexSnapshot,
            forecasts: state.quotaInsights,
            anomalies: state.quotaAnomalies
        ) { codexRecords.append(record) }
        codexRecords += analyticsOnlyRecords(
            product: .codex,
            excluding: Set(codexRecords.map(\.identity)),
            forecasts: state.quotaInsights,
            anomalies: state.quotaAnomalies
        )
        if !codexRecords.isEmpty {
            products.append(InvestigationProductEvidence(
                product: .codex,
                records: codexRecords.sorted { ($0.start, $0.end) < ($1.start, $1.end) },
                attributions: attributions(state.local.attributionBreakdowns, provider: .openAI)
            ))
        }
        guard !products.isEmpty else {
            if case .loading = state.claudeModel.state {
                return ForensicInvestigationSnapshot(
                    publicationState: .loading,
                    publishedAt: now,
                    products: [],
                    apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary,
                    message: "Waiting for the first coherent quota publication. Partial refresh results are not shown."
                )
            }
            if !state.quotaInsightsStorageAvailable || !state.local.storeHealth.isOpen {
                return ForensicInvestigationSnapshot(
                    publicationState: .error,
                    publishedAt: now,
                    products: [],
                    apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary,
                    message: "Normalized quota evidence could not be loaded. Existing concise status rows remain independent and no missing value is treated as zero."
                )
            }
            return .empty(publishedAt: now)
        }
        let partial = products.flatMap(\.records).contains { $0.isGap || $0.forecast.status == "Unavailable" || $0.anomaly.status.hasPrefix("Unavailable") }
        return ForensicInvestigationSnapshot(
            publicationState: partial ? .partial : .available,
            publishedAt: now,
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
            return InvestigationRecord(
                id: "analytics-\(identity.product.rawValue)-\(identity.identifier)-\(identity.resetBoundary.timeIntervalSince1970)",
                identity: identity,
                start: interval.start,
                end: interval.end,
                authoritativeTotal: "Authoritative quota observations exist, but a comparable movement total is unavailable for this exact range.",
                localBreakdown: "Observed Local Breakdown unavailable. This is a Gap, not Observed Zero.",
                unattributed: "Unattributed: no local activity is assigned to the authoritative quota observations.",
                forecast: ForensicInvestigationPresentation.forecast(forecasts[identity]),
                anomaly: ForensicInvestigationPresentation.anomaly(anomalies[identity]),
                version: "Explanation adapter/client version unavailable - no explanation interval was published. Analytics versions remain in their finding details.",
                limitations: "Movement cannot be calculated safely from this published finding alone. No interpolation, allocation, or exact movement is inferred.",
                isGap: true,
                isObservedZero: false
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
        let movement = value.map { "Reported provider total: \($0.reportedQuotaMovementPercent.formatted()) percentage-point movement between two Reported observations." }
            ?? "Reported provider total unavailable: \(selection.state.displayText)"
        let limitations = selection.limitations.map(\.rawValue).joined(separator: ", ")
        return InvestigationRecord(
            id: selection.interval.id,
            identity: selection.interval.identity,
            start: selection.interval.intervalStart,
            end: selection.interval.intervalEnd,
            authoritativeTotal: movement,
            localBreakdown: local,
            unattributed: value?.inferredAllocationPercent.map { "Inferred allocation: \($0.formatted())%. Method and causal attribution are unavailable; remaining movement is Unattributed." } ?? "Unattributed: provider movement is not allocated to local activity and no causal claim is made.",
            forecast: ForensicInvestigationPresentation.forecast(forecasts[selection.interval.identity]),
            anomaly: ForensicInvestigationPresentation.anomaly(anomalies[selection.interval.identity]),
            version: "Explanation method \(value?.methodVersion ?? ClaudeQuotaExplanationEngine.methodVersion); source adapter \(value?.sourceAdapterVersion ?? ClaudeCodeOTLPEvidenceAdapter.adapterVersion); source/client version \(value?.sourceVersion ?? "unavailable - not captured").",
            limitations: "Limitations: \(limitations.isEmpty ? "none recorded" : limitations). Exact source traces: \(value?.observationIdentityCount ?? 0) Reported observations and \(value?.evidenceIdentityCount ?? 0) Measured evidence items; observation span \(value.map { ForensicInvestigationPresentation.duration($0.observationSpan) } ?? "unavailable"); evidence age \(value.map { ForensicInvestigationPresentation.duration($0.evidenceAge) } ?? "unavailable").",
            isGap: value == nil || value.map { if case .unavailable = $0.attribution { true } else { false } } == true,
            isObservedZero: observedZero
        )
    }

    private static func codexRecord(
        _ explanation: CodexQuotaExplanationState,
        snapshot: CodexRateLimitSnapshot?,
        forecasts: [QuotaWindowIdentity: QuotaInsightState],
        anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    ) -> InvestigationRecord? {
        let value: CodexQuotaExplanation?
        switch explanation {
        case let .available(item), let .partial(item): value = item
        case .observedZero, .unavailable: value = nil
        }
        let identity = value.flatMap { try? QuotaWindowIdentity(product: .codex, identifier: "primary:\(snapshot?.primary?.windowMinutes ?? 300)", resetBoundary: $0.quotaResetBoundary) }
            ?? snapshot.flatMap { MeasuredQuotaObservationAdapter.codex($0).first?.identity }
        guard let identity else { return nil }
        let start = value?.intervalStart ?? snapshot?.reportedAt ?? identity.resetBoundary
        let end = value?.intervalEnd ?? snapshot?.reportedAt ?? identity.resetBoundary
        let observedZero: Bool
        if case .observedZero = explanation { observedZero = true } else { observedZero = false }
        let local = value.map {
            let tokens = $0.observedLocalBreakdown.tokens
            return "Measured Observed Local Breakdown: \(tokens.total) tokens across \($0.observedLocalBreakdown.sessionCount) privacy-safe sessions; input \(tokens.input), cached input \(tokens.cachedInput), output \(tokens.output), reasoning output \(tokens.reasoningOutput). Not added to the provider total."
        } ?? (observedZero
            ? "Measured Observed Zero local activity with complete supported evidence coverage. This is not a Gap."
            : "Observed Local Breakdown unavailable. This is a Gap, not zero usage.")
        return InvestigationRecord(
            id: "codex-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)",
            identity: identity,
            start: start,
            end: end,
            authoritativeTotal: value.map { "Reported provider total: \($0.reportedQuotaMovementPercent.formatted()) percentage-point movement between two Reported observations." } ?? "Reported provider total unavailable: \(explanation.displayText)",
            localBreakdown: local,
            unattributed: value?.allocationPercent.map { "Inferred allocation: \($0.formatted())%. Local activity does not establish cause; remaining movement is Unattributed." } ?? "Unattributed: provider movement is not allocated to local activity and no causal claim is made.",
            forecast: ForensicInvestigationPresentation.forecast(forecasts[identity]),
            anomaly: ForensicInvestigationPresentation.anomaly(anomalies[identity]),
            version: "Explanation method \(CodexQuotaExplanationEngine.methodVersion); adapter \(value?.adapterVersion ?? CodexRolloutEvidenceAdapter.adapterVersion); client version unavailable - not captured.",
            limitations: value.map { "Exact source traces: \($0.observationIdentityCount) Reported observations and \($0.evidenceIdentityCount) Measured evidence items; barriers \($0.barriers.map(\.rawValue).joined(separator: ", ")). Local token activity cannot be converted to provider quota percentage." } ?? "No comparable explanation interval. Local token activity cannot be converted to provider quota percentage.",
            isGap: value == nil,
            isObservedZero: observedZero
        )
    }

    private static func attributions(_ breakdowns: [ObservedLocalAttributionBreakdown], provider: ProviderKind) -> [InvestigationAttribution] {
        breakdowns.filter { $0.provider == provider }.map { value in
            let project = value.project.map { "project \($0.label ?? $0.id)" }
            let agent = value.agent.map { "agent \($0.label ?? $0.id)" }
            let dimensions = ([project, agent, "model \(value.model)"] as [String?]).compactMap { $0 }.joined(separator: ", ")
            return InvestigationAttribution(
                id: value.eventIDs.map(\.uuidString).sorted().joined(separator: ":"),
                start: value.window.start,
                end: value.window.end,
                summary: "Measured local attribution: \(dimensions); \(value.tokenUsage.totalTokens) tokens. Temporal evidence only - not a causal allocation of provider quota."
            )
        }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }
}

struct ForensicInvestigationView: View {
    let snapshot: ForensicInvestigationSnapshot
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedProduct: ProviderProduct?
    @State private var rangeStart: Date
    @State private var rangeEnd: Date

    init(snapshot: ForensicInvestigationSnapshot) {
        self.snapshot = snapshot
        let records = snapshot.products.flatMap(\.records)
        _selectedProduct = State(initialValue: snapshot.supportedProducts.first)
        _rangeStart = State(initialValue: records.map(\.start).min() ?? snapshot.publishedAt.addingTimeInterval(-3_600))
        _rangeEnd = State(initialValue: records.map(\.end).max() ?? snapshot.publishedAt)
    }

    private var evidence: InvestigationProductEvidence? {
        snapshot.products.first { $0.product == selectedProduct }
    }

    private var records: [InvestigationRecord] {
        evidence?.records.filter { $0.end >= rangeStart && $0.start <= rangeEnd }.sorted { ($0.start, $0.end) < ($1.start, $1.end) } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    publicationState
                    controls
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
                    Text("Published atomically \(ForensicInvestigationPresentation.exact(snapshot.publishedAt)). Refreshing concise provider rows does not mutate this open investigation.")
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selectedProduct)
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
            Label("Reported reset: \(ForensicInvestigationPresentation.exact(record.identity.resetBoundary)). Trend ends at this boundary; no line crosses the reset.", systemImage: "arrow.counterclockwise.circle")
                .accessibilityIdentifier("investigation-reset")
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
            Text(record.limitations).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(14)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var attribution: some View {
        if let evidence, !evidence.attributions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Privacy-safe local attribution").font(.headline)
                ForEach(evidence.attributions.filter { $0.end >= rangeStart && $0.start <= rangeEnd }) { item in
                    Text(item.summary).font(.caption).textSelection(.enabled)
                }
                Text("These Observed Local Breakdowns are not added to the authoritative provider total and do not prove cause.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
