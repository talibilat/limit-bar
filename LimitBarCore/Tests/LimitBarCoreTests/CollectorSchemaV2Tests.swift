import Foundation
import Testing
@testable import LimitBarCore

@Suite("Collector schema v2")
struct CollectorSchemaV2Tests {
    private let eventID = UUID(uuidString: "fa2d37c5-1c49-49c8-88c4-6eebe339c6c7")!

    @Test("round trips explicit project and agent attribution")
    func roundTripsAttribution() throws {
        let event = try CollectorSchemaV2.decode(Data(validJSON().utf8))

        #expect(event.project == CollectorAttribution(id: "project-alpha", label: "Project Alpha"))
        #expect(event.agent == CollectorAttribution(id: "reviewer-1", label: "Reviewer 1"))
        #expect(try CollectorSchemaV2.decode(CollectorSchemaV2.encode(event)) == event)
    }

    @Test("allows missing attribution without inventing values")
    func allowsMissingAttribution() throws {
        let request = validJSON()
            .replacingOccurrences(of: ",\"projectID\":\"project-alpha\",\"projectLabel\":\"Project Alpha\"", with: "")
            .replacingOccurrences(of: ",\"agentID\":\"reviewer-1\",\"agentLabel\":\"Reviewer 1\"", with: "")

        let event = try CollectorSchemaV2.decode(Data(request.utf8))

        #expect(event.project == nil)
        #expect(event.agent == nil)
    }

    @Test("accepts maximum bounded ASCII attribution")
    func acceptsMaximumBounds() throws {
        let identifier = "a" + String(repeating: "b", count: CollectorSchemaV2.maximumAttributionBytes - 1)
        let label = "A" + String(repeating: "b", count: CollectorSchemaV2.maximumAttributionBytes - 1)
        let request = validJSON()
            .replacingOccurrences(of: "project-alpha", with: identifier)
            .replacingOccurrences(of: "Project Alpha", with: label)

        #expect(throws: Never.self) { try CollectorSchemaV2.decode(Data(request.utf8)) }
    }

    @Test("rejects unsafe attribution without reproducing submitted values", arguments: [
        ("projectID", ""),
        ("projectID", "project alpha"),
        ("projectID", "../private"),
        ("projectID", "projéct"),
        ("projectID", "sk-secretvalue"),
        ("projectID", String(repeating: "a", count: 65)),
        ("projectLabel", "/Users/person/private"),
        ("projectLabel", "line\\path"),
        ("projectLabel", "line\nvalue"),
        ("projectLabel", "Projéct"),
        ("projectLabel", "Bearer secret"),
        ("projectLabel", String(repeating: "a", count: 65)),
        ("agentID", "agent:value"),
        ("agentLabel", "agent=value")
    ])
    func rejectsUnsafeAttribution(field: String, value: String) {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let request = validJSON().replacingOccurrences(of: valueFor(field), with: escaped)

        #expect(throws: CollectorSchemaError.invalidAttribution(field)) {
            try CollectorSchemaV2.decode(Data(request.utf8))
        }
    }

    @Test("rejects labels without stable identifiers")
    func rejectsLabelWithoutIdentifier() {
        let request = validJSON().replacingOccurrences(of: ",\"projectID\":\"project-alpha\"", with: "")
        #expect(throws: CollectorSchemaError.invalidAttribution("projectLabel")) {
            try CollectorSchemaV2.decode(Data(request.utf8))
        }
    }

    @Test("rejects non-integer schema versions")
    func rejectsNonIntegerVersion() {
        for replacement in ["2.5", "true", "\"2\""] {
            let request = validJSON().replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":\(replacement)")
            #expect(throws: CollectorSchemaError.invalidSchemaVersion) {
                try CollectorSchemaV2.decode(Data(request.utf8))
            }
        }
    }

    @Test("uses a positive field allow-list")
    func rejectsUnknownContent() {
        let request = validJSON().replacingOccurrences(of: "{", with: "{\"prompt\":\"PRIVATE_SENTINEL\",", options: [], range: validJSON().startIndex..<validJSON().endIndex)
        #expect(throws: CollectorSchemaError.unknownField("prompt")) {
            try CollectorSchemaV2.decode(Data(request.utf8))
        }
    }

    private func valueFor(_ field: String) -> String {
        switch field {
        case "projectID": "project-alpha"
        case "projectLabel": "Project Alpha"
        case "agentID": "reviewer-1"
        default: "Reviewer 1"
        }
    }

    private func validJSON() -> String {
        "{\"schemaVersion\":2,\"eventID\":\"\(eventID.uuidString)\",\"provider\":\"openAI\",\"timestamp\":\"2026-07-12T10:00:00Z\",\"model\":\"gpt-5\",\"inputTokens\":10,\"outputTokens\":2,\"projectID\":\"project-alpha\",\"projectLabel\":\"Project Alpha\",\"agentID\":\"reviewer-1\",\"agentLabel\":\"Reviewer 1\"}"
    }
}
