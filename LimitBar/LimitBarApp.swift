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
    var claudeExplanation: ClaudeQuotaExplanationState {
        claudeExplanationCatalog.defaultSelection?.state ?? .unavailable(.insufficientObservations)
    }

    private let coordinator: LocalRefreshCoordinator
    private let quotaInsightsService: (any QuotaInsightsServing)?
    private let codexExplanationStore: SQLiteCodexExplanationStore?
    private let claudeExplanationStore: SQLiteClaudeExplanationStore?
    private let attributionEvidenceStore: any AttributionEvidenceDeleting
    private let usesLiveRefresh: Bool
    private var observationTask: Task<Void, Never>?
    private var latestUsageRefreshed = false
    private var latestCodexRefreshed = false

    private init() {
        let sessionsDirectory = LimitBarFileLocations.codexSessionsDirectory(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let refreshCadence = LocalRefreshSettingsStore().cadence
        providerSettings = ProviderSettingsStore().settings
        let codexExplanationStore = try? SQLiteCodexExplanationStore.applicationSupportStore()
        let claudeExplanationStore = try? SQLiteClaudeExplanationStore.applicationSupportStore()
        self.codexExplanationStore = codexExplanationStore
        self.claudeExplanationStore = claudeExplanationStore
        attributionEvidenceStore = UsageDatabase.shared
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
    }

    init(
        providerSettings: [ProviderSettings],
        claudeModel: ClaudeRateLimitsModel,
        coordinator: LocalRefreshCoordinator,
        quotaInsightsService: (any QuotaInsightsServing)? = nil,
        codexExplanationStore: SQLiteCodexExplanationStore? = nil,
        claudeExplanationStore: SQLiteClaudeExplanationStore? = nil,
        attributionEvidenceStore: any AttributionEvidenceDeleting = UsageDatabase.shared
    ) {
        self.providerSettings = providerSettings
        self.claudeModel = claudeModel
        self.coordinator = coordinator
        self.quotaInsightsService = quotaInsightsService
        self.codexExplanationStore = codexExplanationStore
        self.claudeExplanationStore = claudeExplanationStore
        self.attributionEvidenceStore = attributionEvidenceStore
        quotaInsightsStorageAvailable = quotaInsightsService != nil
        usesLiveRefresh = false
        let alertSettingsStore = AlertSettingsStore()
        self.alertSettingsStore = alertSettingsStore
        alertCoordinator = AlertCoordinator(settingsStore: alertSettingsStore)
        local.restoreCodexExplanation(try? codexExplanationStore?.latest())
        claudeExplanationCatalog = Self.catalog(restoring: try? claudeExplanationStore?.latest())
    }

    func start() {
        guard usesLiveRefresh else { return }
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, coordinator] in
            await coordinator.start()
            for await snapshot in coordinator.snapshots {
                guard let self else { return }
                local.apply(snapshot)
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
            return true
        } catch {
            quotaInsightsStorageAvailable = false
            return false
        }
    }

    func deleteCodexExplanations() async -> Bool {
        guard let codexExplanationStore else { return false }
        do {
            try codexExplanationStore.deleteAll()
            local.clearCodexExplanation()
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

    func refreshQuotaInsights(for snapshot: LocalRefreshSnapshot) async {
        await reevaluateClaudeInsights(now: snapshot.refreshedAt)
        await reevaluateCodexInsights(now: snapshot.refreshedAt)
        if snapshot.codexRefreshed, let codex = snapshot.codex {
            await recordCodexInsights(codex, now: snapshot.refreshedAt)
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
        }
    }

    private func reevaluateClaudeInsights(now: Date) async {
        guard let quotaInsightsService else { return }
        do {
            let analysis = try await quotaInsightsService.reevaluateClaudeAnalysis(now: now)
            publish(analysis, for: .claudeCode)
            quotaInsightsStorageAvailable = true
        } catch {
            quotaInsightsStorageAvailable = false
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
        }
    }

    private func publish(_ analysis: QuotaFindingAnalysisSnapshot, for product: ProviderProduct) {
        var forecasts = quotaAnalysis.forecasts.filter { $0.key.product != product }
        var anomalies = quotaAnalysis.anomalies.filter { $0.key.product != product }
        forecasts.merge(analysis.forecasts) { _, new in new }
        anomalies.merge(analysis.anomalies) { _, new in new }
        let explanations = product == .claudeCode ? analysis.claudeExplanations : quotaAnalysis.claudeExplanations
        quotaAnalysis = QuotaFindingAnalysisSnapshot(forecasts: forecasts, anomalies: anomalies, claudeExplanations: explanations)
        claudeExplanationCatalog = explanations
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
