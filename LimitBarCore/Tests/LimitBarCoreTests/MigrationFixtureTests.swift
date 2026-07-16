import Foundation
import LimitBarMigrationValidation
import Testing

@Suite("Release migration fixtures")
struct MigrationFixtureTests {
    @Test("every declared fixture migrates without record loss")
    func validatesManifest() throws {
        let fixtureDirectory = fixtureDirectory

        let report = try MigrationFixtureValidator.validateManifest(
            at: fixtureDirectory.appendingPathComponent("manifest.json")
        )

        #expect(report.fixtureCount == 8)
    }

    @Test(arguments: ["logicalSchema", "releaseRange"])
    func requiresSchemaOwnershipMetadata(field: String) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        for source in try FileManager.default.contentsOfDirectory(
            at: fixtureDirectory,
            includingPropertiesForKeys: nil
        ) where source.pathExtension == "sql" {
            try FileManager.default.copyItem(
                at: source,
                to: temporaryDirectory.appendingPathComponent(source.lastPathComponent)
            )
        }

        var manifest = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixtureDirectory.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        var fixtures = try #require(manifest["fixtures"] as? [[String: Any]])
        fixtures[0].removeValue(forKey: field)
        manifest["fixtures"] = fixtures
        let manifestURL = temporaryDirectory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        #expect(throws: DecodingError.self) {
            try MigrationFixtureValidator.validateManifest(at: manifestURL)
        }
    }

    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Migrations", isDirectory: true)
    }
}
