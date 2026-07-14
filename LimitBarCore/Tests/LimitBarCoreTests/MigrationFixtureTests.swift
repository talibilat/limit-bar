import Foundation
import LimitBarMigrationValidation
import Testing

@Suite("Release migration fixtures")
struct MigrationFixtureTests {
    @Test("every declared fixture migrates without record loss")
    func validatesManifest() throws {
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Migrations", isDirectory: true)

        let report = try MigrationFixtureValidator.validateManifest(
            at: fixtureDirectory.appendingPathComponent("manifest.json")
        )

        #expect(report.fixtureCount == 6)
    }
}
