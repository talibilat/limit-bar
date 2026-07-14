import XCTest

final class LimitBarUITests: XCTestCase {
    private var app: XCUIApplication!
    private var runIdentifier: String!
    private var defaultsSuiteName: String!
    private var fixtureDirectory: URL!
    private var fixtureURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        runIdentifier = UUID().uuidString
        defaultsSuiteName = "com.talibilat.LimitBar.ui-tests.\(runIdentifier!)"
        fixtureDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("limitbar-ui-tests", isDirectory: true)
            .appendingPathComponent(runIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        fixtureURL = fixtureDirectory.appendingPathComponent("usage.jsonl")
        try Data().write(to: fixtureURL, options: .atomic)

        app = XCUIApplication()
        app.launchArguments = ["--limitbar-testing", "--limitbar-ui-testing"]
        app.launchEnvironment["LIMITBAR_UI_TEST_RUN_ID"] = runIdentifier
        app.launchEnvironment["LIMITBAR_UI_TEST_CUSTOM_SOURCE_PATH"] = fixtureURL.path
        app.launchEnvironment["AppleLanguages"] = "(en)"
        app.launchEnvironment["AppleLocale"] = "en_US_POSIX"
        app.launchEnvironment["TZ"] = "UTC"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: fixtureDirectory)
        app = nil
        fixtureURL = nil
        fixtureDirectory = nil
        defaultsSuiteName = nil
        runIdentifier = nil
        try super.tearDownWithError()
    }

    func testNativeAppLaunchesProductionPopoverContent() {
        launch(screen: "popover")

        XCTAssertTrue(app.windows["LimitBar UI Tests"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["app-title"].exists)
        XCTAssertTrue(app.buttons["settings-action"].exists)
    }

    func testPassiveAuthorizationCheckPresentsConnectAction() {
        launch(screen: "popover")

        let authorizationMessage = app.staticTexts["claude-authorization-required"]
        XCTAssertTrue(authorizationMessage.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["claude-connect"].exists)
    }

    func testConnectUsesInteractiveFixture() {
        launch(screen: "popover")

        let authorizationMessage = app.staticTexts["claude-authorization-required"]
        XCTAssertTrue(authorizationMessage.waitForExistence(timeout: 5))
        app.buttons["claude-connect"].click()

        XCTAssertTrue(app.otherElements["claude-loaded-state"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Session (5 hours)"].exists)
        XCTAssertTrue(app.staticTexts["75% left"].exists)
        XCTAssertFalse(authorizationMessage.exists)
    }

    func testConfiguresPersistsAndRemovesCustomUsageSource() {
        launch(screen: "settings")

        let nameField = app.textFields["custom-source-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Fixture Tool")
        app.buttons["custom-source-choose-file"].click()
        app.buttons["custom-source-add"].click()
        XCTAssertTrue(app.staticTexts["Fixture Tool"].waitForExistence(timeout: 5))

        app.terminate()
        launch(screen: "settings")
        XCTAssertTrue(app.staticTexts["Fixture Tool"].waitForExistence(timeout: 5))

        app.buttons["custom-source-remove"].click()
        XCTAssertTrue(app.staticTexts["custom-sources-empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fixture Tool"].exists)
    }

    private func launch(screen: String) {
        app.launchEnvironment["LIMITBAR_UI_TEST_SCREEN"] = screen
        app.launch()
    }
}
