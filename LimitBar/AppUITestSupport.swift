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
        switch intent {
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
                    resetsAt: nil,
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
        default:
            MonitoringPopoverView(state: state)
                .defaultAppStorage(AppUITestConfiguration.userDefaults!)
        }
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
