import Foundation

public enum RefreshProfileScenario: String, CaseIterable, Codable, Sendable {
    case cycleFingerprintStable = "cycle-fingerprint-stable"
    case cycleEventAppend = "cycle-event-append"
    case builtInFingerprintStable = "built-in-fingerprint-stable"
    case builtInEventAppend = "built-in-event-append"
    case customFingerprintStable = "custom-fingerprint-stable"
    case customEventAppend = "custom-event-append"
    case sqliteCurrentMetricsRead = "sqlite-current-metrics-read"
    case codexSessionScan = "codex-session-scan"
}

public enum RefreshProfileConfigurationError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case missingValue(String)
}

public struct RefreshProfileConfiguration: Codable, Equatable, Sendable {
    public static let maximumFixtureBytes = 100 * 1_024 * 1_024
    public static let maximumCustomSourceCount = 100
    public static let maximumCodexFileCount = 10_000
    public static let maximumGeneratedJSONLBytes = 1_024 * 1_024 * 1_024
    public static let maximumIterations = 100_000
    public static let maximumWarmupIterations = 10_000
    public static let maximumCadenceSeconds = 3_600.0
    public static let maximumAppendedEventBytes = 512

    public let scenario: RefreshProfileScenario
    public let iterations: Int
    public let warmupIterations: Int
    public let fixtureBytes: Int
    public let customSourceCount: Int
    public let codexFileCount: Int
    public let cadenceSeconds: Double

    public init(
        scenario: RefreshProfileScenario,
        iterations: Int,
        warmupIterations: Int,
        fixtureBytes: Int,
        customSourceCount: Int,
        codexFileCount: Int,
        cadenceSeconds: Double
    ) {
        self.scenario = scenario
        self.iterations = iterations
        self.warmupIterations = warmupIterations
        self.fixtureBytes = fixtureBytes
        self.customSourceCount = customSourceCount
        self.codexFileCount = codexFileCount
        self.cadenceSeconds = cadenceSeconds
    }

    public static func parse(arguments: [String]) throws -> RefreshProfileConfiguration {
        var scenario = RefreshProfileScenario.cycleFingerprintStable
        var iterations = 10
        var warmups = 2
        var fixtureBytes = 100 * 1_024
        var customSources = 1
        var codexFiles = 100
        var cadenceSeconds = 0.0
        var index = 0

        func value(after argument: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw RefreshProfileConfigurationError.missingValue(argument)
            }
            return arguments[index + 1]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--scenario":
                let rawValue = try value(after: argument)
                guard let parsed = RefreshProfileScenario(rawValue: rawValue) else {
                    throw RefreshProfileConfigurationError.invalidArgument(argument)
                }
                scenario = parsed
            case "--iterations":
                let rawValue = try value(after: argument)
                guard let parsed = Int(rawValue), (1...maximumIterations).contains(parsed) else {
                    throw RefreshProfileConfigurationError.invalidArgument(argument)
                }
                iterations = parsed
            case "--warmups":
                let rawValue = try value(after: argument)
                guard let parsed = Int(rawValue), (0...maximumWarmupIterations).contains(parsed) else {
                    throw RefreshProfileConfigurationError.invalidArgument(argument)
                }
                warmups = parsed
            case "--fixture-bytes":
                let rawValue = try value(after: argument)
                guard let parsed = Int(rawValue), (0...maximumFixtureBytes).contains(parsed) else {
                    throw RefreshProfileConfigurationError.invalidArgument(argument)
                }
                fixtureBytes = parsed
            case "--custom-sources":
                let rawValue = try value(after: argument)
                guard let parsed = Int(rawValue), (0...maximumCustomSourceCount).contains(parsed) else {
                    throw RefreshProfileConfigurationError.invalidArgument(argument)
                }
                customSources = parsed
            case "--codex-files":
                let rawValue = try value(after: argument)
                guard let parsed = Int(rawValue), (0...maximumCodexFileCount).contains(parsed) else {
                    throw RefreshProfileConfigurationError.invalidArgument(argument)
                }
                codexFiles = parsed
            case "--cadence-seconds":
                let rawValue = try value(after: argument)
                guard let parsed = Double(rawValue), parsed.isFinite,
                      (0...maximumCadenceSeconds).contains(parsed) else {
                    throw RefreshProfileConfigurationError.invalidArgument(argument)
                }
                cadenceSeconds = parsed
            default:
                throw RefreshProfileConfigurationError.invalidArgument(argument)
            }
            index += 2
        }

        var appendedBytesPerSource = 0
        if scenario == .cycleEventAppend || scenario == .builtInEventAppend || scenario == .customEventAppend {
            let (appendedBytes, appendOverflow) = iterations.multipliedReportingOverflow(by: maximumAppendedEventBytes)
            guard !appendOverflow, fixtureBytes <= maximumFixtureBytes - appendedBytes else {
                throw RefreshProfileConfigurationError.invalidArgument("--fixture-bytes")
            }
            appendedBytesPerSource = appendedBytes
        }
        let (maximumBytesPerSource, sourceOverflow) = fixtureBytes.addingReportingOverflow(appendedBytesPerSource)
        let (generatedJSONLBytes, aggregateOverflow) = maximumBytesPerSource.multipliedReportingOverflow(by: customSources + 1)
        guard !sourceOverflow, !aggregateOverflow, generatedJSONLBytes <= maximumGeneratedJSONLBytes else {
            throw RefreshProfileConfigurationError.invalidArgument("--fixture-bytes")
        }
        if scenario == .cycleEventAppend, codexFiles > 0,
           appendedBytesPerSource > 8 * 1_024 * 1_024 {
            throw RefreshProfileConfigurationError.invalidArgument("--iterations")
        }
        if cadenceSeconds > 0,
           scenario != .cycleFingerprintStable {
            throw RefreshProfileConfigurationError.invalidArgument("--cadence-seconds")
        }
        if warmups == 0,
           scenario == .cycleFingerprintStable
            || scenario == .builtInFingerprintStable
            || scenario == .customFingerprintStable {
            throw RefreshProfileConfigurationError.invalidArgument("--warmups")
        }

        return RefreshProfileConfiguration(
            scenario: scenario,
            iterations: iterations,
            warmupIterations: warmups,
            fixtureBytes: fixtureBytes,
            customSourceCount: customSources,
            codexFileCount: codexFiles,
            cadenceSeconds: cadenceSeconds
        )
    }
}

public enum RefreshProfileStatisticsError: Error, Equatable, Sendable {
    case invalidSamples
}

public struct RefreshProfileStatistics: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let minimumMilliseconds: Double
    public let medianMilliseconds: Double
    public let p95Milliseconds: Double
    public let maximumMilliseconds: Double
    public let meanMilliseconds: Double

    public init(milliseconds: [Double]) throws {
        guard !milliseconds.isEmpty, milliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw RefreshProfileStatisticsError.invalidSamples
        }
        let sorted = milliseconds.sorted()
        sampleCount = sorted.count
        minimumMilliseconds = sorted[0]
        medianMilliseconds = Self.nearestRank(sorted, percentile: 0.5)
        p95Milliseconds = Self.nearestRank(sorted, percentile: 0.95)
        maximumMilliseconds = sorted[sorted.count - 1]
        meanMilliseconds = sorted.reduce(0, +) / Double(sorted.count)
    }

    private static func nearestRank(_ sorted: [Double], percentile: Double) -> Double {
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[rank - 1]
    }
}

public enum RefreshProfilePowerState: String, Codable, Sendable {
    case ac
    case battery
    case batteryLowPowerMode = "battery-low-power-mode"
    case unknown
}

public struct RefreshProfileEnvironment: Codable, Sendable {
    public let operatingSystemVersion: String
    public let architecture: String
    public let processorCount: Int
    public let physicalMemoryBytes: UInt64
    public let powerState: RefreshProfilePowerState

    public init(
        operatingSystemVersion: String,
        architecture: String,
        processorCount: Int,
        physicalMemoryBytes: UInt64,
        powerState: RefreshProfilePowerState
    ) {
        self.operatingSystemVersion = operatingSystemVersion
        self.architecture = architecture
        self.processorCount = processorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.powerState = powerState
    }
}

public struct RefreshProfileOutput: Codable, Sendable {
    public let formatVersion: Int
    public let scenarioVersion: Int
    public let configuration: RefreshProfileConfiguration
    public let environment: RefreshProfileEnvironment
    public let statistics: RefreshProfileStatistics
    public let resources: RefreshProfileResources?
    public let aggregateResultCount: Int
    public let cadenceOverrunCount: Int

    public init(
        formatVersion: Int,
        scenarioVersion: Int,
        configuration: RefreshProfileConfiguration,
        environment: RefreshProfileEnvironment,
        statistics: RefreshProfileStatistics,
        resources: RefreshProfileResources? = nil,
        aggregateResultCount: Int,
        cadenceOverrunCount: Int
    ) {
        self.formatVersion = formatVersion
        self.scenarioVersion = scenarioVersion
        self.configuration = configuration
        self.environment = environment
        self.statistics = statistics
        self.resources = resources
        self.aggregateResultCount = aggregateResultCount
        self.cadenceOverrunCount = cadenceOverrunCount
    }
}

public struct RefreshProfileResources: Codable, Equatable, Sendable {
    public let userCPUSeconds: Double
    public let systemCPUSeconds: Double
    public let maximumResidentSetBytes: UInt64
    public let blockInputOperations: Int64
    public let blockOutputOperations: Int64
    public let voluntaryContextSwitches: Int64
    public let involuntaryContextSwitches: Int64

    public init(
        userCPUSeconds: Double,
        systemCPUSeconds: Double,
        maximumResidentSetBytes: UInt64,
        blockInputOperations: Int64,
        blockOutputOperations: Int64,
        voluntaryContextSwitches: Int64,
        involuntaryContextSwitches: Int64
    ) {
        self.userCPUSeconds = userCPUSeconds
        self.systemCPUSeconds = systemCPUSeconds
        self.maximumResidentSetBytes = maximumResidentSetBytes
        self.blockInputOperations = blockInputOperations
        self.blockOutputOperations = blockOutputOperations
        self.voluntaryContextSwitches = voluntaryContextSwitches
        self.involuntaryContextSwitches = involuntaryContextSwitches
    }
}
