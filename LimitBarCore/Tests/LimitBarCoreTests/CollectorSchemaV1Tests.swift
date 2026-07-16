import Foundation
import Testing
@testable import LimitBarCore

@Suite("Collector schema v1")
struct CollectorSchemaV1Tests {
    private let eventID = "FA2D37C5-1C49-49C8-88C4-6EEBE339C6C7"

    @Test("round trips provider and custom-source identities")
    func roundTripsIdentities() throws {
        let timestamp = try #require(CollectorSchemaV1.parseTimestamp("2026-07-12T10:00:00Z"))
        let typedEventID = try #require(UUID(uuidString: eventID))
        let customSourceID = try #require(UUID(uuidString: "9598575e-259b-47df-9f34-f161c9015e65"))
        let provider = CollectorEventV1(eventID: typedEventID, identity: .provider(.azureOpenAI), timestamp: timestamp, model: "gpt-4o", deployment: "production", inputTokens: 12, outputTokens: 3)
        let custom = CollectorEventV1(eventID: typedEventID, identity: .customSource(customSourceID), timestamp: timestamp, model: "local", inputTokens: 1, outputTokens: 2)

        #expect(try CollectorSchemaV1.decode(CollectorSchemaV1.encode(provider)) == provider)
        #expect(try CollectorSchemaV1.decode(CollectorSchemaV1.encode(custom)) == custom)
    }

    @Test("rejects content-bearing and arbitrary fields", arguments: [
        "prompt", "code", "response", "terminal", "terminalOutput", "requestBody", "rawPayload", "metadata", "credentials"
    ])
    func rejectsContentBearingFields(field: String) {
        let request = validJSON(inserting: "\"\(field)\":\"private\",")
        #expect(throws: CollectorSchemaError.unknownField(field)) {
            try CollectorSchemaV1.decode(Data(request.utf8))
        }
    }

    @Test("rejects malformed versions, identities, labels, deployments, and counters")
    func rejectsAdversarialValues() {
        assertError(.invalidSchemaVersion, replacing: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        assertError(.invalidSchemaVersion, replacing: "\"schemaVersion\":1", with: "\"schemaVersion\":true")
        assertError(.invalidIdentity, replacing: "\"provider\":\"openAI\"", with: "\"provider\":\"OpenAI\"")
        assertError(.invalidIdentity, replacing: "\"provider\":\"openAI\"", with: "\"provider\":\"openAI\",\"customSourceID\":\"9598575e-259b-47df-9f34-f161c9015e65\"")
        assertError(.invalidLabel("model"), replacing: "\"model\":\"gpt-4o\"", with: "\"model\":\" \\n \"")
        assertError(.invalidCounter("inputTokens"), replacing: "\"inputTokens\":1", with: "\"inputTokens\":-1")
        assertError(.invalidCounter("inputTokens"), replacing: "\"inputTokens\":1", with: "\"inputTokens\":1.5")
        assertError(.invalidCounter("inputTokens"), replacing: "\"inputTokens\":1", with: "\"inputTokens\":true")
        assertError(.deploymentNotAllowed, inserting: "\"deployment\":\"prod\",")
    }

    @Test("rejects requests over 16 KiB before parsing")
    func rejectsOversizedRequest() {
        #expect(throws: CollectorSchemaError.requestTooLarge) {
            try CollectorSchemaV1.decode(Data(repeating: 0x20, count: CollectorSchemaV1.maximumRequestBytes + 1))
        }
    }

    @Test("rejects non-UTF-8 JSON encodings")
    func rejectsNonUTF8JSON() throws {
        let utf16 = try #require(validJSON().data(using: .utf16))
        #expect(throws: CollectorSchemaError.malformedJSON) {
            try CollectorSchemaV1.decode(utf16)
        }
    }

    private func assertError(_ expected: CollectorSchemaError, replacing target: String? = nil, with replacement: String = "", inserting: String = "") {
        var request = validJSON(inserting: inserting)
        if let target { request = request.replacingOccurrences(of: target, with: replacement) }
        #expect(throws: expected) { try CollectorSchemaV1.decode(Data(request.utf8)) }
    }

    private func validJSON(inserting field: String = "") -> String {
        "{\(field)\"schemaVersion\":1,\"eventID\":\"\(eventID)\",\"provider\":\"openAI\",\"timestamp\":\"2026-07-12T10:00:00Z\",\"model\":\"gpt-4o\",\"inputTokens\":1,\"outputTokens\":2}"
    }
}
