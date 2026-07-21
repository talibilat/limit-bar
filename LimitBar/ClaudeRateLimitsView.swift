import Foundation
import LimitBarCore
import Observation
import SwiftUI

protocol ClaudeLoginLaunching: Sendable {
    func login() async throws
}

enum ClaudeLoginLaunchError: Error {
    case executableUnavailable
    case loginFailed
}

struct ClaudeBrowserLoginLauncher: ClaudeLoginLaunching {
    private let executableCandidates: [URL]

    init(executableCandidates: [URL] = Self.productionExecutableCandidates()) {
        self.executableCandidates = executableCandidates
    }

    func login() async throws {
        guard let command = executableCandidates.lazy.compactMap(validatedCommand).first else {
            throw ClaudeLoginLaunchError.executableUnavailable
        }
        guard command.isStillValid else { throw ClaudeLoginLaunchError.executableUnavailable }
        try await ClaudeLoginProcess().run(command)
    }

    private func validatedCommand(_ candidate: URL) -> ClaudeLoginCommand? {
        let canonicalURL = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard candidate.lastPathComponent == "claude",
              canonicalURL.path.hasPrefix("/"),
              let identity = try? RecoveryExecutableValidator.identity(of: canonicalURL) else {
            return nil
        }
        return ClaudeLoginCommand(executableURL: canonicalURL, executableIdentity: identity)
    }

    private static func productionExecutableCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let nvmRoot = ProcessInfo.processInfo.environment["NVM_DIR"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".nvm")
        let nvmVersions = (try? FileManager.default.contentsOfDirectory(
            at: nvmRoot.appendingPathComponent("versions/node"),
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        let known = [
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".volta/bin/claude"),
            home.appendingPathComponent(".npm-global/bin/claude"),
            home.appendingPathComponent(".asdf/shims/claude"),
            home.appendingPathComponent(".local/share/fnm/aliases/default/bin/claude"),
            home.appendingPathComponent(".local/share/mise/shims/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
            home.appendingPathComponent(".local/share/pnpm/claude"),
        ]
        let environment = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        let nvm = nvmVersions
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin/claude") }
        return known + environment + nvm
    }
}

private struct ClaudeLoginCommand: Sendable {
    let executableURL: URL
    let executableIdentity: RecoveryExecutableIdentity

    var isStillValid: Bool {
        (try? RecoveryExecutableValidator.identity(of: executableURL)) == executableIdentity
    }
}

private final class ClaudeLoginProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<Void, Error>?
    private var isCancelled = false
    private var isFinished = false

    func run(_ command: ClaudeLoginCommand) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = command.executableURL
                process.arguments = ["auth", "login", "--claudeai"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [weak self] process in
                    let result: Result<Void, Error> = process.terminationReason == .exit && process.terminationStatus == 0
                        ? .success(())
                        : .failure(ClaudeLoginLaunchError.loginFailed)
                    self?.finish(result)
                }

                lock.lock()
                guard !isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.process = process
                self.continuation = continuation
                do {
                    guard command.isStillValid else { throw ClaudeLoginLaunchError.executableUnavailable }
                    try process.run()
                    lock.unlock()
                } catch {
                    lock.unlock()
                    finish(.failure(error))
                }
            }
        } onCancel: {
            let process = lock.withLock {
                isCancelled = true
                return self.process
            }
            finish(.failure(CancellationError()))
            process?.terminate()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !isFinished else { return nil }
            isFinished = true
            process = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

@MainActor
@Observable
final class ClaudeLoginController {
    private(set) var isLoggingIn = false
    private(set) var message: String?

    private let launcher: any ClaudeLoginLaunching

    init(launcher: any ClaudeLoginLaunching = ClaudeBrowserLoginLauncher()) {
        self.launcher = launcher
    }

    func refresh(model: ClaudeRateLimitsModel) async {
        guard !isLoggingIn else { return }
        guard model.state == .notConnected else {
            await model.refresh()
            return
        }

        isLoggingIn = true
        message = nil
        defer { isLoggingIn = false }
        do {
            try await launcher.login()
            await model.refresh()
        } catch ClaudeLoginLaunchError.executableUnavailable {
            message = "Claude Code is not installed in a supported location."
        } catch {
            message = "Claude login was canceled or did not complete."
        }
    }
}

struct ClaudeRateLimitsView: View {
    @Bindable var model: ClaudeRateLimitsModel
    @State private var loginController: ClaudeLoginController
    let insights: [QuotaWindowIdentity: QuotaInsightState]
    let anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    let insightsStorageAvailable: Bool
    let explanationCatalog: ClaudeQuotaExplanationCatalog
    var showsAnalysis = true
    let onActionCompleted: () -> Void
    @State private var selectedIntervalID: String?
    @State private var loginTask: Task<Void, Never>?

    @MainActor
    init(
        model: ClaudeRateLimitsModel,
        insights: [QuotaWindowIdentity: QuotaInsightState],
        anomalies: [QuotaWindowIdentity: QuotaAnomalyState],
        insightsStorageAvailable: Bool,
        explanationCatalog: ClaudeQuotaExplanationCatalog,
        showsAnalysis: Bool = true,
        onActionCompleted: @escaping () -> Void
    ) {
        self.init(
            model: model,
            insights: insights,
            anomalies: anomalies,
            insightsStorageAvailable: insightsStorageAvailable,
            explanationCatalog: explanationCatalog,
            showsAnalysis: showsAnalysis,
            loginController: ClaudeLoginController(),
            onActionCompleted: onActionCompleted
        )
    }

    @MainActor
    init(
        model: ClaudeRateLimitsModel,
        insights: [QuotaWindowIdentity: QuotaInsightState],
        anomalies: [QuotaWindowIdentity: QuotaAnomalyState],
        insightsStorageAvailable: Bool,
        explanationCatalog: ClaudeQuotaExplanationCatalog,
        showsAnalysis: Bool = true,
        loginController: ClaudeLoginController,
        onActionCompleted: @escaping () -> Void
    ) {
        self.model = model
        _loginController = State(initialValue: loginController)
        self.insights = insights
        self.anomalies = anomalies
        self.insightsStorageAvailable = insightsStorageAvailable
        self.explanationCatalog = explanationCatalog
        self.showsAnalysis = showsAnalysis
        self.onActionCompleted = onActionCompleted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                if loginController.isLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                    Text("Signing In...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel Sign-In") {
                        loginTask?.cancel()
                    }
                    .accessibilityIdentifier("claude-cancel-login")
                } else {
                    Button(refreshButtonTitle) {
                        loginTask = Task {
                            defer { loginTask = nil }
                            await loginController.refresh(model: model)
                            guard !Task.isCancelled else { return }
                            onActionCompleted()
                        }
                    }
                    .disabled(model.isRefreshing)
                    .accessibilityIdentifier("claude-refresh")
                }
            }

            switch model.state {
            case .loading:
                ProgressView("Loading Claude rate limits")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            case .notConnected:
                VStack(alignment: .leading, spacing: 8) {
                    Text("No active Claude Code login found. Select Refresh to sign in through Claude in your browser.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Link("Open login instructions", destination: ClaudeLoginHelp.url)
                        .accessibilityIdentifier("claude-login-help")
                    if let message = loginController.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("claude-login-error")
                    }
                }
            case let .failed(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            case .authorizationRequired:
                HStack {
                    Text("Authorize LimitBar to read your Claude Code login.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("claude-authorization-required")
                    Spacer()
                    Link("Login instructions", destination: ClaudeLoginHelp.url)
                        .accessibilityIdentifier("claude-login-help")
                    Button(model.isRefreshing ? "Connecting..." : "Connect") {
                        Task {
                            await model.connect()
                            onActionCompleted()
                        }
                    }
                    .disabled(model.isRefreshing)
                    .accessibilityIdentifier("claude-connect")
                }
            case let .loaded(snapshot, subscription):
                let displayed = snapshot.displayLimits(forSubscriptionType: subscription)
                VStack(spacing: 10) {
                    ForEach(Array(displayed.enumerated()), id: \.offset) { _, limit in
                        PercentRateLimitRowView(
                            label: limit.displayLabel,
                            percentUsed: limit.percentUsed,
                            severity: limit.severity,
                            resetsAt: limit.resetsAt,
                            isActive: limit.isActive,
                            insight: insight(for: limit),
                            anomaly: anomaly(for: limit),
                            insightsStorageAvailable: insightsStorageAvailable,
                            showsAnalysis: showsAnalysis
                        )
                    }
                }
                .accessibilityIdentifier("claude-loaded-state")

                if showsAnalysis {
                    VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code quota movement")
                        .font(.caption.weight(.semibold))
                    if explanationCatalog.intervals.count > 1 {
                        Picker("Exact interval", selection: intervalSelection) {
                            ForEach(explanationCatalog.intervals, id: \.id) { interval in
                                Text(intervalLabel(interval)).tag(Optional(interval.id))
                            }
                        }
                        .accessibilityIdentifier("claude-explanation-interval")
                    }
                    if let selectedSelection {
                        Text(intervalTraceText(selectedSelection))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("claude-explanation-trace")
                    }
                    Text(selectedExplanation.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("claude-quota-explanation")
                    Text("Method: \(ClaudeQuotaExplanationEngine.methodVersion); source adapter: \(ClaudeCodeOTLPEvidenceAdapter.adapterVersion). Tokens are never converted to quota percentage.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let metadata = explanationMetadata {
                        Text(metadata)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    }
                    .padding(10)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack {
                    if let subscription {
                        Text("Plan: \(subscription.capitalized)")
                    }
                    Spacer()
                    Text("Fetched \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .task {
            await model.appeared()
            onActionCompleted()
        }
        .onChange(of: explanationCatalog.defaultSelectionID, initial: true) { _, defaultID in
            if selectedIntervalID.flatMap({ explanationCatalog.selection(id: $0) }) == nil {
                selectedIntervalID = defaultID
            }
        }
        .onDisappear {
            loginTask?.cancel()
        }
    }

    private var refreshButtonTitle: String {
        return model.isRefreshing ? "Refreshing..." : "Refresh"
    }

    private func insight(for limit: ClaudeRateLimit) -> QuotaInsightState? {
        guard let identity = QuotaWindowIdentity.claudeCode(limit) else { return nil }
        return insights[identity]
    }

    private func anomaly(for limit: ClaudeRateLimit) -> QuotaAnomalyState? {
        guard let identity = QuotaWindowIdentity.claudeCode(limit) else { return nil }
        return anomalies[identity]
    }

    private var explanationMetadata: String? {
        let value: ClaudeQuotaExplanation
        switch selectedExplanation {
        case let .movement(explanation), let .flat(explanation): value = explanation
        case .unavailable:
            let limitations = (selectedSelection?.limitations ?? explanationCatalog.limitations).map(\.rawValue).joined(separator: ", ")
            return "Production source unavailable; limitations: \(limitations); manual signed acceptance unavailable. No generic Anthropic API fallback."
        }
        let source = value.sourceVersion.map { "source \($0)" } ?? "source not configured"
        let limitations = selectedSelection?.limitations.map(\.rawValue).joined(separator: ", ") ?? "none"
        return "Reported inputs: \(value.observationIdentityCount); calculated method: \(value.methodVersion); measured evidence trace: \(value.evidenceIdentityCount); evidence age \(wholeSecondDuration(value.evidenceAge)); \(source); limitations: \(limitations); manual acceptance unavailable; source last verified \(ClaudeCodeOTLPEvidenceAdapter.lastVerified)."
    }

    private var selectedSelection: ClaudeQuotaExplanationSelection? {
        explanationCatalog.selection(id: selectedIntervalID) ?? explanationCatalog.defaultSelection
    }

    private var selectedExplanation: ClaudeQuotaExplanationState {
        selectedSelection?.state ?? .unavailable(.insufficientObservations)
    }

    private var intervalSelection: Binding<String?> {
        Binding(get: { selectedIntervalID ?? explanationCatalog.defaultSelectionID }, set: { selectedIntervalID = $0 })
    }

    private func intervalLabel(_ interval: ClaudeQuotaExplanationInterval) -> String {
        let status = interval.lifecycle == .active ? "Active" : "Completed"
        return "\(status) · \(interval.intervalStart.formatted(date: .abbreviated, time: .shortened)) to \(interval.intervalEnd.formatted(date: .abbreviated, time: .shortened))"
    }

    private func intervalTraceText(_ selection: ClaudeQuotaExplanationSelection) -> String {
        let evidenceCount: Int
        switch selection.state {
        case let .movement(value), let .flat(value): evidenceCount = value.evidenceIdentityCount
        case .unavailable: evidenceCount = 0
        }
        return "Exact selected interval: \(selection.interval.intervalStart.formatted(date: .abbreviated, time: .standard)) to \(selection.interval.intervalEnd.formatted(date: .abbreviated, time: .standard)); interval trace: \(selection.interval.id); Reported observation traces: 2; Measured evidence traces: \(evidenceCount); Calculated method: \(ClaudeQuotaExplanationEngine.methodVersion); provenance: Reported percentages, Calculated movement, Measured local breakdown when available."
    }
}

enum ClaudeLoginHelp {
    static let url = URL(string: "https://code.claude.com/docs/en/iam#log-in-to-claude-code")!
}

#Preview {
    ClaudeRateLimitsView(
        model: ClaudeRateLimitsModel(
            credentials: ClaudeCredentialBroker.shared,
            client: ClaudeOAuthUsageClient(httpClient: URLSessionHTTPClient())
        ),
        insights: [:],
        anomalies: [:],
        insightsStorageAvailable: true,
        explanationCatalog: .empty,
        onActionCompleted: {}
    )
        .padding(20)
        .frame(width: 440, height: 400)
}
