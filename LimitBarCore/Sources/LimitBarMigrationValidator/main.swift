import Foundation
import LimitBarMigrationValidation

@main
struct LimitBarMigrationValidatorCommand {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw CommandError.usage
        }
        let report = try MigrationFixtureValidator.validateManifest(
            at: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        print("migration validation passed: \(report.fixtureCount) synthetic schemas")
    }
}

private enum CommandError: Error {
    case usage
}
