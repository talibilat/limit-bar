import Foundation
import Testing
@testable import LimitBarCore

@Suite("Claude Code OTLP evidence")
struct ClaudeCodeOTLPEvidenceTests {
    @Test("accepts only allow-listed Claude Code token metrics")
    func acceptsDocumentedMetric() throws {
        let result = ClaudeCodeOTLPEvidenceAdapter.scan(
            data: try fixture("valid-token-metrics"),
            identityKey: Data("local-test-key".utf8)
        )

        #expect(result.sourceStatus == .supported)
        #expect(result.evidence.count == 2)
        #expect(result.evidence.map(\.tokenType) == [.input, .output])
        #expect(result.evidence.map(\.tokenCount) == [120, 30])
        #expect(result.evidence.allSatisfy { $0.model == "claude-sonnet-4-5" })
        #expect(result.evidence.allSatisfy { $0.sourceVersion == "2.1.207" })
        #expect(result.evidence.map(\.intervalStart) == [Date(timeIntervalSince1970: 120), Date(timeIntervalSince1970: 150)])
        #expect(result.evidence.map(\.intervalEnd) == [Date(timeIntervalSince1970: 150), Date(timeIntervalSince1970: 160)])
        #expect(result.omittedFieldCategories.contains(.contentBearing))
        #expect(result.omittedFieldCategories.contains(.accountLabel))
    }

    @Test("requires documented datapoint identity and complete delta boundaries")
    func requiresDatapointAttributesAndBoundaries() throws {
        let result = ClaudeCodeOTLPEvidenceAdapter.scan(data: try fixture("missing-datapoint-boundary"), identityKey: Data("key".utf8))

        #expect(result.evidence.isEmpty)
        #expect(result.limitations.contains(.missingEvidenceBoundary))
        #expect(result.sourceStatus == .unsupportedMetric)
    }

    @Test("validated evidence factory rejects every invalid invariant")
    func validatedFactory() throws {
        let valid = try ClaudeCodeOTLPEvidence.validated(identity: digest("a"), accountIdentity: digest("b"), sessionIdentity: digest("c"), intervalStart: Date(timeIntervalSince1970: 1), intervalEnd: Date(timeIntervalSince1970: 2), model: "claude-sonnet-4-5", tokenType: .input, tokenCount: 0, sourceVersion: ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion, adapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion)
        #expect(valid.tokenCount == 0)
        #expect(throws: ClaudeCodeOTLPEvidenceValidationError.invalidInterval) {
            try ClaudeCodeOTLPEvidence.validated(identity: digest("a"), accountIdentity: digest("b"), sessionIdentity: digest("c"), intervalStart: Date(timeIntervalSince1970: 2), intervalEnd: Date(timeIntervalSince1970: 2), model: "claude", tokenType: .input, tokenCount: 0, sourceVersion: ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion, adapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion)
        }
        #expect(throws: ClaudeCodeOTLPEvidenceValidationError.invalidTokenCount) {
            try ClaudeCodeOTLPEvidence.validated(identity: digest("a"), accountIdentity: digest("b"), sessionIdentity: digest("c"), intervalStart: Date(timeIntervalSince1970: 1), intervalEnd: Date(timeIntervalSince1970: 2), model: "claude", tokenType: .input, tokenCount: -1, sourceVersion: ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion, adapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion)
        }
        #expect(throws: ClaudeCodeOTLPEvidenceValidationError.invalidModel) {
            try ClaudeCodeOTLPEvidence.validated(identity: digest("a"), accountIdentity: digest("b"), sessionIdentity: digest("c"), intervalStart: Date(timeIntervalSince1970: 1), intervalEnd: Date(timeIntervalSince1970: 2), model: "/private/model", tokenType: .input, tokenCount: 0, sourceVersion: ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion, adapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion)
        }
        #expect(throws: ClaudeCodeOTLPEvidenceValidationError.invalidDigest) {
            try ClaudeCodeOTLPEvidence.validated(identity: "raw", accountIdentity: digest("b"), sessionIdentity: digest("c"), intervalStart: Date(timeIntervalSince1970: 1), intervalEnd: Date(timeIntervalSince1970: 2), model: "claude", tokenType: .input, tokenCount: 0, sourceVersion: ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion, adapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion)
        }
        #expect(throws: ClaudeCodeOTLPEvidenceValidationError.unsupportedVersion) {
            try ClaudeCodeOTLPEvidence.validated(identity: digest("a"), accountIdentity: digest("b"), sessionIdentity: digest("c"), intervalStart: Date(timeIntervalSince1970: 1), intervalEnd: Date(timeIntervalSince1970: 2), model: "claude", tokenType: .input, tokenCount: 0, sourceVersion: "future", adapterVersion: ClaudeCodeOTLPEvidenceAdapter.adapterVersion)
        }
    }

    @Test("fails closed for unsupported versions and non-Claude metrics")
    func rejectsUnsupportedInputs() throws {
        let unsupported = ClaudeCodeOTLPEvidenceAdapter.scan(
            data: try fixture("unsupported-version"),
            identityKey: Data("local-test-key".utf8)
        )
        let generic = ClaudeCodeOTLPEvidenceAdapter.scan(
            data: try fixture("generic-anthropic"),
            identityKey: Data("local-test-key".utf8)
        )

        #expect(unsupported.sourceStatus == .unsupportedVersion)
        #expect(unsupported.evidence.isEmpty)
        #expect(generic.sourceStatus == .noClaudeCodeMetric)
        #expect(generic.evidence.isEmpty)
    }

    @Test("mixed invalid points fail closed regardless of point order")
    func mixedPointsFailClosed() throws {
        let fixtureText = try #require(String(data: try fixture("valid-token-metrics"), encoding: .utf8))
        let cases: [(String, String, ClaudeCodeOTLPSourceStatus, ClaudeEvidenceLimitation?)] = [
            (#""startTimeUnixNano": "120000000000", "#, "", .unsupportedMetric, .missingEvidenceBoundary),
            (#""startTimeUnixNano": "150000000000", "#, "", .unsupportedMetric, .missingEvidenceBoundary),
            (#"{"key": "app.version", "value": {"stringValue": "2.1.207"}}"#, #"{"key": "app.version", "value": {"stringValue": "future"}}"#, .unsupportedVersion, nil),
            (#"{"key": "app.version", "value": {"stringValue": "2.1.207"}}"#, #"{"key": "app.version", "value": {"stringValue": "future"}}"#, .unsupportedVersion, nil),
            (#""asInt": "120""#, #""asInt": "invalid""#, .unsupportedMetric, nil),
            (#""asInt": "30""#, #""asInt": "invalid""#, .unsupportedMetric, nil),
        ]

        for (index, fixtureCase) in cases.enumerated() {
            var mixed = fixtureText
            let options: String.CompareOptions = index == 3 ? .backwards : []
            let range = try #require(mixed.range(of: fixtureCase.0, options: options))
            mixed.replaceSubrange(range, with: fixtureCase.1)
            let result = ClaudeCodeOTLPEvidenceAdapter.scan(
                data: try #require(mixed.data(using: .utf8)),
                identityKey: Data("key".utf8)
            )

            #expect(result.sourceStatus == fixtureCase.2)
            #expect(result.evidence.isEmpty)
            if let limitation = fixtureCase.3 { #expect(result.limitations.contains(limitation)) }
        }
    }

    @Test("prohibited payload content never enters normalized evidence")
    func omitsProhibitedContent() throws {
        let sentinel = "PRIVATE-PROMPT-/Users/alice/work-secret-BEARER-secret"
        let data = try #require(String(data: try fixture("valid-token-metrics"), encoding: .utf8))
            .replacingOccurrences(of: "PRIVATE_SENTINEL", with: sentinel)
            .data(using: .utf8)
        let result = ClaudeCodeOTLPEvidenceAdapter.scan(data: try #require(data), identityKey: Data("key".utf8))
        let encoded = try JSONEncoder().encode(result.evidence)

        #expect(!String(decoding: encoded, as: UTF8.self).contains(sentinel))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("/Users/alice"))
        for prohibited in ["CODE_SENTINEL", "RESPONSE_SENTINEL", "TERMINAL_SENTINEL", "CREDENTIAL_SENTINEL", "RAW_PAYLOAD_SENTINEL", "ACCOUNT_LABEL_SENTINEL", "PRIVATE_PATH_SENTINEL"] {
            #expect(!String(decoding: encoded, as: UTF8.self).contains(prohibited))
        }
    }

    @Test("raw account identity and prohibited fields do not enter explanation persistence")
    func persistenceOmitsRawInput() throws {
        let rawAccount = "11111111-1111-4111-8111-111111111111"
        let scan = ClaudeCodeOTLPEvidenceAdapter.scan(data: try fixture("valid-token-metrics"), identityKey: Data("key".utf8))
        let account = try #require(scan.evidence.first?.accountIdentity)
        let identity = try QuotaWindowIdentity(product: .claudeCode, identifier: "session:session", resetBoundary: Date(timeIntervalSince1970: 600))
        let observations = try [
            MeasuredQuotaObservation(identity: identity, percentageUsed: 10, observedAt: Date(timeIntervalSince1970: 100), source: .claudeProviderReport),
            MeasuredQuotaObservation(identity: identity, percentageUsed: 12, observedAt: Date(timeIntervalSince1970: 200), source: .claudeProviderReport)
        ]
        let state = ClaudeQuotaExplanationEngine.explain(
            observations: observations,
            evidence: scan.evidence,
            expectedAccountIdentity: account,
            sourceConfigured: true,
            now: Date(timeIntervalSince1970: 250)
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try SQLiteClaudeExplanationStore(path: url.path).record(state, now: Date(timeIntervalSince1970: 250))
        let bytes = try Data(contentsOf: url)
        let persisted = String(decoding: bytes, as: UTF8.self)

        #expect(!persisted.contains(rawAccount))
        #expect(!persisted.contains("PRIVATE_SENTINEL"))
        #expect(!persisted.contains("workspace.host_paths"))
        for prohibited in ["CODE_SENTINEL", "RESPONSE_SENTINEL", "TERMINAL_SENTINEL", "CREDENTIAL_SENTINEL", "RAW_PAYLOAD_SENTINEL", "ACCOUNT_LABEL_SENTINEL", "PRIVATE_PATH_SENTINEL"] {
            #expect(!persisted.contains(prohibited))
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ClaudeCodeOTLP/\(name).json")
        return try Data(contentsOf: file)
    }
}

private func digest(_ character: Character) -> String { String(repeating: character, count: 64) }
