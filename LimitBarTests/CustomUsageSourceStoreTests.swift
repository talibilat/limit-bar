import Foundation
import XCTest
@testable import LimitBar

final class CustomUsageSourceStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.talibilat.LimitBar.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAddPersistsTrimmedSourceInInjectedDefaults() throws {
        let store = CustomUsageSourceStore(defaults: defaults)

        XCTAssertTrue(store.add(name: "  Fixture Tool  ", filePath: "  /tmp/fixture.jsonl  "))

        let source = try XCTUnwrap(CustomUsageSourceStore(defaults: defaults).sources.first)
        XCTAssertEqual(source.name, "Fixture Tool")
        XCTAssertEqual(source.filePath, "/tmp/fixture.jsonl")
    }

    func testRemovePersistsAndPublishesChange() throws {
        let store = CustomUsageSourceStore(defaults: defaults)
        XCTAssertTrue(store.add(name: "Fixture Tool", filePath: "/tmp/fixture.jsonl"))
        let source = try XCTUnwrap(store.sources.first)
        let notification = expectation(forNotification: .customUsageSourcesDidChange, object: nil)

        store.remove(id: source.id)

        wait(for: [notification], timeout: 1)
        XCTAssertTrue(CustomUsageSourceStore(defaults: defaults).sources.isEmpty)
    }
}
