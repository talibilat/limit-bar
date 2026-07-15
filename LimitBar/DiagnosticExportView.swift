import AppKit
import Foundation
import LimitBarCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum DiagnosticExportInputBuilder {
    @MainActor
    static func live(state: LimitBarState, selection: DiagnosticExportSelection? = nil, now: Date = Date()) async throws -> DiagnosticExportInput {
        let snapshot = state.investigationPublication
        let product = selection?.product ?? snapshot.supportedProducts.first
        let productRecords = snapshot.products.first { $0.product == product }?.records ?? []
        return try make(
            generatedAt: now,
            applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            applicationBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            providerSettings: state.providerSettings,
            customSourceCount: CustomUsageSourceStore().sources.count,
            databaseIsAvailable: state.local.storeHealth.isOpen,
            acceptedImportCount: state.local.localImport.validEventCount,
            rejectedImportCount: state.local.localImport.malformedEventCount,
            customImportFailures: state.local.customImportFailures,
            customRejectedLines: state.local.customRejectedLines,
            refreshHistory: await ProviderRefreshHistoryRepository.shared.summaries(),
            quotaInsights: state.quotaInsights,
            claudeExplanations: state.claudeExplanationCatalog,
            codexExplanation: state.local.codexExplanation,
            codexExplanationRetained: state.local.codexExplanationRetained,
            quotaEvidence: try product.flatMap { selectedProduct in
                guard let start = selection?.rangeStart ?? productRecords.map(\.start).min(),
                      let end = selection?.rangeEnd ?? productRecords.map(\.end).max(), start < end else { return nil }
                return try QuotaEvidenceReportBuilder.make(snapshot: snapshot, product: selectedProduct, rangeStart: start, rangeEnd: end)
            }
        )
    }

    static func make(
        generatedAt: Date,
        applicationVersion: String?,
        applicationBuild: String?,
        operatingSystemVersion: OperatingSystemVersion,
        providerSettings: [ProviderSettings],
        customSourceCount: Int,
        databaseIsAvailable: Bool,
        acceptedImportCount: Int,
        rejectedImportCount: Int,
        customImportFailures: Int,
        customRejectedLines: Int,
        refreshHistory: [ProviderRefreshProduct: ProviderRefreshHistorySummary],
        quotaInsights: [QuotaWindowIdentity: QuotaInsightState] = [:],
        claudeExplanations: ClaudeQuotaExplanationCatalog = .empty,
        codexExplanation: CodexQuotaExplanationState? = nil,
        codexExplanationRetained: Bool = false,
        quotaEvidence: DiagnosticQuotaEvidenceReport? = nil
    ) throws -> DiagnosticExportInput {
        let rejected = rejectedImportCount.addingReportingOverflow(customRejectedLines)
        guard !rejected.overflow,
              customSourceCount >= 0,
              customImportFailures >= 0,
              customImportFailures <= customSourceCount else {
            throw DiagnosticExportError.invalidImportCount
        }
        guard let applicationBuild, let build = Int(applicationBuild), build >= 0 else {
            throw DiagnosticExportError.invalidVersion
        }

        var statuses = providerSettings.filter { $0.provider != .custom }.map {
            DiagnosticProviderStatus(provider: provider($0.provider), state: providerState($0))
        }
        statuses.append(DiagnosticProviderStatus(
            provider: .custom,
            state: customSourceCount == 0 ? .notConfigured : (customImportFailures > 0 ? .failed : .connected)
        ))

        var projectedHistory: [DiagnosticRefreshHistoryRecord] = []
        for (product, summary) in refreshHistory {
            if let latest = summary.latest {
                projectedHistory.append(try historyRecord(role: .latest, product: product, entry: latest))
            }
            if let lastFullSuccess = summary.lastFullSuccess {
                projectedHistory.append(try historyRecord(role: .lastFullSuccess, product: product, entry: lastFullSuccess))
            }
        }
        projectedHistory.sort {
            if $0.product != $1.product { return $0.product.rawValue < $1.product.rawValue }
            return $0.role.rawValue < $1.role.rawValue
        }
        let projectedQuota = try quotaFindings(from: quotaInsights, generatedAt: generatedAt)
        _ = claudeExplanations // Deliberately omitted until a diagnostic positive allow-list is specified.

        return try DiagnosticExportInput(
            generatedAt: generatedAt,
            appVersion: version(applicationVersion),
            appBuild: build,
            operatingSystemVersion: DiagnosticVersion(
                major: operatingSystemVersion.majorVersion,
                minor: operatingSystemVersion.minorVersion,
                patch: operatingSystemVersion.patchVersion
            ),
            providerStatuses: statuses,
            databaseState: databaseIsAvailable ? .available : .unavailable,
            importCounts: DiagnosticImportCounts(accepted: acceptedImportCount, rejected: rejected.partialValue),
            resourceLimitReasons: [],
            refreshHistory: projectedHistory.isEmpty ? nil : projectedHistory,
            quotaFindings: projectedQuota.isEmpty ? nil : projectedQuota,
            codexExplanation: try codexExplanation.flatMap { try diagnosticCodexExplanation($0, retained: codexExplanationRetained) },
            quotaEvidence: quotaEvidence
        )
    }

    private static func version(_ value: String?) throws -> DiagnosticVersion {
        let components = (value ?? "").split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              components.allSatisfy({ Int($0).map { $0 >= 0 } == true }) else {
            throw DiagnosticExportError.invalidVersion
        }
        let parsed = components.compactMap { Int($0) }
        guard parsed.count == components.count else { throw DiagnosticExportError.invalidVersion }
        let numbers = parsed + Array(repeating: 0, count: 3 - components.count)
        return try DiagnosticVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    private static func provider(_ value: ProviderKind) -> DiagnosticProvider {
        switch value {
        case .anthropic: .anthropic
        case .azureOpenAI: .azureOpenAI
        case .openAI: .openAI
        case .custom: .custom
        }
    }

    private static func providerState(_ settings: ProviderSettings) -> DiagnosticProviderState {
        switch settings.state {
        case .missing: .notConfigured
        case .configured: .configured
        case .connected: .connected
        case .cancelled: .cancelled
        case .expired, .adminRequired: .authenticationRequired
        case .unsupported: .failed
        case .failed:
            switch settings.failureReason {
            case .networkUnavailable: .networkUnavailable
            case .authenticationRejected, .insufficientPermissions, .expiredCredential: .authenticationRequired
            case .invalidConfiguration, .refreshFailed, nil: .failed
            }
        }
    }

    private static func historyRecord(
        role: DiagnosticRefreshHistoryRole,
        product: ProviderRefreshProduct,
        entry: ProviderRefreshHistoryEntry
    ) throws -> DiagnosticRefreshHistoryRecord {
        let projectedProduct: DiagnosticRefreshProduct = switch product {
        case .anthropicAPI: .anthropicAPI
        case .openAIAPI: .openAIAPI
        }
        let projectedOutcome: DiagnosticRefreshOutcome = switch entry.outcome {
        case .success: .success
        case .partialFailure: .partialFailure
        case .cancelled: .cancelled
        case .authenticationFailure: .authenticationFailure
        case .networkFailure: .networkFailure
        case .failed: .failed
        }
        let projectedDuration: DiagnosticRefreshDuration = switch entry.duration {
        case .underOneSecond: .underOneSecond
        case .oneToFiveSeconds: .oneToFiveSeconds
        case .fiveToThirtySeconds: .fiveToThirtySeconds
        case .overThirtySeconds: .overThirtySeconds
        }
        let windowKinds = Set(entry.affectedWindows.map(\.timeWindow)).map { window in
            switch window {
            case .today: DiagnosticRefreshWindowKind.today
            case .currentWeek: DiagnosticRefreshWindowKind.currentWeek
            }
        }
        return try DiagnosticRefreshHistoryRecord(
            role: role,
            product: projectedProduct,
            outcome: projectedOutcome,
            startedAt: entry.startedAt,
            duration: projectedDuration,
            affectedWindowKinds: windowKinds
        )
    }

    private static func quotaFindings(
        from insights: [QuotaWindowIdentity: QuotaInsightState],
        generatedAt: Date
    ) throws -> [DiagnosticQuotaFinding] {
        var findings: [DiagnosticQuotaFinding] = []
        let current = insights.filter { $0.key.resetBoundary > generatedAt }
            .sorted { ($0.key.product.rawValue, $0.key.identifier) < ($1.key.product.rawValue, $1.key.identifier) }
            .prefix(DiagnosticExport.maximumQuotaFindings)
        for (identity, state) in current {
            let product: DiagnosticQuotaProduct = identity.product == .claudeCode ? .claudeCode : .codex
            let kind: DiagnosticQuotaWindowKind = switch identity.insightWindowKind {
            case .session: .session
            case .weekly: .weekly
            case .other: .other
            }
            switch state {
            case let .unavailable(finding):
                let forecastMethod: DiagnosticQuotaForecastMethod = switch finding.forecastMethod {
                case .pairwisePositiveSlopeInterquartileV1: .pairwisePositiveSlopeInterquartileV1
                case .pairwisePositiveSlopeInterquartileV2: .pairwisePositiveSlopeInterquartileV2
                }
                findings.append(try DiagnosticQuotaFinding(
                    product: product,
                    windowKind: kind,
                    status: diagnosticStatus(finding.reason),
                    qualification: .unavailable,
                    measuredObservationCount: finding.measuredObservationCount,
                    measuredSpanMinutes: min(43_200, max(0, Int(finding.measuredSpan / 60))),
                    forecastMethod: forecastMethod
                ))
            case let .qualified(finding):
                let burnLower = min(10_000, max(0, finding.calculatedBurnPercentPerHour.lower))
                let burnUpper = min(10_000, max(burnLower, finding.calculatedBurnPercentPerHour.upper))
                let exhaustion = try finding.calculatedExhaustionRange.map {
                    try DiagnosticNumberRange(
                        lower: min(10_000, max(0, $0.lowerBound.timeIntervalSince(generatedAt) / 60)),
                        upper: min(10_000, max(0, $0.upperBound.timeIntervalSince(generatedAt) / 60))
                    )
                }
                let forecastMethod: DiagnosticQuotaForecastMethod = switch finding.forecastMethod {
                case .pairwisePositiveSlopeInterquartileV1: .pairwisePositiveSlopeInterquartileV1
                case .pairwisePositiveSlopeInterquartileV2: .pairwisePositiveSlopeInterquartileV2
                }
                findings.append(try DiagnosticQuotaFinding(
                    product: product,
                    windowKind: kind,
                    status: .qualified,
                    qualification: .qualified,
                    measuredObservationCount: finding.measuredObservationCount,
                    measuredSpanMinutes: min(43_200, max(0, Int(finding.measuredSpan / 60))),
                    forecastMethod: forecastMethod,
                    calculatedBurnPercentPerHour: try DiagnosticNumberRange(
                        lower: burnLower,
                        upper: burnUpper
                    ),
                    calculatedExhaustionMinutes: exhaustion
                ))
            }
        }
        return findings
    }

    private static func diagnosticCodexExplanation(_ state: CodexQuotaExplanationState, retained: Bool) throws -> DiagnosticCodexExplanationFinding? {
        let retention: DiagnosticCodexExplanationRetention = retained ? .retained : .fresh
        switch state {
        case let .available(explanation):
            return try DiagnosticCodexExplanationFinding(
                status: .available,
                adapterVersion: explanation.adapterVersion,
                coverage: .complete,
                tokenEvidence: explanation.observedLocalBreakdown.tokens.total > 0 ? .positive : .observedZero,
                sessionCount: explanation.observedLocalBreakdown.sessionCount,
                evidenceCount: explanation.evidenceIdentityCount,
                observationCount: explanation.observationIdentityCount,
                barrierCategories: explanation.barriers,
                retention: retention
            )
        case let .partial(explanation):
            return try DiagnosticCodexExplanationFinding(
                status: .partial,
                adapterVersion: explanation.adapterVersion,
                coverage: .partial,
                tokenEvidence: explanation.observedLocalBreakdown.tokens.total > 0 ? .positive : .observedZero,
                sessionCount: explanation.observedLocalBreakdown.sessionCount,
                evidenceCount: explanation.evidenceIdentityCount,
                observationCount: explanation.observationIdentityCount,
                barrierCategories: explanation.barriers,
                retention: retention
            )
        case let .observedZero(value):
            return try DiagnosticCodexExplanationFinding(
                status: .observedZero,
                adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
                coverage: .complete,
                tokenEvidence: .observedZero,
                sessionCount: 0,
                evidenceCount: value.evidenceIdentityCount,
                observationCount: value.observationIdentityCount,
                barrierCategories: [],
                retention: retention
            )
        case let .unavailable(reason):
            return try DiagnosticCodexExplanationFinding(
                status: .unavailable,
                adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
                coverage: .unavailable,
                tokenEvidence: .none,
                sessionCount: 0,
                evidenceCount: 0,
                observationCount: 0,
                barrierCategories: [],
                unavailableReason: reason,
                retention: retention
            )
        }
    }

    private static func diagnosticStatus(_ reason: QuotaInsightUnavailableReason) -> DiagnosticQuotaFindingStatus {
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
}

struct DiagnosticExportSelection: Equatable {
    let product: ProviderProduct
    let rangeStart: Date
    let rangeEnd: Date
}

@MainActor
protocol DiagnosticExportLocalEffects {
    func chooseDestination() -> URL?
    func save(_ artifact: DiagnosticExportArtifact, to destination: URL) throws
}

@MainActor
private struct ClosureDiagnosticExportLocalEffects: DiagnosticExportLocalEffects {
    let destination: () -> URL?
    let write: (DiagnosticExportArtifact, URL) throws -> Void

    func chooseDestination() -> URL? { destination() }
    func save(_ artifact: DiagnosticExportArtifact, to destination: URL) throws { try write(artifact, destination) }
}

@MainActor
@Observable
final class DiagnosticExportModel {
    static let preparationError = "Could not prepare the diagnostic export."
    static let saveError = "Could not save the diagnostic export."
    static let successMessage = "Diagnostic export saved."
    static let destinationDefaultName = "limitbar-diagnostics.json"

    var showsPreview = false
    private(set) var preview = ""
    private(set) var message: String?
    private(set) var isApproved = false
    private(set) var hasDestination = false
    private(set) var selection: DiagnosticExportSelection?
    private var artifact: DiagnosticExportArtifact?
    private var destination: URL?
    private var preparationRevision: UInt64 = 0
    private let makeArtifact: @MainActor () async throws -> DiagnosticExportArtifact
    private let makeSelectedArtifact: (@MainActor (DiagnosticExportSelection) async throws -> DiagnosticExportArtifact)?
    private let localEffects: any DiagnosticExportLocalEffects

    init(makeArtifact: @escaping @MainActor () async throws -> DiagnosticExportArtifact) {
        self.makeArtifact = makeArtifact
        makeSelectedArtifact = nil
        selection = nil
        localEffects = ClosureDiagnosticExportLocalEffects(destination: Self.chooseDestinationWithSavePanel, write: { try $0.save(to: $1) })
    }

    init(
        makeArtifact: @escaping @MainActor () async throws -> DiagnosticExportArtifact,
        chooseDestination: @escaping @MainActor () -> URL?
    ) {
        self.makeArtifact = makeArtifact
        makeSelectedArtifact = nil
        selection = nil
        localEffects = ClosureDiagnosticExportLocalEffects(destination: chooseDestination, write: { try $0.save(to: $1) })
    }

    init(
        selection: DiagnosticExportSelection,
        makeArtifact: @escaping @MainActor (DiagnosticExportSelection) async throws -> DiagnosticExportArtifact
    ) {
        self.selection = selection
        self.makeSelectedArtifact = makeArtifact
        self.makeArtifact = { throw DiagnosticExportError.invalidQuotaEvidence }
        localEffects = ClosureDiagnosticExportLocalEffects(destination: Self.chooseDestinationWithSavePanel, write: { try $0.save(to: $1) })
    }

    init(
        selection: DiagnosticExportSelection,
        makeArtifact: @escaping @MainActor (DiagnosticExportSelection) async throws -> DiagnosticExportArtifact,
        chooseDestination: @escaping @MainActor () -> URL?
    ) {
        self.selection = selection
        self.makeSelectedArtifact = makeArtifact
        self.makeArtifact = { throw DiagnosticExportError.invalidQuotaEvidence }
        localEffects = ClosureDiagnosticExportLocalEffects(destination: chooseDestination, write: { try $0.save(to: $1) })
    }

    init(
        selection: DiagnosticExportSelection,
        makeArtifact: @escaping @MainActor (DiagnosticExportSelection) async throws -> DiagnosticExportArtifact,
        localEffects: any DiagnosticExportLocalEffects
    ) {
        self.selection = selection
        self.makeSelectedArtifact = makeArtifact
        self.makeArtifact = { throw DiagnosticExportError.invalidQuotaEvidence }
        self.localEffects = localEffects
    }

    init(
        makeArtifact: @escaping @MainActor () async throws -> DiagnosticExportArtifact,
        localEffects: any DiagnosticExportLocalEffects
    ) {
        self.makeArtifact = makeArtifact
        makeSelectedArtifact = nil
        selection = nil
        self.localEffects = localEffects
    }

    func prepare() async {
        preparationRevision &+= 1
        let revision = preparationRevision
        let requestedSelection = selection
        clearCandidate()
        message = nil
        do {
            let artifact: DiagnosticExportArtifact
            if let selection, let makeSelectedArtifact {
                artifact = try await makeSelectedArtifact(selection)
            } else {
                artifact = try await makeArtifact()
            }
            let preview = try artifact.preview
            guard preparationRevision == revision, selection == requestedSelection else { return }
            self.preview = preview
            self.artifact = artifact
            destination = nil
            isApproved = false
            hasDestination = false
            message = nil
            showsPreview = true
        } catch {
            guard preparationRevision == revision, selection == requestedSelection else { return }
            clearCandidate()
            message = Self.preparationError
        }
    }

    func approvePreview() {
        guard artifact != nil, showsPreview else { return }
        isApproved = true
        message = nil
    }

    func chooseApprovedDestination() {
        guard isApproved, let chosen = localEffects.chooseDestination() else { return }
        destination = chosen
        hasDestination = true
        message = nil
    }

    func save() {
        guard isApproved, let artifact, let destination else { return }
        do {
            try localEffects.save(artifact, to: destination)
            showsPreview = false
            message = Self.successMessage
        } catch {
            message = Self.saveError
        }
    }

    func invalidateApproval() {
        preparationRevision &+= 1
        clearCandidate()
        message = nil
    }

    func cancelPreview() {
        invalidateApproval()
    }

    private func clearCandidate() {
        artifact = nil
        destination = nil
        preview = ""
        isApproved = false
        hasDestination = false
        showsPreview = false
    }


    func updateSelection(_ value: DiagnosticExportSelection) {
        guard value != selection else { return }
        selection = value
        invalidateApproval()
    }

    static func chooseDestinationWithSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Export"
        panel.nameFieldStringValue = destinationDefaultName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct DiagnosticExportSection: View {
    @State private var model: DiagnosticExportModel
    private let snapshot: ForensicInvestigationSnapshot?

    init(state: LimitBarState) {
        self.init(state: state, chooseDestination: DiagnosticExportModel.chooseDestinationWithSavePanel)
    }

    init(state: LimitBarState, chooseDestination: @escaping @MainActor () -> URL?) {
        self.init(
            state: state,
            localEffects: ClosureDiagnosticExportLocalEffects(destination: chooseDestination, write: { try $0.save(to: $1) })
        )
    }

    init(state: LimitBarState, localEffects: any DiagnosticExportLocalEffects) {
        let snapshot = state.investigationPublication
        self.snapshot = snapshot
        if let selection = Self.defaultSelection(snapshot: snapshot) {
            _model = State(initialValue: DiagnosticExportModel(
                selection: selection,
                makeArtifact: { selection in
                    try DiagnosticExport.make(from: await DiagnosticExportInputBuilder.live(state: state, selection: selection))
                },
                localEffects: localEffects
            ))
        } else {
            _model = State(initialValue: DiagnosticExportModel(
                makeArtifact: { try DiagnosticExport.make(from: await DiagnosticExportInputBuilder.live(state: state)) },
                localEffects: localEffects
            ))
        }
    }

    init(model: DiagnosticExportModel) {
        snapshot = nil
        _model = State(initialValue: model)
    }

    var body: some View {
        Section("Diagnostic Export") {
            Text("Creates a reviewable JSON report from fixed status categories and counts. It excludes logs, paths, labels, credentials, database files, and raw provider or usage payloads.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let snapshot, let selection = model.selection {
                Picker("Quota evidence product", selection: Binding(
                    get: { selection.product },
                    set: { product in
                        if let next = Self.defaultSelection(snapshot: snapshot, product: product) { model.updateSelection(next) }
                    }
                )) {
                    ForEach(snapshot.supportedProducts, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("diagnostic-export-product")
                DatePicker("Exact range start", selection: Binding(
                    get: { model.selection?.rangeStart ?? selection.rangeStart },
                    set: { model.updateSelection(.init(product: selection.product, rangeStart: $0, rangeEnd: model.selection?.rangeEnd ?? selection.rangeEnd)) }
                ))
                .accessibilityIdentifier("diagnostic-export-range-start")
                DatePicker("Exact range end", selection: Binding(
                    get: { model.selection?.rangeEnd ?? selection.rangeEnd },
                    set: { model.updateSelection(.init(product: selection.product, rangeStart: model.selection?.rangeStart ?? selection.rangeStart, rangeEnd: $0)) }
                ))
                .accessibilityIdentifier("diagnostic-export-range-end")
                Text("Half-open [start, end), Gregorian calendar, UTC basis. Changing any selection requires a new complete preview.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagnostic-export-range-basis")
            }
            Button("Preview Diagnostic Export") {
                Task { await model.prepare() }
            }
            .accessibilityIdentifier("diagnostic-export-preview")
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message == DiagnosticExportModel.successMessage ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("diagnostic-export-message")
            }
        }
        .sheet(isPresented: $model.showsPreview) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Review Diagnostic Export")
                    .font(.title2.weight(.semibold))
                Text("The JSON below is the exact immutable content that will be saved.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(model.preview)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("diagnostic-export-json-preview")
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                if model.message == DiagnosticExportModel.saveError {
                    Text(DiagnosticExportModel.saveError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelPreview() }
                    if !model.isApproved {
                        Button("Approve Complete Preview") { model.approvePreview() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("diagnostic-export-approve")
                    } else if !model.hasDestination {
                        Button("Choose Destination...") { model.chooseApprovedDestination() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("diagnostic-export-choose-destination")
                    } else {
                        Button("Save Approved Report") { model.save() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("diagnostic-export-save")
                    }
                }
            }
            .padding(20)
            .frame(width: 680, height: 560)
        }
    }

    private static func defaultSelection(snapshot: ForensicInvestigationSnapshot, product: ProviderProduct? = nil) -> DiagnosticExportSelection? {
        guard let product = product ?? snapshot.supportedProducts.first,
              let evidence = snapshot.products.first(where: { $0.product == product }),
              let start = evidence.records.map(\.start).min(),
              let end = evidence.records.map(\.end).max(), start < end else { return nil }
        return DiagnosticExportSelection(product: product, rangeStart: start, rangeEnd: end)
    }
}
