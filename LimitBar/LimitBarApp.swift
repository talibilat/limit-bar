import SwiftUI
import LimitBarCore
import Observation

protocol QuotaInsightsServing: Sendable {
    func recordClaudeAnalysis(_ snapshot: ClaudeRateLimitSnapshot, now: Date) async throws -> QuotaFindingAnalysisSnapshot
    func recordCodexAnalysis(_ snapshot: CodexRateLimitSnapshot, now: Date) async throws -> QuotaFindingAnalysisSnapshot
    func reevaluateClaudeAnalysis(now: Date) async throws -> QuotaFindingAnalysisSnapshot
    func reevaluateCodexAnalysis(now: Date) async throws -> QuotaFindingAnalysisSnapshot
    func deleteAll() async throws
}

protocol AttributionEvidenceDeleting: Sendable {
    func deleteAllAttributionEvidence(now: Date) async throws
}

extension UsageDatabase: AttributionEvidenceDeleting {}

extension QuotaInsightsService: QuotaInsightsServing {}

@main
struct LimitBarApp: App {
#if DEBUG
    @NSApplicationDelegateAdaptor(AppUITestAppDelegate.self) private var appDelegate
#endif
    @State private var state: LimitBarState

    init() {
#if DEBUG
        if AppTestConfiguration.isEnabled {
            _state = State(initialValue: AppTestConfiguration.state())
            return
        }
#endif
        _state = State(initialValue: .shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MonitoringPopoverView(state: state)
        } label: {
            MenuBarStatusLabel(state: state)
        }
        .menuBarExtraStyle(.window)

        Settings {
#if DEBUG
            if AppTestConfiguration.isEnabled {
                EmptyView()
            } else {
                LimitBarSettingsView(state: state)
            }
#else
            LimitBarSettingsView(state: state)
#endif
        }
    }
}

@MainActor
@Observable
final class LimitBarState {
    private enum PendingInvestigationRefresh: Equatable {
        case requested(UUID)
        case generation(UInt64)
    }
    static let shared = LimitBarState()

    let local = LimitBarLocalStateProjection()
    private(set) var providerSettings: [ProviderSettings]
    let claudeModel: ClaudeRateLimitsModel
    let alertSettingsStore: AlertSettingsStore
    let alertCoordinator: AlertCoordinator
    private(set) var quotaAnalysis = QuotaFindingAnalysisSnapshot.empty
    var quotaInsights: [QuotaWindowIdentity: QuotaInsightState] { quotaAnalysis.forecasts }
    var quotaAnomalies: [QuotaWindowIdentity: QuotaAnomalyState] { quotaAnalysis.anomalies }
    private(set) var quotaInsightsStorageAvailable: Bool
    private(set) var claudeExplanationCatalog: ClaudeQuotaExplanationCatalog = .empty
    private(set) var activityDebuggerState: ActivityDebuggerState = .unavailable(.noReceipts)
    private(set) var investigationPublication = ForensicInvestigationSnapshot(
        publicationState: .loading,
        publishedAt: Date(),
        products: [],
        apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary,
        message: "Waiting for the first coherent publication."
    )
    private let coordinator: LocalRefreshCoordinator
    private let quotaInsightsService: (any QuotaInsightsServing)?
    private let codexExplanationStore: SQLiteCodexExplanationStore?
    private let claudeExplanationStore: SQLiteClaudeExplanationStore?
    private let activityReceiptStore: SQLiteActivityReceiptStore?
    private let attributionEvidenceStore: any AttributionEvidenceDeleting
    private let capacityPublicationWriter: CapacityPublicationWriter?
    private let usesLiveRefresh: Bool
    private var observationTask: Task<Void, Never>?
    private var latestUsageRefreshed = false
    private var latestCodexRefreshed = false
    private var pendingInvestigationRefresh: PendingInvestigationRefresh?

    private init() {
        let sessionsDirectory = LimitBarFileLocations.codexSessionsDirectory(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let refreshCadence = LocalRefreshSettingsStore().cadence
        providerSettings = ProviderSettingsStore().settings
        let codexExplanationStore = try? SQLiteCodexExplanationStore.applicationSupportStore()
        let claudeExplanationStore = try? SQLiteClaudeExplanationStore.applicationSupportStore()
        let activityReceiptStore = try? SQLiteActivityReceiptStore.applicationSupportStore()
        self.codexExplanationStore = codexExplanationStore
        self.claudeExplanationStore = claudeExplanationStore
        self.activityReceiptStore = activityReceiptStore
        attributionEvidenceStore = UsageDatabase.shared
        capacityPublicationWriter = try? .production()
        coordinator = LocalRefreshCoordinator(dependencies: .live(
            usage: ApplicationLocalUsageRefresher(),
            codexEvidence: CodexSessionScanner(sessionsDirectory: sessionsDirectory, explanationStore: codexExplanationStore)
        ), refreshInterval: refreshCadence.seconds)
        claudeModel = ClaudeRateLimitsModel(
            credentials: ClaudeCredentialBroker.shared,
            client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
        )
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LimitBar", isDirectory: true)
        quotaInsightsService = try? QuotaInsightsService.live(applicationSupportDirectory: applicationSupport)
        quotaInsightsStorageAvailable = quotaInsightsService != nil
        usesLiveRefresh = true
        let alertSettingsStore = AlertSettingsStore()
        self.alertSettingsStore = alertSettingsStore
        alertCoordinator = AlertCoordinator(settingsStore: alertSettingsStore)
        local.restoreCodexExplanation(try? codexExplanationStore?.latest())
        claudeExplanationCatalog = Self.catalog(restoring: try? claudeExplanationStore?.latest())
        activityDebuggerState = Self.activityState(store: activityReceiptStore)
        publishInvestigation(generation: nil, at: Date())
    }

    init(
        providerSettings: [ProviderSettings],
        claudeModel: ClaudeRateLimitsModel,
        coordinator: LocalRefreshCoordinator,
        quotaInsightsService: (any QuotaInsightsServing)? = nil,
        codexExplanationStore: SQLiteCodexExplanationStore? = nil,
        claudeExplanationStore: SQLiteClaudeExplanationStore? = nil,
        activityReceiptStore: SQLiteActivityReceiptStore? = nil,
        attributionEvidenceStore: any AttributionEvidenceDeleting = UsageDatabase.shared,
        capacityPublicationWriter: CapacityPublicationWriter? = nil,
        investigationPublication: ForensicInvestigationSnapshot? = nil
    ) {
        self.providerSettings = providerSettings
        self.claudeModel = claudeModel
        self.coordinator = coordinator
        self.quotaInsightsService = quotaInsightsService
        self.codexExplanationStore = codexExplanationStore
        self.claudeExplanationStore = claudeExplanationStore
        self.activityReceiptStore = activityReceiptStore
        self.attributionEvidenceStore = attributionEvidenceStore
        self.capacityPublicationWriter = capacityPublicationWriter
        quotaInsightsStorageAvailable = quotaInsightsService != nil
        usesLiveRefresh = false
        let alertSettingsStore = AlertSettingsStore()
        self.alertSettingsStore = alertSettingsStore
        alertCoordinator = AlertCoordinator(settingsStore: alertSettingsStore)
        local.restoreCodexExplanation(try? codexExplanationStore?.latest())
        claudeExplanationCatalog = Self.catalog(restoring: try? claudeExplanationStore?.latest())
        activityDebuggerState = Self.activityState(store: activityReceiptStore)
        if let investigationPublication {
            self.investigationPublication = investigationPublication
        } else {
            publishInvestigation(generation: nil, at: Date())
        }
    }

    func start() {
        guard usesLiveRefresh else { return }
        guard observationTask == nil else { return }
        beginInvestigationRefreshRequest()
        observationTask = Task { [weak self, coordinator] in
            await coordinator.start()
            for await snapshot in coordinator.snapshots {
                guard let self else { return }
                latestUsageRefreshed = snapshot.usageRefreshed
                latestCodexRefreshed = snapshot.codexRefreshed
                await refreshQuotaInsights(for: snapshot)
                await evaluateLocalAlerts()
            }
        }
    }

    func requestLocalRefresh() {
        guard usesLiveRefresh else { return }
        providerSettings = ProviderSettingsStore().settings
        beginInvestigationRefreshRequest()
        Task { [coordinator] in await coordinator.requestRefresh() }
    }

    func localRefreshSettingsChanged() {
        guard usesLiveRefresh else { return }
        let cadence = LocalRefreshSettingsStore().cadence
        Task { [coordinator] in await coordinator.setRefreshInterval(cadence.seconds) }
    }

    func clearHistoricalUsage() {
        local.clearHistory()
    }

    func claudeActionCompleted() {
        guard case let .loaded(snapshot, subscription) = claudeModel.state else { return }
        let now = Date()
        let observations = QuotaObservationAdapter.claude(snapshot, subscriptionType: subscription, now: now)
        publishCapacity(now: now, claude: observations)
        Task {
            await recordClaudeInsights(snapshot, now: now)
            await alertCoordinator.evaluate(
                quota: observations,
                costs: [],
                forecasts: Array(quotaInsights.values),
                anomalies: Array(quotaAnomalies.values),
                now: now
            )
        }
    }

    func deleteQuotaObservations() async -> Bool {
        guard let quotaInsightsService else { return false }
        do {
            try await quotaInsightsService.deleteAll()
            quotaAnalysis = .empty
            quotaInsightsStorageAvailable = true
            publishInvestigation(generation: investigationPublication.generation, at: Date())
            return true
        } catch {
            quotaInsightsStorageAvailable = false
            if pendingInvestigationRefresh == nil {
                investigationPublication = investigationPublication.failed(pendingGeneration: nil)
            }
            return false
        }
    }

    func deleteCodexExplanations() async -> Bool {
        guard let codexExplanationStore else { return false }
        do {
            try codexExplanationStore.deleteAll()
            local.clearCodexExplanation()
            publishInvestigation(generation: investigationPublication.generation, at: Date())
            return true
        } catch {
            return false
        }
    }

    func deleteClaudeExplanations() async -> Bool {
        guard let claudeExplanationStore else { return false }
        do {
            try claudeExplanationStore.deleteAll()
            claudeExplanationCatalog = .empty
            publishInvestigation(generation: investigationPublication.generation, at: Date())
            return true
        } catch {
            return false
        }
    }

    func importActivityReceipts(source: ActivityReceiptSource, url: URL) -> String {
        guard let activityReceiptStore else { return "Could not open Activity Receipt storage." }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 8 * 1_024 * 1_024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return "Could not read a regular Activity Receipt file of 8 MB or less."
        }
        let importer = ActivityReceiptImporter(store: activityReceiptStore)
        let result = source == .claudeCode ? importer.importClaude(data: data) : importer.importCodexJSONL(data: data)
        switch result {
        case let .imported(receipts):
            activityDebuggerState = Self.activityState(store: activityReceiptStore)
            return "Imported \(receipts.count) normalized Activity Receipts."
        case let .unavailable(reason):
            return "Could not import Activity Receipts: \(reason.rawValue)."
        }
    }

    func deleteActivityReceipts() -> Bool {
        guard let activityReceiptStore else { return false }
        do {
            try activityReceiptStore.deleteAll()
            activityDebuggerState = .unavailable(.noReceipts)
            return true
        } catch {
            return false
        }
    }

    func deleteProjectAgentAttribution() async -> Bool {
        do {
            try await attributionEvidenceStore.deleteAllAttributionEvidence(now: Date())
            requestLocalRefresh()
            return true
        } catch {
            return false
        }
    }

    private static func activityState(store: SQLiteActivityReceiptStore?) -> ActivityDebuggerState {
        guard let store else { return .unavailable(.storageUnavailable) }
        guard let receipts = try? store.all() else { return .unavailable(.storageUnavailable) }
        return ActivityReceiptDebugger.latestRunFindings(for: receipts)
    }

    func refreshQuotaInsights(for snapshot: LocalRefreshSnapshot) async {
        let refreshToken = PendingInvestigationRefresh.generation(snapshot.sequence)
        pendingInvestigationRefresh = refreshToken
        investigationPublication = investigationPublication.loading(pendingGeneration: snapshot.sequence)
        local.apply(snapshot)
        guard let quotaInsightsService else {
            if pendingInvestigationRefresh == refreshToken {
                investigationPublication = investigationPublication.failed(pendingGeneration: snapshot.sequence)
                pendingInvestigationRefresh = nil
            }
            return
        }
        do {
            var staged = quotaAnalysis
            let claude = try await quotaInsightsService.reevaluateClaudeAnalysis(now: snapshot.refreshedAt)
            staged = Self.merging(staged, with: claude, for: .claudeCode)
            let codex: QuotaFindingAnalysisSnapshot
            if snapshot.codexRefreshed, let codexSnapshot = snapshot.codex {
                codex = try await quotaInsightsService.recordCodexAnalysis(codexSnapshot, now: snapshot.refreshedAt)
            } else {
                codex = try await quotaInsightsService.reevaluateCodexAnalysis(now: snapshot.refreshedAt)
            }
            staged = Self.merging(staged, with: codex, for: .codex)

            if pendingInvestigationRefresh == refreshToken {
                quotaAnalysis = staged
                claudeExplanationCatalog = staged.claudeExplanations
                quotaInsightsStorageAvailable = true
                publishInvestigation(generation: snapshot.sequence, at: snapshot.refreshedAt)
                pendingInvestigationRefresh = nil
            }
        } catch {
            if pendingInvestigationRefresh == refreshToken {
                quotaInsightsStorageAvailable = false
                investigationPublication = investigationPublication.failed(pendingGeneration: snapshot.sequence)
                pendingInvestigationRefresh = nil
            }
        }
    }

    func alertSettingsChanged() {
        Task {
            await evaluateLocalAlerts()
            guard case let .loaded(snapshot, subscription) = claudeModel.state else { return }
            let now = Date()
            await alertCoordinator.evaluate(
                quota: QuotaObservationAdapter.claude(snapshot, subscriptionType: subscription, now: now),
                costs: [],
                forecasts: Array(quotaInsights.values),
                anomalies: Array(quotaAnomalies.values),
                now: now
            )
        }
    }

    private func evaluateLocalAlerts() async {
        let now = Date()
        let quota = latestCodexRefreshed
            ? local.codexSnapshot.map { QuotaObservationAdapter.codex($0, now: now) } ?? []
            : []
        publishCapacity(now: now, codex: quota)
        let health: AlertObservationHealth = latestUsageRefreshed && local.storeHealth.isOpen ? .healthy : .unhealthy
        let metrics = local.localImport.failureMessage == nil
            ? local.metrics
            : local.metrics.filter { $0.provenance.source != .builtInLocalLog }
        let costs = CostBudgetObservationBuilder.observations(
            metrics: metrics,
            pricing: PricingSettingsStore().pricingTable,
            health: health,
            now: now
        )
        await alertCoordinator.evaluate(
            quota: quota,
            costs: costs,
            forecasts: Array(quotaInsights.values),
            anomalies: Array(quotaAnomalies.values),
            now: now
        )
    }

    private func publishCapacity(
        now: Date,
        claude: [QuotaObservation]? = nil,
        codex: [QuotaObservation]? = nil
    ) {
        guard let capacityPublicationWriter else { return }
        let currentClaude: [QuotaObservation]
        if let claude {
            currentClaude = claude
        } else if case let .loaded(snapshot, subscription) = claudeModel.state {
            currentClaude = QuotaObservationAdapter.claude(snapshot, subscriptionType: subscription, now: now)
        } else {
            currentClaude = []
        }
        let currentCodex = codex ?? (latestCodexRefreshed
            ? local.codexSnapshot.map { QuotaObservationAdapter.codex($0, now: now) } ?? []
            : [])
        try? capacityPublicationWriter.publish(CapacityPublication(
            publishedAt: now,
            quotaObservations: currentClaude + currentCodex
        ))
    }

    private func recordClaudeInsights(_ snapshot: ClaudeRateLimitSnapshot, now: Date) async {
        guard let quotaInsightsService else { return }
        do {
            let analysis = try await quotaInsightsService.recordClaudeAnalysis(snapshot, now: now)
            publish(analysis, for: .claudeCode)
            if let explanation = analysis.claudeExplanations.defaultSelection?.state {
                try? claudeExplanationStore?.record(explanation, now: now)
            }
            quotaInsightsStorageAvailable = true
        } catch {
            quotaInsightsStorageAvailable = false
            if pendingInvestigationRefresh == nil {
                investigationPublication = investigationPublication.failed(pendingGeneration: nil)
            }
        }
    }

    func recordCodexInsights(_ snapshot: CodexRateLimitSnapshot, now: Date) async {
        guard let quotaInsightsService else { return }
        do {
            let analysis = try await quotaInsightsService.recordCodexAnalysis(snapshot, now: now)
            publish(analysis, for: .codex)
            quotaInsightsStorageAvailable = true
        } catch {
            quotaInsightsStorageAvailable = false
            if pendingInvestigationRefresh == nil {
                investigationPublication = investigationPublication.failed(pendingGeneration: nil)
            }
        }
    }

    func reevaluateCodexInsights(now: Date) async {
        guard let quotaInsightsService else { return }
        do {
            let analysis = try await quotaInsightsService.reevaluateCodexAnalysis(now: now)
            publish(analysis, for: .codex)
            quotaInsightsStorageAvailable = true
        } catch {
            quotaInsightsStorageAvailable = false
            if pendingInvestigationRefresh == nil {
                investigationPublication = investigationPublication.failed(pendingGeneration: nil)
            }
        }
    }

    private func publish(_ analysis: QuotaFindingAnalysisSnapshot, for product: ProviderProduct) {
        quotaAnalysis = Self.merging(quotaAnalysis, with: analysis, for: product)
        claudeExplanationCatalog = quotaAnalysis.claudeExplanations
        if pendingInvestigationRefresh == nil {
            publishInvestigation(generation: investigationPublication.generation, at: Date())
        }
    }

    func beginInvestigationRefreshRequest() {
        pendingInvestigationRefresh = .requested(UUID())
        investigationPublication = investigationPublication.loading(pendingGeneration: nil)
    }

    private static func merging(
        _ current: QuotaFindingAnalysisSnapshot,
        with analysis: QuotaFindingAnalysisSnapshot,
        for product: ProviderProduct
    ) -> QuotaFindingAnalysisSnapshot {
        var forecasts = current.forecasts.filter { $0.key.product != product }
        var anomalies = current.anomalies.filter { $0.key.product != product }
        forecasts.merge(analysis.forecasts) { _, new in new }
        anomalies.merge(analysis.anomalies) { _, new in new }
        let explanations = product == .claudeCode ? analysis.claudeExplanations : current.claudeExplanations
        return QuotaFindingAnalysisSnapshot(forecasts: forecasts, anomalies: anomalies, claudeExplanations: explanations)
    }

    private func publishInvestigation(generation: UInt64?, at date: Date) {
        investigationPublication = ForensicInvestigationAssembler.make(ForensicInvestigationInput(
            generation: generation,
            publishedAt: date,
            codexSnapshot: local.codexSnapshot,
            codexExplanation: local.codexExplanation,
            codexExplanationRetained: local.codexExplanationRetained,
            claudeExplanationCatalog: claudeExplanationCatalog,
            forecasts: quotaAnalysis.forecasts,
            anomalies: quotaAnalysis.anomalies,
            storageAvailable: quotaInsightsStorageAvailable,
            storeOpen: local.storeHealth.isOpen
        ))
    }

    private static func catalog(restoring state: ClaudeQuotaExplanationState?) -> ClaudeQuotaExplanationCatalog {
        guard let state else { return .empty }
        let value: ClaudeQuotaExplanation
        switch state {
        case let .movement(explanation), let .flat(explanation): value = explanation
        case .unavailable: return .empty
        }
        guard let identity = try? QuotaWindowIdentity(product: .claudeCode, identifier: "retained", resetBoundary: value.quotaResetBoundary) else { return .empty }
        let interval = ClaudeQuotaExplanationInterval(
            id: value.observationIdentities.map(\.digest).joined(separator: ":"),
            identity: identity,
            intervalStart: value.intervalStart,
            intervalEnd: value.intervalEnd,
            lifecycle: value.lifecycle
        )
        return ClaudeQuotaExplanationCatalog(
            selections: [ClaudeQuotaExplanationSelection(interval: interval, state: state, limitations: [])],
            defaultSelectionID: interval.id
        )
    }

}

private struct ApplicationLocalUsageRefresher: LocalUsageRefreshing {
    func refresh(now: Date, calendar: Calendar) async -> LocalUsageRefresh {
        let diagnostics = await UsageDatabase.shared.refreshCustomSources(CustomUsageSourceStore().sources, now: now, calendar: calendar)
        let snapshot = await UsageDatabase.shared.snapshot(now: now, calendar: calendar)
        let pricing = PricingSettingsStore()
        var observedSources = Set<UsageMetricSource>()
        if snapshot.localImport.failureMessage == nil {
            observedSources.insert(.builtInLocalLog)
        }
        for diagnostic in diagnostics where diagnostic.failureMessage == nil {
            observedSources.insert(.custom(diagnostic.sourceID))
        }
        let history = await UsageDatabase.shared.historicalUsage(
            metrics: snapshot.metrics,
            now: now,
            calendar: calendar,
            pricing: pricing.pricingTable,
            pricingRevision: pricing.revision,
            observedSources: observedSources
        )
        return LocalUsageRefresh(snapshot: snapshot, customDiagnostics: diagnostics, history: history)
    }
}

private struct MenuBarStatusLabel: View {
    let state: LimitBarState

    var body: some View {
        Label(state.local.status.menuBarText, systemImage: state.local.status.symbolName)
            .labelStyle(.iconOnly)
            .foregroundStyle(statusColor)
            .accessibilityLabel(state.local.status.accessibilityDescription)
            .task { state.start() }
            .onReceive(NotificationCenter.default.publisher(for: .providerSettingsDidChange)) { _ in
                state.requestLocalRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .customUsageSourcesDidChange)) { _ in
                state.requestLocalRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .historicalUsageDidChange)) { _ in
                state.requestLocalRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .localRefreshSettingsDidChange)) { _ in
                state.localRefreshSettingsChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: .alertSettingsDidChange)) { _ in
                state.alertSettingsChanged()
            }
    }

    private var statusColor: Color {
        switch state.local.status.statusColor {
        case .green:
            .green
        case .yellow:
            .yellow
        case .red:
            .red
        case .gray:
            .secondary
        }
    }
}

extension Notification.Name {
    static let historicalUsageDidChange = Notification.Name("LimitBar.historicalUsageDidChange")
}
