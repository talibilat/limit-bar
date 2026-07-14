import AppKit
import Foundation
import LimitBarCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum DiagnosticExportInputBuilder {
    @MainActor
    static func live(state: LimitBarState, now: Date = Date()) async throws -> DiagnosticExportInput {
        try make(
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
            quotaInsights: state.quotaInsights
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
        quotaInsights: [QuotaWindowIdentity: QuotaInsightState] = [:]
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
            quotaFindings: projectedQuota.isEmpty ? nil : projectedQuota
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
            case let .unavailable(reason, count, span):
                findings.append(try DiagnosticQuotaFinding(
                    product: product,
                    windowKind: kind,
                    status: diagnosticStatus(reason),
                    measuredObservationCount: count,
                    measuredSpanMinutes: min(43_200, max(0, Int(span / 60)))
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
                findings.append(try DiagnosticQuotaFinding(
                    product: product,
                    windowKind: kind,
                    status: .qualified,
                    measuredObservationCount: finding.measuredObservationCount,
                    measuredSpanMinutes: min(43_200, max(0, Int(finding.measuredSpan / 60))),
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

    private static func diagnosticStatus(_ reason: QuotaInsightUnavailableReason) -> DiagnosticQuotaFindingStatus {
        switch reason {
        case .insufficientObservations: .insufficientObservations
        case .insufficientSpan: .insufficientSpan
        case .staleEvidence: .staleEvidence
        case .resetOrExpired: .resetOrExpired
        case .counterDecreased: .counterDecreased
        case .noPositiveBurn: .noPositiveBurn
        case .conflictingObservations: .conflictingObservations
        }
    }
}

@MainActor
@Observable
final class DiagnosticExportModel {
    static let preparationError = "Could not prepare the diagnostic export."
    static let saveError = "Could not save the diagnostic export."

    var showsPreview = false
    private(set) var preview = ""
    private(set) var message: String?
    private var artifact: DiagnosticExportArtifact?
    private let makeArtifact: @MainActor () async throws -> DiagnosticExportArtifact
    private let chooseDestination: @MainActor () -> URL?

    init(makeArtifact: @escaping @MainActor () async throws -> DiagnosticExportArtifact) {
        self.makeArtifact = makeArtifact
        chooseDestination = Self.chooseDestinationWithSavePanel
    }

    init(
        makeArtifact: @escaping @MainActor () async throws -> DiagnosticExportArtifact,
        chooseDestination: @escaping @MainActor () -> URL?
    ) {
        self.makeArtifact = makeArtifact
        self.chooseDestination = chooseDestination
    }

    func prepare() async {
        do {
            let artifact = try await makeArtifact()
            preview = try artifact.preview
            self.artifact = artifact
            message = nil
            showsPreview = true
        } catch {
            artifact = nil
            preview = ""
            showsPreview = false
            message = Self.preparationError
        }
    }

    func save() {
        guard let artifact, let destination = chooseDestination() else { return }
        do {
            try artifact.save(to: destination)
            showsPreview = false
            message = "Diagnostic export saved."
        } catch {
            message = Self.saveError
        }
    }

    private static func chooseDestinationWithSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Export"
        panel.nameFieldStringValue = "limitbar-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct DiagnosticExportSection: View {
    @State private var model: DiagnosticExportModel

    init(state: LimitBarState) {
        _model = State(initialValue: DiagnosticExportModel {
            try DiagnosticExport.make(from: await DiagnosticExportInputBuilder.live(state: state))
        })
    }

    init(model: DiagnosticExportModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Section("Diagnostic Export") {
            Text("Creates a reviewable JSON report from fixed status categories and counts. It excludes logs, paths, labels, credentials, database files, and raw provider or usage payloads.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Preview Diagnostic Export") {
                Task { await model.prepare() }
            }
            .accessibilityIdentifier("diagnostic-export-preview")
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message == "Diagnostic export saved." ? Color.secondary : Color.orange)
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
                    Button("Cancel", role: .cancel) { model.showsPreview = false }
                    Button("Save As...") { model.save() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("diagnostic-export-save")
                }
            }
            .padding(20)
            .frame(width: 680, height: 560)
        }
    }
}
