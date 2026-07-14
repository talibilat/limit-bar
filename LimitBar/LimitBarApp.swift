import SwiftUI
import LimitBarCore
import Observation

@main
struct LimitBarApp: App {
    @State private var state = LimitBarState.shared

    var body: some Scene {
        MenuBarExtra {
            MonitoringPopoverView(state: state)
        } label: {
            MenuBarStatusLabel(state: state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            LimitBarSettingsView(state: state)
        }
    }
}

@MainActor
@Observable
final class LimitBarState {
    static let shared = LimitBarState()

    let local = LimitBarLocalStateProjection()
    private(set) var providerSettings = ProviderSettingsStore().settings
    let claudeModel: ClaudeRateLimitsModel
    let alertSettingsStore: AlertSettingsStore
    let alertCoordinator: AlertCoordinator

    private let coordinator: LocalRefreshCoordinator
    private var observationTask: Task<Void, Never>?
    private var latestUsageRefreshed = false
    private var latestCodexRefreshed = false

    private init() {
        let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
        coordinator = LocalRefreshCoordinator(dependencies: .live(
            usage: ApplicationLocalUsageRefresher(),
            codex: CodexSessionScanner(sessionsDirectory: sessionsDirectory)
        ))
        claudeModel = ClaudeRateLimitsModel(
            credentials: ClaudeCredentialBroker.shared,
            client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
        )
        let alertSettingsStore = AlertSettingsStore()
        self.alertSettingsStore = alertSettingsStore
        alertCoordinator = AlertCoordinator(settingsStore: alertSettingsStore)
    }

    func start() {
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
        providerSettings = ProviderSettingsStore().settings
        Task { [coordinator] in await coordinator.requestRefresh() }
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
        return LocalUsageRefresh(snapshot: snapshot, customDiagnostics: diagnostics)
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
