import Foundation
import Testing
@testable import LimitBarCore

@Suite("Provider refresh history")
struct ProviderRefreshHistoryTests {
    @Test("duration boundaries map to fixed safe buckets", arguments: [
        (0.0, ProviderRefreshDurationBucket.underOneSecond),
        (0.999, .underOneSecond),
        (1.0, .oneToFiveSeconds),
        (4.999, .oneToFiveSeconds),
        (5.0, .fiveToThirtySeconds),
        (29.999, .fiveToThirtySeconds),
        (30.0, .overThirtySeconds),
    ])
    func durationBuckets(duration: TimeInterval, expected: ProviderRefreshDurationBucket) throws {
        #expect(try ProviderRefreshDurationBucket(duration: duration) == expected)
    }

    @Test("invalid durations and empty windows are rejected")
    func rejectsInvalidValues() throws {
        #expect(throws: ProviderRefreshHistoryValidationError.invalidDuration) {
            try ProviderRefreshDurationBucket(duration: -.infinity)
        }
        #expect(throws: ProviderRefreshHistoryValidationError.noAffectedWindows) {
            try entry(startedAt: Date(timeIntervalSince1970: 0), windows: [])
        }
    }

    @Test("history retains thirty days inclusively")
    func ageRetention() async throws {
        let history = ProviderRefreshHistory()
        let now = Date(timeIntervalSince1970: 4_000_000)
        try await history.record(entry(startedAt: now.addingTimeInterval(-(30 * 24 * 60 * 60))), now: now)
        try await history.record(entry(startedAt: now.addingTimeInterval(-(30 * 24 * 60 * 60) - 0.001)), now: now)

        let retained = await history.entries(for: .anthropic, now: now)

        #expect(retained.map(\.startedAt) == [now.addingTimeInterval(-(30 * 24 * 60 * 60))])
    }

    @Test("history retains at most two hundred newest entries per provider")
    func countRetention() async throws {
        let history = ProviderRefreshHistory()
        let now = Date(timeIntervalSince1970: 20_000_000)

        for offset in 0...ProviderRefreshHistory.maximumEntriesPerProvider {
            try await history.record(entry(startedAt: now.addingTimeInterval(TimeInterval(-offset))), now: now)
        }

        let retained = await history.entries(for: .anthropic, now: now)
        #expect(retained.count == 200)
        #expect(retained.first?.startedAt == now)
        #expect(retained.last?.startedAt == now.addingTimeInterval(-199))
    }

    @Test("provider deletion is independent")
    func independentDeletion() async throws {
        let history = ProviderRefreshHistory()
        let now = Date(timeIntervalSince1970: 2_000_000)
        try await history.record(entry(provider: .anthropic, startedAt: now), now: now)
        try await history.record(entry(provider: .openAI, startedAt: now), now: now)

        await history.deleteEntries(for: .anthropic)

        #expect(await history.entries(for: .anthropic, now: now).isEmpty)
        #expect(await history.entries(for: .openAI, now: now).count == 1)
    }

    @Test("entry schema has only allow-listed fields")
    func schemaAllowList() throws {
        let encoded = try JSONEncoder().encode(entry(startedAt: Date(timeIntervalSince1970: 1_000)))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(Set(object.keys) == [
            "schemaVersion", "provider", "operation", "outcome", "startedAt", "duration", "affectedWindows",
        ])
        let windows = try #require(object["affectedWindows"] as? [[String: Any]])
        #expect(Set(try #require(windows.first).keys) == ["kind", "start", "end", "basis", "aggregationVersion"])
        #expect(object["schemaVersion"] as? Int == ProviderRefreshHistoryEntry.currentSchemaVersion)
    }

    @Test("entry schema cannot carry prohibited content")
    func prohibitedContentSentinels() throws {
        let text = try #require(String(data: JSONEncoder().encode(entry(startedAt: Date(timeIntervalSince1970: 1_000))), encoding: .utf8))
        let prohibitedSentinels = [
            "HEADER_SECRET", "QUERY_VALUE", "REQUEST_BODY", "RESPONSE_BODY", "TOKEN_SECRET",
            "STACK_TRACE", "ARBITRARY_ERROR", "PROMPT_SECRET", "SOURCE_CODE", "MODEL_RESPONSE",
            "TERMINAL_OUTPUT", "PRIVATE_PATH", "PROVIDER_PAYLOAD", "ACCOUNT_LABEL", "PROJECT_LABEL",
            "MODEL_LABEL", "DEPLOYMENT_LABEL", "SOURCE_NAME", "FILE_NAME",
        ]

        for sentinel in prohibitedSentinels {
            #expect(!text.contains(sentinel))
        }
    }

    private func entry(
        provider: ProviderRefreshHistoryProvider = .anthropic,
        startedAt: Date,
        windows: [ProviderRefreshWindow]? = nil
    ) throws -> ProviderRefreshHistoryEntry {
        try ProviderRefreshHistoryEntry(
            provider: provider,
            operation: .usageAndRateLimits,
            outcome: .success,
            startedAt: startedAt,
            duration: 1.5,
            affectedWindows: windows ?? [window]
        )
    }

    private var window: ProviderRefreshWindow {
        get throws {
            try ProviderRefreshWindow(
                kind: .today,
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 86_400),
                basis: .localCalendar,
                aggregationVersion: 1
            )
        }
    }
}
