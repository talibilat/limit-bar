import Foundation
import Testing
@testable import LimitBarCore

@Suite("Diagnostic export")
struct DiagnosticExportTests {
    @Test("export has the complete deterministic v6 positive allow-list")
    func deterministicSchema() throws {
        let first = try DiagnosticExport.make(from: input(providerStatuses: [
            DiagnosticProviderStatus(provider: .openAI, state: .networkUnavailable),
            DiagnosticProviderStatus(provider: .anthropic, state: .connected),
        ], includesHistory: true, includesQuotaFinding: true, includesCodexExplanation: true))
        let second = try DiagnosticExport.make(from: input(providerStatuses: [
            DiagnosticProviderStatus(provider: .anthropic, state: .connected),
            DiagnosticProviderStatus(provider: .openAI, state: .networkUnavailable),
        ], includesHistory: true, includesQuotaFinding: true, includesCodexExplanation: true))

        #expect(first.bytes == second.bytes)
        let object = try JSONSerialization.jsonObject(with: first.bytes)
        #expect(keySnapshot(object) == [
            "application", "application.build", "application.version", "application.version.major",
            "application.version.minor", "application.version.patch", "database", "database.state",
            "codexExplanation", "codexExplanation.adapterVersion", "codexExplanation.barrierCategories",
            "codexExplanation.coverage", "codexExplanation.evidenceCount", "codexExplanation.observationCount",
            "codexExplanation.retention", "codexExplanation.sessionCount", "codexExplanation.status", "codexExplanation.tokenEvidence",
            "generatedAt", "imports", "imports.accepted", "imports.rejected", "operatingSystem",
            "operatingSystem.version", "operatingSystem.version.major", "operatingSystem.version.minor",
            "operatingSystem.version.patch", "providers", "providers[].provider", "providers[].state",
            "refreshHistory", "refreshHistory[].affectedWindowKinds", "refreshHistory[].duration",
            "refreshHistory[].outcome", "refreshHistory[].product", "refreshHistory[].role",
            "refreshHistory[].startedAt", "quotaFindings", "quotaFindings[].calculatedBurnPercentPerHour",
            "quotaFindings[].calculatedBurnPercentPerHour.lower", "quotaFindings[].calculatedBurnPercentPerHour.upper",
            "quotaFindings[].calculatedExhaustionMinutes", "quotaFindings[].calculatedExhaustionMinutes.lower",
            "quotaFindings[].calculatedExhaustionMinutes.upper", "quotaFindings[].forecastMethod",
            "quotaFindings[].qualification",
            "quotaFindings[].measuredObservationCount",
            "quotaFindings[].measuredSpanMinutes", "quotaFindings[].product", "quotaFindings[].status",
            "quotaFindings[].windowKind", "resourceLimitReasons", "schemaVersion",
        ])
        let report = try DiagnosticExport.decode(first.bytes)
        #expect(report.schemaVersion == DiagnosticExport.currentSchemaVersion)
        #expect(report.providers.map(\.provider) == [.anthropic, .openAI])
        #expect(report.refreshHistory?.count == 1)
        #expect(report.quotaFindings?.count == 1)
        #expect(report.quotaFindings?.first?.forecastMethod == .pairwisePositiveSlopeInterquartileV2)
        #expect(report.codexExplanation?.adapterVersion == CodexRolloutEvidenceAdapter.adapterVersion)
    }

    @Test("quota evidence report is an exact bounded deterministic positive allow-list")
    func quotaEvidenceReport() throws {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        var records: [DiagnosticQuotaEvidenceRecord] = []
        for index in 0...(DiagnosticExport.maximumQuotaEvidenceRecords + 2) {
            records.append(try evidenceRecord(index: index, start: start))
        }
        let evidence = try DiagnosticQuotaEvidenceReport(
            selectedProduct: .codex,
            selectedRange: .init(start: start, end: start.addingTimeInterval(3_600), basis: .gregorianUTC),
            publicationGeneration: 7,
            publicationTime: start,
            apiProviderEvidence: .unavailable,
            records: records
        )

        let artifact = try DiagnosticExport.make(from: input(quotaEvidence: evidence))
        let report = try DiagnosticExport.decode(artifact.bytes)
        let decoded = try #require(report.quotaEvidence)
        let references = decoded.records.map { $0.traceReference }

        #expect(decoded.records.count == DiagnosticExport.maximumQuotaEvidenceRecords)
        #expect(decoded.omittedRecordCount == 3)
        #expect(references == Array(references.sorted().reversed()))
        #expect(decoded.records.first?.resetBoundary == nil)
        #expect(decoded.records.first?.resetBoundaryAvailability == .unavailable)
        #expect(decoded.records.first?.resetBoundaryProvenance == nil)
        #expect(decoded.records.first?.localBreakdown == .gap)
        #expect(decoded.records.dropFirst().allSatisfy { $0.localBreakdown == DiagnosticEvidenceState.observedZero })
        #expect(decoded.records.dropFirst().allSatisfy { $0.resetBoundaryAvailability == .available && $0.resetBoundaryProvenance == .reported })
        #expect(decoded.records.first?.anomaly.status == .unavailable)
        #expect(decoded.records.dropFirst().allSatisfy { $0.anomaly.status == DiagnosticEvidenceState.noFinding })
        #expect(artifact.previewBytes == artifact.bytes)
    }

    @Test("quota evidence rejects unbounded text before preview")
    func quotaEvidenceBounds() throws {
        #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
            try DiagnosticEvidenceVersion(kind: .adapter, value: String(repeating: "x", count: DiagnosticExport.maximumEvidenceTextLength + 1))
        }
        for unsafe in ["/Users/private", "TOKEN SECRET", "account@label", "credential:value", "..\\private"] {
            #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
                try DiagnosticEvidenceVersion(kind: .adapter, value: unsafe)
            }
        }
    }

    @Test("forecast and anomaly states require complete typed evidence")
    func analyticalEvidenceInvariants() throws {
        #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
            try DiagnosticEvidenceForecast(status: .available, method: .pairwisePositiveSlopeInterquartileV2, qualification: .qualified, unavailableReason: nil, observationCount: 4, observationSpanSeconds: 900, evidenceAgeSeconds: 10, range: nil, resetInteraction: .beforeReportedReset, evidenceTraceReferences: ["aaaaaaaaaaaa"], limitations: [.providerWeightingUnknown])
        }
        #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
            try DiagnosticEvidenceForecast(status: .unavailable, method: .pairwisePositiveSlopeInterquartileV2, qualification: .unavailable, unavailableReason: nil, observationCount: 1, observationSpanSeconds: 0, evidenceAgeSeconds: nil, range: nil, resetInteraction: .unavailable, evidenceTraceReferences: ["aaaaaaaaaaaa"], limitations: [.providerWeightingUnknown])
        }
        #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
            try DiagnosticEvidenceAnomaly(status: .noFinding, method: .trailingMedianRatioV1, qualification: .qualified, unavailableReason: nil, currentPeriod: nil, baselinePeriod: nil, measuredInputCount: 7, currentValue: nil, baselineValue: nil, result: nil, evidenceTraceReferences: ["bbbbbbbbbbbb"], limitations: [.noCausalAttribution])
        }
        #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
            try DiagnosticEvidenceAnomaly(status: .unavailable, method: .trailingMedianRatioV1, qualification: .unavailable, unavailableReason: .gap, currentPeriod: nil, baselinePeriod: nil, measuredInputCount: 0, currentValue: DiagnosticEvidenceValue(value: 1, unit: .percentagePoints, provenance: .calculated), baselineValue: nil, result: nil, evidenceTraceReferences: [], limitations: [.noCausalAttribution])
        }
        #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
            try DiagnosticEvidenceForecast(status: .unavailable, method: .pairwisePositiveSlopeInterquartileV2, qualification: .unavailable, unavailableReason: .staleEvidence, observationCount: 4, observationSpanSeconds: 900, evidenceAgeSeconds: 100, range: nil, resetInteraction: .unavailable, evidenceTraceReferences: [], limitations: [.providerWeightingUnknown])
        }
        #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
            try DiagnosticEvidenceAnomaly(status: .unavailable, method: .trailingMedianRatioV1, qualification: .unavailable, unavailableReason: .gap, currentPeriod: nil, baselinePeriod: nil, measuredInputCount: 2, currentValue: nil, baselineValue: nil, result: nil, evidenceTraceReferences: [], limitations: [.noCausalAttribution])
        }
        #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
            let traces = (0...DiagnosticExport.maximumFindingTraceCandidates).map { String(format: "%012x", $0) }
            _ = try DiagnosticEvidenceForecast(status: .unavailable, method: .notPublished, qualification: .unavailable, unavailableReason: .notPublished, observationCount: 0, observationSpanSeconds: 0, evidenceAgeSeconds: nil, range: nil, resetInteraction: .unavailable, evidenceTraceReferences: traces, limitations: [.providerWeightingUnknown])
        }
    }

    @Test("finding traces canonicalize complete shuffled inputs before truncation")
    func findingTraceTruncation() throws {
        let traces = (0..<25).map { String(format: "%012x", $0) }
        let shuffledWithDuplicates = Array(Array(traces[9...] + traces[..<9]).reversed()) + [traces[3], traces[3]]
        let forecast = try DiagnosticEvidenceForecast(
            status: .unavailable,
            method: .pairwisePositiveSlopeInterquartileV2,
            qualification: .unavailable,
            unavailableReason: .staleEvidence,
            observationCount: 25,
            observationSpanSeconds: 900,
            evidenceAgeSeconds: 100,
            range: nil,
            resetInteraction: .unavailable,
            evidenceTraceReferences: Array(shuffledWithDuplicates),
            limitations: [.providerWeightingUnknown]
        )
        let anomaly = try DiagnosticEvidenceAnomaly(
            status: .unavailable,
            method: .trailingMedianRatioV1,
            qualification: .unavailable,
            unavailableReason: .staleEvidence,
            currentPeriod: nil,
            baselinePeriod: nil,
            measuredInputCount: 25,
            currentValue: nil,
            baselineValue: nil,
            result: nil,
            evidenceTraceReferences: Array(shuffledWithDuplicates),
            limitations: [.noCausalAttribution]
        )

        #expect(forecast.traceLimit == 16)
        #expect(forecast.omittedTraceCount == 9)
        #expect(forecast.evidenceTraceReferences == Array(traces.prefix(16)))
        #expect(anomaly.traceLimit == 16)
        #expect(anomaly.omittedTraceCount == 9)
        #expect(anomaly.evidenceTraceReferences == Array(traces.prefix(16)))
        #expect(throws: DiagnosticExportError.invalidQuotaEvidence) {
            _ = try DiagnosticEvidenceForecast(status: .unavailable, method: .notPublished, qualification: .unavailable, unavailableReason: .notPublished, observationCount: 0, observationSpanSeconds: 0, evidenceAgeSeconds: nil, range: nil, resetInteraction: .unavailable, evidenceTraceReferences: ["trace/conflict"], limitations: [.providerWeightingUnknown])
        }
    }

    @Test("more than one hundred shuffled records produce identical newest-first bytes and complete omitted count")
    func quotaEvidenceLargeShuffledDeterminism() throws {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let records = try (0..<137).map { try evidenceRecord(index: $0, start: start) }
        let shuffled = Array(records[37...] + records[..<37]).reversed()
        let range = try DiagnosticEvidenceSelection(start: start, end: start.addingTimeInterval(20_000), basis: .gregorianUTC)
        let first = try DiagnosticQuotaEvidenceReport(selectedProduct: .codex, selectedRange: range, publicationGeneration: 7, publicationTime: start, apiProviderEvidence: .unavailable, records: records)
        let second = try DiagnosticQuotaEvidenceReport(selectedProduct: .codex, selectedRange: range, publicationGeneration: 7, publicationTime: start, apiProviderEvidence: .unavailable, records: Array(shuffled))

        let firstBytes = try DiagnosticExport.make(from: input(quotaEvidence: first)).bytes
        let secondBytes = try DiagnosticExport.make(from: input(quotaEvidence: second)).bytes

        #expect(firstBytes == secondBytes)
        #expect(first.omittedRecordCount == 129)
        #expect(first.records.map(\.traceReference) == (129..<137).reversed().map { String(format: "%012d", $0) })
    }

    @Test("v6 decode rejects noncanonical order and omitted counts")
    func quotaEvidenceDecodeCanonicality() throws {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let evidence = try DiagnosticQuotaEvidenceReport(
            selectedProduct: .codex,
            selectedRange: .init(start: start, end: start.addingTimeInterval(3_600), basis: .gregorianUTC),
            publicationGeneration: 7,
            publicationTime: start,
            apiProviderEvidence: .unavailable,
            records: [try evidenceRecord(index: 1, start: start), try evidenceRecord(index: 2, start: start)]
        )
        let bytes = try DiagnosticExport.make(from: input(quotaEvidence: evidence)).bytes
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var quota = try #require(object["quotaEvidence"] as? [String: Any])
        var records = try #require(quota["records"] as? [[String: Any]])
        records.swapAt(0, 1)
        quota["records"] = records
        object["quotaEvidence"] = quota
        #expect(throws: DiagnosticExportError.malformedArtifact) {
            try DiagnosticExport.decode(JSONSerialization.data(withJSONObject: object))
        }
        quota["records"] = Array(records.reversed())
        quota["omittedRecordCount"] = 3
        object["quotaEvidence"] = quota
        #expect(throws: DiagnosticExportError.malformedArtifact) {
            try DiagnosticExport.decode(JSONSerialization.data(withJSONObject: object))
        }
        object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        quota = try #require(object["quotaEvidence"] as? [String: Any])
        records = try #require(quota["records"] as? [[String: Any]])
        records[0]["resetBoundaryProvenance"] = "measured"
        quota["records"] = records
        object["quotaEvidence"] = quota
        #expect(throws: DiagnosticExportError.malformedArtifact) {
            try DiagnosticExport.decode(JSONSerialization.data(withJSONObject: object))
        }
        object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        quota = try #require(object["quotaEvidence"] as? [String: Any])
        records = try #require(quota["records"] as? [[String: Any]])
        var forecast = try #require(records[0]["forecast"] as? [String: Any])
        forecast["traceLimit"] = 15
        forecast["omittedTraceCount"] = 1
        records[0]["forecast"] = forecast
        quota["records"] = records
        object["quotaEvidence"] = quota
        #expect(throws: DiagnosticExportError.malformedArtifact) {
            try DiagnosticExport.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test("decode routes supported, unsupported, and malformed versions")
    func versionAwareDecode() throws {
        let artifact = try DiagnosticExport.make(from: input())
        #expect(try DiagnosticExport.decode(artifact.bytes).application.build == 42)
        #expect(throws: DiagnosticExportError.unsupportedSchemaVersion(7)) {
            try DiagnosticExport.decode(Data(#"{"schemaVersion":7,"privateFuturePayload":"SECRET"}"#.utf8))
        }
        #expect(throws: DiagnosticExportError.malformedArtifact) {
            try DiagnosticExport.decode(Data(#"{"schemaVersion":1}"#.utf8))
        }
        let invalidKnownVersion = try artifact.preview.replacingOccurrences(of: #""build" : 42"#, with: #""build" : -1"#)
        #expect(throws: DiagnosticExportError.malformedArtifact) {
            try DiagnosticExport.decode(Data(invalidKnownVersion.utf8))
        }
        #expect(throws: DiagnosticExportError.malformedArtifact) {
            try DiagnosticExport.decode(Data("not json".utf8))
        }
    }

    @Test("all timestamps are rounded down to a minute")
    func timestampPrecision() throws {
        let artifact = try DiagnosticExport.make(from: input(
            generatedAt: Date(timeIntervalSince1970: 1_720_000_019.999),
            includesHistory: true
        ))
        let object = try #require(JSONSerialization.jsonObject(with: artifact.bytes) as? [String: Any])

        #expect(object["generatedAt"] as? String == "2024-07-03T09:46:00Z")
        #expect(try artifact.preview.contains("2024-07-03T09:46:00Z"))
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

    @Test("optional history is absent by default and bounded when supplied")
    func optionalBoundedHistory() throws {
        let absent = try DiagnosticExport.make(from: input())
        #expect(!keySnapshot(try JSONSerialization.jsonObject(with: absent.bytes)).contains("refreshHistory"))

        let record = try historyRecord()
        #expect(throws: DiagnosticExportError.invalidRefreshHistory) {
            try DiagnosticExportInput(
                generatedAt: Date(),
                appVersion: DiagnosticVersion(major: 1, minor: 0, patch: 0),
                appBuild: 1,
                operatingSystemVersion: DiagnosticVersion(major: 15, minor: 0, patch: 0),
                providerStatuses: [],
                databaseState: .available,
                importCounts: DiagnosticImportCounts(accepted: 0, rejected: 0),
                resourceLimitReasons: [],
                refreshHistory: Array(repeating: record, count: DiagnosticExport.maximumRefreshHistoryRecords + 1)
            )
        }
    }

    @Test("pre-fetch refresh failures can report no affected windows")
    func prefetchFailureHistory() throws {
        let record = try DiagnosticRefreshHistoryRecord(
            role: .latest,
            product: .anthropicAPI,
            outcome: .failed,
            startedAt: Date(timeIntervalSince1970: 1_720_000_000),
            duration: .underOneSecond,
            affectedWindowKinds: []
        )

        let artifact = try DiagnosticExport.make(from: input(refreshHistory: [record]))
        let report = try DiagnosticExport.decode(artifact.bytes)

        #expect(report.refreshHistory?.first?.affectedWindowKinds == [])
    }

    @Test("v1 artifacts remain decodable without quota findings")
    func legacyDecode() throws {
        let v3 = try DiagnosticExport.make(from: input())
        let legacyText = try v3.preview
            .replacingOccurrences(of: #""schemaVersion" : 6"#, with: #""schemaVersion" : 1"#)
        let legacy = try DiagnosticExport.decode(Data(legacyText.utf8))
        #expect(legacy.schemaVersion == 1)
        #expect(legacy.quotaFindings == nil)
    }

    @Test("v2 qualified findings decode with the method that produced them")
    func v2ForecastMethodDecode() throws {
        let v3 = try DiagnosticExport.make(from: input(includesQuotaFinding: true))
        let v2Text = try v3.preview
            .replacingOccurrences(of: #""schemaVersion" : 6"#, with: #""schemaVersion" : 2"#)
            .replacingOccurrences(of: #"      "qualification" : "qualified",\n"#, with: "")
            .replacingOccurrences(of: "pairwise_positive_slope_interquartile_v2", with: "pairwise_positive_slope_interquartile_v1")

        let finding = try #require(DiagnosticExport.decode(Data(v2Text.utf8)).quotaFindings?.first)
        #expect(finding.forecastMethod == .pairwisePositiveSlopeInterquartileV1)
    }

    @Test("v3 unavailable findings decode with explicit method and qualification metadata")
    func v3UnavailableMetadataDecode() throws {
        let v4 = try DiagnosticExport.make(from: input(quotaFindings: [try unavailableQuotaFinding()]))
        let v3Text = try v4.preview
            .replacingOccurrences(of: #""schemaVersion" : 6"#, with: #""schemaVersion" : 3"#)
            .replacingOccurrences(of: "pairwise_positive_slope_interquartile_v2", with: "pairwise_positive_slope_interquartile_v1")
            .replacingOccurrences(of: #"      "qualification" : "unavailable",\n"#, with: "")
            .replacingOccurrences(of: "incompatible_evidence", with: "stale_evidence")

        let finding = try #require(DiagnosticExport.decode(Data(v3Text.utf8)).quotaFindings?.first)
        #expect(finding.status == .staleEvidence)
        #expect(finding.qualification == .unavailable)
        #expect(finding.forecastMethod == .pairwisePositiveSlopeInterquartileV1)
    }

    @Test("quota finding methods and qualification are required and internally consistent")
    func forecastMethodValidation() throws {
        #expect(throws: DiagnosticExportError.invalidQuotaFindings) {
            try DiagnosticQuotaFinding(
                product: .codex,
                windowKind: .session,
                status: .qualified,
                qualification: .unavailable,
                measuredObservationCount: 4,
                measuredSpanMinutes: 30,
                forecastMethod: .pairwisePositiveSlopeInterquartileV2,
                calculatedBurnPercentPerHour: DiagnosticNumberRange(lower: 4, upper: 7)
            )
        }
        let unavailable = try unavailableQuotaFinding()
        #expect(unavailable.qualification == .unavailable)
        #expect(unavailable.forecastMethod == .pairwisePositiveSlopeInterquartileV2)
        let artifact = try DiagnosticExport.make(from: input(includesQuotaFinding: true))
        let unknownMethod = try artifact.preview.replacingOccurrences(
            of: "pairwise_positive_slope_interquartile_v2",
            with: "unapproved_private_method_v99"
        )
        #expect(throws: DiagnosticExportError.malformedArtifact) {
            try DiagnosticExport.decode(Data(unknownMethod.utf8))
        }
        let unknownQualification = try artifact.preview.replacingOccurrences(of: #""qualification" : "qualified""#, with: #""qualification" : "private_unknown""#)
        #expect(throws: DiagnosticExportError.malformedArtifact) {
            try DiagnosticExport.decode(Data(unknownQualification.utf8))
        }
    }

    @Test("schema omits every prohibited content category")
    func prohibitedContentSentinels() throws {
        let artifact = try DiagnosticExport.make(from: input(includesHistory: true))
        let text = try artifact.preview
        let prohibitedKeys = [
            "headers", "url", "query", "request", "response", "body", "token", "credential", "keychain",
            "stackTrace", "errorMessage", "log", "prompt", "code", "terminalOutput", "path", "fileName",
            "accountLabel", "organizationLabel", "projectLabel", "sourceName", "modelLabel", "deploymentLabel",
            "payload", "databaseCopy", "jsonl", "exactWindow", "timezone", "identifier",
        ]
        let prohibitedSentinels = [
            "HEADER_SECRET", "QUERY_VALUE", "REQUEST_BODY", "RESPONSE_BODY", "TOKEN_SECRET", "CREDENTIAL_SECRET",
            "KEYCHAIN_SECRET", "STACK_TRACE", "ARBITRARY_ERROR", "LOG_SECRET", "PROMPT_SECRET", "SOURCE_CODE",
            "MODEL_RESPONSE", "TERMINAL_OUTPUT", "/Users/private/work", "PRIVATE_FILE_NAME", "ACCOUNT_LABEL",
            "ORGANIZATION_LABEL", "PROJECT_LABEL", "SOURCE_NAME", "MODEL_LABEL", "DEPLOYMENT_LABEL",
            "PROVIDER_PAYLOAD", "DATABASE_COPY", "JSONL_CONTENT",
        ]
        let allKeys = keySnapshot(try JSONSerialization.jsonObject(with: artifact.bytes))

        for key in prohibitedKeys {
            #expect(!allKeys.contains(where: { $0.split(separator: ".").last == Substring(key) }))
        }
        for sentinel in prohibitedSentinels {
            #expect(!text.contains(sentinel))
        }
    }

    @Test("invalid values, history, and duplicate providers are rejected")
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
        #expect(throws: DiagnosticExportError.invalidRefreshHistory) {
            try DiagnosticRefreshHistoryRecord(
                role: .latest,
                product: .anthropicAPI,
                outcome: .success,
                startedAt: Date(),
                duration: .underOneSecond,
                affectedWindowKinds: [.today, .today]
            )
        }
    }

    private func input(
        generatedAt: Date = Date(timeIntervalSince1970: 1_720_000_059),
        providerStatuses: [DiagnosticProviderStatus] = [
            DiagnosticProviderStatus(provider: .anthropic, state: .connected),
        ],
        includesHistory: Bool = false,
        includesQuotaFinding: Bool = false,
        includesCodexExplanation: Bool = false,
        refreshHistory: [DiagnosticRefreshHistoryRecord]? = nil,
        quotaFindings: [DiagnosticQuotaFinding]? = nil,
        quotaEvidence: DiagnosticQuotaEvidenceReport? = nil
    ) throws -> DiagnosticExportInput {
        try DiagnosticExportInput(
            generatedAt: generatedAt,
            appVersion: DiagnosticVersion(major: 1, minor: 2, patch: 3),
            appBuild: 42,
            operatingSystemVersion: DiagnosticVersion(major: 15, minor: 5, patch: 0),
            providerStatuses: providerStatuses,
            databaseState: .available,
            importCounts: DiagnosticImportCounts(accepted: 12, rejected: 2),
            resourceLimitReasons: [.rateLimited, .responseTooLarge],
            refreshHistory: refreshHistory ?? (includesHistory ? [try historyRecord()] : nil),
            quotaFindings: quotaFindings ?? (includesQuotaFinding ? [try quotaFinding()] : nil),
            codexExplanation: includesCodexExplanation ? try codexExplanationFinding() : nil,
            quotaEvidence: quotaEvidence
        )
    }

    private func codexExplanationFinding() throws -> DiagnosticCodexExplanationFinding {
        try DiagnosticCodexExplanationFinding(
            status: .partial,
            adapterVersion: CodexRolloutEvidenceAdapter.adapterVersion,
            coverage: .partial,
            tokenEvidence: .positive,
            sessionCount: 2,
            evidenceCount: 3,
            observationCount: 2,
            barrierCategories: [.malformedRecord]
        )
    }

    private func quotaFinding() throws -> DiagnosticQuotaFinding {
        try DiagnosticQuotaFinding(
            product: .codex,
            windowKind: .session,
            status: .qualified,
            qualification: .qualified,
            measuredObservationCount: 6,
            measuredSpanMinutes: 45,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2,
            calculatedBurnPercentPerHour: DiagnosticNumberRange(lower: 4, upper: 7),
            calculatedExhaustionMinutes: DiagnosticNumberRange(lower: 90, upper: 150)
        )
    }

    private func unavailableQuotaFinding() throws -> DiagnosticQuotaFinding {
        try DiagnosticQuotaFinding(
            product: .codex,
            windowKind: .session,
            status: .incompatibleEvidence,
            qualification: .unavailable,
            measuredObservationCount: 4,
            measuredSpanMinutes: 30,
            forecastMethod: .pairwisePositiveSlopeInterquartileV2
        )
    }

    private func evidenceRecord(index: Int, start: Date) throws -> DiagnosticQuotaEvidenceRecord {
        let unavailable = index == DiagnosticExport.maximumQuotaEvidenceRecords + 2
        let forecast = try DiagnosticEvidenceForecast(
            status: .unavailable,
            method: .pairwisePositiveSlopeInterquartileV2,
            qualification: .unavailable,
            unavailableReason: .insufficientObservations,
            observationCount: 0,
            observationSpanSeconds: 0,
            evidenceAgeSeconds: nil,
            range: nil,
            resetInteraction: .unavailable,
            evidenceTraceReferences: [],
            limitations: [.providerWeightingUnknown]
        )
        let currentPeriod = try DiagnosticEvidencePeriod(start: start, end: start.addingTimeInterval(60))
        let baselinePeriod = try DiagnosticEvidencePeriod(start: start.addingTimeInterval(-60), end: start)
        let anomaly = try DiagnosticEvidenceAnomaly(
            status: unavailable ? .unavailable : .noFinding,
            method: .trailingMedianRatioV1,
            qualification: unavailable ? .unavailable : .qualified,
            unavailableReason: unavailable ? .gap : nil,
            currentPeriod: unavailable ? nil : currentPeriod,
            baselinePeriod: unavailable ? nil : baselinePeriod,
            measuredInputCount: unavailable ? 0 : 1,
            currentValue: unavailable ? nil : DiagnosticEvidenceValue(value: 1, unit: .percentagePoints, provenance: .calculated),
            baselineValue: unavailable ? nil : DiagnosticEvidenceValue(value: 1, unit: .percentagePoints, provenance: .calculated),
            result: nil,
            evidenceTraceReferences: unavailable ? [] : [String(format: "%012x", index + 1)],
            limitations: [.noCausalAttribution]
        )
        return try DiagnosticQuotaEvidenceRecord(
            traceReference: String(format: "%012d", index),
            intervalStart: start.addingTimeInterval(Double(index) * 60),
            intervalEnd: start.addingTimeInterval(Double(index + 1) * 60),
            resetBoundary: unavailable ? nil : start.addingTimeInterval(100_000),
            movement: DiagnosticEvidenceMovement(value: Double(min(index, 100)), unit: .percentagePoints, provenance: unavailable ? .reported : .calculated),
            localBreakdown: unavailable ? .gap : .observedZero,
            unattributedRemainder: DiagnosticEvidenceRemainder(availability: .available, value: Double(min(index, 100)), provenance: .calculated, method: nil, unavailableReason: nil, limitations: [.noCausalAttribution]),
            inferredAllocation: nil,
            forecast: forecast,
            anomaly: anomaly,
            interpretation: .codexLocalReportV1,
            versions: [try DiagnosticEvidenceVersion(kind: .adapter, value: "quota-observation-v1")],
            limitations: [.fixtureValidationOnly]
        )
    }

    private func historyRecord() throws -> DiagnosticRefreshHistoryRecord {
        try DiagnosticRefreshHistoryRecord(
            role: .latest,
            product: .anthropicAPI,
            outcome: .networkFailure,
            startedAt: Date(timeIntervalSince1970: 1_720_000_019),
            duration: .oneToFiveSeconds,
            affectedWindowKinds: [.today, .currentWeek]
        )
    }

    private func keySnapshot(_ value: Any, prefix: String = "") -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set<String>()) { result, element in
                let path = prefix.isEmpty ? element.key : "\(prefix).\(element.key)"
                result.insert(path)
                result.formUnion(keySnapshot(element.value, prefix: path))
            }
        }
        if let array = value as? [Any] {
            let arrayPrefix = "\(prefix)[]"
            return array.reduce(into: Set<String>()) { result, element in
                result.formUnion(keySnapshot(element, prefix: arrayPrefix))
            }
        }
        return []
    }
}
