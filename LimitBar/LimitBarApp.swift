import SwiftUI
import LimitBarCore
import Observation

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
    private(set) var quotaInsights: [QuotaWindowIdentity: QuotaInsightState] = [:]
    private(set) var quotaAnomalies: [QuotaWindowIdentity: QuotaAnomalyState] = [:]
    private(set) var quotaInsightsStorageAvailable: Bool

    private let coordinator: LocalRefreshCoordinator
    private let quotaInsightsService: QuotaInsightsService?
    private let codexExplanationStore: SQLiteCodexExplanationStore?
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
        self.codexExplanationStore = codexExplanationStore
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
    }

    init(
        providerSettings: [ProviderSettings],
        claudeModel: ClaudeRateLimitsModel,
        coordinator: LocalRefreshCoordinator,
        quotaInsightsService: QuotaInsightsService? = nil,
        codexExplanationStore: SQLiteCodexExplanationStore? = nil
    ) {
        self.providerSettings = providerSettings
        self.claudeModel = claudeModel
        self.coordinator = coordinator
        self.quotaInsightsService = quotaInsightsService
        self.codexExplanationStore = codexExplanationStore
        quotaInsightsStorageAvailable = quotaInsightsService != nil
        usesLiveRefresh = false
        let alertSettingsStore = AlertSettingsStore()
        self.alertSettingsStore = alertSettingsStore
        alertCoordinator = AlertCoordinator(settingsStore: alertSettingsStore)
        local.restoreCodexExplanation(try? codexExplanationStore?.latest())
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
            quotaInsights = [:]
            quotaAnomalies = [:]
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
            quotaInsights.merge(try await quotaInsightsService.recordClaude(snapshot, now: now)) { _, new in new }
            let anomalies = try await quotaInsightsService.reevaluateClaudeAnomalies(now: now)
            quotaAnomalies = quotaAnomalies.filter { $0.key.product != .claudeCode }
            quotaAnomalies.merge(anomalies) { _, new in new }
            quotaInsightsStorageAvailable = true
        } catch {
            quotaInsightsStorageAvailable = false
        }
    }

    private func reevaluateClaudeInsights(now: Date) async {
        guard let quotaInsightsService else { return }
        do {
            let reevaluated = try await quotaInsightsService.reevaluateClaude(now: now)
            let anomalies = try await quotaInsightsService.reevaluateClaudeAnomalies(now: now)
            quotaInsights = quotaInsights.filter { $0.key.product != .claudeCode }
            quotaInsights.merge(reevaluated) { _, new in new }
            quotaAnomalies = quotaAnomalies.filter { $0.key.product != .claudeCode }
            quotaAnomalies.merge(anomalies) { _, new in new }
            quotaInsightsStorageAvailable = true
        } catch {
            quotaInsightsStorageAvailable = false
        }
    }

    private func recordCodexInsights(_ snapshot: CodexRateLimitSnapshot, now: Date) async {
        guard let quotaInsightsService else { return }
        do {
            quotaInsights.merge(try await quotaInsightsService.recordCodex(snapshot, now: now)) { _, new in new }
            let anomalies = try await quotaInsightsService.reevaluateCodexAnomalies(now: now)
            quotaAnomalies = quotaAnomalies.filter { $0.key.product != .codex }
            quotaAnomalies.merge(anomalies) { _, new in new }
            quotaInsightsStorageAvailable = true
        } catch {
            quotaInsightsStorageAvailable = false
        }
    }

    private func reevaluateCodexInsights(now: Date) async {
        guard let quotaInsightsService else { return }
        do {
            let reevaluated = try await quotaInsightsService.reevaluateCodex(now: now)
            let anomalies = try await quotaInsightsService.reevaluateCodexAnomalies(now: now)
            quotaInsights = quotaInsights.filter { $0.key.product != .codex }
            quotaInsights.merge(reevaluated) { _, new in new }
            quotaAnomalies = quotaAnomalies.filter { $0.key.product != .codex }
            quotaAnomalies.merge(anomalies) { _, new in new }
            quotaInsightsStorageAvailable = true
        } catch {
            quotaInsightsStorageAvailable = false
        }
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
