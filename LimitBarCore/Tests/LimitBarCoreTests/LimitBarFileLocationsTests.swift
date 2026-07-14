import Foundation
import Testing
@testable import LimitBarCore

@Suite("LimitBar file locations")
struct LimitBarFileLocationsTests {
    @Test("production policy resolves exactly the documented built-in resources")
    func resolvesBuiltInResources() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let applicationSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let locations = LimitBarFileLocations(homeDirectory: home, applicationSupportDirectory: applicationSupport)

        #expect(locations.codexSessionsDirectory.path == "/Users/example/.codex/sessions")
        #expect(locations.usageEventsFile.path == "/Users/example/Library/Application Support/LimitBar/usage-events.jsonl")
        #expect(locations.usageMetricsDatabase.path == "/Users/example/Library/Application Support/LimitBar/usage-metrics.sqlite")
        #expect(locations.historicalUsageDatabase.path == "/Users/example/Library/Application Support/LimitBar/historical-usage-trends.sqlite")
    }
}
