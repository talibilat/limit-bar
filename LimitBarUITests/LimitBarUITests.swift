import XCTest

final class LimitBarUITests: XCTestCase {
    private var app: XCUIApplication!
    private var defaultsSuiteName: String!
    private var fixtureDirectory: URL!
    private var fixtureURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        let runIdentifier = UUID().uuidString
        defaultsSuiteName = "com.talibilat.LimitBar.ui-tests.\(runIdentifier)"
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
        app.launchEnvironment["LIMITBAR_UI_TEST_EXPORT_PATH"] = fixtureDirectory.appendingPathComponent("quota-evidence.json").path
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
        try super.tearDownWithError()
    }

    func testNativeAppLaunchesProductionPopoverContent() {
        launch(screen: "popover")

        XCTAssertTrue(app.windows["LimitBar UI Tests"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["app-title"].exists)
        XCTAssertTrue(app.staticTexts["rate-limit-placeholder"].exists)
        XCTAssertTrue(app.buttons["settings-action"].exists)
    }

    func testAnalysisTabPresentsClaudeAuthorizationAnalysis() {
        launch(screen: "popover")

        app.buttons["Analysis"].click()
        XCTAssertTrue(app.staticTexts["Analysis will appear after a Claude Code rate-limit report is available."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Read analysis"].exists)
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
        XCTAssertTrue(app.popUpButtons["diagnostic-export-product"].exists)
        XCTAssertTrue(app.datePickers["diagnostic-export-range-start"].exists)
        XCTAssertTrue(app.datePickers["diagnostic-export-range-end"].exists)
        XCTAssertTrue(text(of: app.staticTexts["diagnostic-export-range-basis"]).contains("Half-open"))
        XCTAssertFalse(app.buttons["diagnostic-export-save"].exists)
        previewButton.click()

        XCTAssertTrue(app.staticTexts["Review Diagnostic Export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["diagnostic-export-json-preview"].exists)
        XCTAssertFalse(app.buttons["diagnostic-export-save"].exists)
        let preview = app.staticTexts["diagnostic-export-json-preview"]
        let previewText = (preview.value as? String) ?? preview.label
        XCTAssertTrue(previewText.contains("schemaVersion"))
        XCTAssertTrue(previewText.contains("quotaEvidence"))
        XCTAssertTrue(previewText.contains("gregorian_utc_half_open"))
        XCTAssertFalse(previewText.contains("PRIVATE_SENTINEL_PROMPT_PATH_COOKIE"))
        app.buttons["diagnostic-export-approve"].click()
        XCTAssertTrue(app.buttons["diagnostic-export-choose-destination"].exists)
        app.buttons["diagnostic-export-choose-destination"].click()
        XCTAssertTrue(app.buttons["diagnostic-export-save"].exists)
        app.buttons["diagnostic-export-save"].click()
        let saved = try? String(contentsOf: fixtureDirectory.appendingPathComponent("quota-evidence.json"), encoding: .utf8)
        XCTAssertEqual(saved, previewText)
    }

    func testDiagnosticExportCancellationCreatesNoReport() {
        launch(screen: "diagnostic-export")
        app.buttons["diagnostic-export-preview"].click()
        XCTAssertTrue(app.buttons["diagnostic-export-approve"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureDirectory.appendingPathComponent("quota-evidence.json").path))
    }

    func testDiagnosticExportDestinationCancellationKeepsPreviewAndCreatesNoReport() {
        launch(screen: "diagnostic-export-cancel-destination")
        app.buttons["diagnostic-export-preview"].click()
        app.buttons["diagnostic-export-approve"].click()
        app.buttons["diagnostic-export-choose-destination"].click()

        XCTAssertTrue(app.buttons["diagnostic-export-choose-destination"].exists)
        XCTAssertFalse(app.buttons["diagnostic-export-save"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureDirectory.appendingPathComponent("quota-evidence.json").path))
    }

    func testDiagnosticExportProductPickerChangesExactCandidateBeforePreview() {
        launch(screen: "diagnostic-export")
        let picker = app.popUpButtons["diagnostic-export-product"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        app.menuItems["Claude Code"].click()
        app.buttons["diagnostic-export-preview"].click()

        let preview = app.staticTexts["diagnostic-export-json-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let previewText = (preview.value as? String) ?? preview.label
        XCTAssertTrue(previewText.contains(#""selectedProduct" : "claude_code""#))
        XCTAssertFalse(app.buttons["diagnostic-export-save"].exists)
    }

    func testDiagnosticExportCancellationAfterDestinationCreatesNoReport() {
        launch(screen: "diagnostic-export")
        app.buttons["diagnostic-export-preview"].click()
        app.buttons["diagnostic-export-approve"].click()
        app.buttons["diagnostic-export-choose-destination"].click()
        XCTAssertTrue(app.buttons["diagnostic-export-save"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureDirectory.appendingPathComponent("quota-evidence.json").path))
    }

    func testDiagnosticExportAppHostedWriteFailureRetriesSameDestinationAndBytes() {
        launch(screen: "diagnostic-export-write-retry")
        driveDiagnosticExportToSave()
        app.buttons["diagnostic-export-save"].click()
        XCTAssertTrue(app.staticTexts["Could not save the diagnostic export."].waitForExistence(timeout: 5))

        app.buttons["diagnostic-export-save"].click()

        XCTAssertTrue(app.staticTexts["diagnostic-export-write-attempts"].waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: app.staticTexts["diagnostic-export-write-attempts"]), "2")
        XCTAssertEqual(text(of: app.staticTexts["diagnostic-export-byte-equality"]), "equal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureDirectory.appendingPathComponent("quota-evidence.json").path))
    }

    func testDiagnosticExportAppHostedNetworkTrapSeesNoRequestsAcrossAllOperations() {
        launch(screen: "diagnostic-export-network-trap")
        driveDiagnosticExportToSave()
        app.buttons["diagnostic-export-save"].click()
        XCTAssertTrue(app.staticTexts["Could not save the diagnostic export."].waitForExistence(timeout: 5))
        app.buttons["diagnostic-export-save"].click()
        XCTAssertTrue(app.staticTexts["diagnostic-export-network-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: app.staticTexts["diagnostic-export-network-count"]), "0")

        app.buttons["diagnostic-export-preview"].click()
        XCTAssertTrue(app.buttons["diagnostic-export-approve"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertEqual(text(of: app.staticTexts["diagnostic-export-network-count"]), "0")
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
        XCTAssertTrue(text.contains("Measured local quota observations; Calculated movement: +3.5%"))
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

        app.buttons["Analysis"].click()
        XCTAssertTrue(app.staticTexts["Planned workload"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.steppers["planned-workload-units"].exists)
        XCTAssertTrue(app.staticTexts["No supported adapter records measured completed runs, so LimitBar did not estimate quota or completion."].exists)
    }

    func testInvestigationWorkflowShowsExactRangeAndTraceableEvidence() {
        launch(screen: "investigation-all-available")

        XCTAssertTrue(app.popUpButtons["investigation-product"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers["investigation-range-start"].exists)
        XCTAssertTrue(app.datePickers["investigation-range-end"].exists)
        XCTAssertTrue(text(of: app.staticTexts["investigation-range-basis"]).contains("UTC"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-authoritative-total"].firstMatch).contains("Calculated movement"))
        XCTAssertFalse(text(of: app.staticTexts["investigation-authoritative-total"].firstMatch).contains("Reported provider total"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-local-breakdown"].firstMatch).contains("Observed Local Breakdown"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-unattributed"].firstMatch).contains("Unattributed"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-reset"].firstMatch).contains("Reported reset"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-forecast"].firstMatch).contains("Calculated"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-anomaly"].firstMatch).contains("method"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-version"].firstMatch).contains("adapter"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-api-unavailable"]).contains("API-provider quota evidence is unavailable"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-selected-range"]).contains("half-open"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-traces"].firstMatch).contains("Privacy-safe bounded traces"))
        XCTAssertTrue(text(of: app.staticTexts["investigation-attribution-unavailable"]).contains("not mapped"))
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
            if screen == "investigation-loading" || screen == "investigation-error" {
                XCTAssertTrue(app.popUpButtons["investigation-product"].exists, screen)
            }
        }
    }

    func testInvestigationWorkflowOpensFromPopoverAndChangesProductAndRange() {
        launch(screen: "investigation-workflow")

        app.buttons["Analysis"].click()
        app.buttons["open-forensic-investigation"].click()
        let picker = app.popUpButtons["investigation-product"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let range = app.staticTexts["investigation-selected-range"]
        let originalRange = text(of: range)
        app.buttons["investigation-latest-range"].click()
        XCTAssertNotEqual(text(of: range), originalRange)

        picker.click()
        app.menuItems["Claude Code"].click()
        XCTAssertTrue(app.staticTexts["investigation-reset-unavailable"].waitForExistence(timeout: 5))
        let sentinel = "PRIVATE_SENTINEL_PROMPT_PATH_COOKIE"
        let sentinelPredicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR identifier CONTAINS %@", sentinel, sentinel, sentinel)
        XCTAssertFalse(app.staticTexts.matching(sentinelPredicate).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(sentinelPredicate).firstMatch.exists)
        XCTAssertFalse(app.popUpButtons.matching(sentinelPredicate).firstMatch.exists)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(picker.exists)
    }

    func testInvestigationKeyboardShortcutOpensAndEscapeRestoresPopoverFocusContext() {
        launch(screen: "investigation-workflow")

        app.buttons["Analysis"].click()
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.popUpButtons["investigation-product"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["open-forensic-investigation"].waitForExistence(timeout: 5))
    }

    func testInvestigationMinimumWindowLargeTextReducedMotionAndPrivacySentinel() {
        launch(screen: "investigation-minimum-large-text")

        XCTAssertEqual(app.windows["LimitBar UI Tests"].frame.size.width, 420, accuracy: 2)
        XCTAssertEqual(app.windows["LimitBar UI Tests"].frame.size.height, 552, accuracy: 2) // 520-point content plus title bar.
        XCTAssertTrue(app.popUpButtons["investigation-product"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["investigation-selected-range"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "PRIVATE_SENTINEL_PROMPT_PATH_COOKIE", "PRIVATE_SENTINEL_PROMPT_PATH_COOKIE")).firstMatch.exists)
    }

    func testPopoverExposesSubordinateInvestigationEntryPoint() {
        launch(screen: "popover")

        app.buttons["Analysis"].click()
        XCTAssertTrue(app.buttons["open-forensic-investigation"].waitForExistence(timeout: 5))
    }

    private func launch(screen: String) {
        app.launchEnvironment["LIMITBAR_UI_TEST_SCREEN"] = screen
        app.launch()
    }

    private func driveDiagnosticExportToSave() {
        XCTAssertTrue(app.buttons["diagnostic-export-preview"].waitForExistence(timeout: 5))
        app.buttons["diagnostic-export-preview"].click()
        XCTAssertTrue(app.buttons["diagnostic-export-approve"].waitForExistence(timeout: 5))
        app.buttons["diagnostic-export-approve"].click()
        app.buttons["diagnostic-export-choose-destination"].click()
        XCTAssertTrue(app.buttons["diagnostic-export-save"].waitForExistence(timeout: 5))
    }

    private func text(of element: XCUIElement) -> String {
        [element.label, element.value as? String]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
