import Foundation

public enum ActivityReceiptSource: String, Codable, CaseIterable, Sendable { case claudeCode, codexExec }
public enum ActivityLifecycle: String, Codable, CaseIterable, Sendable { case modelAttempt, compaction, recoveryReplay, cache, unknown }
public enum ActivityAttempt: String, Codable, CaseIterable, Sendable { case normal, retry, unknown }
public enum ActivityRole: String, Codable, CaseIterable, Sendable { case primary, subagent, unknown }
public enum ActivityOutcome: String, Codable, CaseIterable, Sendable { case succeeded, failed, unknown }

public struct ActivityTokenCounts: Codable, Equatable, Sendable {
    public static let maximumValue = Int64(1_000_000_000_000_000)
    public let input: Int64
    public let cachedInput: Int64
    public let cacheCreationInput: Int64
    public let output: Int64
    public let reasoningOutput: Int64

    public init(input: Int64, cachedInput: Int64, cacheCreationInput: Int64, output: Int64, reasoningOutput: Int64) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheCreationInput = cacheCreationInput
        self.output = output
        self.reasoningOutput = reasoningOutput
    }

    var checkedTotal: Int64? {
        var total: Int64 = 0
        for value in [input, cachedInput, cacheCreationInput, output, reasoningOutput] {
            guard (0...Self.maximumValue).contains(value) else { return nil }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow, result.partialValue <= Self.maximumValue else { return nil }
            total = result.partialValue
        }
        return total
    }

    var isBounded: Bool { checkedTotal != nil }

    static let zero = Self(input: 0, cachedInput: 0, cacheCreationInput: 0, output: 0, reasoningOutput: 0)
}

public struct ActivityReceiptCompatibility: Codable, Equatable, Hashable, Sendable {
    public let source: ActivityReceiptSource
    public let adapterSchema: String
    public let clientVersion: String
    public let model: String
    public let mode: String
    public let concurrency: Int
    public let tokenSemantics: String

    public init(source: ActivityReceiptSource, adapterSchema: String, clientVersion: String, model: String, mode: String, concurrency: Int, tokenSemantics: String) {
        self.source = source
        self.adapterSchema = adapterSchema
        self.clientVersion = clientVersion
        self.model = model
        self.mode = mode
        self.concurrency = concurrency
        self.tokenSemantics = tokenSemantics
    }
}

public enum ActivityEvidenceLimitation: String, Codable, CaseIterable, Sendable {
    case localLifecycleAssociation, notProviderBilling, notQuotaAllocation, unknownActivityPreserved
    case sourceTimestampMayBeImportTime, clientVersionPinnedByAdapter
    case configurationFromExplicitImportMetadata
}

public struct ActivityReceipt: Codable, Equatable, Sendable {
    public static let contractVersion = 1
    public let contractVersion: Int
    public let runIdentity: UUID
    public let operationIdentity: String
    public let occurredAt: Date
    public let compatibility: ActivityReceiptCompatibility
    public let lifecycle: ActivityLifecycle
    public let attempt: ActivityAttempt
    public let role: ActivityRole
    public let outcome: ActivityOutcome
    public let tokens: ActivityTokenCounts
    public let evidenceLimitations: [ActivityEvidenceLimitation]

    public init(runIdentity: UUID, operationIdentity: String, occurredAt: Date, compatibility: ActivityReceiptCompatibility, lifecycle: ActivityLifecycle, attempt: ActivityAttempt, role: ActivityRole, outcome: ActivityOutcome, tokens: ActivityTokenCounts, evidenceLimitations: [ActivityEvidenceLimitation]) {
        contractVersion = Self.contractVersion
        self.runIdentity = runIdentity
        self.operationIdentity = operationIdentity
        self.occurredAt = occurredAt
        self.compatibility = compatibility
        self.lifecycle = lifecycle
        self.attempt = attempt
        self.role = role
        self.outcome = outcome
        self.tokens = tokens
        self.evidenceLimitations = evidenceLimitations
    }
}

public enum ActivityReceiptUnavailableReason: String, Codable, Equatable, Sendable {
    case sourceDisabled, malformed, unsupportedSchema, unsupportedClientVersion, partialRecord
    case insufficientLifecycleSemantics, duplicateRecord, conflictingRecord, outOfOrder, futureTimestamp
    case storageUnavailable, noReceipts, incompatibleRuns, missingImportMetadata, noMeasuredInput, tokenOverflow
}

public enum ActivityReceiptImportResult: Equatable, Sendable {
    case imported([ActivityReceipt])
    case unavailable(ActivityReceiptUnavailableReason)
}

public struct ActivityImportMetadata: Codable, Equatable, Sendable {
    public let clientVersion: String?
    public let mode: String
    public let concurrency: Int

    public init(clientVersion: String? = nil, mode: String, concurrency: Int) {
        self.clientVersion = clientVersion
        self.mode = mode
        self.concurrency = concurrency
    }
}

public struct ActivitySourcePreferences: Codable, Equatable, Sendable {
    public var claudeCodeEnabled: Bool
    public var codexExecEnabled: Bool
    public var claudeImportMetadata: ActivityImportMetadata?
    public var codexImportMetadata: ActivityImportMetadata?
    public init(claudeCodeEnabled: Bool = false, codexExecEnabled: Bool = false, claudeImportMetadata: ActivityImportMetadata? = nil, codexImportMetadata: ActivityImportMetadata? = nil) {
        self.claudeCodeEnabled = claudeCodeEnabled
        self.codexExecEnabled = codexExecEnabled
        self.claudeImportMetadata = claudeImportMetadata
        self.codexImportMetadata = codexImportMetadata
    }
    public func isEnabled(_ source: ActivityReceiptSource) -> Bool { source == .claudeCode ? claudeCodeEnabled : codexExecEnabled }
}

public final class ActivitySourcePreferencesStore: @unchecked Sendable {
    public static let storageKey = "activityReceiptSourcePreferencesV1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var preferences: ActivitySourcePreferences {
        get { defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(ActivitySourcePreferences.self, from: $0) } ?? .init() }
        set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.storageKey) } }
    }
}

public enum ActivityReceiptParser {
    public static let claudeSchema = "claude-code-otlp-logs-v1"
    public static let claudeClientVersion = "2.1.207"
    public static let claudeTokenSemantics = "claude-code-api-request-tokens-v1"
    public static let codexSchema = "codex-exec-events-v1"
    public static let codexClientVersion = "0.144.4"
    public static let codexTokenSemantics = "codex-exec-turn-usage-v1"
    public static let maximumFutureSkew: TimeInterval = 300
    private static let limitations = ActivityEvidenceLimitation.allCases

    public static func parseClaude(data: Data, preferences: ActivitySourcePreferences, now: Date = Date()) -> ActivityReceiptImportResult {
        guard preferences.claudeCodeEnabled else { return .unavailable(.sourceDisabled) }
        guard validNow(now), data.count <= 8 * 1_024 * 1_024,
              let request = try? JSONDecoder().decode(OTLPExportLogsRequest.self, from: data) else { return .unavailable(.malformed) }
        let records = request.resourceLogs.flatMap(\.scopeLogs).flatMap(\.logRecords)
        guard !records.isEmpty else { return .unavailable(.unsupportedSchema) }
        let metadata = preferences.claudeImportMetadata
        let mode = metadata?.mode ?? "unknown"
        let concurrency = metadata?.concurrency ?? 0
        guard validIdentifier(mode), (0...64).contains(concurrency), metadata == nil || concurrency > 0 else { return .unavailable(.missingImportMetadata) }

        struct Candidate {
            let values: AttributeMap
            let event: String
            let timestamp: Date
            let sequence: Int64
            let run: UUID
            let clientVersion: String
        }
        var candidates: [Candidate] = []
        var modelsByRun: [UUID: Set<String>] = [:]
        for record in records {
            guard let values = attributes(record.attributes) else { return .unavailable(.malformed) }
            guard let event = values.string("event.name") else { return .unavailable(.partialRecord) }
            guard supportedClaudeEvents.contains(event) else { return .unavailable(.insufficientLifecycleSemantics) }
            guard let timestampText = values.string("event.timestamp"), let timestamp = CollectorSchemaV1.parseTimestamp(timestampText),
                  let sequence = values.int64("event.sequence"), sequence > 0,
                  let runText = values.string("session.id"), let run = UUID(uuidString: runText),
                  let clientVersion = values.string("app.version") else { return .unavailable(.partialRecord) }
            guard timestamp <= now.addingTimeInterval(maximumFutureSkew) else { return .unavailable(.futureTimestamp) }
            guard clientVersion == claudeClientVersion else { return .unavailable(.unsupportedClientVersion) }
            if let model = values.string("model") {
                guard validIdentifier(model) else { return .unavailable(.partialRecord) }
                modelsByRun[run, default: []].insert(model)
            }
            candidates.append(Candidate(values: values, event: event, timestamp: timestamp, sequence: sequence, run: run, clientVersion: clientVersion))
        }

        var receipts: [ActivityReceipt] = []
        for candidate in candidates {
            let values = candidate.values
            let model: String
            if let reportedModel = values.string("model") {
                model = reportedModel
            } else if modelsByRun[candidate.run]?.count == 1, let inferredModel = modelsByRun[candidate.run]?.first {
                model = inferredModel
            } else {
                model = "unknown"
            }
            let compatibility = ActivityReceiptCompatibility(source: .claudeCode, adapterSchema: claudeSchema, clientVersion: candidate.clientVersion, model: model, mode: mode, concurrency: concurrency, tokenSemantics: claudeTokenSemantics)
            let dimensions: (ActivityLifecycle, ActivityAttempt, ActivityRole, ActivityOutcome, ActivityTokenCounts)
            let role = claudeRole(values)
            let lifecycle = values.string("query_source") == "compact" ? ActivityLifecycle.compaction : .modelAttempt
            switch candidate.event {
            case "api_request":
                guard values.string("query_source") != nil, let tokens = claudeTokens(values) else { return .unavailable(.partialRecord) }
                dimensions = (lifecycle, .unknown, role, .unknown, tokens)
            case "api_error":
                guard values.string("query_source") != nil, let attemptNumber = values.int("attempt"), attemptNumber > 0 else { return .unavailable(.partialRecord) }
                dimensions = (lifecycle, attemptNumber == 1 ? .normal : .retry, role, .failed, .zero)
            case "compaction":
                let outcome = explicitOutcome(values)
                dimensions = (.compaction, .unknown, .unknown, outcome, .zero)
            default:
                dimensions = (.unknown, .unknown, .unknown, .unknown, .zero)
            }
            receipts.append(ActivityReceipt(runIdentity: candidate.run, operationIdentity: "event-\(candidate.sequence)", occurredAt: candidate.timestamp, compatibility: compatibility, lifecycle: dimensions.0, attempt: dimensions.1, role: dimensions.2, outcome: dimensions.3, tokens: dimensions.4, evidenceLimitations: limitations))
        }
        return normalize(receipts)
    }

    public static func parseCodexJSONL(data: Data, preferences: ActivitySourcePreferences, now: Date = Date()) -> ActivityReceiptImportResult {
        guard preferences.codexExecEnabled else { return .unavailable(.sourceDisabled) }
        guard let metadata = preferences.codexImportMetadata, let clientVersion = metadata.clientVersion,
              clientVersion == codexClientVersion, metadata.mode == "exec", (1...64).contains(metadata.concurrency) else { return .unavailable(.missingImportMetadata) }
        guard validNow(now), data.count <= 8 * 1_024 * 1_024, data.last == 0x0A else { return .unavailable(.partialRecord) }
        let lines = data.split(separator: 0x0A)
        guard let first = lines.first, let start = try? decoder.decode(CodexThreadStarted.self, from: Data(first)), start.type == "thread.started",
              let run = UUID(uuidString: start.threadID) else { return .unavailable(.unsupportedSchema) }
        let compatibility = ActivityReceiptCompatibility(source: .codexExec, adapterSchema: codexSchema, clientVersion: clientVersion, model: "unknown", mode: metadata.mode, concurrency: metadata.concurrency, tokenSemantics: codexTokenSemantics)
        var receipts: [ActivityReceipt] = []
        var terminalTurnCount = 0
        for (offset, line) in lines.dropFirst().enumerated() {
            guard let discriminator = try? decoder.decode(CodexDiscriminator.self, from: Data(line)) else { return .unavailable(.malformed) }
            switch discriminator.type {
            case "turn.started": continue
            case "turn.completed", "turn.failed":
                guard let event = try? decoder.decode(CodexTurnEvent.self, from: Data(line)) else { return .unavailable(.partialRecord) }
                terminalTurnCount += 1
                guard terminalTurnCount == 1 else { return .unavailable(.unsupportedSchema) }
                let tokens: ActivityTokenCounts
                if discriminator.type == "turn.completed" {
                    guard let usage = event.usage, usage.isValid else { return .unavailable(.partialRecord) }
                    tokens = usage.tokens
                } else {
                    guard event.usage == nil else { return .unavailable(.unsupportedSchema) }
                    tokens = .zero
                }
                receipts.append(ActivityReceipt(runIdentity: run, operationIdentity: "turn-terminal-1", occurredAt: now.addingTimeInterval(Double(offset) / 1_000_000), compatibility: compatibility, lifecycle: .unknown, attempt: .unknown, role: .unknown, outcome: discriminator.type == "turn.completed" ? .succeeded : .failed, tokens: tokens, evidenceLimitations: limitations))
            case "item.completed":
                guard let event = try? decoder.decode(CodexItemEvent.self, from: Data(line)), validOpaqueIdentity(event.item.id) else { return .unavailable(.partialRecord) }
                receipts.append(ActivityReceipt(runIdentity: run, operationIdentity: "item-\(event.item.id)", occurredAt: now.addingTimeInterval(Double(offset) / 1_000_000), compatibility: compatibility, lifecycle: .unknown, attempt: .unknown, role: .unknown, outcome: .unknown, tokens: .zero, evidenceLimitations: limitations))
            case "item.started": continue
            case "error":
                receipts.append(ActivityReceipt(runIdentity: run, operationIdentity: "error-\(offset + 1)", occurredAt: now.addingTimeInterval(Double(offset) / 1_000_000), compatibility: compatibility, lifecycle: .unknown, attempt: .unknown, role: .unknown, outcome: .unknown, tokens: .zero, evidenceLimitations: limitations))
            default: return .unavailable(.insufficientLifecycleSemantics)
            }
        }
        return normalize(receipts)
    }

    private static func normalize(_ receipts: [ActivityReceipt]) -> ActivityReceiptImportResult {
        guard !receipts.isEmpty else { return .unavailable(.insufficientLifecycleSemantics) }
        var identities = Set<String>()
        var previousByRun: [UUID: Date] = [:]
        var compatibilityByRun: [UUID: ActivityReceiptCompatibility] = [:]
        for receipt in receipts {
            guard isSupported(receipt) else { return .unavailable(.partialRecord) }
            let identity = "\(receipt.compatibility.source.rawValue):\(receipt.runIdentity):\(receipt.operationIdentity)"
            guard identities.insert(identity).inserted else { return .unavailable(.duplicateRecord) }
            guard previousByRun[receipt.runIdentity].map({ receipt.occurredAt >= $0 }) ?? true else { return .unavailable(.outOfOrder) }
            previousByRun[receipt.runIdentity] = receipt.occurredAt
            guard compatibilityByRun[receipt.runIdentity].map({ $0 == receipt.compatibility }) ?? true else { return .unavailable(.incompatibleRuns) }
            compatibilityByRun[receipt.runIdentity] = receipt.compatibility
        }
        return .imported(receipts)
    }

    static func isSupported(_ receipt: ActivityReceipt) -> Bool {
        guard receipt.contractVersion == ActivityReceipt.contractVersion, receipt.occurredAt.timeIntervalSince1970.isFinite,
              validOpaqueIdentity(receipt.operationIdentity), validIdentifier(receipt.compatibility.model), validIdentifier(receipt.compatibility.mode),
              (0...64).contains(receipt.compatibility.concurrency), receipt.tokens.isBounded,
              receipt.evidenceLimitations == limitations else { return false }
        switch receipt.compatibility.source {
        case .claudeCode:
            guard receipt.compatibility.adapterSchema == claudeSchema, receipt.compatibility.clientVersion == claudeClientVersion,
                  receipt.compatibility.tokenSemantics == claudeTokenSemantics else { return false }
            switch receipt.lifecycle {
            case .modelAttempt:
                return (receipt.attempt == .unknown && receipt.outcome == .unknown)
                    || (receipt.attempt != .unknown && receipt.outcome == .failed && receipt.tokens == .zero)
            case .compaction:
                return receipt.attempt == .unknown && (receipt.tokens == .zero || receipt.outcome == .unknown)
            case .unknown: return receipt.attempt == .unknown && receipt.role == .unknown && receipt.outcome == .unknown && receipt.tokens == .zero
            case .recoveryReplay, .cache: return false
            }
        case .codexExec:
            guard receipt.compatibility.adapterSchema == codexSchema, receipt.compatibility.clientVersion == codexClientVersion,
                  receipt.compatibility.tokenSemantics == codexTokenSemantics, receipt.compatibility.mode == "exec",
                  receipt.compatibility.concurrency > 0, receipt.lifecycle == .unknown,
                  receipt.attempt == .unknown, receipt.role == .unknown else { return false }
            return receipt.outcome != .unknown || receipt.tokens == .zero
        }
    }

    private static func claudeTokens(_ values: AttributeMap) -> ActivityTokenCounts? {
        guard let input = values.int64("input_tokens"), let cached = values.int64("cache_read_tokens"),
              let creation = values.int64("cache_creation_tokens"), let output = values.int64("output_tokens") else { return nil }
        let tokens = ActivityTokenCounts(input: input, cachedInput: cached, cacheCreationInput: creation, output: output, reasoningOutput: 0)
        return tokens.isBounded ? tokens : nil
    }

    private static let supportedClaudeEvents: Set<String> = [
        "user_prompt", "assistant_response", "tool_result", "api_request", "api_error", "api_refusal",
        "api_retries_exhausted", "compaction", "permission_mode_changed", "internal_error"
    ]

    private static func claudeRole(_ values: AttributeMap) -> ActivityRole {
        switch values.string("query_source") {
        case "repl_main_thread", "main": return .primary
        case "subagent": return .subagent
        default: return values.string("agent.name") == nil ? .unknown : .subagent
        }
    }

    private static func explicitOutcome(_ values: AttributeMap) -> ActivityOutcome {
        if let value = values.bool("success") { return value ? .succeeded : .failed }
        switch values.string("success") {
        case "true": return .succeeded
        case "false": return .failed
        default: return .unknown
        }
    }

    private static func validNow(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite }
    private static func validIdentifier(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) } }
    private static func validOpaqueIdentity(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }
    private static let decoder: JSONDecoder = { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }()

    private struct OTLPExportLogsRequest: Decodable { let resourceLogs: [OTLPResourceLogs] }
    private struct OTLPResourceLogs: Decodable { let scopeLogs: [OTLPScopeLogs] }
    private struct OTLPScopeLogs: Decodable { let logRecords: [OTLPLogRecord] }
    private struct OTLPLogRecord: Decodable { let attributes: [OTLPAttribute] }
    private struct OTLPAttribute: Decodable { let key: String; let value: OTLPValue }
    private struct OTLPValue: Decodable { let stringValue: String?; let intValue: String?; let boolValue: Bool? }
    private struct AttributeMap {
        let values: [String: OTLPValue]
        func string(_ key: String) -> String? { values[key]?.stringValue }
        func int64(_ key: String) -> Int64? { values[key]?.intValue.flatMap(Int64.init) }
        func int(_ key: String) -> Int? { int64(key).flatMap { Int(exactly: $0) } }
        func bool(_ key: String) -> Bool? { values[key]?.boolValue }
    }
    private static func attributes(_ values: [OTLPAttribute]) -> AttributeMap? {
        var result: [String: OTLPValue] = [:]
        for value in values where result.updateValue(value.value, forKey: value.key) != nil { return nil }
        return AttributeMap(values: result)
    }

    private struct CodexDiscriminator: Decodable { let type: String }
    private struct CodexThreadStarted: Decodable {
        let type: String; let threadID: String
        enum CodingKeys: String, CodingKey { case type, threadID = "thread_id" }
    }
    private struct CodexTurnEvent: Decodable {
        let type: String; let usage: CodexUsage?
    }
    private struct CodexItemEvent: Decodable {
        struct Item: Decodable { let id: String; let type: String }
        let type: String; let item: Item
    }
    private struct CodexUsage: Decodable {
        let input: Int64; let cachedInput: Int64; let output: Int64; let reasoningOutput: Int64?
        enum CodingKeys: String, CodingKey { case input = "input_tokens", cachedInput = "cached_input_tokens", output = "output_tokens", reasoningOutput = "reasoning_output_tokens" }
        var tokens: ActivityTokenCounts { .init(input: input, cachedInput: cachedInput, cacheCreationInput: 0, output: output, reasoningOutput: reasoningOutput ?? 0) }
        var isValid: Bool { tokens.isBounded && cachedInput <= input && (reasoningOutput ?? 0) <= output }
    }
}

public struct ActivityDebuggerFinding: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case normalAttempts(count: Int), retryAssociatedInput(percent: Int, tokens: Int64), compactionAssociated(count: Int)
        case retryEvidence(count: Int)
        case recoveryReplayAssociated(count: Int), cacheReadAssociatedInput(tokens: Int64), cacheCreationAssociatedInput(tokens: Int64)
        case subagentAssociated(count: Int), failedOperations(count: Int), successfulCompletions(count: Int), unknownActivity(count: Int)
        case compatibleRunDelta(metric: String, delta: Int64)
        case compatibleRunShareDelta(metric: String, earlierPercent: Int, laterPercent: Int)
        case incompatibleConfigurationChange(dimensions: [String])
    }
    public let kind: Kind
    public let statement: String
    public init(kind: Kind, statement: String) { self.kind = kind; self.statement = statement }
}

public enum ActivityDebuggerState: Equatable, Sendable { case available([ActivityDebuggerFinding]), unavailable(ActivityReceiptUnavailableReason) }

public struct ActivityRunComparison: Equatable, Sendable {
    public let earlierRun: UUID
    public let laterRun: UUID
    public let findings: [ActivityDebuggerFinding]
}
public enum ActivityRunComparisonState: Equatable, Sendable { case available(ActivityRunComparison), unavailable(ActivityReceiptUnavailableReason) }

public enum ActivityReceiptDebugger {
    private struct RunKey: Hashable { let source: ActivityReceiptSource; let run: UUID }
    private struct Totals {
        var total: Int64 = 0, input: Int64 = 0, retryInput: Int64 = 0, cached: Int64 = 0, creation: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0
        var normal = 0, compaction = 0, recovery = 0, subagent = 0, failed = 0, succeeded = 0, unknown = 0
        var retry = 0, lifecycleKnown = 0, attemptKnown = 0, roleKnown = 0, outcomeKnown = 0
    }

    public static func latestRunFindings(for receipts: [ActivityReceipt]) -> ActivityDebuggerState {
        let groups = Dictionary(grouping: receipts) { RunKey(source: $0.compatibility.source, run: $0.runIdentity) }.values.sorted {
            let left = ($0.map(\.occurredAt).max() ?? .distantPast, $0.first?.compatibility.source.rawValue ?? "", $0.first?.runIdentity.uuidString ?? "")
            let right = ($1.map(\.occurredAt).max() ?? .distantPast, $1.first?.compatibility.source.rawValue ?? "", $1.first?.runIdentity.uuidString ?? "")
            return left < right
        }
        guard let latest = groups.last else { return .unavailable(.noReceipts) }
        guard case let .available(current) = findings(for: latest) else { return findings(for: latest) }
        guard let compatibility = latest.first?.compatibility,
              let prior = groups.dropLast().last(where: { $0.first?.compatibility.source == compatibility.source }),
              let priorCompatibility = prior.first?.compatibility else { return .available(current) }
        if priorCompatibility == compatibility, case let .available(comparison) = compare(prior, latest) {
            return .available(current + comparison.findings)
        }
        let changed = changedDimensions(priorCompatibility, compatibility)
        guard !changed.isEmpty else { return .available(current) }
        let statement = "A previous run used different \(changed.joined(separator: ", ")). Values were not compared."
        return .available(current + [.init(kind: .incompatibleConfigurationChange(dimensions: changed), statement: statement)])
    }

    public static func findings(for receipts: [ActivityReceipt]) -> ActivityDebuggerState {
        guard !receipts.isEmpty else { return .unavailable(.noReceipts) }
        guard Set(receipts.map(\.compatibility)).count == 1 else { return .unavailable(.incompatibleRuns) }
        guard receipts.contains(where: semanticKnown) else { return .unavailable(.insufficientLifecycleSemantics) }
        guard let totals = totals(receipts) else { return .unavailable(.tokenOverflow) }
        var values: [(ActivityDebuggerFinding.Kind, String)] = []
        if totals.retry > 0 { values.append((.retryEvidence(count: totals.retry), "\(totals.retry) operations had documented retry evidence.")) }
        if totals.normal > 0 { values.append((.normalAttempts(count: totals.normal), "\(totals.normal) operations reported one documented API attempt.")) }
        if totals.compaction > 0 { values.append((.compactionAssociated(count: totals.compaction), "\(totals.compaction) compaction-associated operations were measured.")) }
        if totals.recovery > 0 { values.append((.recoveryReplayAssociated(count: totals.recovery), "\(totals.recovery) recovery or replay-associated operations were measured.")) }
        if totals.cached > 0 { values.append((.cacheReadAssociatedInput(tokens: totals.cached), "\(totals.cached) measured input tokens were reported as cache reads.")) }
        if totals.creation > 0 { values.append((.cacheCreationAssociatedInput(tokens: totals.creation), "\(totals.creation) measured input tokens were reported as cache creation.")) }
        if totals.subagent > 0 { values.append((.subagentAssociated(count: totals.subagent), "\(totals.subagent) subagent-associated operations were measured.")) }
        if totals.failed > 0 { values.append((.failedOperations(count: totals.failed), "\(totals.failed) operations had an explicit failed outcome.")) }
        if totals.succeeded > 0 { values.append((.successfulCompletions(count: totals.succeeded), "\(totals.succeeded) operations had an explicit successful outcome.")) }
        if totals.unknown > 0 { values.append((.unknownActivity(count: totals.unknown), "\(totals.unknown) supported events retained unclassified dimensions.")) }
        guard !values.isEmpty else { return .unavailable(.insufficientLifecycleSemantics) }
        return .available(values.map { .init(kind: $0.0, statement: $0.1) })
    }

    public static func compare(_ earlier: [ActivityReceipt], _ later: [ActivityReceipt]) -> ActivityRunComparisonState {
        guard let left = earlier.first?.compatibility, let right = later.first?.compatibility,
              earlier.allSatisfy({ $0.compatibility == left }), later.allSatisfy({ $0.compatibility == right }), left == right,
              let earlierRun = earlier.first?.runIdentity, let laterRun = later.first?.runIdentity,
              earlier.allSatisfy({ $0.runIdentity == earlierRun }), later.allSatisfy({ $0.runIdentity == laterRun }) else { return .unavailable(.incompatibleRuns) }
        guard left.model != "unknown", left.mode != "unknown", left.concurrency > 0 else { return .unavailable(.incompatibleRuns) }
        guard earlier.contains(where: semanticKnown), later.contains(where: semanticKnown) else { return .unavailable(.insufficientLifecycleSemantics) }
        guard let first = totals(earlier), let second = totals(later) else { return .unavailable(.tokenOverflow) }
        var deltas: [(String, Int64)] = []
        if first.input > 0 || second.input > 0 { deltas.append(("measured input tokens", second.input - first.input)) }
        var values = deltas.map { metric, delta in
            ActivityDebuggerFinding(kind: .compatibleRunDelta(metric: metric, delta: delta), statement: "The later compatible run had \(delta == 0 ? "the same number of" : "\(abs(delta)) \(delta > 0 ? "more" : "fewer")") \(metric).")
        }
        let shares: [(String, Int, Int, Int, Int)] = [
            ("compaction-associated lifecycle share", first.compaction, first.lifecycleKnown, second.compaction, second.lifecycleKnown),
            ("retry-evidence attempt share", first.retry, first.attemptKnown, second.retry, second.attemptKnown),
            ("subagent-associated role share", first.subagent, first.roleKnown, second.subagent, second.roleKnown),
            ("explicit failed-outcome share", first.failed, first.outcomeKnown, second.failed, second.outcomeKnown),
        ]
        for (metric, firstPart, firstTotal, secondPart, secondTotal) in shares where firstTotal > 0 && secondTotal > 0 {
            let earlierPercent = Int((Double(firstPart) / Double(firstTotal) * 100).rounded())
            let laterPercent = Int((Double(secondPart) / Double(secondTotal) * 100).rounded())
            values.append(.init(kind: .compatibleRunShareDelta(metric: metric, earlierPercent: earlierPercent, laterPercent: laterPercent), statement: "Among operations with observable \(metric.replacingOccurrences(of: " share", with: "")) semantics, the measured share changed from \(earlierPercent)% to \(laterPercent)% in the later compatible run."))
        }
        return .available(ActivityRunComparison(earlierRun: earlierRun, laterRun: laterRun, findings: values))
    }

    private static func semanticKnown(_ receipt: ActivityReceipt) -> Bool { receipt.lifecycle != .unknown || receipt.attempt != .unknown || receipt.role != .unknown || receipt.outcome != .unknown }
    private static func totals(_ receipts: [ActivityReceipt]) -> Totals? {
        var value = Totals()
        func add(_ amount: Int64, to total: inout Int64) -> Bool {
            let result = total.addingReportingOverflow(amount)
            guard !result.overflow, result.partialValue <= ActivityTokenCounts.maximumValue else { return false }
            total = result.partialValue
            return true
        }
        for receipt in receipts {
            guard let receiptTotal = receipt.tokens.checkedTotal, add(receiptTotal, to: &value.total) else { return nil }
            guard add(receipt.tokens.input, to: &value.input), add(receipt.tokens.cachedInput, to: &value.cached),
                  add(receipt.tokens.cacheCreationInput, to: &value.creation), add(receipt.tokens.output, to: &value.output),
                  add(receipt.tokens.reasoningOutput, to: &value.reasoning) else { return nil }
            if receipt.attempt == .retry, !add(receipt.tokens.input, to: &value.retryInput) { return nil }
            if receipt.lifecycle == .modelAttempt && receipt.attempt == .normal { value.normal += 1 }
            if receipt.lifecycle == .compaction { value.compaction += 1 }
            if receipt.lifecycle == .recoveryReplay { value.recovery += 1 }
            if receipt.role == .subagent { value.subagent += 1 }
            if receipt.outcome == .failed { value.failed += 1 }
            if receipt.outcome == .succeeded { value.succeeded += 1 }
            if receipt.lifecycle == .unknown || receipt.attempt == .unknown || receipt.role == .unknown || receipt.outcome == .unknown { value.unknown += 1 }
            if receipt.lifecycle != .unknown { value.lifecycleKnown += 1 }
            if receipt.attempt != .unknown { value.attemptKnown += 1; if receipt.attempt == .retry { value.retry += 1 } }
            if receipt.role != .unknown { value.roleKnown += 1 }
            if receipt.outcome != .unknown { value.outcomeKnown += 1 }
        }
        return value
    }

    private static func changedDimensions(_ first: ActivityReceiptCompatibility, _ second: ActivityReceiptCompatibility) -> [String] {
        var values: [String] = []
        if first.clientVersion != second.clientVersion { values.append("client version") }
        if first.model != second.model { values.append("model") }
        if first.mode != second.mode { values.append("mode") }
        if first.concurrency != second.concurrency { values.append("concurrency") }
        if first.adapterSchema != second.adapterSchema { values.append("adapter schema") }
        if first.tokenSemantics != second.tokenSemantics { values.append("token semantics") }
        return values
    }
}
