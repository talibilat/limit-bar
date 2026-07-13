import Foundation
import Testing
@testable import LimitBarCore

@Suite("Collector command")
struct CollectorCommandTests {
    @Test("help succeeds without writing")
    func help() throws {
        #expect(try CollectorCommand.run(["--help"]) == CollectorCommand.usage)
    }

    @Test("writes a provider event and reports an identical retry")
    func writesAndRetries() throws {
        let output = temporaryOutput()
        let arguments = providerArguments(output: output)

        #expect(try CollectorCommand.run(arguments) == "accepted")
        #expect(try CollectorCommand.run(arguments) == "duplicate")
        #expect(try Data(contentsOf: output).split(separator: 0x0A).count == 1)
    }

    @Test("rejects unknown, duplicate, and incomplete options")
    func rejectsInvalidArguments() {
        #expect(throws: CollectorCommandError.self) { try CollectorCommand.run(["--private", "value"]) }
        #expect(throws: CollectorCommandError.self) { try CollectorCommand.run(["--provider", "openAI", "--provider", "anthropic"]) }
        #expect(throws: CollectorCommandError.self) { try CollectorCommand.run(["--event-id"]) }
    }

    @Test("custom sources require an explicit configured output path")
    func customSourceRequiresOutput() {
        #expect(throws: CollectorCommandError.usage("Custom sources require --output with their configured JSONL path")) {
            try CollectorCommand.run([
                "--event-id", "00000000-0000-0000-0000-000000000001",
                "--custom-source-id", "00000000-0000-0000-0000-000000000099",
                "--timestamp", ISO8601DateFormatter().string(from: Date()),
                "--model", "local", "--input-tokens", "1", "--output-tokens", "2"
            ])
        }
    }

    private func providerArguments(output: URL) -> [String] {
        [
            "--event-id", "00000000-0000-0000-0000-000000000001",
            "--provider", "openAI",
            "--timestamp", ISO8601DateFormatter().string(from: Date()),
            "--model", "gpt-test",
            "--input-tokens", "1",
            "--output-tokens", "2",
            "--output", output.path
        ]
    }

    private func temporaryOutput() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("usage-events.jsonl")
    }
}
