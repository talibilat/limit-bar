import AppKit
import LimitBarCore
import SwiftUI

enum ActivityReceiptPresentation {
    static func summary(_ state: ActivityDebuggerState) -> String {
        switch state {
        case let .available(findings):
            findings.first?.statement ?? "Activity Receipt evidence is available."
        case let .unavailable(reason):
            "Activity Receipt debugger unavailable: \(unavailableText(reason))."
        }
    }

    static func detail(_ state: ActivityDebuggerState) -> String {
        let boundary = "Activity Receipt evidence describes measured local lifecycle associations. It is separate from provider quota movement and provider-reported cost, and does not establish billing error or authoritative quota allocation."
        switch state {
        case let .available(findings):
            return ([boundary] + findings.dropFirst().map(\.statement)).joined(separator: " ")
        case let .unavailable(reason):
            return "\(boundary) Unavailable reason: \(reason.rawValue)."
        }
    }

    private static func unavailableText(_ reason: ActivityReceiptUnavailableReason) -> String {
        switch reason {
        case .sourceDisabled: "the source is disabled"
        case .malformed: "the selected data is malformed"
        case .unsupportedSchema: "the source schema is unsupported"
        case .unsupportedClientVersion: "the client version is unsupported"
        case .partialRecord: "the source is partial or lacks required fields"
        case .insufficientLifecycleSemantics: "the source does not provide explicit lifecycle semantics"
        case .duplicateRecord: "the source contains duplicate records"
        case .conflictingRecord: "an operation identity was reused with different facts"
        case .outOfOrder: "the source contains unsafe timestamp ordering"
        case .futureTimestamp: "the source contains a timestamp beyond the allowed clock skew"
        case .storageUnavailable: "local receipt storage could not be opened"
        case .noReceipts: "no compatible receipts have been explicitly imported"
        case .incompatibleRuns: "the selected runs are not exactly compatible"
        case .missingImportMetadata: "required trusted import configuration is missing"
        case .noMeasuredInput: "the receipts contain no measured input tokens"
        case .tokenOverflow: "the measured token totals exceed the safe analysis bound"
        }
    }
}

struct ActivityReceiptSettingsSection: View {
    let state: LimitBarState
    private let preferencesStore = ActivitySourcePreferencesStore()
    @State private var preferences: ActivitySourcePreferences
    @State private var claudeMode: String
    @State private var claudeConcurrency: String
    @State private var codexClientVersion: String
    @State private var codexMode: String
    @State private var codexConcurrency: String
    @State private var message: String?
    @State private var confirmsDeletion = false

    init(state: LimitBarState) {
        self.state = state
        let preferences = ActivitySourcePreferencesStore().preferences
        _preferences = State(initialValue: preferences)
        _claudeMode = State(initialValue: preferences.claudeImportMetadata?.mode ?? "")
        _claudeConcurrency = State(initialValue: preferences.claudeImportMetadata.map { String($0.concurrency) } ?? "")
        _codexClientVersion = State(initialValue: preferences.codexImportMetadata?.clientVersion ?? "")
        _codexMode = State(initialValue: preferences.codexImportMetadata?.mode ?? "")
        _codexConcurrency = State(initialValue: preferences.codexImportMetadata.map { String($0.concurrency) } ?? "")
    }

    var body: some View {
        Section("Activity Receipts") {
            Text("Collection is disabled by default. LimitBar reads only a file you explicitly select and retains positive-allow-listed lifecycle dimensions and token counters, never raw telemetry, prompts, responses, commands, paths, arguments, account identifiers, or raw errors.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Enable Claude Code lifecycle imports", isOn: $preferences.claudeCodeEnabled)
                .onChange(of: preferences.claudeCodeEnabled) { _, _ in savePreferences() }
            Text("Optional trusted Claude Code import configuration")
                .font(.caption.weight(.medium))
            HStack {
                TextField("Mode", text: $claudeMode)
                TextField("Concurrency", text: $claudeConcurrency)
                    .frame(width: 110)
            }
            .onChange(of: claudeMode) { _, _ in savePreferences() }
            .onChange(of: claudeConcurrency) { _, _ in savePreferences() }
            Toggle("Enable Codex exec JSONL imports", isOn: $preferences.codexExecEnabled)
                .onChange(of: preferences.codexExecEnabled) { _, _ in savePreferences() }
            Text("Required trusted Codex import configuration")
                .font(.caption.weight(.medium))
            TextField("Codex client version", text: $codexClientVersion)
                .onChange(of: codexClientVersion) { _, _ in savePreferences() }
            HStack {
                TextField("Mode", text: $codexMode)
                TextField("Concurrency", text: $codexConcurrency)
                    .frame(width: 110)
            }
            .onChange(of: codexMode) { _, _ in savePreferences() }
            .onChange(of: codexConcurrency) { _, _ in savePreferences() }
            HStack {
                Button("Import Claude Code File...") { importFile(source: .claudeCode) }
                    .disabled(!preferences.claudeCodeEnabled)
                Button("Import Codex Exec File...") { importFile(source: .codexExec) }
                    .disabled(!preferences.codexExecEnabled || preferences.codexImportMetadata == nil)
            }
            Text("Mode and concurrency are trusted import configuration, not fields trusted from provider payloads. Codex also requires the exact client version. Unknown dimensions never become zero-valued findings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Delete Activity Receipts", role: .destructive) { confirmsDeletion = true }
                .accessibilityIdentifier("delete-activity-receipts")
            if let message {
                Text(message).font(.caption).foregroundStyle(message.hasPrefix("Could not") ? Color.orange : Color.secondary)
            }
        }
        .confirmationDialog("Delete all Activity Receipts?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Activity Receipts", role: .destructive) {
                message = state.deleteActivityReceipts()
                    ? "Activity Receipts deleted. Usage, quota evidence, provider-reported cost, settings, and source files were not changed."
                    : "Could not delete Activity Receipts. Existing receipts were left available."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This independently removes normalized Activity Receipts only. Source preferences and source files are unchanged.")
        }
    }

    private func savePreferences() {
        let trimmedClaudeMode = claudeMode.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeCount = Int(claudeConcurrency)
        preferences.claudeImportMetadata = !trimmedClaudeMode.isEmpty && claudeCount.map({ (1...64).contains($0) }) == true
            ? ActivityImportMetadata(mode: trimmedClaudeMode, concurrency: claudeCount!)
            : nil
        let trimmedCodexVersion = codexClientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCodexMode = codexMode.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexCount = Int(codexConcurrency)
        preferences.codexImportMetadata = !trimmedCodexVersion.isEmpty && !trimmedCodexMode.isEmpty && codexCount.map({ (1...64).contains($0) }) == true
            ? ActivityImportMetadata(clientVersion: trimmedCodexVersion, mode: trimmedCodexMode, concurrency: codexCount!)
            : nil
        preferencesStore.preferences = preferences
    }

    private func importFile(source: ActivityReceiptSource) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = state.importActivityReceipts(source: source, url: url)
    }
}
