import Foundation
import Testing
@testable import LimitBarCore

@Suite("Official provider status")
struct ProviderStatusTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    @Test("official clients send an anonymous context-free request")
    func privacyRequest() async {
        let recorder = RecordingStatusHTTPClient(data: fixture(service: .anthropic))
        _ = await OfficialProviderStatusClient(service: .anthropic, httpClient: recorder).check(now: now)
        let request = await recorder.request
        #expect(request?.url == ProviderStatusService.anthropic.endpoint)
        #expect(request?.method == .get)
        #expect(request?.headers == [:])
        #expect(request?.body == nil)
    }

    @Test("fixtures normalize only bounded approved incident fields")
    func normalization() throws {
        let anthropic = try ProviderStatusNormalizer.normalize(fixture(service: .anthropic), service: .anthropic, checkedAt: now)
        let openAI = try ProviderStatusNormalizer.normalize(fixture(service: .openAI), service: .openAI, checkedAt: now)
        #expect(anthropic.incidents.first?.products == [.anthropicAPI, .claudeCode])
        #expect(openAI.incidents.first?.products == [.codex])
        #expect(anthropic.outcome == .incidentsPublished)
        let encoded = String(decoding: try JSONEncoder().encode(anthropic), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE INCIDENT PROSE"))
    }

    @Test("unknown component, no incident, malformed, and unsupported schema stay distinct")
    func distinctStates() async throws {
        let unknown = try ProviderStatusNormalizer.normalize(Data(#"{"components":[{"id":"x","name":"Future Product","status":"operational"}],"incidents":[]}"#.utf8), service: .openAI, checkedAt: now)
        let none = try ProviderStatusNormalizer.normalize(Data(#"{"components":[{"id":"x","name":"Codex API","status":"operational"}],"incidents":[]}"#.utf8), service: .openAI, checkedAt: now)
        #expect(unknown.outcome == .unsupportedComponent)
        #expect(none.outcome == .noPublishedIncident)
        #expect(throws: ProviderStatusNormalizationError.unsupportedSchema) { try ProviderStatusNormalizer.normalize(Data(#"{"incidents":[]}"#.utf8), service: .openAI, checkedAt: now) }
        #expect(throws: ProviderStatusNormalizationError.malformedPayload) { try ProviderStatusNormalizer.normalize(Data("broken".utf8), service: .openAI, checkedAt: now) }
    }

    @Test("OpenAI incidents without official component links remain provider-level history only")
    func openAIRequiresOfficialComponentLinks() throws {
        let data = Data(#"{"components":[{"id":"codex","name":"Codex API","status":"operational"},{"id":"desktop","name":"Codex in ChatGPT Desktop","status":"degraded_performance"},{"id":"vscode","name":"VS Code extension","status":"operational"}],"incidents":[{"id":"incident","impact":"minor","status":"monitoring","created_at":"2030-03-17T17:40:00Z","updated_at":"2030-03-17T17:45:00Z","resolved_at":null,"incident_updates":[] }]}"#.utf8)

        let observation = try ProviderStatusNormalizer.normalize(data, service: .openAI, checkedAt: now)

        #expect(observation.incidents.count == 1)
        #expect(observation.incidents.first?.products == [])
        #expect(observation.incidents.first?.componentStates == [:])
        #expect(observation.outcome == .unsupportedComponent)
        #expect(ProviderStatusCorrelation.incidents(overlapping: now, product: .codexChatGPT, observations: [observation]).isEmpty)
        #expect(ProviderStatusCapacity.incidents(from: [observation], now: now).isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderStatusStore(destination: directory.appendingPathComponent("status.json"))
        _ = try store.record([observation], now: now)
        let restored = try #require(store.load(now: now).first)
        #expect(restored.incidents.count == 1)
        #expect(restored.incidents.first?.products == [])
    }

    @Test("OpenAI component mapping uses exact official names or IDs, never API substrings")
    func openAIExactComponentAllowList() throws {
        let data = Data(#"{"components":[{"id":"unrelated","name":"Unofficial Codex API Proxy","status":"degraded_performance"},{"id":"01KMP3KP5MGE23B80K1EK4S8PV","name":"Renamed by provider","status":"partial_outage"},{"id":"exact","name":"VS Code extension","status":"major_outage"}],"incidents":[{"id":"incident","impact":"major","status":"monitoring","created_at":"2030-03-17T17:40:00Z","updated_at":"2030-03-17T17:45:00Z","resolved_at":null,"components":[{"id":"unrelated","name":"Unofficial Codex API Proxy","status":"degraded_performance"},{"id":"01KMP3KP5MGE23B80K1EK4S8PV","name":"Renamed by provider","status":"partial_outage"},{"id":"exact","name":"VS Code extension","status":"major_outage"}],"incident_updates":[] }]}"#.utf8)

        let observation = try ProviderStatusNormalizer.normalize(data, service: .openAI, checkedAt: now)

        #expect(observation.incidents.first?.products == [.codex, .codexVSCode])
        #expect(observation.incidents.first?.componentStates.keys.contains(.openAIAPI) == false)
        #expect(observation.unsupportedComponentCount == 1)
    }

    @Test("every incident update timestamp must be valid")
    func malformedIncidentUpdateTimestamp() async {
        let malformedCreated = Data(#"{"components":[{"id":"code","name":"Codex API","status":"degraded_performance"}],"incidents":[{"id":"incident","impact":"major","status":"monitoring","created_at":"2030-03-17T17:40:00Z","updated_at":"2030-03-17T17:45:00Z","resolved_at":null,"components":[{"id":"code","name":"Codex API","status":"degraded_performance"}],"incident_updates":[{"status":"monitoring","created_at":"invalid","updated_at":"2030-03-17T17:45:00Z"}]}]}"#.utf8)
        let malformedUpdated = Data(#"{"components":[{"id":"code","name":"Codex API","status":"degraded_performance"}],"incidents":[{"id":"incident","impact":"major","status":"monitoring","created_at":"2030-03-17T17:40:00Z","updated_at":"2030-03-17T17:45:00Z","resolved_at":null,"components":[{"id":"code","name":"Codex API","status":"degraded_performance"}],"incident_updates":[{"status":"monitoring","created_at":"2030-03-17T17:44:00Z","updated_at":"invalid"}]}]}"#.utf8)

        #expect(throws: ProviderStatusNormalizationError.malformedPayload) {
            try ProviderStatusNormalizer.normalize(malformedCreated, service: .openAI, checkedAt: now)
        }
        #expect(throws: ProviderStatusNormalizationError.malformedPayload) {
            try ProviderStatusNormalizer.normalize(malformedUpdated, service: .openAI, checkedAt: now)
        }
        let observation = await OpenAIPublicStatusClient(httpClient: RecordingStatusHTTPClient(data: malformedCreated)).check(now: now)
        #expect(observation.outcome == .malformedPayload)
        #expect(observation.incidents.isEmpty)
    }

    @Test("timeout and transport failures remain endpoint unavailable")
    func endpointTimeout() async {
        let observation = await OpenAIPublicStatusClient(httpClient: FailingStatusHTTPClient()).check(now: now)
        #expect(observation.outcome == .endpointUnavailable)
        #expect(observation.incidents.isEmpty)
    }

    @Test("temporal overlap is half-open and never claims health or causation")
    func temporalCorrelation() throws {
        let observation = try ProviderStatusNormalizer.normalize(fixture(service: .openAI), service: .openAI, checkedAt: now)
        let incident = try #require(observation.incidents.first)
        #expect(incident.overlaps(incident.startedAt))
        #expect(!incident.overlaps(try #require(incident.resolvedAt)))
        #expect(ProviderStatusCorrelation.incidents(overlapping: incident.startedAt, product: .codex, observations: [observation]).count == 1)
        #expect(ProviderStatusCorrelation.overlapLanguage == "Official incident overlapped this failure. Temporal overlap does not establish causation.")
        #expect(ProviderStatusCorrelation.noIncidentLanguage.contains("does not establish provider health or quota exhaustion"))
    }

    @Test("persistence bounds age and count, rejects provenance-free v1 migration, and deletes independently")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let store = ProviderStatusStore(destination: url)
        let values = (0..<120).map { index in ProviderStatusObservation(service: .openAI, checkedAt: now.addingTimeInterval(Double(-index)), outcome: .noPublishedIncident) }
        #expect(try store.record(values, now: now).count == ProviderStatusLimits.maximumStoredObservations)
        try store.deleteAll()
        #expect(try store.load(now: now).isEmpty)

        let incident = try #require(try ProviderStatusNormalizer.normalize(fixture(service: .openAI), service: .openAI, checkedAt: now).incidents.first)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Legacy(schemaVersion: 1, incidents: [incident])).write(to: url)
        let original = try Data(contentsOf: url)
        #expect(throws: ProviderStatusNormalizationError.unsupportedSchema) { try store.load(now: now) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("persisted incident service must match its containing observation")
    func persistedServiceMismatchFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let store = ProviderStatusStore(destination: url)
        let mismatched = NormalizedProviderIncident(
            id: "mismatch", service: .anthropic, products: [.claudeCode], impact: .major, status: .monitoring,
            startedAt: now.addingTimeInterval(-60), updatedAt: now, resolvedAt: nil,
            componentStates: [.claudeCode: .degradedPerformance], latestUpdateState: .monitoring
        )
        let observation = ProviderStatusObservation(
            service: .openAI, checkedAt: now, outcome: .incidentsPublished, incidents: [mismatched]
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PersistedEnvelope(schemaVersion: ProviderStatusStore.schemaVersion, observations: [observation])).write(to: url)
        let original = try Data(contentsOf: url)

        #expect(throws: ProviderStatusNormalizationError.malformedPayload) { try store.load(now: now) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("subscription is disabled by default and six-hour checks survive restart and wake")
    func subscriptionSchedule() throws {
        let settings = ProviderStatusSubscriptionSettings.decode(nil)
        #expect(!settings.isEnabled)
        #expect(settings.cadenceSeconds == 21_600)
        #expect(!ProviderStatusSubscriptionSchedule.isDue(enabled: false, lastCheck: nil, now: now))
        #expect(!ProviderStatusSubscriptionSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(-21_599), now: now))
        #expect(ProviderStatusSubscriptionSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(-21_600), now: now))
        #expect(ProviderStatusSubscriptionSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(-86_400), now: now))
    }

    @Test("only the latest fresh successful check can publish active capacity incidents")
    func capacityProjectionUsesLatestObservation() throws {
        let active = try ProviderStatusNormalizer.normalize(fixture(service: .openAI, resolved: false), service: .openAI, checkedAt: now)
        #expect(ProviderStatusCapacity.incidents(from: [active], now: now).count == 1)
        for outcome in [
            ProviderStatusCheckOutcome.noPublishedIncident,
            .unsupportedComponent,
            .endpointUnavailable,
            .malformedPayload,
            .unsupportedSchema,
        ] {
            let retired = ProviderStatusObservation(service: .openAI, checkedAt: now.addingTimeInterval(60), outcome: outcome)
            #expect(ProviderStatusCapacity.incidents(from: [active, retired], now: retired.checkedAt).isEmpty)
        }
        #expect(ProviderStatusCapacity.incidents(from: [active], now: now.addingTimeInterval(ProviderStatusLimits.freshness + 1)).isEmpty)
    }

    @Test("unknown incident or component statuses never become active capacity evidence")
    func unknownStatusesAreNeverActive() {
        let unknownIncident = incident(status: .unknown, componentStatus: .degradedPerformance)
        let unknownComponent = incident(status: .monitoring, componentStatus: .unknown)
        let unknownUpdate = NormalizedProviderIncident(
            id: "unknown-update", service: .openAI, products: [.codex], impact: .major, status: .monitoring,
            startedAt: now.addingTimeInterval(-60), updatedAt: now, resolvedAt: nil,
            componentStates: [.codex: .degradedPerformance], latestUpdateState: .unknown
        )
        let observation = ProviderStatusObservation(
            service: .openAI,
            checkedAt: now,
            outcome: .incidentsPublished,
            incidents: [unknownIncident, unknownComponent, unknownUpdate]
        )

        #expect(ProviderStatusCapacity.incidents(from: [observation], now: now).isEmpty)
    }

    @Test("unresolved incidents correlate only through confirmed observations and survive later disappearance historically")
    func unresolvedHistoricalTimeline() {
        let active = ProviderStatusObservation(
            service: .openAI,
            checkedAt: now,
            outcome: .incidentsPublished,
            incidents: [incident(startedAt: now.addingTimeInterval(-60))]
        )
        let disappeared = ProviderStatusObservation(
            service: .openAI,
            checkedAt: now.addingTimeInterval(120),
            outcome: .noPublishedIncident
        )

        #expect(ProviderStatusCorrelation.incidents(overlapping: now.addingTimeInterval(-30), product: .codex, observations: [active, disappeared]).count == 1)
        #expect(ProviderStatusCorrelation.incidents(overlapping: now.addingTimeInterval(1), product: .codex, observations: [active, disappeared]).isEmpty)
        #expect(ProviderStatusCapacity.incidents(from: [active, disappeared], now: disappeared.checkedAt).isEmpty)
    }

    @Test("approved status origins reject cross-origin, downgrade, and alternate-port destinations")
    func approvedOrigins() throws {
        #expect(ProviderStatusService.openAI.isApproved(url: try #require(URL(string: "https://status.openai.com/api/v2/summary.json"))))
        #expect(!ProviderStatusService.openAI.isApproved(url: try #require(URL(string: "https://example.com/api/v2/summary.json"))))
        #expect(!ProviderStatusService.openAI.isApproved(url: try #require(URL(string: "http://status.openai.com/api/v2/summary.json"))))
        #expect(!ProviderStatusService.openAI.isApproved(url: try #require(URL(string: "https://status.openai.com:444/api/v2/summary.json"))))
    }

    private struct Legacy: Codable { let schemaVersion: Int; let incidents: [NormalizedProviderIncident] }
    private struct PersistedEnvelope: Codable { let schemaVersion: Int; let observations: [ProviderStatusObservation] }

    private func incident(
        status: ProviderIncidentStatus = .monitoring,
        componentStatus: ProviderComponentStatus = .degradedPerformance,
        startedAt: Date? = nil
    ) -> NormalizedProviderIncident {
        NormalizedProviderIncident(
            id: UUID().uuidString,
            service: .openAI,
            products: [.codex],
            impact: .major,
            status: status,
            startedAt: startedAt ?? now.addingTimeInterval(-60),
            updatedAt: now,
            resolvedAt: nil,
            componentStates: [.codex: componentStatus],
            latestUpdateState: status
        )
    }

    private func fixture(service: ProviderStatusService, resolved: Bool = true) -> Data {
        let componentName = service == .anthropic ? "Claude Code" : "Codex"
        let second = service == .anthropic ? #",{"id":"api","name":"Claude API","status":"partial_outage"}"# : ""
        let components = service == .anthropic ? #"[{"id":"code","name":"Claude Code","status":"degraded_performance"},{"id":"api","name":"Claude API","status":"partial_outage"}]"# : #"[{"id":"code","name":"Codex API","status":"degraded_performance"}]"#
        _ = componentName; _ = second
        let resolvedValue = resolved ? #""2030-03-17T17:50:00Z""# : "null"
        let status = resolved ? "resolved" : "monitoring"
        return Data(#"{"page":{"id":"ignored"},"components":\#(components),"incidents":[{"id":"inc-1","name":"PRIVATE INCIDENT PROSE","impact":"major","status":"\#(status)","created_at":"2030-03-17T17:40:00Z","updated_at":"2030-03-17T17:45:00Z","resolved_at":\#(resolvedValue),"components":\#(components),"incident_updates":[{"status":"\#(status)","body":"PRIVATE INCIDENT PROSE","created_at":"2030-03-17T17:45:00Z","updated_at":"2030-03-17T17:45:00Z"}]}],"scheduled_maintenances":[]}"#.utf8)
    }
}

private actor RecordingStatusHTTPClient: HTTPClient {
    let data: Data
    private(set) var request: HTTPRequest?
    init(data: Data) { self.data = data }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        self.request = request
        return HTTPResponse(statusCode: 200, data: data)
    }
}

private struct FailingStatusHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.timedOut) }
}
