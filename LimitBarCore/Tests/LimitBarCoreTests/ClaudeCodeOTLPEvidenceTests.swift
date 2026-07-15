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
        #expect(result.omittedFieldCategories.contains(.contentBearing))
        #expect(result.omittedFieldCategories.contains(.accountLabel))
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
    }

    private func fixture(_ name: String) throws -> Data {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ClaudeCodeOTLP/\(name).json")
        return try Data(contentsOf: file)
    }
}
