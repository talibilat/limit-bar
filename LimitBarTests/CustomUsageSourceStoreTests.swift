import Foundation
import LimitBarCore
import XCTest
@testable import LimitBar

final class CustomUsageSourceStoreTests: XCTestCase {
    private let suiteName = "com.talibilat.LimitBar.tests.\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = UserDefaults(suiteName: suiteName)
        try Data().write(to: fixtureURL)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: fixtureURL)
        super.tearDown()
    }

    func testAddPersistsTrimmedSourceInInjectedDefaults() throws {
        let store = CustomUsageSourceStore(defaults: defaults)

        XCTAssertTrue(store.add(name: "  Fixture Tool  ", filePath: "  \(fixtureURL.path)  "))

        let source = try XCTUnwrap(CustomUsageSourceStore(defaults: defaults).sources.first)
        XCTAssertEqual(source.name, "Fixture Tool")
        XCTAssertEqual(source.filePath, CustomUsageSource(name: "Expected", filePath: fixtureURL.path).filePath)
    }

    func testRemovePersistsAndPublishesChange() throws {
        let store = CustomUsageSourceStore(defaults: defaults)
        XCTAssertTrue(store.add(name: "Fixture Tool", filePath: fixtureURL.path))
        let source = try XCTUnwrap(store.sources.first)
        let notification = expectation(forNotification: .customUsageSourcesDidChange, object: nil)

        store.remove(id: source.id)

        wait(for: [notification], timeout: 1)
        XCTAssertTrue(CustomUsageSourceStore(defaults: defaults).sources.isEmpty)
    }

    func testAddRejectsAPathThatIsNotARegularFile() {
        let store = CustomUsageSourceStore(defaults: defaults)

        XCTAssertFalse(store.add(name: "Directory", filePath: FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(store.sources.isEmpty)
    }
}
