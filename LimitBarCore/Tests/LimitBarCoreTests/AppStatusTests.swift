import Testing
@testable import LimitBarCore

@Suite("AppStatus")
struct AppStatusTests {
    @Test("initial status is compact and neutral")
    func initialStatusIsCompactAndNeutral() {
        let status = AppStatus.initial

        #expect(status.menuBarText == "LimitBar")
        #expect(status.symbolName == "gauge.with.dots.needle.bottom.50percent")
        #expect(status.accessibilityDescription == "LimitBar usage monitor")
    }
}
