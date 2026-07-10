import Testing
@testable import LimitBarCore

@Suite("AppStatus")
struct AppStatusTests {
    @Test("initial status is compact and neutral")
    func initialStatusIsCompactAndNeutral() {
        let status = AppStatus.initial

        #expect(status.menuBarText == "LimitBar")
        #expect(status.symbolName == "gauge.with.dots.needle.bottom.50percent")
        #expect(status.statusColorName == "gray")
        #expect(status.accessibilityDescription == "LimitBar usage monitor")
    }

    @Test("app status can be derived from menu bar status")
    func appStatusCanBeDerivedFromMenuBarStatus() {
        let appStatus = AppStatus.from(menuBarStatus: MenuBarStatus(color: .yellow, confirmedUsagePercentage: 82))

        #expect(appStatus.menuBarText == "82%")
        #expect(appStatus.symbolName == "gauge.with.dots.needle.bottom.50percent")
        #expect(appStatus.statusColorName == "yellow")
        #expect(appStatus.accessibilityDescription == "LimitBar usage monitor, 82%, yellow")
    }
}
