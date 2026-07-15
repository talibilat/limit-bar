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
        XCTAssertTrue(app.links["claude-login-help"].exists)
    }

    func testConnectUsesInteractiveFixture() {
        launch(screen: "popover")

        let authorizationMessage = app.staticTexts["claude-authorization-required"]
        XCTAssertTrue(authorizationMessage.waitForExistence(timeout: 5))
        app.buttons["claude-connect"].click()

        XCTAssertTrue(app.staticTexts["Session (5 hours)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["75% left"].exists)
        XCTAssertFalse(authorizationMessage.exists)
    }

    func testMissingClaudeLoginProvidesRecoveryInstructions() {
        launch(screen: "claude-login-required")

        XCTAssertTrue(app.staticTexts["No active Claude Code login found. Run Claude Code and enter /login, then check again."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["claude-login-help"].exists)
        XCTAssertTrue(app.buttons["Check Again"].exists)
        XCTAssertFalse(app.buttons["claude-connect"].exists)
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

        app.buttons["custom-source-row"].click()
        XCTAssertTrue(app.staticTexts["custom-sources-empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fixture Tool"].exists)
    }

    func testDiagnosticExportRequiresReviewBeforeSave() {
        launch(screen: "diagnostic-export")

        let previewButton = app.buttons["diagnostic-export-preview"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["diagnostic-export-save"].exists)
        previewButton.click()

        XCTAssertTrue(app.staticTexts["Review Diagnostic Export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["diagnostic-export-json-preview"].exists)
        XCTAssertTrue(app.buttons["diagnostic-export-save"].exists)
        let preview = app.staticTexts["diagnostic-export-json-preview"]
        let previewText = (preview.value as? String) ?? preview.label
        XCTAssertTrue(previewText.contains("schemaVersion"))
    }

    func testQuotaInsightFixtureShowsMethodQualificationAndLimitation() {
        launch(screen: "quota-insight")

        let disclosure = app.staticTexts["quota-insight-method"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        let text = (disclosure.value as? String) ?? disclosure.label
        XCTAssertTrue(text.contains("pairwise_positive_slope_interquartile_v2 qualified"))
        XCTAssertTrue(text.contains("provider weighting is unknown"))
    }

    func testCodexExplanationFixtureShowsMeasuredBreakdownAndUnattributedStatus() {
        launch(screen: "codex-explanation")

        let explanation = app.staticTexts["codex-quota-explanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        let text = (explanation.value as? String) ?? explanation.label
        XCTAssertTrue(text.contains("Measured quota change: +3.5%"))
        XCTAssertTrue(text.contains("Observed Local Breakdown: 10 measured tokens"))
        XCTAssertTrue(text.contains("Quota movement remains unattributed"))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "codex-rollout-observed-0.144.4")).firstMatch.exists)
    }

    func testClaudeExplanationOffersIntervalsAndShowsConservativeProductionBoundary() {
        launch(screen: "claude-explanation")

        let explanation = app.staticTexts["claude-quota-explanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        let text = (explanation.value as? String) ?? explanation.label
        XCTAssertTrue(text.contains("Retained quota observations have no trustworthy account binding"))
        XCTAssertTrue(app.popUpButtons["claude-explanation-interval"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "receiver_not_configured")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "manual signed acceptance unavailable")).firstMatch.exists)
        let trace = app.staticTexts["claude-explanation-trace"]
        XCTAssertTrue(trace.exists)
        let traceText = (trace.value as? String) ?? trace.label
        XCTAssertTrue(traceText.contains("Exact selected interval:"))
        XCTAssertTrue(traceText.contains("interval trace: \(String(repeating: "f", count: 64))"))
        XCTAssertTrue(traceText.contains("Reported observation traces: 2"))
        XCTAssertTrue(traceText.contains("Measured evidence traces: 0"))
        XCTAssertTrue(traceText.contains("Calculated method: claude-code-quota-explanation-v2"))
        XCTAssertTrue(traceText.contains("provenance: Reported percentages, Calculated movement, Measured local breakdown"))
    }

    func testClaudeExplanationAlwaysShowsExactIntervalTraceForOneInterval() {
        launch(screen: "claude-explanation-single")

        let trace = app.staticTexts["claude-explanation-trace"]
        XCTAssertTrue(trace.waitForExistence(timeout: 5))
        XCTAssertFalse(app.popUpButtons["claude-explanation-interval"].exists)
        let text = (trace.value as? String) ?? trace.label
        XCTAssertTrue(text.contains("Exact selected interval:"))
        XCTAssertTrue(text.contains("interval trace: \(String(repeating: "f", count: 64))"))
        XCTAssertTrue(text.contains("Reported observation traces: 2"))
        XCTAssertTrue(text.contains("Calculated method: claude-code-quota-explanation-v2"))
    }

    func testPlanningSurfaceAcceptsBoundedInputAndExplainsUnavailableHistory() {
        launch(screen: "popover")

        XCTAssertTrue(app.staticTexts["planned-workload-title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.steppers["planned-workload-units"].exists)
        let outcome = app.staticTexts["planned-workload-outcome"]
        XCTAssertTrue(outcome.exists)
        let text = (outcome.value as? String) ?? outcome.label
        XCTAssertTrue(text.contains("Assessment unavailable"))
        XCTAssertTrue(text.contains("No supported adapter records measured completed runs"))
    }

    func testInvestigationWorkflowShowsExactRangeAndTraceableEvidence() {
        launch(screen: "investigation-all-available")

        XCTAssertTrue(app.popUpButtons["investigation-product"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers["investigation-range-start"].exists)
        XCTAssertTrue(app.datePickers["investigation-range-end"].exists)
        XCTAssertTrue(text(of: app.staticTexts["investigation-range-basis"]).contains("UTC"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-authoritative-total"]).contains("Reported provider total"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-local-breakdown"]).contains("Observed Local Breakdown"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-unattributed"]).contains("Unattributed"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-reset"]).contains("Reported reset"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-forecast"]).contains("Calculated"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-anomaly"]).contains("method"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-version"]).contains("adapter"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-api-unavailable"]).contains("API-provider quota evidence is unavailable"))
    }

    func testInvestigationDistinguishesObservedZeroGapAndPartialEvidence() {
        launch(screen: "investigation-partial")

        XCTAssertTrue(app.staticTexts["investigation-publication-state"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: app.staticTexts["investigation-publication-state"]).contains("Partial evidence"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-observed-zero"]).contains("Observed Zero"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-gap"]).contains("Gap"))
        XCTAssertFalse(text(of: app.staticTexts["investigation-gap"]).contains("Observed Zero"))
    }

    func testInvestigationHasDistinctLoadingEmptyUnavailableAndErrorFixtures() {
        for screen in ["investigation-loading", "investigation-empty", "investigation-unavailable", "investigation-error"] {
            app.terminate()
            launch(screen: screen)
            XCTAssertTrue(app.staticTexts["investigation-publication-state"].waitForExistence(timeout: 5), screen)
        }
    }

    func testPopoverExposesSubordinateInvestigationEntryPoint() {
        launch(screen: "popover")

        XCTAssertTrue(app.buttons["open-forensic-investigation"].waitForExistence(timeout: 5))
    }

    private func launch(screen: String) {
        app.launchEnvironment["LIMITBAR_UI_TEST_SCREEN"] = screen
        app.launch()
    }

    private func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }
}
