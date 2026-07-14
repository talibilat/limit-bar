import Foundation

public struct DiagnosticVersion: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) throws {
        guard major >= 0, minor >= 0, patch >= 0 else {
            throw DiagnosticExportError.invalidVersion
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public enum DiagnosticProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case anthropic
    case azureOpenAI
    case openAI
    case custom
}

public enum DiagnosticProviderState: String, Codable, CaseIterable, Equatable, Sendable {
    case notConfigured
    case configured
    case connected
    case authenticationRequired
    case networkUnavailable
    case failed
    case cancelled
}

public struct DiagnosticProviderStatus: Codable, Equatable, Sendable {
    public let provider: DiagnosticProvider
    public let state: DiagnosticProviderState

    public init(provider: DiagnosticProvider, state: DiagnosticProviderState) {
        self.provider = provider
        self.state = state
    }
}

public enum DiagnosticDatabaseState: String, Codable, CaseIterable, Equatable, Sendable {
    case available
    case unavailable
}

public struct DiagnosticImportCounts: Codable, Equatable, Sendable {
    public let accepted: Int
    public let rejected: Int

    public init(accepted: Int, rejected: Int) throws {
        guard accepted >= 0, rejected >= 0 else {
            throw DiagnosticExportError.invalidImportCount
        }
        self.accepted = accepted
        self.rejected = rejected
    }
}

public enum DiagnosticResourceLimitReason: String, Codable, CaseIterable, Equatable, Sendable {
    case rateLimited
    case responseTooLarge
    case importLimitReached
}

public enum DiagnosticRefreshHistoryRole: String, Codable, CaseIterable, Equatable, Sendable {
    case latest
    case lastFullSuccess
}

public enum DiagnosticRefreshProduct: String, Codable, CaseIterable, Equatable, Sendable {
    case anthropicAPI = "anthropic_api"
    case openAIAPI = "openai_api"
}

public enum DiagnosticRefreshOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case success
    case partialFailure = "partial_failure"
    case cancelled
    case authenticationFailure = "authentication_failure"
    case networkFailure = "network_failure"
    case failed
}

public enum DiagnosticRefreshDuration: String, Codable, CaseIterable, Equatable, Sendable {
    case underOneSecond = "under_1_second"
    case oneToFiveSeconds = "1_to_5_seconds"
    case fiveToThirtySeconds = "5_to_30_seconds"
    case overThirtySeconds = "over_30_seconds"
}

public enum DiagnosticRefreshWindowKind: String, Codable, CaseIterable, Equatable, Sendable {
    case today
    case currentWeek
}

public struct DiagnosticRefreshHistoryRecord: Codable, Equatable, Sendable {
    public let role: DiagnosticRefreshHistoryRole
    public let product: DiagnosticRefreshProduct
    public let outcome: DiagnosticRefreshOutcome
    public let startedAt: Date
    public let duration: DiagnosticRefreshDuration
    public let affectedWindowKinds: [DiagnosticRefreshWindowKind]

    public init(
        role: DiagnosticRefreshHistoryRole,
        product: DiagnosticRefreshProduct,
        outcome: DiagnosticRefreshOutcome,
        startedAt: Date,
        duration: DiagnosticRefreshDuration,
        affectedWindowKinds: [DiagnosticRefreshWindowKind]
    ) throws {
        guard startedAt.timeIntervalSince1970.isFinite else {
            throw DiagnosticExportError.invalidTimestamp
        }
        guard !affectedWindowKinds.isEmpty,
              Set(affectedWindowKinds.map(\.rawValue)).count == affectedWindowKinds.count else {
            throw DiagnosticExportError.invalidRefreshHistory
        }
        self.role = role
        self.product = product
        self.outcome = outcome
        self.startedAt = startedAt
        self.duration = duration
        self.affectedWindowKinds = affectedWindowKinds.sorted { $0.rawValue < $1.rawValue }
    }
}

public enum DiagnosticQuotaProduct: String, Codable, CaseIterable, Equatable, Sendable {
    case claudeCode = "claude_code"
    case codex
}

public enum DiagnosticQuotaWindowKind: String, Codable, CaseIterable, Equatable, Sendable {
    case session
    case weekly
    case other
}

public enum DiagnosticQuotaFindingStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case qualified
    case insufficientObservations = "insufficient_observations"
    case insufficientSpan = "insufficient_span"
    case staleEvidence = "stale_evidence"
    case resetOrExpired = "reset_or_expired"
    case counterDecreased = "counter_decreased"
    case noPositiveBurn = "no_positive_burn"
}

public struct DiagnosticNumberRange: Codable, Equatable, Sendable {
    public let lower: Double
    public let upper: Double

    public init(lower: Double, upper: Double) throws {
        guard lower.isFinite, upper.isFinite, lower >= 0, upper >= lower, upper <= 10_000 else {
            throw DiagnosticExportError.invalidQuotaFindings
        }
        self.lower = lower
        self.upper = upper
    }
}

public struct DiagnosticQuotaFinding: Codable, Equatable, Sendable {
    public let product: DiagnosticQuotaProduct
    public let windowKind: DiagnosticQuotaWindowKind
    public let status: DiagnosticQuotaFindingStatus
    public let measuredObservationCount: Int
    public let measuredSpanMinutes: Int
    public let calculatedBurnPercentPerHour: DiagnosticNumberRange?
    public let calculatedExhaustionMinutes: DiagnosticNumberRange?

    public init(
        product: DiagnosticQuotaProduct,
        windowKind: DiagnosticQuotaWindowKind,
        status: DiagnosticQuotaFindingStatus,
        measuredObservationCount: Int,
        measuredSpanMinutes: Int,
        calculatedBurnPercentPerHour: DiagnosticNumberRange? = nil,
        calculatedExhaustionMinutes: DiagnosticNumberRange? = nil
    ) throws {
        guard (0...SQLiteQuotaObservationStore.maximumObservationsPerWindow).contains(measuredObservationCount),
              (0...43_200).contains(measuredSpanMinutes),
              status == .qualified || (calculatedBurnPercentPerHour == nil && calculatedExhaustionMinutes == nil),
              status != .qualified || calculatedBurnPercentPerHour != nil else {
            throw DiagnosticExportError.invalidQuotaFindings
        }
        self.product = product
        self.windowKind = windowKind
        self.status = status
        self.measuredObservationCount = measuredObservationCount
        self.measuredSpanMinutes = measuredSpanMinutes
        self.calculatedBurnPercentPerHour = calculatedBurnPercentPerHour
        self.calculatedExhaustionMinutes = calculatedExhaustionMinutes
    }
}

public struct DiagnosticExportInput: Equatable, Sendable {
    public let generatedAt: Date
    public let appVersion: DiagnosticVersion
    public let appBuild: Int
    public let operatingSystemVersion: DiagnosticVersion
    public let providerStatuses: [DiagnosticProviderStatus]
    public let databaseState: DiagnosticDatabaseState
    public let importCounts: DiagnosticImportCounts
    public let resourceLimitReasons: Set<DiagnosticResourceLimitReason>
    public let refreshHistory: [DiagnosticRefreshHistoryRecord]?
    public let quotaFindings: [DiagnosticQuotaFinding]?

    public init(
        generatedAt: Date,
        appVersion: DiagnosticVersion,
        appBuild: Int,
        operatingSystemVersion: DiagnosticVersion,
        providerStatuses: [DiagnosticProviderStatus],
        databaseState: DiagnosticDatabaseState,
        importCounts: DiagnosticImportCounts,
        resourceLimitReasons: Set<DiagnosticResourceLimitReason>,
        refreshHistory: [DiagnosticRefreshHistoryRecord]? = nil,
        quotaFindings: [DiagnosticQuotaFinding]? = nil
    ) throws {
        guard generatedAt.timeIntervalSince1970.isFinite else {
            throw DiagnosticExportError.invalidTimestamp
        }
        guard appBuild >= 0 else {
            throw DiagnosticExportError.invalidVersion
        }
        guard Set(providerStatuses.map(\.provider)).count == providerStatuses.count else {
            throw DiagnosticExportError.duplicateProvider
        }
        guard refreshHistory.map({ $0.count <= DiagnosticExport.maximumRefreshHistoryRecords }) ?? true else {
            throw DiagnosticExportError.invalidRefreshHistory
        }
        guard quotaFindings.map({ $0.count <= DiagnosticExport.maximumQuotaFindings }) ?? true else {
            throw DiagnosticExportError.invalidQuotaFindings
        }

        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.operatingSystemVersion = operatingSystemVersion
        self.providerStatuses = providerStatuses
        self.databaseState = databaseState
        self.importCounts = importCounts
        self.resourceLimitReasons = resourceLimitReasons
        self.refreshHistory = refreshHistory
        self.quotaFindings = quotaFindings
    }
}

public enum DiagnosticExportError: Error, Equatable {
    case invalidVersion
    case invalidImportCount
    case invalidTimestamp
    case duplicateProvider
    case invalidRefreshHistory
    case invalidQuotaFindings
    case unsupportedSchemaVersion(Int)
    case malformedArtifact
    case previewEncodingFailed
}

public struct DiagnosticExportArtifact: Equatable, Sendable {
    public let bytes: Data

    public var previewBytes: Data { bytes }

    public var preview: String {
        get throws {
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw DiagnosticExportError.previewEncodingFailed
            }
            return value
        }
    }

    public func save(to destination: URL) throws {
        try bytes.write(to: destination, options: .atomic)
    }
}

public struct DiagnosticExportReport: Codable, Equatable, Sendable {
    public struct Application: Codable, Equatable, Sendable {
        public let version: DiagnosticVersion
        public let build: Int
    }

    public struct OperatingSystem: Codable, Equatable, Sendable {
        public let version: DiagnosticVersion
    }

    public struct Database: Codable, Equatable, Sendable {
        public let state: DiagnosticDatabaseState
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let application: Application
    public let operatingSystem: OperatingSystem
    public let providers: [DiagnosticProviderStatus]
    public let database: Database
    public let imports: DiagnosticImportCounts
    public let resourceLimitReasons: [DiagnosticResourceLimitReason]
    public let refreshHistory: [DiagnosticRefreshHistoryRecord]?
    public let quotaFindings: [DiagnosticQuotaFinding]?
}

public typealias DiagnosticExportReportV1 = DiagnosticExportReport

private struct LegacyDiagnosticExportReportV1: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let application: DiagnosticExportReport.Application
    let operatingSystem: DiagnosticExportReport.OperatingSystem
    let providers: [DiagnosticProviderStatus]
    let database: DiagnosticExportReport.Database
    let imports: DiagnosticImportCounts
    let resourceLimitReasons: [DiagnosticResourceLimitReason]
    let refreshHistory: [DiagnosticRefreshHistoryRecord]?
}

public enum DiagnosticExport {
    public static let currentSchemaVersion = 2
    public static let maximumRefreshHistoryRecords = 20
    public static let maximumQuotaFindings = 8

    public static func make(from input: DiagnosticExportInput) throws -> DiagnosticExportArtifact {
        let report = DiagnosticExportReport(
            schemaVersion: currentSchemaVersion,
            generatedAt: roundedDownToMinute(input.generatedAt),
            application: .init(version: input.appVersion, build: input.appBuild),
            operatingSystem: .init(version: input.operatingSystemVersion),
            providers: input.providerStatuses.sorted { $0.provider.rawValue < $1.provider.rawValue },
            database: .init(state: input.databaseState),
            imports: input.importCounts,
            resourceLimitReasons: input.resourceLimitReasons.sorted { $0.rawValue < $1.rawValue },
            refreshHistory: try input.refreshHistory?.map {
                try DiagnosticRefreshHistoryRecord(
                    role: $0.role,
                    product: $0.product,
                    outcome: $0.outcome,
                    startedAt: roundedDownToMinute($0.startedAt),
                    duration: $0.duration,
                    affectedWindowKinds: $0.affectedWindowKinds
                )
            },
            quotaFindings: input.quotaFindings?.sorted {
                ($0.product.rawValue, $0.windowKind.rawValue) < ($1.product.rawValue, $1.windowKind.rawValue)
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(report)
        bytes.append(0x0A)
        return DiagnosticExportArtifact(bytes: bytes)
    }

    public static func decode(_ bytes: Data) throws -> DiagnosticExportReport {
        struct VersionEnvelope: Decodable { let schemaVersion: Int }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(VersionEnvelope.self, from: bytes) else {
            throw DiagnosticExportError.malformedArtifact
        }
        guard (1...currentSchemaVersion).contains(envelope.schemaVersion) else {
            throw DiagnosticExportError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        decoder.dateDecodingStrategy = .iso8601
        do {
            let report: DiagnosticExportReport
            if envelope.schemaVersion == 1 {
                let legacy = try decoder.decode(LegacyDiagnosticExportReportV1.self, from: bytes)
                report = DiagnosticExportReport(
                    schemaVersion: legacy.schemaVersion,
                    generatedAt: legacy.generatedAt,
                    application: legacy.application,
                    operatingSystem: legacy.operatingSystem,
                    providers: legacy.providers,
                    database: legacy.database,
                    imports: legacy.imports,
                    resourceLimitReasons: legacy.resourceLimitReasons,
                    refreshHistory: legacy.refreshHistory,
                    quotaFindings: nil
                )
            } else {
                report = try decoder.decode(DiagnosticExportReport.self, from: bytes)
            }
            let history = try report.refreshHistory?.map {
                try DiagnosticRefreshHistoryRecord(
                    role: $0.role,
                    product: $0.product,
                    outcome: $0.outcome,
                    startedAt: $0.startedAt,
                    duration: $0.duration,
                    affectedWindowKinds: $0.affectedWindowKinds
                )
            }
            _ = try DiagnosticExportInput(
                generatedAt: report.generatedAt,
                appVersion: DiagnosticVersion(
                    major: report.application.version.major,
                    minor: report.application.version.minor,
                    patch: report.application.version.patch
                ),
                appBuild: report.application.build,
                operatingSystemVersion: DiagnosticVersion(
                    major: report.operatingSystem.version.major,
                    minor: report.operatingSystem.version.minor,
                    patch: report.operatingSystem.version.patch
                ),
                providerStatuses: report.providers,
                databaseState: report.database.state,
                importCounts: DiagnosticImportCounts(
                    accepted: report.imports.accepted,
                    rejected: report.imports.rejected
                ),
                resourceLimitReasons: Set(report.resourceLimitReasons),
                refreshHistory: history,
                quotaFindings: try report.quotaFindings?.map {
                    try DiagnosticQuotaFinding(
                        product: $0.product,
                        windowKind: $0.windowKind,
                        status: $0.status,
                        measuredObservationCount: $0.measuredObservationCount,
                        measuredSpanMinutes: $0.measuredSpanMinutes,
                        calculatedBurnPercentPerHour: $0.calculatedBurnPercentPerHour.map {
                            try DiagnosticNumberRange(lower: $0.lower, upper: $0.upper)
                        },
                        calculatedExhaustionMinutes: $0.calculatedExhaustionMinutes.map {
                            try DiagnosticNumberRange(lower: $0.lower, upper: $0.upper)
                        }
                    )
                }
            )
            return report
        } catch {
            throw DiagnosticExportError.malformedArtifact
        }
    }

    private static func roundedDownToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }
}
