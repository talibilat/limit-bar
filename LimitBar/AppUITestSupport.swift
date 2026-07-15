#if DEBUG
import AppKit
import Foundation
import LimitBarCore
import SwiftUI

enum AppTestConfiguration {
    private static let enabledArguments = ["--limitbar-testing", "--limitbar-ui-testing"]

    static var isEnabled: Bool {
        enabledArguments.contains { ProcessInfo.processInfo.arguments.contains($0) }
    }

    @MainActor
    static func state() -> LimitBarState {
        LimitBarState(
            providerSettings: [],
            claudeModel: ClaudeRateLimitsModel(
                credentials: AppUITestClaudeCredentials(),
                client: AppUITestClaudeRateLimitsClient()
            ),
            coordinator: LocalRefreshCoordinator(dependencies: LocalRefreshDependencies(
                refreshUsage: { _, _ in throw CancellationError() },
                scanCodex: { _ in nil }
            ))
        )
    }
}

enum AppUITestConfiguration {
    private static let enabledArgument = "--limitbar-ui-testing"
    private static let screenEnvironmentKey = "LIMITBAR_UI_TEST_SCREEN"
    private static let runIdentifierEnvironmentKey = "LIMITBAR_UI_TEST_RUN_ID"
    private static let fixturePathEnvironmentKey = "LIMITBAR_UI_TEST_CUSTOM_SOURCE_PATH"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(enabledArgument) && runIdentifier != nil
    }

    static var screen: String? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.environment[screenEnvironmentKey]
    }

    static var customSourceFixturePath: String? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.environment[fixturePathEnvironmentKey]
    }

    static var userDefaults: UserDefaults? {
        guard isEnabled, let runIdentifier else { return nil }
        return UserDefaults(suiteName: "com.talibilat.LimitBar.ui-tests.\(runIdentifier)")
    }

    private static var runIdentifier: String? {
        ProcessInfo.processInfo.environment[runIdentifierEnvironmentKey]
    }
}

@MainActor
final class AppUITestAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppUITestConfiguration.isEnabled else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LimitBar UI Tests"
        window.center()
        window.contentViewController = NSHostingController(rootView: LimitBarUITestHostView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private actor AppUITestClaudeCredentials: ClaudeCredentialProviding {
    func credential(intent: ClaudeCredentialIntent) -> ClaudeCredentialResult {
        if AppUITestConfiguration.screen == "claude-login-required" {
            return .absent
        }
        return switch intent {
        case .passive:
            .failure(.interactionRequired)
        case .interactive:
            .credential(ClaudeCodeOAuthCredential(
                accessToken: "",
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                subscriptionType: "pro"
            ))
        }
    }

    func invalidate() {}
}

private struct AppUITestClaudeRateLimitsClient: ClaudeRateLimitsFetching {
    func fetchRateLimits(accessToken: String) async -> Result<ClaudeRateLimitSnapshot, ClaudeRateLimitFailure> {
        .success(ClaudeRateLimitSnapshot(
            limits: [
                ClaudeRateLimit(
                    kind: "session",
                    group: .session,
                    percentUsed: 25,
                    severity: .normal,
                    resetsAt: Date(timeIntervalSince1970: 2_000_000_000),
                    scopeDisplayName: nil,
                    isActive: true
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }
}

private struct LimitBarUITestHostView: View {
    @State private var state = AppTestConfiguration.state()

    var body: some View {
        switch AppUITestConfiguration.screen {
        case "settings":
            Form {
                CustomUsageSourcesSection(
                    store: CustomUsageSourceStore(defaults: AppUITestConfiguration.userDefaults!),
                    chooseFile: { AppUITestConfiguration.customSourceFixturePath }
                )
            }
            .formStyle(.grouped)
            .padding(20)
            .frame(width: 620, height: 720)
        case "diagnostic-export":
            Form {
                DiagnosticExportSection(model: AppUITestDiagnosticExport.model())
            }
            .formStyle(.grouped)
            .padding(20)
            .frame(width: 620, height: 720)
        case "quota-insight":
            QuotaInsightUITestView()
        case "codex-explanation":
            CodexExplanationUITestView()
        case "claude-explanation":
            ClaudeExplanationUITestView()
        case "claude-explanation-single":
            ClaudeExplanationUITestView(includeCompleted: false)
        case "investigation-all-available":
            ForensicInvestigationView(snapshot: AppUITestInvestigation.fixture(.available))
        case "investigation-partial":
            ForensicInvestigationView(snapshot: AppUITestInvestigation.fixture(.partial))
        case "investigation-loading":
            ForensicInvestigationView(snapshot: AppUITestInvestigation.fixture(.loading))
        case "investigation-empty":
            ForensicInvestigationView(snapshot: AppUITestInvestigation.fixture(.empty))
        case "investigation-unavailable":
            ForensicInvestigationView(snapshot: AppUITestInvestigation.fixture(.unavailable))
        case "investigation-error":
            ForensicInvestigationView(snapshot: AppUITestInvestigation.fixture(.error))
        default:
            MonitoringPopoverView(state: state)
                .defaultAppStorage(AppUITestConfiguration.userDefaults!)
        }
    }
}

private enum AppUITestInvestigation {
    static let start = Date(timeIntervalSince1970: 1_900_000_000)
    static let reset = start.addingTimeInterval(7_200)

    static func fixture(_ state: InvestigationPublicationState) -> ForensicInvestigationSnapshot {
        guard state == .available || state == .partial else {
            return ForensicInvestigationSnapshot(
                publicationState: state,
                publishedAt: start.addingTimeInterval(1_800),
                products: [],
                apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary,
                message: state.label
            )
        }
        let identity = try! QuotaWindowIdentity(product: .codex, identifier: "primary:300", resetBoundary: reset)
        let qualifiedForecast = InvestigationFindingPresentation(
            status: "Qualified",
            summary: "Calculated burn 4.0-6.0% per hour; exhaustion is not projected before the Reported reset.",
            details: "4 Measured observations over 30m; evidence age 2m; method pairwise_positive_slope_interquartile_v2; qualification qualified; exact bounded evidence range."
        )
        let noFinding = InvestigationFindingPresentation(
            status: "No finding",
            summary: "Qualified analysis found no anomaly.",
            details: "Current exact period and trailing baseline exact period; method trailing_median_ratio_v1; Measured inputs; limitations no_causal_attribution."
        )
        let available = InvestigationRecord(
            id: "available",
            identity: identity,
            start: start,
            end: start.addingTimeInterval(900),
            authoritativeTotal: "Reported provider total: 6 percentage-point movement between two Reported observations.",
            localBreakdown: "Measured Observed Local Breakdown: 42 tokens across 2 privacy-safe sessions. Not added to the provider total.",
            unattributed: "Unattributed: provider movement is not allocated to local activity and no causal claim is made.",
            forecast: qualifiedForecast,
            anomaly: noFinding,
            version: "Explanation method codex-quota-explanation-v1; adapter codex-rollout-observed-0.144.4; client version unavailable - not captured.",
            limitations: "Exact source traces: 2 Reported observations and 3 Measured evidence items; provider weighting unknown.",
            isGap: false,
            isObservedZero: false
        )
        var records = [available]
        if state == .partial {
            records.append(InvestigationRecord(
                id: "observed-zero",
                identity: identity,
                start: start.addingTimeInterval(1_200),
                end: start.addingTimeInterval(1_800),
                authoritativeTotal: "Reported provider total: 0 percentage-point movement.",
                localBreakdown: "Measured Observed Zero local activity with complete supported evidence coverage.",
                unattributed: "Unattributed: flat movement does not prove that no activity occurred.",
                forecast: InvestigationFindingPresentation(status: "Unavailable", summary: "Unavailable - no point estimate is shown.", details: "Reason no_positive_burn; method pairwise_positive_slope_interquartile_v2."),
                anomaly: InvestigationFindingPresentation(status: "Observed Zero", summary: "Measured inputs produced a Calculated zero value.", details: "Current period and baseline period preserved; method trailing_median_ratio_v1."),
                version: "Adapter version codex-rollout-observed-0.144.4; client version unavailable - not captured.",
                limitations: "Observed Zero does not prove that no other activity occurred.",
                isGap: false,
                isObservedZero: true
            ))
            records.append(InvestigationRecord(
                id: "gap",
                identity: identity,
                start: start.addingTimeInterval(2_100),
                end: start.addingTimeInterval(2_700),
                authoritativeTotal: "Authoritative movement unavailable for this exact interval.",
                localBreakdown: "Observed Local Breakdown unavailable. This is a Gap, not zero usage.",
                unattributed: "Unattributed: no local activity is assigned to provider movement.",
                forecast: InvestigationFindingPresentation(status: "Unavailable", summary: "Unavailable - no point estimate is shown.", details: "Reason gap; method pairwise_positive_slope_interquartile_v2."),
                anomaly: InvestigationFindingPresentation(status: "Unavailable - Gap", summary: "Analysis unavailable: gap. No numerical finding is shown.", details: "Current period and baseline period preserved; method trailing_median_ratio_v1."),
                version: "Adapter version unavailable - not captured; no unchanged-version claim.",
                limitations: "Partial coverage and Gap. No interpolation is drawn.",
                isGap: true,
                isObservedZero: false
            ))
        }
        return ForensicInvestigationSnapshot(
            publicationState: state,
            publishedAt: start.addingTimeInterval(1_800),
            products: [InvestigationProductEvidence(product: .codex, records: records, attributions: [])],
            apiEvidenceNotice: APIProviderQuotaPathAvailability.fixedUnavailableSummary,
            message: state == .partial ? "Independent qualified sections remain available; unavailable sections are not presented as zero." : nil
        )
    }
}

private struct ClaudeExplanationUITestView: View {
    var includeCompleted = true
    private let reset = Date(timeIntervalSince1970: 2_000_000_000)

    var body: some View {
        ClaudeRateLimitsView(
            model: ClaudeRateLimitsModel(
                credentials: ClaudeExplanationCredentials(),
                client: AppUITestClaudeRateLimitsClient(),
                state: .loaded(ClaudeRateLimitSnapshot(
                    limits: [ClaudeRateLimit(kind: "session", group: .session, percentUsed: 14, severity: .normal, resetsAt: reset, scopeDisplayName: nil, isActive: true)],
                    fetchedAt: Date(timeIntervalSince1970: 1_900_000_100)
                ), subscription: "max")
            ),
            insights: [:],
            anomalies: [:],
            insightsStorageAvailable: true,
            explanationCatalog: explanationCatalog,
            onActionCompleted: {}
        )
        .padding(20)
        .frame(width: 620, height: 420)
    }

    private var explanationCatalog: ClaudeQuotaExplanationCatalog {
        guard let identity = try? QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: reset) else { return .empty }
        let interval = ClaudeQuotaExplanationInterval(id: String(repeating: "f", count: 64), identity: identity, intervalStart: Date(timeIntervalSince1970: 1_900_000_000), intervalEnd: Date(timeIntervalSince1970: 1_900_000_100), lifecycle: .active)
        let state = ClaudeQuotaExplanationState.unavailable(.quotaAccountScopeUnavailable)
        guard let completedIdentity = try? QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: Date(timeIntervalSince1970: 1_800_000_200)) else { return .empty }
        let completed = ClaudeQuotaExplanationInterval(id: "completed-fixture", identity: completedIdentity, intervalStart: Date(timeIntervalSince1970: 1_800_000_000), intervalEnd: Date(timeIntervalSince1970: 1_800_000_100), lifecycle: .completed)
        let active = ClaudeQuotaExplanationSelection(interval: interval, state: state, limitations: [.receiverNotConfigured, .accountBindingUnavailable, .quotaAccountScopeUnavailable])
        let historical = ClaudeQuotaExplanationSelection(interval: completed, state: state, limitations: [.receiverNotConfigured, .accountBindingUnavailable, .quotaAccountScopeUnavailable])
        return ClaudeQuotaExplanationCatalog(
            selections: includeCompleted ? [active, historical] : [active],
            defaultSelectionID: interval.id
        )
    }
}

private actor ClaudeExplanationCredentials: ClaudeCredentialProviding {
    func credential(intent: ClaudeCredentialIntent) -> ClaudeCredentialResult {
        .credential(ClaudeCodeOAuthCredential(
            accessToken: "fixture",
            expiresAt: Date(timeIntervalSince1970: 2_100_000_000),
            subscriptionType: "max"
        ))
    }

    func invalidate() {}
}

private struct CodexExplanationUITestView: View {
    var body: some View {
        CodexRateLimitsView(
            snapshot: CodexRateLimitSnapshot(
                planType: "plus",
                primary: CodexRateLimitWindow(percentUsed: 13.5, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1_783_716_600)),
                secondary: nil,
                credits: nil,
                reportedAt: Date(timeIntervalSince1970: 1_783_716_200)
            ),
            metrics: [],
            pricingTable: .empty,
            insights: [:],
            anomalies: [:],
            insightsStorageAvailable: true,
            explanation: .available(CodexQuotaExplanation(
                intervalStart: Date(timeIntervalSince1970: 1_783_716_100),
                intervalEnd: Date(timeIntervalSince1970: 1_783_716_200),
                quotaResetBoundary: Date(timeIntervalSince1970: 1_783_716_600),
                coverageStart: Date(timeIntervalSince1970: 1_783_716_090),
                coverageEnd: Date(timeIntervalSince1970: 1_783_716_210),
                reportedQuotaMovementPercent: 3.5,
                observedLocalBreakdown: CodexObservedLocalBreakdown(
                    tokens: CodexMeasuredTokens(input: 7, cachedInput: 2, output: 3, reasoningOutput: 1),
                    sessionCount: 1
                ),
                unattributed: true,
                allocationPercent: nil,
                observationIdentities: [],
                evidenceIdentities: ["fixture"],
                adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
                barriers: []
            ))
        )
        .padding(20)
        .frame(width: 620, height: 420)
    }
}

private struct QuotaInsightUITestView: View {
    private let fixture: QuotaForecastReplayFixture
    private let insight: QuotaInsightState

    init() {
        let fixtures = try! QuotaForecastFrozenCorpus.validatedFixtures()
        fixture = fixtures.first { $0.id == "heldout-codex-stable-01" }!
        insight = QuotaInsightAnalytics.analyze(
            fixture.observations,
            now: fixture.evaluationTime,
            maximumAge: fixture.maximumEvidenceAge
        )
    }

    var body: some View {
        PercentRateLimitRowView(
            label: "Session (5 hours)",
            percentUsed: 76,
            severity: .normal,
            resetsAt: fixture.observations.first?.identity.resetBoundary,
            isActive: true,
            insight: insight,
            anomaly: nil,
            insightsStorageAvailable: true
        )
        .padding(20)
        .frame(width: 620, height: 300)
    }
}

@MainActor
private enum AppUITestDiagnosticExport {
    static func model() -> DiagnosticExportModel {
        DiagnosticExportModel(
            makeArtifact: {
                try DiagnosticExport.make(from: DiagnosticExportInput(
                    generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    appVersion: DiagnosticVersion(major: 1, minor: 2, patch: 3),
                    appBuild: 42,
                    operatingSystemVersion: DiagnosticVersion(major: 15, minor: 0, patch: 0),
                    providerStatuses: [DiagnosticProviderStatus(provider: .anthropic, state: .connected)],
                    databaseState: .available,
                    importCounts: DiagnosticImportCounts(accepted: 7, rejected: 2),
                    resourceLimitReasons: []
                ))
            },
            chooseDestination: { nil }
        )
    }
}
#endif
