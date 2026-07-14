import XCTest
import LimitBarCore
@testable import LimitBar

final class ProviderRefreshHistoryPresentationTests: XCTestCase {
    func testOutcomesUseDistinctSafeCopy() {
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.success), "Succeeded")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.partialFailure), "Partially failed")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.cancelled), "Cancelled")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.authenticationFailure), "Authentication failed")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.networkFailure), "Network failed")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.outcome(.failed), "Failed")
    }

    func testMissingHistoryDoesNotImplySuccessOrZeroUsage() {
        XCTAssertEqual(ProviderRefreshHistoryStatusText.latest(nil), "No explicit refresh recorded")
        XCTAssertEqual(ProviderRefreshHistoryStatusText.lastFullSuccess(nil), "No full success recorded")
    }
}
