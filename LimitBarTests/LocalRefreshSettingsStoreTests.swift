import Foundation
import XCTest
@testable import LimitBar

final class LocalRefreshSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.talibilat.LimitBar.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultAndAllowedCadencesNeverPollFasterThanFiveSeconds() {
        let store = LocalRefreshSettingsStore(defaults: defaults)

        XCTAssertEqual(store.cadence, .fiveSeconds)
        XCTAssertEqual(LocalRefreshCadence.allCases.map(\.seconds), [5, 15, 30])
    }

    func testCadencePersistsInVersionedPreferenceAndPublishesChange() {
        let store = LocalRefreshSettingsStore(defaults: defaults)
        let notification = expectation(forNotification: .localRefreshSettingsDidChange, object: nil)

        store.cadence = .thirtySeconds

        wait(for: [notification], timeout: 1)
        XCTAssertEqual(LocalRefreshSettingsStore(defaults: defaults).cadence, .thirtySeconds)
    }

    func testInvalidPersistedPreferencesReturnToFiveSecondDefault() {
        let invalidValues = [
            #"{"version":1,"cadenceSeconds":1}"#,
            #"{"version":2,"cadenceSeconds":15}"#,
            #"{"cadenceSeconds":15}"#,
            "not-json"
        ]

        for value in invalidValues {
            defaults.set(Data(value.utf8), forKey: LocalRefreshSettingsStore.storageKey)
            XCTAssertEqual(LocalRefreshSettingsStore(defaults: defaults).cadence, .fiveSeconds)
        }
    }
}
