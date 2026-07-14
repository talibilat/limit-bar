import Foundation

public struct DiagnosticVersion: Equatable, Sendable {
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

public enum DiagnosticProvider: String, CaseIterable, Equatable, Sendable {
    case anthropic
    case azureOpenAI
    case openAI
    case custom
}

public enum DiagnosticProviderState: String, CaseIterable, Equatable, Sendable {
    case notConfigured
    case connected
    case authenticationRequired
    case networkUnavailable
    case failed
    case cancelled
}

public struct DiagnosticProviderStatus: Equatable, Sendable {
    public let provider: DiagnosticProvider
    public let state: DiagnosticProviderState

    public init(provider: DiagnosticProvider, state: DiagnosticProviderState) {
        self.provider = provider
        self.state = state
    }
}

public enum DiagnosticDatabaseState: String, CaseIterable, Equatable, Sendable {
    case available
    case unavailable
}

public struct DiagnosticImportCounts: Equatable, Sendable {
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

public enum DiagnosticResourceLimitReason: String, CaseIterable, Equatable, Sendable {
    case rateLimited
    case responseTooLarge
    case importLimitReached
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

    public init(
        generatedAt: Date,
        appVersion: DiagnosticVersion,
        appBuild: Int,
        operatingSystemVersion: DiagnosticVersion,
        providerStatuses: [DiagnosticProviderStatus],
        databaseState: DiagnosticDatabaseState,
        importCounts: DiagnosticImportCounts,
        resourceLimitReasons: Set<DiagnosticResourceLimitReason>
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

        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.operatingSystemVersion = operatingSystemVersion
        self.providerStatuses = providerStatuses
        self.databaseState = databaseState
        self.importCounts = importCounts
        self.resourceLimitReasons = resourceLimitReasons
    }
}

public enum DiagnosticExportError: Error, Equatable {
    case invalidVersion
    case invalidImportCount
    case invalidTimestamp
    case duplicateProvider
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

public enum DiagnosticExport {
    public static let currentSchemaVersion = 1

    public static func make(from input: DiagnosticExportInput) throws -> DiagnosticExportArtifact {
        let report = Report(
            schemaVersion: currentSchemaVersion,
            generatedAt: roundedDownToMinute(input.generatedAt),
            application: Application(version: Version(input.appVersion), build: input.appBuild),
            operatingSystem: OperatingSystem(version: Version(input.operatingSystemVersion)),
            providers: input.providerStatuses
                .sorted { $0.provider.rawValue < $1.provider.rawValue }
                .map { Provider(provider: $0.provider.rawValue, state: $0.state.rawValue) },
            database: Database(state: input.databaseState.rawValue),
            imports: Imports(accepted: input.importCounts.accepted, rejected: input.importCounts.rejected),
            resourceLimitReasons: input.resourceLimitReasons.map(\.rawValue).sorted()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(report)
        bytes.append(0x0A)
        return DiagnosticExportArtifact(bytes: bytes)
    }

    private static func roundedDownToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }
}

private struct Report: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let application: Application
    let operatingSystem: OperatingSystem
    let providers: [Provider]
    let database: Database
    let imports: Imports
    let resourceLimitReasons: [String]
}

private struct Application: Encodable {
    let version: Version
    let build: Int
}

private struct OperatingSystem: Encodable {
    let version: Version
}

private struct Version: Encodable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ version: DiagnosticVersion) {
        major = version.major
        minor = version.minor
        patch = version.patch
    }
}

private struct Provider: Encodable {
    let provider: String
    let state: String
}

private struct Database: Encodable {
    let state: String
}

private struct Imports: Encodable {
    let accepted: Int
    let rejected: Int
}
