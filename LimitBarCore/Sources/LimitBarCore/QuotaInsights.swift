import Foundation
import CryptoKit
import SQLite3

public enum QuotaObservationSource: String, Codable, CaseIterable, Sendable {
    case claudeProviderReport = "claude_provider_report"
    case codexLocalReport = "codex_local_report"
}

public enum QuotaInsightValidationError: Error, Equatable {
    case invalidObservation
}

public enum QuotaObservationIdentityVersion: String, Codable, Equatable, Hashable, Sendable {
    case normalizedQuotaObservationV1 = "normalized_quota_observation_v1"
}

public enum QuotaObservationNormalizationVersion: String, Codable, Equatable, Hashable, Sendable {
    case quotaObservationNormalizationV1 = "quota_observation_normalization_v1"
}

public enum QuotaObservationInterpretationVersion: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case claudeProviderReportV1 = "claude_provider_report_v1"
    case codexLocalReportV1 = "codex_local_report_v1"

    public init(derivedFrom source: QuotaObservationSource) {
        self = switch source {
        case .claudeProviderReport: .claudeProviderReportV1
        case .codexLocalReport: .codexLocalReportV1
        }
    }
}

public struct QuotaObservationIdentity: Codable, Equatable, Hashable, Sendable {
    public let version: QuotaObservationIdentityVersion
    public let digest: String

    fileprivate init(version: QuotaObservationIdentityVersion, digest: String) {
        self.version = version
        self.digest = digest
    }
}

public struct MeasuredQuotaObservation: Equatable, Sendable {
    public let identity: QuotaWindowIdentity
    public let percentageUsed: Double
    public let observedAt: Date
    public let source: QuotaObservationSource
    public let normalizationVersion: QuotaObservationNormalizationVersion
    public var interpretationVersion: QuotaObservationInterpretationVersion { .init(derivedFrom: source) }

    public var stableIdentity: QuotaObservationIdentity {
        var content = Data()
        content.appendLengthPrefixed(normalizationVersion.rawValue)
        content.appendLengthPrefixed(interpretationVersion.rawValue)
        content.appendLengthPrefixed(identity.product.rawValue)
        content.appendLengthPrefixed(identity.identifier.precomposedStringWithCanonicalMapping)
        content.appendCanonicalDouble(identity.resetBoundary.timeIntervalSince1970)
        content.appendCanonicalDouble(observedAt.timeIntervalSince1970)
        content.appendCanonicalDouble(percentageUsed)
        content.appendLengthPrefixed(source.rawValue)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        return QuotaObservationIdentity(version: .normalizedQuotaObservationV1, digest: digest)
    }

    public init(
        identity: QuotaWindowIdentity,
        percentageUsed: Double,
        observedAt: Date,
        source: QuotaObservationSource
    ) throws {
        guard percentageUsed.isFinite, (0...100).contains(percentageUsed),
              observedAt.timeIntervalSince1970.isFinite,
              observedAt <= identity.resetBoundary,
              (identity.product == .claudeCode && source == .claudeProviderReport)
                || (identity.product == .codex && source == .codexLocalReport) else {
            throw QuotaInsightValidationError.invalidObservation
        }
        self.identity = identity
        self.percentageUsed = percentageUsed == 0 ? 0 : percentageUsed
        self.observedAt = observedAt
        self.source = source
        self.normalizationVersion = .quotaObservationNormalizationV1
    }
}

public enum MeasuredQuotaObservationAdapter {
    public static func claude(_ snapshot: ClaudeRateLimitSnapshot) -> [MeasuredQuotaObservation] {
        snapshot.limits.compactMap { limit in
            guard limit.scopeDisplayName == nil,
                  let identity = QuotaWindowIdentity.claudeCode(limit) else { return nil }
            return try? MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: limit.percentUsed,
                observedAt: snapshot.fetchedAt,
                source: .claudeProviderReport
            )
        }
    }

    public static func codex(_ snapshot: CodexRateLimitSnapshot) -> [MeasuredQuotaObservation] {
        guard !snapshot.isBusinessPlan else { return [] }
        return [("primary", snapshot.primary), ("secondary", snapshot.secondary)].compactMap { slot, window in
            guard let window, let identity = QuotaWindowIdentity.codex(slot: slot, window: window) else { return nil }
            return try? MeasuredQuotaObservation(
                identity: identity,
                percentageUsed: window.percentUsed,
                observedAt: snapshot.reportedAt,
                source: .codexLocalReport
            )
        }
    }
}

public enum QuotaInsightUnavailableReason: String, Codable, Equatable, Hashable, Sendable {
    case insufficientObservations = "insufficient_observations"
    case insufficientSpan = "insufficient_span"
    case staleEvidence = "stale_evidence"
    case resetOrExpired = "reset_or_expired"
    case counterDecreased = "counter_decreased"
    case noPositiveBurn = "no_positive_burn"
    case conflictingObservations = "conflicting_observations"
    case incompatibleEvidence = "incompatible_evidence"
    case invalidEvaluation = "invalid_evaluation"

    public var displayText: String {
        switch self {
        case .insufficientObservations: "Collecting measured observations"
        case .insufficientSpan: "Collecting a longer measured span"
        case .staleEvidence: "Measured observations are stale"
        case .resetOrExpired: "Quota window reset or expired"
        case .counterDecreased: "Usage decreased; waiting for a stable window"
        case .noPositiveBurn: "No positive burn measured"
        case .conflictingObservations: "Conflicting measured observations at the same time"
        case .incompatibleEvidence: "Measured observations belong to different quota windows"
        case .invalidEvaluation: "Evaluation time is invalid"
        }
    }
}

public enum QuotaInsightWindowKind: Equatable, Sendable {
    case session
    case weekly
    case other
}

public extension QuotaWindowIdentity {
    var insightWindowKind: QuotaInsightWindowKind {
        switch product {
        case .claudeCode:
            guard let separator = identifier.firstIndex(of: ":") else { return .other }
            let group = identifier[..<separator]
            let kind = identifier[identifier.index(after: separator)...]
            guard !kind.isEmpty else { return .other }
            return switch group {
            case ClaudeRateLimitGroup.session.rawValue: .session
            case ClaudeRateLimitGroup.weekly.rawValue: .weekly
            default: .other
            }
        case .codex:
            let components = identifier.split(separator: ":", omittingEmptySubsequences: false)
            let windowComponents: ArraySlice<Substring>
            if components.count == 2 {
                windowComponents = components[0...1]
            } else if components.count == 3, !components[0].isEmpty {
                windowComponents = components[1...2]
            } else {
                return .other
            }
            guard windowComponents.first == "primary" || windowComponents.first == "secondary",
                  let minutesText = windowComponents.last,
                  let minutes = Int(minutesText), String(minutes) == minutesText else { return .other }
            return switch minutes {
            case 300: .session
            case 10_080: .weekly
            default: .other
            }
        default:
            return .other
        }
    }
}

public struct QuotaInsightRange: Equatable, Sendable {
    public let lower: Double
    public let upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }
}

public enum QuotaForecastMethod: String, Codable, CaseIterable, Equatable, Sendable {
    case pairwisePositiveSlopeInterquartileV1 = "pairwise_positive_slope_interquartile_v1"
    case pairwisePositiveSlopeInterquartileV2 = "pairwise_positive_slope_interquartile_v2"
}

public enum QuotaInsightQualificationStatus: String, Codable, Equatable, Sendable {
    case qualified
    case unavailable
}

public struct QualifiedQuotaInsight: Equatable, Sendable {
    public let identity: QuotaWindowIdentity
    public let measuredObservationCount: Int
    public let measuredSpan: TimeInterval
    public let forecastMethod: QuotaForecastMethod
    public let createdAt: Date
    public let evidenceAge: TimeInterval
    public let inputObservationIdentities: [QuotaObservationIdentity]
    public let latestObservationIdentity: QuotaObservationIdentity
    public let latestObservationAt: Date
    public let interpretationVersions: [QuotaObservationInterpretationVersion]
    public let calculatedBurnPercentPerHour: QuotaInsightRange
    public let calculatedExhaustionRange: ClosedRange<Date>?

    init(
        identity: QuotaWindowIdentity,
        measuredObservationCount: Int,
        measuredSpan: TimeInterval,
        forecastMethod: QuotaForecastMethod,
        createdAt: Date,
        evidenceAge: TimeInterval,
        inputObservationIdentities: [QuotaObservationIdentity],
        latestObservationIdentity: QuotaObservationIdentity,
        latestObservationAt: Date,
        interpretationVersions: [QuotaObservationInterpretationVersion],
        calculatedBurnPercentPerHour: QuotaInsightRange,
        calculatedExhaustionRange: ClosedRange<Date>?
    ) {
        self.identity = identity
        self.measuredObservationCount = measuredObservationCount
        self.measuredSpan = measuredSpan
        self.forecastMethod = forecastMethod
        self.createdAt = createdAt
        self.evidenceAge = evidenceAge
        self.inputObservationIdentities = inputObservationIdentities
        self.latestObservationIdentity = latestObservationIdentity
        self.latestObservationAt = latestObservationAt
        self.interpretationVersions = interpretationVersions
        self.calculatedBurnPercentPerHour = calculatedBurnPercentPerHour
        self.calculatedExhaustionRange = calculatedExhaustionRange
    }
}

public struct UnavailableQuotaInsight: Equatable, Sendable {
    public let reason: QuotaInsightUnavailableReason
    public let implicatedIdentities: [QuotaWindowIdentity]
    public let measuredObservationCount: Int
    public let measuredSpan: TimeInterval
    public let forecastMethod: QuotaForecastMethod
    public let createdAt: Date?
    public let evidenceAge: TimeInterval?
    public let inputObservationIdentities: [QuotaObservationIdentity]
    public let interpretationVersions: [QuotaObservationInterpretationVersion]

    init(
        reason: QuotaInsightUnavailableReason,
        implicatedIdentities: [QuotaWindowIdentity],
        measuredObservationCount: Int,
        measuredSpan: TimeInterval,
        forecastMethod: QuotaForecastMethod,
        createdAt: Date?,
        evidenceAge: TimeInterval?,
        inputObservationIdentities: [QuotaObservationIdentity],
        interpretationVersions: [QuotaObservationInterpretationVersion]
    ) {
        self.reason = reason
        self.implicatedIdentities = implicatedIdentities
        self.measuredObservationCount = measuredObservationCount
        self.measuredSpan = measuredSpan
        self.forecastMethod = forecastMethod
        self.createdAt = createdAt
        self.evidenceAge = evidenceAge
        self.inputObservationIdentities = inputObservationIdentities
        self.interpretationVersions = interpretationVersions
    }
}

public enum QuotaInsightState: Equatable, Sendable {
    case qualified(QualifiedQuotaInsight)
    case unavailable(UnavailableQuotaInsight)

    public var qualificationStatus: QuotaInsightQualificationStatus {
        switch self {
        case .qualified: .qualified
        case .unavailable: .unavailable
        }
    }
}

public enum QuotaInsightAnalytics {
    public static let minimumObservationCount = 4
    public static let minimumObservationSpan: TimeInterval = 15 * 60

    public static func analyze(
        _ observations: [MeasuredQuotaObservation],
        now: Date,
        maximumAge: TimeInterval,
        expectedIdentity: QuotaWindowIdentity? = nil
    ) -> QuotaInsightState {
        let ordered = observations.sorted {
            ($0.observedAt, $0.stableIdentity.digest) < ($1.observedAt, $1.stableIdentity.digest)
        }
        var seen = Set<QuotaObservationIdentity>()
        let unique = ordered.filter { seen.insert($0.stableIdentity).inserted }
        guard now.timeIntervalSince1970.isFinite else {
            let identities = orderedIdentities(unique.map(\.identity) + [expectedIdentity].compactMap { $0 })
            let span: TimeInterval
            if let first = unique.first, let last = unique.last {
                span = last.observedAt.timeIntervalSince(first.observedAt)
            } else {
                span = 0
            }
            return .unavailable(UnavailableQuotaInsight(
                reason: .invalidEvaluation,
                implicatedIdentities: identities,
                measuredObservationCount: unique.count,
                measuredSpan: span,
                forecastMethod: .pairwisePositiveSlopeInterquartileV2,
                createdAt: nil,
                evidenceAge: nil,
                inputObservationIdentities: unique.map(\.stableIdentity),
                interpretationVersions: Array(Set(unique.map(\.interpretationVersion))).sorted { $0.rawValue < $1.rawValue }
            ))
        }
        let implicatedIdentities = orderedIdentities(unique.map(\.identity) + [expectedIdentity].compactMap { $0 })
        let span = max(0, (unique.last?.observedAt ?? now).timeIntervalSince(unique.first?.observedAt ?? now))
        let evidenceAge = unique.last.map { now.timeIntervalSince($0.observedAt) }
        func unavailable(
            _ reason: QuotaInsightUnavailableReason,
            implicatedIdentities: [QuotaWindowIdentity],
            inputs: [MeasuredQuotaObservation] = unique,
            span: TimeInterval? = nil
        ) -> QuotaInsightState {
            .unavailable(UnavailableQuotaInsight(
                reason: reason,
                implicatedIdentities: implicatedIdentities,
                measuredObservationCount: inputs.count,
                measuredSpan: span ?? max(0, (inputs.last?.observedAt ?? now).timeIntervalSince(inputs.first?.observedAt ?? now)),
                forecastMethod: .pairwisePositiveSlopeInterquartileV2,
                createdAt: now,
                evidenceAge: inputs.last.map { now.timeIntervalSince($0.observedAt) },
                inputObservationIdentities: inputs.map(\.stableIdentity),
                interpretationVersions: Array(Set(inputs.map(\.interpretationVersion))).sorted { $0.rawValue < $1.rawValue }
            ))
        }
        guard let identity = unique.first?.identity ?? expectedIdentity else {
            return unavailable(.insufficientObservations, implicatedIdentities: [], span: 0)
        }
        guard implicatedIdentities.count == 1 else {
            return unavailable(.incompatibleEvidence, implicatedIdentities: implicatedIdentities, span: span)
        }
        let grouped = Dictionary(grouping: unique, by: \.observedAt)
        let hasConflict = grouped.values.contains { Set($0.map(\.percentageUsed)).count > 1 }
        let distinct = grouped
            .compactMap { $0.value.first }
            .sorted { ($0.observedAt, $0.stableIdentity.digest) < ($1.observedAt, $1.stableIdentity.digest) }
        let distinctSpan = max(0, (distinct.last?.observedAt ?? now).timeIntervalSince(distinct.first?.observedAt ?? now))

        guard !hasConflict else {
            return unavailable(.conflictingObservations, implicatedIdentities: implicatedIdentities, inputs: unique, span: distinctSpan)
        }
        guard !distinct.isEmpty else {
            return unavailable(.insufficientObservations, implicatedIdentities: implicatedIdentities, inputs: distinct, span: 0)
        }

        guard identity.resetBoundary > now else {
            return unavailable(.resetOrExpired, implicatedIdentities: implicatedIdentities, inputs: distinct, span: distinctSpan)
        }
        guard let latest = distinct.last,
              maximumAge.isFinite, maximumAge >= 0,
              let evidenceAge, evidenceAge >= 0,
              evidenceAge <= maximumAge else {
            return unavailable(.staleEvidence, implicatedIdentities: implicatedIdentities, inputs: distinct, span: distinctSpan)
        }
        guard distinct.count >= minimumObservationCount else {
            return unavailable(.insufficientObservations, implicatedIdentities: implicatedIdentities, inputs: distinct, span: distinctSpan)
        }
        guard distinctSpan >= minimumObservationSpan else {
            return unavailable(.insufficientSpan, implicatedIdentities: implicatedIdentities, inputs: distinct, span: distinctSpan)
        }
        for pair in zip(distinct, distinct.dropFirst()) where pair.1.percentageUsed < pair.0.percentageUsed {
            return unavailable(.counterDecreased, implicatedIdentities: implicatedIdentities, inputs: distinct, span: distinctSpan)
        }

        var slopes: [Double] = []
        for lowerIndex in distinct.indices {
            for upperIndex in distinct.indices where upperIndex > lowerIndex {
                let elapsedHours = distinct[upperIndex].observedAt.timeIntervalSince(distinct[lowerIndex].observedAt) / 3_600
                let delta = distinct[upperIndex].percentageUsed - distinct[lowerIndex].percentageUsed
                if elapsedHours > 0, delta > 0 {
                    slopes.append(delta / elapsedHours)
                }
            }
        }
        slopes.sort()
        guard !slopes.isEmpty else {
            return unavailable(.noPositiveBurn, implicatedIdentities: implicatedIdentities, inputs: distinct, span: distinctSpan)
        }
        let lowerBurn = percentile(slopes, fraction: 0.25)
        let upperBurn = percentile(slopes, fraction: 0.75)
        let remaining = max(0, 100 - latest.percentageUsed)
        let earliest = latest.observedAt.addingTimeInterval(remaining / upperBurn * 3_600)
        let latestProjection = latest.observedAt.addingTimeInterval(remaining / lowerBurn * 3_600)
        let exhaustion = latestProjection < identity.resetBoundary
            ? earliest...latestProjection
            : nil
        return .qualified(QualifiedQuotaInsight(
            identity: identity,
            measuredObservationCount: distinct.count,
            measuredSpan: distinctSpan,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            createdAt: now,
            evidenceAge: now.timeIntervalSince(latest.observedAt),
            inputObservationIdentities: distinct.map(\.stableIdentity),
            latestObservationIdentity: latest.stableIdentity,
            latestObservationAt: latest.observedAt,
            interpretationVersions: Array(Set(distinct.map(\.interpretationVersion))).sorted { $0.rawValue < $1.rawValue },
            calculatedBurnPercentPerHour: QuotaInsightRange(lower: lowerBurn, upper: upperBurn),
            calculatedExhaustionRange: exhaustion
        ))
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private static func orderedIdentities(_ identities: [QuotaWindowIdentity]) -> [QuotaWindowIdentity] {
        Array(Set(identities)).sorted {
            ($0.product.rawValue, $0.identifier, $0.resetBoundary.timeIntervalSince1970)
                < ($1.product.rawValue, $1.identifier, $1.resetBoundary.timeIntervalSince1970)
        }
    }
}

private extension Data {
    mutating func appendLengthPrefixed(_ value: String) {
        let bytes = Data(value.utf8)
        appendBigEndian(UInt64(bytes.count))
        append(bytes)
    }

    mutating func appendBigEndian(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
    mutating func appendCanonicalDouble(_ value: Double) {
        appendBigEndian((value == 0 ? 0 : value).bitPattern)
    }
}

public enum QuotaObservationStoreError: Error, Equatable {
    case openFailed
    case schemaFailed
    case writeFailed
    case readFailed
}

public final class SQLiteQuotaObservationStore {
    public static let schemaVersion = 1
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumObservationsPerWindow = 500

    private var database: OpaquePointer?

    private struct SchemaColumn: Equatable {
        let position: Int
        let name: String
        let type: String
        let isNotNull: Bool
        let primaryKeyPosition: Int
    }

    private static let createTableSQL = """
    CREATE TABLE quota_observations (
        product TEXT NOT NULL CHECK (product IN ('claudeCode', 'codex')),
        window_identifier TEXT NOT NULL CHECK (length(window_identifier) BETWEEN 1 AND 128),
        reset_boundary REAL NOT NULL,
        observed_at REAL NOT NULL,
        percentage_used REAL NOT NULL CHECK (percentage_used BETWEEN 0 AND 100),
        observation_source TEXT NOT NULL CHECK (observation_source IN ('claude_provider_report', 'codex_local_report')),
        PRIMARY KEY (product, window_identifier, reset_boundary, observed_at, percentage_used, observation_source)
    )
    """
    private static let createRetentionIndexSQL = "CREATE INDEX quota_observations_retention ON quota_observations(observed_at)"
    private static let expectedColumns = [
        SchemaColumn(position: 0, name: "product", type: "TEXT", isNotNull: true, primaryKeyPosition: 1),
        SchemaColumn(position: 1, name: "window_identifier", type: "TEXT", isNotNull: true, primaryKeyPosition: 2),
        SchemaColumn(position: 2, name: "reset_boundary", type: "REAL", isNotNull: true, primaryKeyPosition: 3),
        SchemaColumn(position: 3, name: "observed_at", type: "REAL", isNotNull: true, primaryKeyPosition: 4),
        SchemaColumn(position: 4, name: "percentage_used", type: "REAL", isNotNull: true, primaryKeyPosition: 5),
        SchemaColumn(position: 5, name: "observation_source", type: "TEXT", isNotNull: true, primaryKeyPosition: 6),
    ]

    public init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw QuotaObservationStoreError.openFailed
        }
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        do {
            try createSchema()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public static func inMemory() throws -> SQLiteQuotaObservationStore {
        try SQLiteQuotaObservationStore(path: ":memory:")
    }

    @discardableResult
    public func record(_ observations: [MeasuredQuotaObservation], now: Date = Date()) throws -> Int {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var inserted = 0
            for observation in observations {
                let statement = try prepare("""
                INSERT OR IGNORE INTO quota_observations
                    (product, window_identifier, reset_boundary, observed_at, percentage_used, observation_source)
                VALUES (?, ?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(statement) }
                bind(observation.identity.product.rawValue, at: 1, in: statement)
                bind(observation.identity.identifier, at: 2, in: statement)
                sqlite3_bind_double(statement, 3, observation.identity.resetBoundary.timeIntervalSince1970)
                sqlite3_bind_double(statement, 4, observation.observedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 5, observation.percentageUsed)
                bind(observation.source.rawValue, at: 6, in: statement)
                try stepDone(statement, error: .writeFailed)
                inserted += Int(sqlite3_changes(database))
            }
            try prune(now: now, canonicalIdentities: Set(observations.map(\.identity)))
            try execute("COMMIT;")
            return inserted
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func observations(for identity: QuotaWindowIdentity, now: Date = Date()) throws -> [MeasuredQuotaObservation] {
        try pruneInTransaction(now: now, canonicalIdentities: [identity])
        let statement = try prepare("""
        SELECT window_identifier, percentage_used, observed_at, observation_source
        FROM quota_observations
        WHERE product = ? AND reset_boundary = ?
        ORDER BY observed_at ASC, percentage_used ASC, observation_source ASC, window_identifier ASC;
        """)
        defer { sqlite3_finalize(statement) }
        bind(identity.product.rawValue, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, identity.resetBoundary.timeIntervalSince1970)
        var result: [MeasuredQuotaObservation] = []
        var seen = Set<QuotaObservationIdentity>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let storedIdentifier = stringColumn(statement, index: 0),
                  storedIdentifier.precomposedStringWithCanonicalMapping == identity.identifier else {
                step = sqlite3_step(statement)
                continue
            }
            guard let sourceRaw = stringColumn(statement, index: 3),
                   let source = QuotaObservationSource(rawValue: sourceRaw),
                   let observation = try? MeasuredQuotaObservation(
                       identity: identity,
                       percentageUsed: sqlite3_column_double(statement, 1),
                       observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                       source: source
                   ) else { throw QuotaObservationStoreError.readFailed }
            if seen.insert(observation.stableIdentity).inserted {
                result.append(observation)
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.readFailed }
        return result
    }

    public func identities(for product: ProviderProduct, now: Date = Date()) throws -> [QuotaWindowIdentity] {
        try pruneInTransaction(now: now, canonicalIdentities: [])
        let statement = try prepare("""
        SELECT DISTINCT window_identifier, reset_boundary
        FROM quota_observations WHERE product = ?
        ORDER BY reset_boundary, window_identifier;
        """)
        defer { sqlite3_finalize(statement) }
        bind(product.rawValue, at: 1, in: statement)
        var result: [QuotaWindowIdentity] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let identifier = stringColumn(statement, index: 0),
                  let identity = try? QuotaWindowIdentity(
                      product: product,
                      identifier: identifier,
                      resetBoundary: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                  ) else { throw QuotaObservationStoreError.readFailed }
            result.append(identity)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.readFailed }
        return result
    }

    public func deleteAll() throws {
        try execute("DELETE FROM quota_observations;")
    }

    private func createSchema() throws {
        let existingVersion = try schemaVersion()
        guard existingVersion <= Self.schemaVersion else { throw QuotaObservationStoreError.schemaFailed }
        let objects = try schemaObjects()
        if !objects.isEmpty || existingVersion != 0 {
            guard existingVersion == Self.schemaVersion else { throw QuotaObservationStoreError.schemaFailed }
            try validateCanonicalSchema()
            return
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(Self.createTableSQL)
            try execute(Self.createRetentionIndexSQL)
            try validateCanonicalSchema()
            try execute("PRAGMA user_version = \(Self.schemaVersion);")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func pruneInTransaction(now: Date, canonicalIdentities: Set<QuotaWindowIdentity>) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try prune(now: now, canonicalIdentities: canonicalIdentities)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prune(now: Date, canonicalIdentities: Set<QuotaWindowIdentity>) throws {
        let age = try prepare("DELETE FROM quota_observations WHERE observed_at < ?;")
        defer { sqlite3_finalize(age) }
        sqlite3_bind_double(age, 1, now.addingTimeInterval(-Self.retentionInterval).timeIntervalSince1970)
        try stepDone(age, error: .writeFailed)

        let count = try prepare("""
        DELETE FROM quota_observations WHERE rowid IN (
            SELECT rowid FROM (
                SELECT rowid, ROW_NUMBER() OVER (
                    PARTITION BY product, window_identifier, reset_boundary
                    ORDER BY observed_at DESC, percentage_used DESC, observation_source DESC
                ) AS position
                FROM quota_observations
            ) WHERE position > ?
        );
        """)
        defer { sqlite3_finalize(count) }
        sqlite3_bind_int64(count, 1, Int64(Self.maximumObservationsPerWindow))
        try stepDone(count, error: .writeFailed)

        for identity in canonicalIdentities {
            try pruneCanonicalIdentity(identity)
        }
    }

    private func pruneCanonicalIdentity(_ identity: QuotaWindowIdentity) throws {
        while true {
            let candidates = try prepare("""
            SELECT rowid, window_identifier
            FROM quota_observations
            WHERE product = ? AND reset_boundary = ?
            ORDER BY observed_at DESC, percentage_used DESC, observation_source DESC, window_identifier ASC, rowid DESC;
            """)
            bind(identity.product.rawValue, at: 1, in: candidates)
            sqlite3_bind_double(candidates, 2, identity.resetBoundary.timeIntervalSince1970)
            var canonicalPosition = 0
            var excessRowIDs: [Int64] = []
            var step = sqlite3_step(candidates)
            while step == SQLITE_ROW, excessRowIDs.count < Self.maximumObservationsPerWindow {
                guard let storedIdentifier = stringColumn(candidates, index: 1) else {
                    sqlite3_finalize(candidates)
                    throw QuotaObservationStoreError.readFailed
                }
                if storedIdentifier.precomposedStringWithCanonicalMapping == identity.identifier {
                    canonicalPosition += 1
                    if canonicalPosition > Self.maximumObservationsPerWindow {
                        excessRowIDs.append(sqlite3_column_int64(candidates, 0))
                    }
                }
                step = sqlite3_step(candidates)
            }
            guard step == SQLITE_DONE || excessRowIDs.count == Self.maximumObservationsPerWindow else {
                sqlite3_finalize(candidates)
                throw QuotaObservationStoreError.readFailed
            }
            sqlite3_finalize(candidates)
            guard !excessRowIDs.isEmpty else { return }

            let deletion = try prepare("DELETE FROM quota_observations WHERE rowid = ?;")
            defer { sqlite3_finalize(deletion) }
            for rowID in excessRowIDs {
                sqlite3_reset(deletion)
                sqlite3_clear_bindings(deletion)
                sqlite3_bind_int64(deletion, 1, rowID)
                try stepDone(deletion, error: .writeFailed)
            }
        }
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw QuotaObservationStoreError.schemaFailed }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func schemaObjects() throws -> Set<String> {
        let statement = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var objects = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let type = stringColumn(statement, index: 0),
                  let name = stringColumn(statement, index: 1) else { throw QuotaObservationStoreError.schemaFailed }
            objects.insert("\(type):\(name)")
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.schemaFailed }
        return objects
    }

    private func validateCanonicalSchema() throws {
        guard try schemaObjects() == ["table:quota_observations", "index:quota_observations_retention"],
              try schemaSQL(type: "table", name: "quota_observations") == normalizedSQL(Self.createTableSQL),
              try schemaSQL(type: "index", name: "quota_observations_retention") == normalizedSQL(Self.createRetentionIndexSQL),
              try columns() == Self.expectedColumns,
              try indexColumns() == ["observed_at"] else {
            throw QuotaObservationStoreError.schemaFailed
        }
    }

    private func columns() throws -> [SchemaColumn] {
        let statement = try prepare("PRAGMA table_info(quota_observations);")
        defer { sqlite3_finalize(statement) }
        var columns: [SchemaColumn] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let name = stringColumn(statement, index: 1),
                  let type = stringColumn(statement, index: 2),
                  sqlite3_column_type(statement, 4) == SQLITE_NULL else {
                throw QuotaObservationStoreError.schemaFailed
            }
            columns.append(SchemaColumn(
                position: Int(sqlite3_column_int(statement, 0)),
                name: name,
                type: type,
                isNotNull: sqlite3_column_int(statement, 3) == 1,
                primaryKeyPosition: Int(sqlite3_column_int(statement, 5))
            ))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.schemaFailed }
        return columns
    }

    private func schemaSQL(type: String, name: String) throws -> String {
        let statement = try prepare("SELECT sql FROM sqlite_master WHERE type = ? AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(type, at: 1, in: statement)
        bind(name, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let sql = stringColumn(statement, index: 0),
              sqlite3_step(statement) == SQLITE_DONE else { throw QuotaObservationStoreError.schemaFailed }
        return normalizedSQL(sql)
    }

    private func indexColumns() throws -> [String] {
        let statement = try prepare("PRAGMA index_info(quota_observations_retention);")
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard Int(sqlite3_column_int(statement, 0)) == columns.count,
                  let name = stringColumn(statement, index: 2) else { throw QuotaObservationStoreError.schemaFailed }
            columns.append(name)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaObservationStoreError.schemaFailed }
        return columns
    }

    private func normalizedSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: " ;", with: ";")
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .lowercased()
            .replacingOccurrences(of: "create table if not exists ", with: "create table ")
            .replacingOccurrences(of: "create index if not exists ", with: "create index ")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw QuotaObservationStoreError.schemaFailed }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QuotaObservationStoreError.schemaFailed
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?, error: QuotaObservationStoreError) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}

public struct QuotaFindingAnalysisSnapshot: Equatable, Sendable {
    public let forecasts: [QuotaWindowIdentity: QuotaInsightState]
    public let anomalies: [QuotaWindowIdentity: QuotaAnomalyState]
    public let claudeExplanations: ClaudeQuotaExplanationCatalog

    public init(
        forecasts: [QuotaWindowIdentity: QuotaInsightState],
        anomalies: [QuotaWindowIdentity: QuotaAnomalyState],
        claudeExplanations: ClaudeQuotaExplanationCatalog = .empty
    ) {
        self.forecasts = forecasts
        self.anomalies = anomalies
        self.claudeExplanations = claudeExplanations
    }

    public static let empty = QuotaFindingAnalysisSnapshot(forecasts: [:], anomalies: [:])
}

public actor QuotaInsightsService {
    private let store: SQLiteQuotaObservationStore

    public init(store: SQLiteQuotaObservationStore) {
        self.store = store
    }

    public static func live(applicationSupportDirectory: URL) throws -> QuotaInsightsService {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        return try QuotaInsightsService(store: SQLiteQuotaObservationStore(
            path: applicationSupportDirectory.appendingPathComponent("quota-observations.sqlite").path
        ))
    }

    public func recordClaude(_ snapshot: ClaudeRateLimitSnapshot, now: Date) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try record(MeasuredQuotaObservationAdapter.claude(snapshot), now: now, maximumAge: QuotaObservationAdapter.claudeMaximumAge)
    }

    public func recordClaudeAnalysis(_ snapshot: ClaudeRateLimitSnapshot, now: Date) throws -> QuotaFindingAnalysisSnapshot {
        _ = try recordClaude(snapshot, now: now)
        let forecasts = try reevaluateClaude(now: now)
        let anomalies = try reevaluateClaudeAnomalies(now: now)
        return QuotaFindingAnalysisSnapshot(forecasts: forecasts, anomalies: anomalies, claudeExplanations: try claudeExplanationCatalog(now: now))
    }

    public func recordCodex(_ snapshot: CodexRateLimitSnapshot, now: Date) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try record(MeasuredQuotaObservationAdapter.codex(snapshot), now: now, maximumAge: QuotaObservationAdapter.codexMaximumAge)
    }

    public func recordCodexAnalysis(_ snapshot: CodexRateLimitSnapshot, now: Date) throws -> QuotaFindingAnalysisSnapshot {
        _ = try recordCodex(snapshot, now: now)
        let forecasts = try reevaluateCodex(now: now)
        let anomalies = try reevaluateCodexAnomalies(now: now)
        return QuotaFindingAnalysisSnapshot(forecasts: forecasts, anomalies: anomalies)
    }

    public func reevaluateClaude(now: Date) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try reevaluate(product: .claudeCode, now: now, maximumAge: QuotaObservationAdapter.claudeMaximumAge)
    }

    public func reevaluateClaudeAnalysis(now: Date) throws -> QuotaFindingAnalysisSnapshot {
        let forecasts = try reevaluateClaude(now: now)
        let anomalies = try reevaluateClaudeAnomalies(now: now)
        return QuotaFindingAnalysisSnapshot(forecasts: forecasts, anomalies: anomalies, claudeExplanations: try claudeExplanationCatalog(now: now))
    }

    public func reevaluateCodex(now: Date) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try reevaluate(product: .codex, now: now, maximumAge: QuotaObservationAdapter.codexMaximumAge)
    }

    public func reevaluateCodexAnalysis(now: Date) throws -> QuotaFindingAnalysisSnapshot {
        let forecasts = try reevaluateCodex(now: now)
        let anomalies = try reevaluateCodexAnomalies(now: now)
        return QuotaFindingAnalysisSnapshot(forecasts: forecasts, anomalies: anomalies)
    }

    public func reevaluateClaudeAnomalies(now: Date) throws -> [QuotaWindowIdentity: QuotaAnomalyState] {
        try reevaluateAnomalies(product: .claudeCode, now: now, maximumAge: QuotaObservationAdapter.claudeMaximumAge)
    }

    public func claudeExplanationCatalog(now: Date) throws -> ClaudeQuotaExplanationCatalog {
        let observations = try store.identities(for: .claudeCode, now: now).flatMap {
            try store.observations(for: $0, now: now)
        }
        return ClaudeQuotaExplanationEngine.catalog(
            observations: observations.map {
                ClaudeScopedQuotaObservation(observation: $0, accountIdentity: nil, unit: .percentageUsed)
            },
            evidence: [],
            source: .unavailable([.receiverNotConfigured, .accountBindingUnavailable]),
            evidenceLimitations: [],
            now: now
        )
    }

    public func reevaluateCodexAnomalies(now: Date) throws -> [QuotaWindowIdentity: QuotaAnomalyState] {
        try reevaluateAnomalies(product: .codex, now: now, maximumAge: QuotaObservationAdapter.codexMaximumAge)
    }

    public func deleteAll() throws {
        try store.deleteAll()
    }

    private func record(
        _ observations: [MeasuredQuotaObservation],
        now: Date,
        maximumAge: TimeInterval
    ) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try store.record(observations, now: now)
        return try findings(for: Set(observations.map(\.identity)), now: now, maximumAge: maximumAge)
    }

    private func reevaluate(
        product: ProviderProduct,
        now: Date,
        maximumAge: TimeInterval
    ) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try findings(for: Set(store.identities(for: product, now: now)), now: now, maximumAge: maximumAge)
    }

    private func findings(
        for identities: Set<QuotaWindowIdentity>,
        now: Date,
        maximumAge: TimeInterval
    ) throws -> [QuotaWindowIdentity: QuotaInsightState] {
        try Dictionary(uniqueKeysWithValues: identities.map { identity in
            let retained = try store.observations(for: identity, now: now)
            return (identity, QuotaInsightAnalytics.analyze(retained, now: now, maximumAge: maximumAge, expectedIdentity: identity))
        })
    }

    private func reevaluateAnomalies(
        product: ProviderProduct,
        now: Date,
        maximumAge: TimeInterval
    ) throws -> [QuotaWindowIdentity: QuotaAnomalyState] {
        try Dictionary(uniqueKeysWithValues: store.identities(for: product, now: now).map { identity in
            let retained = try store.observations(for: identity, now: now)
            return (
                identity,
                QuotaAnomalyAnalytics.analyze(retained, now: now, maximumAge: maximumAge, expectedIdentity: identity)
            )
        })
    }
}
