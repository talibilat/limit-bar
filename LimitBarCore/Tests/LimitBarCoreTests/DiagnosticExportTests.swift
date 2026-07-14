import Foundation
import Testing
@testable import LimitBarCore

@Suite("Diagnostic export")
struct DiagnosticExportTests {
    @Test("export is a deterministic versioned positive allow-list")
    func deterministicSchema() throws {
        let first = try DiagnosticExport.make(from: input(providerStatuses: [
            DiagnosticProviderStatus(provider: .openAI, state: .networkUnavailable),
            DiagnosticProviderStatus(provider: .anthropic, state: .connected),
        ]))
        let second = try DiagnosticExport.make(from: input(providerStatuses: [
            DiagnosticProviderStatus(provider: .anthropic, state: .connected),
            DiagnosticProviderStatus(provider: .openAI, state: .networkUnavailable),
        ]))

        #expect(first.bytes == second.bytes)
        let object = try #require(JSONSerialization.jsonObject(with: first.bytes) as? [String: Any])
        #expect(Set(object.keys) == [
            "schemaVersion", "generatedAt", "application", "operatingSystem", "providers", "database",
            "imports", "resourceLimitReasons",
        ])
        #expect(object["schemaVersion"] as? Int == DiagnosticExport.currentSchemaVersion)
        #expect(Set(try dictionary(object, key: "application").keys) == ["version", "build"])
        #expect(Set(try dictionary(object, key: "operatingSystem").keys) == ["version"])
        #expect(Set(try dictionary(object, key: "database").keys) == ["state"])
        #expect(Set(try dictionary(object, key: "imports").keys) == ["accepted", "rejected"])
        let providers = try #require(object["providers"] as? [[String: Any]])
        #expect(providers.allSatisfy { Set($0.keys) == ["provider", "state"] })
        #expect(providers.compactMap { $0["provider"] as? String } == ["anthropic", "openAI"])
    }

    @Test("all timestamps are rounded down to a minute")
    func timestampPrecision() throws {
        let artifact = try DiagnosticExport.make(from: input(generatedAt: Date(timeIntervalSince1970: 1_720_000_019.999)))
        let object = try #require(JSONSerialization.jsonObject(with: artifact.bytes) as? [String: Any])

        #expect(object["generatedAt"] as? String == "2024-07-03T09:46:00Z")
        #expect(try artifact.preview.contains("2024-07-03T09:46:00Z"))
    }

    @Test("preview bytes exactly equal explicitly saved bytes")
    func previewEqualsSavedBytes() throws {
        let artifact = try DiagnosticExport.make(from: input())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostic.json")

        try artifact.save(to: destination)

        #expect(artifact.previewBytes == artifact.bytes)
        #expect(try Data(contentsOf: destination) == artifact.previewBytes)
        #expect(try artifact.preview.data(using: .utf8) == artifact.bytes)
    }

    @Test("schema omits refresh history and every prohibited content category")
    func prohibitedContentSentinels() throws {
        let artifact = try DiagnosticExport.make(from: input())
        let text = try artifact.preview
        let prohibitedKeys = [
            "history", "refreshHistory", "headers", "url", "query", "request", "response", "body", "token",
            "credential", "keychain", "stackTrace", "errorMessage", "log", "prompt", "code", "terminalOutput",
            "path", "fileName", "accountLabel", "organizationLabel", "projectLabel", "sourceName", "modelLabel",
            "deploymentLabel", "payload", "databaseCopy", "jsonl",
        ]
        let prohibitedSentinels = [
            "HEADER_SECRET", "QUERY_VALUE", "REQUEST_BODY", "RESPONSE_BODY", "TOKEN_SECRET", "CREDENTIAL_SECRET",
            "KEYCHAIN_SECRET", "STACK_TRACE", "ARBITRARY_ERROR", "LOG_SECRET", "PROMPT_SECRET", "SOURCE_CODE",
            "MODEL_RESPONSE", "TERMINAL_OUTPUT", "/Users/private/work", "PRIVATE_FILE_NAME", "ACCOUNT_LABEL",
            "ORGANIZATION_LABEL", "PROJECT_LABEL", "SOURCE_NAME", "MODEL_LABEL", "DEPLOYMENT_LABEL",
            "PROVIDER_PAYLOAD", "DATABASE_COPY", "JSONL_CONTENT",
        ]
        let object = try JSONSerialization.jsonObject(with: artifact.bytes)
        let allKeys = keys(in: object)

        for key in prohibitedKeys {
            #expect(!allKeys.contains(key))
        }
        for sentinel in prohibitedSentinels {
            #expect(!text.contains(sentinel))
        }
    }

    @Test("invalid values and duplicate providers are rejected")
    func validation() throws {
        #expect(throws: DiagnosticExportError.invalidVersion) {
            try DiagnosticVersion(major: -1, minor: 0, patch: 0)
        }
        #expect(throws: DiagnosticExportError.invalidImportCount) {
            try DiagnosticImportCounts(accepted: 0, rejected: -1)
        }
        #expect(throws: DiagnosticExportError.duplicateProvider) {
            try input(providerStatuses: [
                DiagnosticProviderStatus(provider: .anthropic, state: .connected),
                DiagnosticProviderStatus(provider: .anthropic, state: .failed),
            ])
        }
    }

    private func input(
        generatedAt: Date = Date(timeIntervalSince1970: 1_720_000_059),
        providerStatuses: [DiagnosticProviderStatus] = [
            DiagnosticProviderStatus(provider: .anthropic, state: .connected),
        ]
    ) throws -> DiagnosticExportInput {
        try DiagnosticExportInput(
            generatedAt: generatedAt,
            appVersion: DiagnosticVersion(major: 1, minor: 2, patch: 3),
            appBuild: 42,
            operatingSystemVersion: DiagnosticVersion(major: 15, minor: 5, patch: 0),
            providerStatuses: providerStatuses,
            databaseState: .available,
            importCounts: DiagnosticImportCounts(accepted: 12, rejected: 2),
            resourceLimitReasons: [.rateLimited, .responseTooLarge]
        )
    }

    private func dictionary(_ object: [String: Any], key: String) throws -> [String: Any] {
        try #require(object[key] as? [String: Any])
    }

    private func keys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { result, element in
                result.formUnion(keys(in: element.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: []) { result, element in
                result.formUnion(keys(in: element))
            }
        }
        return []
    }
}
