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

    private let coordinator: LocalRefreshCoordinator
    private let usesLiveRefresh: Bool
    private var observationTask: Task<Void, Never>?
    private var latestUsageRefreshed = false
    private var latestCodexRefreshed = false

    private init() {
        let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
        providerSettings = ProviderSettingsStore().settings
        coordinator = LocalRefreshCoordinator(dependencies: .live(
            usage: ApplicationLocalUsageRefresher(),
            codex: CodexSessionScanner(sessionsDirectory: sessionsDirectory)
        ))
        claudeModel = ClaudeRateLimitsModel(
            credentials: ClaudeCredentialBroker.shared,
            client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
        )
        usesLiveRefresh = true
        let alertSettingsStore = AlertSettingsStore()
        self.alertSettingsStore = alertSettingsStore
        alertCoordinator = AlertCoordinator(settingsStore: alertSettingsStore)
    }

    init(
        providerSettings: [ProviderSettings],
        claudeModel: ClaudeRateLimitsModel,
        coordinator: LocalRefreshCoordinator
    ) {
        self.providerSettings = providerSettings
        self.claudeModel = claudeModel
        self.coordinator = coordinator
        usesLiveRefresh = false
        let alertSettingsStore = AlertSettingsStore()
        self.alertSettingsStore = alertSettingsStore
        alertCoordinator = AlertCoordinator(settingsStore: alertSettingsStore)
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
                await evaluateLocalAlerts()
            }
        }
    }

    func requestLocalRefresh() {
        guard usesLiveRefresh else { return }
        providerSettings = ProviderSettingsStore().settings
        Task { [coordinator] in await coordinator.requestRefresh() }
    }

    func clearHistoricalUsage() {
        local.clearHistory()
    }

    func claudeActionCompleted() {
        guard case let .loaded(snapshot, subscription) = claudeModel.state else { return }
        let now = Date()
        let observations = QuotaObservationAdapter.claude(snapshot, subscriptionType: subscription, now: now)
        Task { await alertCoordinator.evaluate(quota: observations, costs: [], now: now) }
    }

    func alertSettingsChanged() {
        Task {
            await evaluateLocalAlerts()
            guard case let .loaded(snapshot, subscription) = claudeModel.state else { return }
            let now = Date()
            await alertCoordinator.evaluate(
                quota: QuotaObservationAdapter.claude(snapshot, subscriptionType: subscription, now: now),
                costs: [],
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
        await alertCoordinator.evaluate(quota: quota, costs: costs, now: now)
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
