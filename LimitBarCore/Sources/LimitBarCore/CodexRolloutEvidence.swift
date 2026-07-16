import CryptoKit
import Foundation

public enum CodexEvidenceConfidence: String, Codable, Equatable, Sendable {
    case observedCompatible = "observed-compatible"
}

public enum CodexEvidenceBarrier: String, Codable, Equatable, Hashable, Sendable {
    case malformedRecord = "malformed_record"
    case unsupportedVersionOrMixedAuthorship = "unsupported_version_or_mixed_authorship"
    case unsupportedVariant = "unsupported_variant"
    case invalidTokenState = "invalid_token_state"
    case tokenCounterDecreased = "token_counter_decreased"
    case mismatchedTokenDelta = "mismatched_token_delta"
    case unsafeTimestampOrder = "unsafe_timestamp_order"
    case sourceDiscontinuity = "source_discontinuity"
    case unsupportedCompression = "unsupported_compression"
    case evidenceLimitExceeded = "evidence_limit_exceeded"
}

public struct CodexMeasuredTokens: Codable, Equatable, Sendable {
    public let input: Int64
    public let cachedInput: Int64
    public let output: Int64
    public let reasoningOutput: Int64

    public init(input: Int64, cachedInput: Int64, output: Int64, reasoningOutput: Int64) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.reasoningOutput = reasoningOutput
    }

    public var total: Int64 { input + output }
}

public struct CodexRolloutEvidence: Codable, Equatable, Sendable {
    public let sessionIdentity: String
    public let lineOrdinal: Int
    public let lineSHA256: String
    public let adapterVersion: String
    public let creatorVersion: String
    public let observedAt: Date
    public let tokens: CodexMeasuredTokens
}

public struct CodexRolloutScanResult: Equatable, Sendable {
    public let adapterVersion: String
    public let confidence: CodexEvidenceConfidence
    public let lastVerified: String
    public let creatorVersion: String?
    public let evidence: [CodexRolloutEvidence]
    public let quotaSnapshots: [CodexRateLimitSnapshot]
    public let barriers: [CodexEvidenceBarrier]
    public let completeLineCount: Int
    public let coverageStart: Date?
    public let coverageEnd: Date?

    public init(
        adapterVersion: String,
        confidence: CodexEvidenceConfidence,
        lastVerified: String,
        creatorVersion: String?,
        evidence: [CodexRolloutEvidence],
        quotaSnapshots: [CodexRateLimitSnapshot],
        barriers: [CodexEvidenceBarrier],
        completeLineCount: Int,
        coverageStart: Date?,
        coverageEnd: Date?
    ) {
        self.adapterVersion = adapterVersion
        self.confidence = confidence
        self.lastVerified = lastVerified
        self.creatorVersion = creatorVersion
        self.evidence = evidence
        self.quotaSnapshots = quotaSnapshots
        self.barriers = barriers
        self.completeLineCount = completeLineCount
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
    }
}

public struct CodexSessionScanPublication: Equatable, Sendable {
    public let snapshot: CodexRateLimitSnapshot?
    public let explanation: CodexQuotaExplanationState
    public let evidence: [CodexRolloutEvidence]
    public let barriers: [CodexEvidenceBarrier]
    public let coverageStart: Date?
    public let coverageEnd: Date?

    public init(
        snapshot: CodexRateLimitSnapshot?,
        explanation: CodexQuotaExplanationState,
        evidence: [CodexRolloutEvidence],
        barriers: [CodexEvidenceBarrier],
        coverageStart: Date?,
        coverageEnd: Date?
    ) {
        self.snapshot = snapshot
        self.explanation = explanation
        self.evidence = evidence
        self.barriers = barriers
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
    }
}

public enum CodexRolloutEvidenceAdapter {
    public static let adapterVersion = "codex-rollout-observed-0.144.4"
    public static let supportedCreatorVersion = "0.144.4"
    public static let lastVerified = "2026-07-15"

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable {
                let totalTokenUsage: TokenState?
                let lastTokenUsage: TokenState?
                let hasTotalTokenUsage: Bool
                let hasLastTokenUsage: Bool

                enum CodingKeys: String, CodingKey {
                    case totalTokenUsage = "total_token_usage"
                    case lastTokenUsage = "last_token_usage"
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    hasTotalTokenUsage = container.contains(.totalTokenUsage)
                    hasLastTokenUsage = container.contains(.lastTokenUsage)
                    totalTokenUsage = try container.decodeIfPresent(TokenState.self, forKey: .totalTokenUsage)
                    lastTokenUsage = try container.decodeIfPresent(TokenState.self, forKey: .lastTokenUsage)
                }
            }

            struct Window: Decodable {
                let usedPercent: Double?
                let windowMinutes: Int?
                let resetsAt: Double?

                enum CodingKeys: String, CodingKey {
                    case usedPercent = "used_percent"
                    case windowMinutes = "window_minutes"
                    case resetsAt = "resets_at"
                }
            }

            struct Credits: Decodable {
                let hasCredits: Bool?
                let unlimited: Bool?
                let balance: String?

                enum CodingKeys: String, CodingKey {
                    case hasCredits = "has_credits"
                    case unlimited
                    case balance
                }
            }

            struct RateLimits: Decodable {
                let limitID: String?
                let primary: Window?
                let secondary: Window?
                let credits: Credits?
                let planType: String?

                enum CodingKeys: String, CodingKey {
                    case limitID = "limit_id"
                    case primary
                    case secondary
                    case credits
                    case planType = "plan_type"
                }
            }

            let type: String?
            let sessionID: String?
            let id: String?
            let cliVersion: String?
            let info: Info?
            let rateLimits: RateLimits?
            let hasInfo: Bool
            let hasRateLimits: Bool

            enum CodingKeys: String, CodingKey {
                case type
                case sessionID = "session_id"
                case id
                case cliVersion = "cli_version"
                case info
                case rateLimits = "rate_limits"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try container.decodeIfPresent(String.self, forKey: .type)
                sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
                id = try container.decodeIfPresent(String.self, forKey: .id)
                cliVersion = try container.decodeIfPresent(String.self, forKey: .cliVersion)
                hasInfo = container.contains(.info)
                hasRateLimits = container.contains(.rateLimits)
                info = try container.decodeIfPresent(Info.self, forKey: .info)
                rateLimits = try container.decodeIfPresent(RateLimits.self, forKey: .rateLimits)
            }
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct TokenState: Decodable, Equatable {
        let input: Int64
        let cachedInput: Int64
        let output: Int64
        let reasoningOutput: Int64
        let total: Int64

        enum CodingKeys: String, CodingKey {
            case input = "input_tokens"
            case cachedInput = "cached_input_tokens"
            case output = "output_tokens"
            case reasoningOutput = "reasoning_output_tokens"
            case total = "total_tokens"
        }

        var isValid: Bool {
            input >= 0 && cachedInput >= 0 && output >= 0 && reasoningOutput >= 0 && total >= 0
                && cachedInput <= input && reasoningOutput <= output
                && input <= Int64.max - output && total == input + output
        }

        func delta(from previous: Self) -> Self? {
            guard input >= previous.input, cachedInput >= previous.cachedInput,
                  output >= previous.output, reasoningOutput >= previous.reasoningOutput,
                  total >= previous.total else { return nil }
            return Self(
                input: input - previous.input,
                cachedInput: cachedInput - previous.cachedInput,
                output: output - previous.output,
                reasoningOutput: reasoningOutput - previous.reasoningOutput,
                total: total - previous.total
            )
        }

        var measured: CodexMeasuredTokens {
            CodexMeasuredTokens(input: input, cachedInput: cachedInput, output: output, reasoningOutput: reasoningOutput)
        }
    }

    public static func scan(data: Data, identityKey: Data) -> CodexRolloutScanResult {
        var lineSlices: [ArraySlice<UInt8>] = [UInt8](data)
            .split(separator: 0x0A, omittingEmptySubsequences: false)
        guard !lineSlices.isEmpty else { return failed(.malformedRecord, completeLineCount: 0) }
        lineSlices.removeLast()
        let completeLines = lineSlices.map { Data($0) }
        guard let first = completeLines.first,
              let metadata = try? JSONDecoder().decode(Envelope.self, from: first),
              metadata.type == "session_meta", let payload = metadata.payload,
              let sessionID = payload.sessionID, UUID(uuidString: sessionID) != nil,
              let threadID = payload.id, UUID(uuidString: threadID) != nil,
              let creatorVersion = payload.cliVersion,
              parseTimestamp(metadata.timestamp) != nil else {
            return failed(.malformedRecord, completeLineCount: completeLines.count)
        }
        guard creatorVersion == supportedCreatorVersion else {
            return failed(.unsupportedVersionOrMixedAuthorship, creatorVersion: creatorVersion, completeLineCount: completeLines.count)
        }

        let identityMaterial = Data((sessionID.lowercased() + ":" + threadID.lowercased()).utf8)
        let identity = HMAC<SHA256>.authenticationCode(for: identityMaterial, using: SymmetricKey(data: identityKey))
            .map { String(format: "%02x", $0) }.joined()
        var previous: (state: TokenState, timestamp: Date)?
        var evidence: [CodexRolloutEvidence] = []
        var quotaSnapshots: [CodexRateLimitSnapshot] = []
        var barriers: [CodexEvidenceBarrier] = []
        var coverageStart: Date?
        var coverageEnd: Date?

        for (offset, line) in completeLines.dropFirst().enumerated() {
            let ordinal = offset + 2
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line),
                  let timestamp = parseTimestamp(envelope.timestamp),
                  envelope.type == "event_msg", let payload = envelope.payload else {
                barriers.append(.malformedRecord)
                previous = nil
                continue
            }
            guard payload.type == "token_count" else {
                barriers.append(.unsupportedVariant)
                previous = nil
                continue
            }
            guard payload.hasInfo, payload.hasRateLimits else {
                barriers.append(.unsupportedVariant)
                previous = nil
                continue
            }
            if let snapshot = quotaSnapshot(payload.rateLimits, observedAt: timestamp) {
                quotaSnapshots.append(snapshot)
            }
            guard let info = payload.info else {
                if previous != nil { barriers.append(.unsupportedVariant) }
                previous = nil
                continue
            }
            guard info.hasTotalTokenUsage, info.hasLastTokenUsage else {
                barriers.append(.unsupportedVariant)
                previous = nil
                continue
            }
            guard let total = info.totalTokenUsage else {
                barriers.append(.unsupportedVariant)
                previous = nil
                continue
            }
            guard let last = info.lastTokenUsage else {
                barriers.append(.unsupportedVariant)
                previous = nil
                continue
            }
            guard total.isValid else {
                barriers.append(.invalidTokenState)
                previous = nil
                continue
            }
            coverageStart = coverageStart ?? timestamp
            coverageEnd = timestamp
            guard let prior = previous else {
                previous = (total, timestamp)
                continue
            }
            guard timestamp > prior.timestamp else {
                barriers.append(.unsafeTimestampOrder)
                previous = nil
                continue
            }
            guard let delta = total.delta(from: prior.state) else {
                barriers.append(.tokenCounterDecreased)
                previous = nil
                continue
            }
            let isZeroDelta = delta.total == 0 && delta.input == 0 && delta.cachedInput == 0
                && delta.output == 0 && delta.reasoningOutput == 0
            guard isZeroDelta || (last.isValid && last == delta) else {
                barriers.append(.mismatchedTokenDelta)
                previous = nil
                continue
            }
            evidence.append(CodexRolloutEvidence(
                sessionIdentity: identity,
                lineOrdinal: ordinal,
                lineSHA256: SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined(),
                adapterVersion: adapterVersion,
                creatorVersion: creatorVersion,
                observedAt: timestamp,
                tokens: delta.measured
            ))
            previous = (total, timestamp)
        }

        return CodexRolloutScanResult(
            adapterVersion: adapterVersion,
            confidence: .observedCompatible,
            lastVerified: lastVerified,
            creatorVersion: creatorVersion,
            evidence: evidence,
            quotaSnapshots: quotaSnapshots,
            barriers: barriers,
            completeLineCount: completeLines.count,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd
        )
    }

    private static func failed(
        _ barrier: CodexEvidenceBarrier,
        creatorVersion: String? = nil,
        completeLineCount: Int
    ) -> CodexRolloutScanResult {
        CodexRolloutScanResult(
            adapterVersion: adapterVersion,
            confidence: .observedCompatible,
            lastVerified: lastVerified,
            creatorVersion: creatorVersion,
            evidence: [],
            quotaSnapshots: [],
            barriers: [barrier],
            completeLineCount: completeLineCount,
            coverageStart: nil,
            coverageEnd: nil
        )
    }

    private static func parseTimestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func quotaSnapshot(_ raw: Envelope.Payload.RateLimits?, observedAt: Date) -> CodexRateLimitSnapshot? {
        guard let raw else { return nil }
        func window(_ rawWindow: Envelope.Payload.Window?) -> CodexRateLimitWindow? {
            guard let rawWindow, let percent = rawWindow.usedPercent, percent.isFinite, (0...100).contains(percent),
                  let minutes = rawWindow.windowMinutes, (1...525_600).contains(minutes) else { return nil }
            let reset = rawWindow.resetsAt.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            return CodexRateLimitWindow(limitID: raw.limitID ?? "codex", percentUsed: percent, windowMinutes: minutes, resetsAt: reset)
        }
        let credits = raw.credits.map {
            CodexCredits(
                hasCredits: $0.hasCredits ?? false,
                unlimited: $0.unlimited ?? false,
                balance: $0.balance.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
            )
        }
        let snapshot = CodexRateLimitSnapshot(
            planType: raw.planType,
            primary: window(raw.primary),
            secondary: window(raw.secondary),
            credits: credits,
            reportedAt: observedAt
        )
        return snapshot.primary == nil && snapshot.secondary == nil && snapshot.credits == nil ? nil : snapshot
    }
}

public enum CodexSessionEvidenceReader {
    public static func scan(
        sessionsDirectory: URL,
        now: Date,
        identityKey: Data,
        recentWindow: TimeInterval = 9 * 24 * 60 * 60,
        fileManager: FileManager = .default
    ) throws -> CodexSessionScanPublication {
        try Task.checkCancellation()
        guard let root = SecureRegularFile.canonicalURL(sessionsDirectory),
               !SecureRegularFile.isSymbolicLink(sessionsDirectory),
               !SecureRegularFile.isSymbolicLink(sessionsDirectory.deletingLastPathComponent()),
               let enumerator = fileManager.enumerator(
                   at: root,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else { throw CodexRateLimitFailure.notFound }
        let cutoff = now.addingTimeInterval(-recentWindow)
        var entries = 0
        var totalBytes = 0
        var files: [(URL, Date, Int)] = []
        var barriers: [CodexEvidenceBarrier] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            entries += 1
            guard entries <= 10_000 else { throw CodexRateLimitFailure.traversalLimitExceeded }
            if url.lastPathComponent.hasSuffix(".jsonl.zst") {
                barriers.append(.unsupportedCompression)
                continue
            }
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified >= cutoff,
                  let size = values.fileSize, size <= 8 * 1_024 * 1_024,
                  let canonical = SecureRegularFile.canonicalURL(url), canonical.path.hasPrefix(root.path + "/") else { continue }
            files.append((canonical, modified, size))
        }

        var evidence: [CodexRolloutEvidence] = []
        var observations: [MeasuredQuotaObservation] = []
        var snapshots: [CodexRateLimitSnapshot] = []
        var coverageStart: Date?
        var coverageEnd: Date?
        var coverageContributingFiles = 0
        for (url, _, size) in files.sorted(by: { $0.1 > $1.1 }) {
            guard totalBytes <= 32 * 1_024 * 1_024 - size else { break }
            let handle = try SecureRegularFile.open(url)
            let data: Data
            do {
                data = try handle.readToEnd() ?? Data()
                try handle.close()
            } catch {
                try? handle.close()
                barriers.append(.sourceDiscontinuity)
                continue
            }
            guard data.count == size else {
                barriers.append(.sourceDiscontinuity)
                continue
            }
            totalBytes += data.count
            let result = CodexRolloutEvidenceAdapter.scan(data: data, identityKey: identityKey)
            evidence.append(contentsOf: result.evidence)
            let currentSnapshots = result.quotaSnapshots.filter { $0.reportedAt >= cutoff && $0.reportedAt <= now.addingTimeInterval(300) }
            snapshots.append(contentsOf: currentSnapshots)
            observations.append(contentsOf: currentSnapshots.flatMap(MeasuredQuotaObservationAdapter.codex))
            barriers.append(contentsOf: result.barriers)
            if let start = result.coverageStart, let end = result.coverageEnd {
                coverageContributingFiles += 1
                coverageStart = min(coverageStart ?? start, start)
                coverageEnd = max(coverageEnd ?? end, end)
            }
        }
        evidence.sort { ($0.observedAt, $0.sessionIdentity, $0.lineOrdinal) < ($1.observedAt, $1.sessionIdentity, $1.lineOrdinal) }
        for pair in zip(evidence, evidence.dropFirst()) where pair.1.observedAt <= pair.0.observedAt {
            barriers.append(.unsafeTimestampOrder)
        }
        var seen = Set<String>()
        evidence = evidence.filter { seen.insert("\($0.sessionIdentity):\($0.lineOrdinal):\($0.lineSHA256)").inserted }
        if evidence.count > 10_000 {
            evidence = Array(evidence.prefix(10_000))
            barriers.append(.evidenceLimitExceeded)
        }
        if coverageContributingFiles != 1 {
            coverageStart = nil
            coverageEnd = nil
        }
        let latest = snapshots.max { $0.reportedAt < $1.reportedAt }
        guard latest != nil || !barriers.isEmpty || !files.isEmpty else { throw CodexRateLimitFailure.notFound }
        return CodexSessionScanPublication(
            snapshot: latest,
            explanation: CodexQuotaExplanationEngine.explain(
                observations: observations,
                evidence: evidence,
                coverageStart: coverageStart,
                coverageEnd: coverageEnd,
                barriers: barriers,
                now: now,
                maximumObservationAge: recentWindow,
                futureSkew: 300
            ),
            evidence: evidence,
            barriers: Array(Set(barriers)).sorted { $0.rawValue < $1.rawValue },
            coverageStart: coverageStart,
            coverageEnd: coverageEnd
        )
    }
}
