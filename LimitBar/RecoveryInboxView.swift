import AppKit
import Foundation
import LimitBarCore
import Observation
import SwiftUI
import UserNotifications

@MainActor
protocol RecoveryNotificationSending {
    func isAuthorized() async -> Bool
    func add(identifier: String, title: String, body: String) async throws
}

@MainActor
private struct RecoveryUserNotifications: RecoveryNotificationSending {
    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func add(identifier: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        ))
    }
}

@MainActor
protocol RecoveryCommandLaunching {
    func launch(_ command: RecoveryResumeCommand) throws
}

@MainActor
private struct RecoveryDirectCommandLauncher: RecoveryCommandLaunching {
    func launch(_ command: RecoveryResumeCommand) throws {
        guard command.isStillValid() else { throw RecoveryCheckpointError.invalidValue }
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

struct RecoveryPendingResume: Equatable {
    let item: RecoveryInboxItem
    let command: RecoveryResumeCommand
    let confirmedAt: Date
}

@MainActor
@Observable
final class RecoveryInboxModel {
    static let sessionConfirmationLifetime: TimeInterval = 60

    private(set) var items: [RecoveryInboxItem] = []
    private(set) var message: String?
    var pendingResume: RecoveryPendingResume?

    private let store: RecoveryInboxStore?
    private let capacityURL: URL?
    private let fingerprintKeyURL: URL?
    private let usesFixture: Bool
    private let notificationSender: any RecoveryNotificationSending
    private let launcher: any RecoveryCommandLaunching
    private let executableCandidates: (RecoveryProduct) -> [URL]
    private let now: () -> Date
    private var workspaceStates: [String: RecoveryWorkspaceState] = [:]
    private var sessionConfirmations: [String: Date] = [:]
    private var expiredSessions: Set<String> = []
    private var commands: [String: RecoveryResumeCommand] = [:]
    private var notificationInProgress = false

    convenience init() {
        let locations = try? LimitBarFileLocations.production()
        self.init(
            store: try? .production(),
            capacityURL: locations?.capacityPublication,
            fingerprintKeyURL: locations?.recoveryFingerprintKey,
            notificationSender: RecoveryUserNotifications(),
            launcher: RecoveryDirectCommandLauncher(),
            executableCandidates: Self.productionExecutableCandidates,
            now: Date.init
        )
    }

    init(
        store: RecoveryInboxStore?,
        capacityURL: URL?,
        fingerprintKeyURL: URL?,
        notificationSender: any RecoveryNotificationSending,
        launcher: any RecoveryCommandLaunching,
        executableCandidates: @escaping (RecoveryProduct) -> [URL],
        now: @escaping () -> Date
    ) {
        self.store = store
        self.capacityURL = capacityURL
        self.fingerprintKeyURL = fingerprintKeyURL
        self.notificationSender = notificationSender
        self.launcher = launcher
        self.executableCandidates = executableCandidates
        self.now = now
        usesFixture = false
        refresh()
    }

    init(fixtureItems: [RecoveryInboxItem]) {
        store = nil
        capacityURL = nil
        fingerprintKeyURL = nil
        notificationSender = RecoveryUserNotifications()
        launcher = RecoveryDirectCommandLauncher()
        executableCandidates = { _ in [] }
        now = Date.init
        usesFixture = true
        items = fixtureItems
    }

    func refresh(now explicitNow: Date? = nil) {
        guard !usesFixture else { return }
        let now = explicitNow ?? self.now()
        guard let store else {
            message = "Recovery Inbox storage is unavailable."
            items = []
            return
        }
        do {
            let publication: CapacityPublication? = capacityURL.flatMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? CapacityPublicationCodec.decode(data)
            }
            var loaded = try store.all(now: now)
            for index in loaded.indices {
                let item = loaded[index]
                let evidence = publication.map {
                    RecoveryCapacityEvidence.from(
                        $0,
                        product: item.checkpoint.product,
                        windowKind: item.checkpoint.windowKind,
                        now: now
                    )
                } ?? RecoveryCapacityEvidence(
                    availability: .missing,
                    product: item.checkpoint.product,
                    windowKind: item.checkpoint.windowKind
                )
                let command = resolveCommand(for: item.checkpoint)
                if let command { commands[item.id] = command } else { commands.removeValue(forKey: item.id) }
                let context = RecoveryReviewContext(
                    workspace: workspaceStates[item.id] ?? .unknown,
                    session: sessionState(for: item.id, now: now),
                    clientSupported: RecoveryClientSupport.isSupported(
                        product: item.checkpoint.product,
                        version: item.checkpoint.clientVersion
                    ),
                    resumeCommandAvailable: command != nil
                )
                let state = RecoveryStateMachine.evaluate(
                    checkpoint: item.checkpoint,
                    current: item.state,
                    capacity: evidence,
                    review: context,
                    now: now
                )
                if state != item.state {
                    _ = try store.transition(id: item.id, to: state, now: now)
                    loaded[index].state = state
                    loaded[index].updatedAt = now
                }
            }
            items = loaded
            message = nil
            Task { await deliverReadyNotifications() }
        } catch {
            message = "Recovery Inbox could not be read safely. Existing data was left unchanged."
            items = []
        }
    }

    func reviewWorkspace(for item: RecoveryInboxItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review Workspace"
        guard panel.runModal() == .OK, let url = panel.url, let fingerprintKeyURL else { return }
        do {
            let key = try RecoveryWorkspaceFingerprint.loadOrCreateKey(at: fingerprintKeyURL)
            let current = try RecoveryWorkspaceFingerprint.make(workspace: url, key: key)
            workspaceStates[item.id] = current == item.checkpoint.workspaceFingerprint ? .unchanged : .changed
            refresh()
        } catch {
            workspaceStates[item.id] = .deleted
            refresh()
        }
    }

    func markWorkspaceDeleted(for item: RecoveryInboxItem) {
        workspaceStates[item.id] = .deleted
        refresh()
    }

    func recordWorkspaceReview(itemID: String, state: RecoveryWorkspaceState) {
        workspaceStates[itemID] = state
        refresh()
    }

    func markSessionExpired(for item: RecoveryInboxItem) {
        expiredSessions.insert(item.id)
        sessionConfirmations.removeValue(forKey: item.id)
        update(item, state: .unavailable(.sessionExpired))
    }

    func dismiss(_ item: RecoveryInboxItem) { update(item, state: .dismissed) }

    func delete(_ item: RecoveryInboxItem) {
        do {
            _ = try store?.delete(id: item.id)
            refresh()
        } catch {
            message = "The Recovery Inbox item could not be deleted."
        }
    }

    func confirmResume(_ item: RecoveryInboxItem) {
        let confirmationTime = now()
        expiredSessions.remove(item.id)
        sessionConfirmations[item.id] = confirmationTime
        refresh(now: confirmationTime)
        guard let current = items.first(where: { $0.id == item.id }),
              current.state == .readyForReview || current.state == .changedWorkspace,
              let command = commands[item.id] else {
            message = "The session or resume command could not be revalidated."
            return
        }
        pendingResume = RecoveryPendingResume(item: current, command: command, confirmedAt: confirmationTime)
    }

    func launchConfirmedResume() {
        guard let pending = pendingResume else { return }
        pendingResume = nil
        let launchTime = now()
        guard launchTime.timeIntervalSince(pending.confirmedAt) <= Self.sessionConfirmationLifetime else {
            sessionConfirmations.removeValue(forKey: pending.item.id)
            refresh(now: launchTime)
            message = "Session confirmation expired. Revalidate before resuming."
            return
        }
        refresh(now: launchTime)
        guard let item = items.first(where: { $0.id == pending.item.id }) else {
            message = "The Recovery Inbox item is no longer available."
            return
        }
        guard item.state == .readyForReview || item.state == .changedWorkspace else {
            message = "Fresh review is required before resuming."
            return
        }
        guard commands[item.id] == pending.command, pending.command.isStillValid() else {
            message = "The validated provider executable changed. Review it again before resuming."
            return
        }
        do {
            try launcher.launch(pending.command)
            update(item, state: .resumed)
        } catch {
            message = "The documented provider resume command could not be opened. No retry was scheduled."
        }
    }

    func cancelResume() {
        pendingResume = nil
    }

    func displayedCommand(for item: RecoveryInboxItem) -> String {
        commands[item.id]?.display ?? "Validated executable unavailable"
    }

    private func update(_ item: RecoveryInboxItem, state: RecoveryState) {
        do {
            _ = try store?.transition(id: item.id, to: state)
            refresh()
        } catch {
            message = "The Recovery Inbox item could not be updated."
        }
    }

    private func resolveCommand(for checkpoint: RecoveryCheckpoint) -> RecoveryResumeCommand? {
        executableCandidates(checkpoint.product).lazy.compactMap {
            try? RecoveryResumeCommand.documented(for: checkpoint, executableURL: $0)
        }.first
    }

    private func sessionState(for itemID: String, now: Date) -> RecoverySessionState {
        if expiredSessions.contains(itemID) { return .expired }
        guard let confirmedAt = sessionConfirmations[itemID],
              now.timeIntervalSince(confirmedAt) <= Self.sessionConfirmationLifetime else {
            return .revalidationRequired
        }
        return .confirmed
    }

    func deliverReadyNotifications() async {
        guard !notificationInProgress else { return }
        notificationInProgress = true
        defer { notificationInProgress = false }
        guard await notificationSender.isAuthorized() else { return }
        let readyItems = items.filter {
            ($0.state == .readyForReview || $0.state == .changedWorkspace) && $0.notificationDeliveredAt == nil
        }
        for item in readyItems {
            do {
                try await notificationSender.add(
                    identifier: RecoveryNotificationIdentity.identifier(itemID: item.id),
                    title: "Recovery item ready",
                    body: "Fresh capacity is available. Review local state before resuming."
                )
                let deliveredAt = now()
                _ = try store?.markNotificationDelivered(id: item.id, at: deliveredAt)
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].notificationDeliveredAt = deliveredAt
                }
            } catch {
                message = "A Recovery Inbox notification could not be delivered."
            }
        }
    }

    private static func productionExecutableCandidates(_ product: RecoveryProduct) -> [URL] {
        let name = product == .claudeCode ? "claude" : "codex"
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(name)"),
        ]
    }
}

struct RecoveryInboxSection: View {
    @State private var model: RecoveryInboxModel

    @MainActor
    init(model: RecoveryInboxModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Section("Recovery Inbox") {
            Text("Content-free local checkpoints wait for fresh measured capacity. LimitBar never stores task content or resumes work automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.items.isEmpty {
                Text("No recovery checkpoints.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recovery-inbox-empty")
            }
            ForEach(model.items) { item in
                RecoveryInboxRow(item: item, model: model)
            }
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            model.refresh()
        }
        .confirmationDialog(
            "Launch this provider resume command now?",
            isPresented: Binding(
                get: { model.pendingResume != nil },
                set: { if !$0 { model.cancelResume() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Confirm Session and Launch") { model.launchConfirmedResume() }
            Button("Cancel", role: .cancel) { model.cancelResume() }
        } message: {
            if let pending = model.pendingResume {
                Text("Confirm that this provider-owned session still exists. LimitBar will then launch exactly this validated executable: \(pending.command.display). It will not send a prompt, continue instruction, queue item, or permission response.")
            }
        }
    }
}

private struct RecoveryInboxRow: View {
    let item: RecoveryInboxItem
    let model: RecoveryInboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.checkpoint.product == .claudeCode ? "Claude Code" : "Codex")
                    .font(.headline)
                Spacer()
                Text(stateText)
                    .foregroundStyle(stateColor)
            }
            Text("Reset boundary: \(item.checkpoint.resetBoundary.formatted(date: .abbreviated, time: .standard))")
                .font(.caption)
            Text("Resume command: \(model.displayedCommand(for: item))")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            HStack {
                Button("Review Workspace") { model.reviewWorkspace(for: item) }
                Button("Workspace Deleted") { model.markWorkspaceDeleted(for: item) }
                Button("Session Expired") { model.markSessionExpired(for: item) }
            }
            HStack {
                Button("Validate & Resume...") { model.confirmResume(item) }
                    .disabled(!canValidateAndResume)
                Button("Dismiss") { model.dismiss(item) }
                Button("Delete", role: .destructive) { model.delete(item) }
            }
        }
        .accessibilityIdentifier("recovery-inbox-item")
    }

    private var stateText: String {
        switch item.state {
        case .waiting: "Waiting for fresh capacity"
        case .readyForReview: "Ready - workspace unchanged"
        case .changedWorkspace: "Ready - workspace changed"
        case let .unavailable(reason): unavailableText(reason)
        case .expired: "Checkpoint expired"
        case .dismissed: "Dismissed"
        case .resumed: "Resume launched"
        }
    }

    private var canValidateAndResume: Bool {
        if item.state == .readyForReview || item.state == .changedWorkspace { return true }
        return item.state == .unavailable(.sessionRevalidationRequired)
    }

    private var stateColor: Color {
        switch item.state {
        case .readyForReview: .green
        case .changedWorkspace, .unavailable: .orange
        case .waiting, .expired, .dismissed, .resumed: .secondary
        }
    }

    private func unavailableText(_ reason: RecoveryUnavailableReason) -> String {
        switch reason {
        case .staleCapacityEvidence: "Capacity evidence is stale"
        case .missingCapacityEvidence: "Capacity evidence unavailable"
        case .changedResetBoundary: "Reset boundary changed"
        case .providerIncident: "Provider incident active"
        case .workspaceUnavailable: "Workspace unavailable or not reviewed"
        case .sessionExpired: "Session expired"
        case .sessionRevalidationRequired: "Confirm the provider session still exists"
        case .unsupportedClient: "Unsupported client version"
        case .resumeCommandUnavailable: "Resume command unavailable"
        }
    }
}
