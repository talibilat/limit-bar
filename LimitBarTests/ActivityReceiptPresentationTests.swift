import XCTest
import LimitBarCore
@testable import LimitBar

final class ActivityReceiptPresentationTests: XCTestCase {
    func testUnavailableStateSeparatesReceiptEvidenceFromQuotaAndCost() {
        let text = ActivityReceiptPresentation.detail(.unavailable(.insufficientLifecycleSemantics))
        XCTAssertTrue(text.contains("separate from provider quota movement and provider-reported cost"))
        XCTAssertTrue(text.contains("does not establish billing error"))
        XCTAssertTrue(text.contains(ActivityReceiptUnavailableReason.insufficientLifecycleSemantics.rawValue))
    }

    func testAvailableSummaryUsesNeutralAssociationLanguage() {
        let finding = ActivityDebuggerFinding(kind: .compactionAssociated(count: 3), statement: "3 compaction-associated operations were measured.")
        let summary = ActivityReceiptPresentation.summary(.available([finding]))
        XCTAssertEqual(summary, "3 compaction-associated operations were measured.")
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("waste"))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("caused"))
    }

    func testCompatibleRunDeltaUsesNeutralMeasuredLanguage() {
        let delta = ActivityDebuggerFinding(kind: .compatibleRunDelta(metric: "measured input tokens", delta: 15), statement: "The later compatible run had 15 more measured input tokens.")
        let detail = ActivityReceiptPresentation.detail(.available([
            ActivityDebuggerFinding(kind: .normalAttempts(count: 1), statement: "1 normal model attempt was measured."),
            delta,
        ]))
        XCTAssertTrue(detail.contains("later compatible run had 15 more measured input tokens"))
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("caused"))
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("waste"))
    }

    func testNewTypedUnavailableReasonsArePresentedWithoutPayloads() {
        XCTAssertTrue(ActivityReceiptPresentation.summary(.unavailable(.conflictingRecord)).contains("reused with different facts"))
        XCTAssertTrue(ActivityReceiptPresentation.summary(.unavailable(.futureTimestamp)).contains("allowed clock skew"))
        XCTAssertTrue(ActivityReceiptPresentation.summary(.unavailable(.tokenOverflow)).contains("safe analysis bound"))
        XCTAssertTrue(ActivityReceiptPresentation.summary(.unavailable(.missingImportMetadata)).contains("trusted import configuration"))
    }

    func testShareAndConfigurationFindingsRemainNeutral() {
        let share = ActivityDebuggerFinding(kind: .compatibleRunShareDelta(metric: "retry-evidence attempt share", earlierPercent: 20, laterPercent: 40), statement: "Among operations with observable retry evidence, the measured share changed from 20% to 40% in the later compatible run.")
        let changed = ActivityDebuggerFinding(kind: .incompatibleConfigurationChange(dimensions: ["mode", "concurrency"]), statement: "A previous run used different mode, concurrency. Values were not compared.")
        let detail = ActivityReceiptPresentation.detail(.available([share, changed]))
        XCTAssertTrue(detail.contains("Values were not compared"))
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("caused"))
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("waste"))
    }
}
