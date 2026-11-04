import Foundation
import Testing
@testable import LimitBarCore

@Suite("SQLite alert delivery store")
struct SQLiteAlertDeliveryStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("reservation is atomic and delivery satisfies every threshold in the occurrence")
    func atomicReservationAndDelivery() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let firstStore = try SQLiteAlertDeliveryStore(path: path)
        let secondStore = try SQLiteAlertDeliveryStore(path: path)
        let occurrence = try quotaOccurrence(thresholds: [50, 75, 90])

        let reserved = try firstStore.reserve(occurrence, now: now)
        let reservation = try #require(reserved)
        #expect(try secondStore.reserve(occurrence, now: now) == nil)
        try firstStore.markDelivered(reservation, at: now)

        #expect(try firstStore.satisfactions(for: occurrence.ruleID, window: occurrence.window).map(\.threshold) == [50, 75, 90])
        #expect(try firstStore.reserve(occurrence, now: now) == nil)
    }

    @Test("failed deliveries can retry while live reservations cannot")
    func failureAndLeaseRecovery() throws {
        let store = try SQLiteAlertDeliveryStore.inMemory()
        let occurrence = try quotaOccurrence(thresholds: [75])
        let reserved = try store.reserve(occurrence, now: now, leaseDuration: 30)
        let first = try #require(reserved)

        #expect(try store.reserve(occurrence, now: now.addingTimeInterval(10), leaseDuration: 30) == nil)
        try store.markFailed(first)
        #expect(try store.reserve(occurrence, now: now.addingTimeInterval(11), leaseDuration: 30) != nil)

        let other = try quotaOccurrence(thresholds: [90], identifier: "secondary")
        let otherReservation = try store.reserve(other, now: now, leaseDuration: 30)
        _ = try #require(otherReservation)
        #expect(try store.reserve(other, now: now.addingTimeInterval(31), leaseDuration: 30) != nil)
    }

    @Test("accepted reservations survive their initial lease through the exact boundary")
    func acceptedReservationRetention() throws {
        let store = try SQLiteAlertDeliveryStore.inMemory()
        let occurrence = try quotaOccurrence(thresholds: [75])
        let reserved = try store.reserve(occurrence, now: now, leaseDuration: 30)
        let reservation = try #require(reserved)

        try store.retainAcceptedReservation(reservation)

        #expect(try store.reserve(occurrence, now: now.addingTimeInterval(31), leaseDuration: 30) == nil)
        #expect(try store.prune(through: occurrence.window.boundary) == 1)
    }

    @Test("pruning uses the exact reset boundary and reset is user controllable")
    func pruningAndReset() throws {
        let store = try SQLiteAlertDeliveryStore.inMemory()
        let occurrence = try quotaOccurrence(thresholds: [50])
        let reserved = try store.reserve(occurrence, now: now)
        let reservation = try #require(reserved)
        try store.markDelivered(reservation, at: now)

        #expect(try store.prune(through: now.addingTimeInterval(59)) == 0)
        #expect(try store.prune(through: now.addingTimeInterval(60)) == 1)

        let next = try quotaOccurrence(thresholds: [50], identifier: "next")
        let nextReserved = try store.reserve(next, now: now)
        let nextReservation = try #require(nextReserved)
        try store.markDelivered(nextReservation, at: now)
        try store.reset()
        #expect(try store.satisfactions(for: next.ruleID, window: next.window).isEmpty)
    }

    @Test("ledger persists across reopen and coexists with the usage schema")
    func persistenceAndUsageSchemaCoexistence() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try SQLiteUsageMetricStore(path: path)
        let occurrence = try quotaOccurrence(thresholds: [75])
        do {
            let store = try SQLiteAlertDeliveryStore(path: path)
            let reserved = try store.reserve(occurrence, now: now)
            let reservation = try #require(reserved)
            try store.markDelivered(reservation, at: now)
        }

        let reopened = try SQLiteAlertDeliveryStore(path: path)
        #expect(try reopened.satisfactions(for: occurrence.ruleID, window: occurrence.window).map(\.threshold) == [75])
        #expect(try SQLiteUsageMetricStore(path: path).allMetrics().isEmpty)
    }

    @Test("Claude countdown drift does not repeat alerts across reopen or hide other limits")
    func countdownDrift() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ruleID = UUID()
        func occurrence(_ seconds: Double, kind: String = "session:session", threshold: Int = 70) throws -> AlertOccurrence {
            AlertOccurrence(ruleID: ruleID, window: .quota(try QuotaWindowIdentity(
                product: .claudeCode, identifier: kind, resetBoundary: now.addingTimeInterval(seconds)
            )), thresholds: [threshold])
        }
        do {
            let store = try SQLiteAlertDeliveryStore(path: path)
            let reservation = try #require(try store.reserve(occurrence(3600.2), now: now))
            #expect(try store.reserve(occurrence(3599.8), now: now) == nil)
            try store.markDelivered(reservation, at: now)
        }
        let store = try SQLiteAlertDeliveryStore(path: path)
        let drifted = try occurrence(3599.1)
        #expect(try store.satisfactions(for: ruleID, window: drifted.window).map(\.threshold) == [70])
        #expect(try store.reserve(drifted, now: now) == nil)
        #expect(try store.reserve(occurrence(3599.1, threshold: 90), now: now) != nil)
        #expect(try store.reserve(occurrence(3599.1, kind: "weekly:weekly_all"), now: now) != nil)
        #expect(try store.reserve(occurrence(21600), now: now) != nil)
    }

    private func quotaOccurrence(thresholds: [Int], identifier: String = "primary") throws -> AlertOccurrence {
        let identity = try QuotaWindowIdentity(product: .codex, identifier: identifier, resetBoundary: now.addingTimeInterval(60))
        let ruleID = try #require(UUID(uuidString: "8AB1442A-F507-483A-9D92-756898B8190D"))
        return AlertOccurrence(
            ruleID: ruleID,
            window: .quota(identity),
            thresholds: thresholds
        )
    }
}
