import Foundation
import Testing
@testable import LimitBarCore

@Suite("Refresh performance profile")
struct RefreshPerformanceProfileTests {
    @Test("defaults describe a short fingerprint-stable production cycle")
    func defaults() throws {
        let configuration = try RefreshProfileConfiguration.parse(arguments: [])

        #expect(configuration.scenario == .cycleFingerprintStable)
        #expect(configuration.iterations == 10)
        #expect(configuration.warmupIterations == 2)
        #expect(configuration.fixtureBytes == 100 * 1_024)
        #expect(configuration.customSourceCount == 1)
        #expect(configuration.codexFileCount == 100)
        #expect(configuration.cadenceSeconds == 0)
    }

    @Test("all profiling dimensions can be configured")
    func configuredDimensions() throws {
        let configuration = try RefreshProfileConfiguration.parse(arguments: [
            "--scenario", "cycle-fingerprint-stable",
            "--iterations", "50",
            "--warmups", "5",
            "--fixture-bytes", "10485760",
            "--custom-sources", "5",
            "--codex-files", "2000",
            "--cadence-seconds", "5",
        ])

        #expect(configuration.scenario == .cycleFingerprintStable)
        #expect(configuration.iterations == 50)
        #expect(configuration.warmupIterations == 5)
        #expect(configuration.fixtureBytes == 10 * 1_024 * 1_024)
        #expect(configuration.customSourceCount == 5)
        #expect(configuration.codexFileCount == 2_000)
        #expect(configuration.cadenceSeconds == 5)
    }

    @Test(
        "invalid configuration is rejected",
        arguments: [
            ["--scenario", "unknown"],
            ["--iterations", "0"],
            ["--warmups", "-1"],
            ["--fixture-bytes", "104857601"],
            ["--custom-sources", "101"],
            ["--codex-files", "10001"],
            ["--cadence-seconds", "-1"],
            ["--scenario", "sqlite-current-metrics-read", "--cadence-seconds", "5"],
            ["--scenario", "cycle-event-append", "--cadence-seconds", "5"],
            ["--scenario", "cycle-fingerprint-stable", "--warmups", "0"],
            ["--scenario", "cycle-event-append", "--iterations", "1", "--fixture-bytes", "104857600"],
            ["--iterations"],
            ["positional"],
        ]
    )
    func invalidConfiguration(arguments: [String]) {
        #expect(throws: RefreshProfileConfigurationError.self) {
            try RefreshProfileConfiguration.parse(arguments: arguments)
        }
    }

    @Test("statistics use nearest-rank percentiles and retain the maximum")
    func statistics() throws {
        let statistics = try RefreshProfileStatistics(milliseconds: Array(1...20).map(Double.init))

        #expect(statistics.sampleCount == 20)
        #expect(statistics.minimumMilliseconds == 1)
        #expect(statistics.medianMilliseconds == 10)
        #expect(statistics.p95Milliseconds == 19)
        #expect(statistics.maximumMilliseconds == 20)
        #expect(statistics.meanMilliseconds == 10.5)
    }

    @Test("statistics reject empty and non-finite samples")
    func invalidStatistics() {
        #expect(throws: RefreshProfileStatisticsError.self) {
            try RefreshProfileStatistics(milliseconds: [])
        }
        #expect(throws: RefreshProfileStatisticsError.self) {
            try RefreshProfileStatistics(milliseconds: [1, .infinity])
        }
    }

    @Test("profile output contains aggregate metadata and no source paths")
    func privacySafeOutput() throws {
        let output = RefreshProfileOutput(
            formatVersion: 1,
            scenarioVersion: 1,
            configuration: .init(
                scenario: .cycleFingerprintStable,
                iterations: 20,
                warmupIterations: 5,
                fixtureBytes: 100 * 1_024,
                customSourceCount: 1,
                codexFileCount: 100,
                cadenceSeconds: 5
            ),
            environment: .init(
                operatingSystemVersion: "macOS 15.5",
                architecture: "arm64",
                processorCount: 10,
                physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
                powerState: .battery
            ),
            statistics: try RefreshProfileStatistics(milliseconds: [1, 2, 3]),
            resources: .init(
                userCPUSeconds: 0.1,
                systemCPUSeconds: 0.05,
                maximumResidentSetBytes: 1_024,
                blockInputOperations: 1,
                blockOutputOperations: 2,
                voluntaryContextSwitches: 3,
                involuntaryContextSwitches: 4
            ),
            aggregateResultCount: 3,
            cadenceOverrunCount: 0
        )
        let data = try JSONEncoder().encode(output)
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains("cycle-fingerprint-stable"))
        #expect(text.contains("battery"))
        #expect(text.contains("maximumResidentSetBytes"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains(".jsonl"))
        #expect(!text.contains(".sqlite"))
    }
}
