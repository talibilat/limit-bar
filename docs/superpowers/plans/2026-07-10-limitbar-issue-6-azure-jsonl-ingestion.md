# LimitBar Issue 6 Azure JSONL Ingestion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import confirmed Azure OpenAI token usage from a local JSONL file into the existing SQLite-backed monitoring UI with safe diagnostics and integration settings.

**Architecture:** Treat the complete JSONL file as the source of truth on each load. Parse and aggregate events in `LimitBarCore`, transactionally replace only Azure SQLite rows, and expose a compact import report to the SwiftUI settings surface while preserving the existing normalized metric and pricing paths.

**Tech Stack:** Swift 6, Foundation, SQLite3, Swift Testing, SwiftUI, AppKit, macOS 14+.

## Global Constraints

- Resolve the integration file to `~/Library/Application Support/LimitBar/usage-events.jsonl`.
- Accept only confirmed Azure OpenAI events with provider, ISO-8601 timestamp, model, input tokens, output tokens, and optional deployment.
- Never persist raw JSON, prompts, responses, request bodies, terminal output, source code, or credentials.
- Never call Azure management APIs or invent quota or rate-limit values.
- Every imported Azure metric uses `Unsupported by provider API` as its limit status.
- Re-reading unchanged JSONL must not double-count usage.
- A malformed line must not prevent later valid lines from importing.

---

## File Structure

- Create `LimitBarCore/Sources/LimitBarCore/AzureUsageEvents.swift` for the event contract, JSONL parser, path resolution, aggregation, import reporting, and orchestration.
- Create `LimitBarCore/Tests/LimitBarCoreTests/AzureUsageEventsTests.swift` for parser, path, aggregation, and file-ingestion behavior.
- Modify `LimitBarCore/Sources/LimitBarCore/SQLiteUsageMetricStore.swift` to transactionally replace one provider's rows.
- Modify `LimitBarCore/Tests/LimitBarCoreTests/SQLiteUsageMetricStoreTests.swift` to prove replacement isolation and idempotency.
- Modify `LimitBarCore/Sources/LimitBarCore/StoredUsageMetrics.swift` to run Azure ingestion after retention and empty-store seeding and expose its report.
- Modify `LimitBarCore/Tests/LimitBarCoreTests/StoredUsageMetricsTests.swift` to verify imported Azure rows replace demo Azure rows without affecting other providers.
- Modify `LimitBar/LimitBarSettingsView.swift` to display the path, import diagnostics, and Reveal in Finder action.
- Modify `LimitBar/MonitoringPopoverView.swift` to remove demo-only Azure copy and identify locally imported usage.

### Task 1: Azure Event Contract And JSONL Parser

**Files:**
- Create: `LimitBarCore/Sources/LimitBarCore/AzureUsageEvents.swift`
- Create: `LimitBarCore/Tests/LimitBarCoreTests/AzureUsageEventsTests.swift`

**Interfaces:**
- Produces: `AzureUsageEvent`, `AzureUsageDiagnostic`, `AzureUsageParseResult`, `AzureUsageEventParser.parse(_:)`, and `AzureUsageEventFile.url(applicationSupportDirectory:)`.

- [ ] **Step 1: Write failing parser and path tests**

Add tests that parse this exact event and assert every field:

```swift
let data = Data(#"{"provider":"azureOpenAI","timestamp":"2026-07-10T09:30:00Z","model":"gpt-4.1","inputTokens":120,"outputTokens":30,"deployment":"team-tools"}"#.utf8)
let result = AzureUsageEventParser.parse(data)
#expect(result.events == [AzureUsageEvent(timestamp: date("2026-07-10T09:30:00Z"), model: "gpt-4.1", deployment: "team-tools", inputTokens: 120, outputTokens: 30)])
#expect(result.diagnostics.isEmpty)
```

Add table-driven rejected-line cases for malformed JSON, `provider: "openAI"`, a missing required field, an invalid timestamp, an empty model, negative input tokens, and negative output tokens. Assert that a valid line after each rejected line still appears and diagnostics report only line number plus a safe reason. Add an unknown-field case that succeeds and a path test expecting `<applicationSupport>/LimitBar/usage-events.jsonl`.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore --filter AzureUsageEventsTests`

Expected: FAIL because the Azure event types do not exist.

- [ ] **Step 3: Implement the parser and path resolver**

Define these public value types:

```swift
public struct AzureUsageEvent: Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let deployment: String?
    public let inputTokens: Int
    public let outputTokens: Int
}

public struct AzureUsageDiagnostic: Equatable, Sendable {
    public let lineNumber: Int?
    public let message: String
}

public struct AzureUsageParseResult: Equatable, Sendable {
    public let events: [AzureUsageEvent]
    public let diagnostics: [AzureUsageDiagnostic]
}
```

Implement `AzureUsageEventParser.parse(_:)` by splitting on newline bytes, skipping whitespace-only lines, decoding a private raw `Codable` structure, validating provider and trimmed strings, parsing ISO-8601 with and without fractional seconds, and appending a diagnostic such as `Invalid JSON event`, `Expected provider azureOpenAI`, `Invalid timestamp`, `Model is required`, or `Token counts must be nonnegative`. Never place source line contents in a diagnostic.

Implement:

```swift
public enum AzureUsageEventFile {
    public static func url(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("LimitBar", isDirectory: true)
            .appendingPathComponent("usage-events.jsonl", isDirectory: false)
    }
}
```

- [ ] **Step 4: Run focused and full core tests**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore --filter AzureUsageEventsTests`

Expected: PASS.

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: all tests PASS.

- [ ] **Step 5: Commit the parser slice**

```bash
git add LimitBarCore/Sources/LimitBarCore/AzureUsageEvents.swift LimitBarCore/Tests/LimitBarCoreTests/AzureUsageEventsTests.swift
git commit -m "Parse Azure usage JSONL events"
```

### Task 2: Deterministic Azure Aggregation

**Files:**
- Modify: `LimitBarCore/Sources/LimitBarCore/AzureUsageEvents.swift`
- Modify: `LimitBarCore/Tests/LimitBarCoreTests/AzureUsageEventsTests.swift`

**Interfaces:**
- Consumes: `[AzureUsageEvent]`, `Date`, and `Calendar`.
- Produces: `AzureUsageImporter.metrics(events:now:calendar:) -> [UsageMetric]`.

- [ ] **Step 1: Write failing aggregation tests**

Use a Gregorian UTC calendar and a fixed Wednesday noon. Create two same-model/same-deployment events today, one same-model/different-deployment event earlier in the week, and one event before the week. Assert:

```swift
let metrics = AzureUsageImporter.metrics(events: events, now: now, calendar: calendar)
let today = metrics.filter { $0.timeWindow == .today }
let week = metrics.filter { $0.timeWindow == .currentWeek }
#expect(today.count == 1)
#expect(today[0].tokenUsage == TokenUsage(inputTokens: 30, outputTokens: 12))
#expect(week.count == 2)
#expect(metrics.allSatisfy { $0.provider == .azureOpenAI })
#expect(metrics.allSatisfy { $0.limitStatus == .unsupportedByProviderAPI })
#expect(metrics.allSatisfy { $0.freshness == .fresh })
```

Assert rows are ordered by time window, model, then deployment; an event exactly at an interval end is excluded; deployment is retained; and the latest grouped event timestamp is used as `refreshedAt`.

- [ ] **Step 2: Run tests and verify failure**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore --filter AzureUsageEventsTests`

Expected: FAIL because `AzureUsageImporter` does not exist.

- [ ] **Step 3: Implement minimal deterministic aggregation**

Add a private hashable grouping key containing `TimeWindow`, model, and deployment. For each of `.today` and `.currentWeek`, include events where `interval.contains(event.timestamp)`, group them, sum token sides, and emit:

```swift
UsageMetric(
    provider: .azureOpenAI,
    accountLabel: nil,
    projectLabel: nil,
    modelLabel: key.model,
    deploymentLabel: key.deployment,
    timeWindow: key.timeWindow,
    tokenUsage: TokenUsage(inputTokens: aggregate.input, outputTokens: aggregate.output),
    cost: nil,
    limitStatus: .unsupportedByProviderAPI,
    refreshedAt: aggregate.latestTimestamp,
    freshness: .fresh
)
```

- [ ] **Step 4: Run focused and full core tests**

Run the focused Azure test command, then the full core test command from Task 1.

Expected: all tests PASS.

- [ ] **Step 5: Commit aggregation**

```bash
git add LimitBarCore/Sources/LimitBarCore/AzureUsageEvents.swift LimitBarCore/Tests/LimitBarCoreTests/AzureUsageEventsTests.swift
git commit -m "Aggregate Azure usage metrics"
```

### Task 3: Transactional Provider Replacement

**Files:**
- Modify: `LimitBarCore/Sources/LimitBarCore/SQLiteUsageMetricStore.swift`
- Modify: `LimitBarCore/Tests/LimitBarCoreTests/SQLiteUsageMetricStoreTests.swift`

**Interfaces:**
- Produces: `SQLiteUsageMetricStore.replaceMetrics(for:with:) throws`.

- [ ] **Step 1: Write failing persistence tests**

Save Anthropic, old Azure, and OpenAI rows. Replace Azure with a new row and assert old Azure is gone while both non-Azure rows remain. Call replacement again with the same row and assert no duplication. Replace Azure with `[]` and assert only non-Azure rows remain. Add a validation test that passing an OpenAI metric while replacing Azure throws without changing stored rows.

- [ ] **Step 2: Run the focused store tests and verify failure**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore --filter SQLiteUsageMetricStoreTests`

Expected: FAIL because `replaceMetrics(for:with:)` does not exist.

- [ ] **Step 3: Implement transactional replacement**

Add `UsageMetricStoreError.providerMismatch`. Validate all metrics before opening the transaction. Execute `BEGIN IMMEDIATE TRANSACTION`, delete rows with `provider = ?`, call existing `save(_:)`, then `COMMIT`. On any error, execute `ROLLBACK` and rethrow the original error. Use bound parameters for provider deletion rather than string interpolation.

- [ ] **Step 4: Run focused and full tests**

Run the focused store command and the full core command.

Expected: all tests PASS.

- [ ] **Step 5: Commit persistence**

```bash
git add LimitBarCore/Sources/LimitBarCore/SQLiteUsageMetricStore.swift LimitBarCore/Tests/LimitBarCoreTests/SQLiteUsageMetricStoreTests.swift
git commit -m "Replace provider metrics transactionally"
```

### Task 4: File Ingestion And Stored Snapshot Integration

**Files:**
- Modify: `LimitBarCore/Sources/LimitBarCore/AzureUsageEvents.swift`
- Modify: `LimitBarCore/Sources/LimitBarCore/StoredUsageMetrics.swift`
- Modify: `LimitBarCore/Tests/LimitBarCoreTests/AzureUsageEventsTests.swift`
- Modify: `LimitBarCore/Tests/LimitBarCoreTests/StoredUsageMetricsTests.swift`

**Interfaces:**
- Produces: `AzureUsageImportReport`, `AzureUsageImporter.importFile(at:into:now:calendar:fileManager:)`, and `StoredUsageMetricsSnapshot.azureIntegration`.

- [ ] **Step 1: Write failing file and snapshot tests**

Create temporary JSONL files. Assert a valid plus malformed file reports `acceptedCount == 1`, `rejectedCount == 1`, stores both Today and Current Week aggregates, and exposes bounded safe diagnostics. Import the same file twice and assert totals do not change. Assert a missing file replaces Azure rows with an empty set and reports no error. Make a path unreadable and assert the previous Azure row remains with a safe file error.

For `StoredUsageMetrics`, seed an empty store, ingest a valid Azure event, and assert demo Azure rows are replaced while Anthropic and OpenAI demo rows remain.

- [ ] **Step 2: Run focused tests and verify failure**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore --filter AzureUsageEventsTests`

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore --filter StoredUsageMetricsTests`

Expected: FAIL because file import reporting is absent.

- [ ] **Step 3: Implement import reporting and orchestration**

Define:

```swift
public struct AzureUsageImportReport: Equatable, Sendable {
    public let fileURL: URL
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let diagnostics: [AzureUsageDiagnostic]
}
```

`importFile` checks `fileExists(atPath:)`. For a missing file, replace Azure with `[]` and return zero counts. For an existing file, read `Data(contentsOf:)`, parse, aggregate, replace Azure, and return the valid event count, total rejected count, and at most the first 20 diagnostics. If reading fails, return one diagnostic with no line number and do not call replacement.

Extend `StoredUsageMetricsSnapshot` with `azureIntegration`. Keep a package-testable load overload accepting `azureFileURL`, `now`, and `calendar`. Its sequence is retention, empty-store demo seeding, Azure import, then `allMetrics()`. `loadFromApplicationSupport` resolves the user Application Support directory once and uses it for both SQLite and JSONL paths.

- [ ] **Step 4: Run all core tests**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: all tests PASS.

- [ ] **Step 5: Commit integrated loading**

```bash
git add LimitBarCore/Sources/LimitBarCore/AzureUsageEvents.swift LimitBarCore/Sources/LimitBarCore/StoredUsageMetrics.swift LimitBarCore/Tests/LimitBarCoreTests/AzureUsageEventsTests.swift LimitBarCore/Tests/LimitBarCoreTests/StoredUsageMetricsTests.swift
git commit -m "Import Azure usage into stored metrics"
```

### Task 5: Settings Integration And Popover Copy

**Files:**
- Modify: `LimitBar/LimitBarSettingsView.swift`
- Modify: `LimitBar/MonitoringPopoverView.swift`

**Interfaces:**
- Consumes: `StoredUsageMetricsSnapshot.azureIntegration` and `AzureUsageImportReport.fileURL`.

- [ ] **Step 1: Add the settings integration section**

Import AppKit and retain one snapshot in `LimitBarSettingsView` so database health and Azure diagnostics come from the same load. Add an `Integration` section with:

```swift
LabeledContent("Azure JSONL") {
    Text(snapshot.azureIntegration.fileURL.path)
        .textSelection(.enabled)
}
LabeledContent("Accepted events", value: snapshot.azureIntegration.acceptedCount.formatted())
LabeledContent("Rejected events", value: snapshot.azureIntegration.rejectedCount.formatted())
Button("Reveal in Finder") { revealAzureUsageFile() }
```

Render each bounded diagnostic as `Line N: reason` or just the safe reason. In `revealAzureUsageFile()`, create the parent directory if necessary, call `NSWorkspace.shared.activateFileViewerSelecting([fileURL])` when the file exists, and otherwise call `NSWorkspace.shared.open(parentDirectory)`.

- [ ] **Step 2: Update monitoring copy**

Replace `Demo data only. Provider integrations arrive in later issues.` with `Azure usage imports from the local JSONL integration.` Remove the hard-coded `Demo` card badge; use `Local` for non-empty Azure cards and `Demo` for other non-empty cards until subsequent provider issues replace their fixtures. Update the header subtitle from `Confirmed demo usage by provider` to `Confirmed usage by provider`.

- [ ] **Step 3: Build the native app**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run core tests again**

Run the full core test command.

Expected: all tests PASS.

- [ ] **Step 5: Commit UI integration**

```bash
git add LimitBar/LimitBarSettingsView.swift LimitBar/MonitoringPopoverView.swift
git commit -m "Show Azure JSONL integration status"
```

### Task 6: End-To-End Verification And Issue Delivery

**Files:**
- Modify only files required by verified defects found during this task.

- [ ] **Step 1: Run the full core suite**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: all tests PASS.

- [ ] **Step 2: Run the native build**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run a launch and ingestion smoke test**

Create a temporary test event only after backing up any existing user integration file within the repository-independent manual test procedure is explicitly avoided. Instead, launch the built app against automated temporary-directory coverage and inspect the settings and popover through the native build previews or app UI without altering external user files. Verify path text, Reveal in Finder behavior, Azure model/deployment display, cost label after configured pricing, unsupported limit copy, and malformed count display.

- [ ] **Step 4: Review the branch**

Review `git diff main...HEAD` for acceptance coverage, secret leakage, raw JSON persistence, destructive provider replacement, timestamp boundaries, integer validation, and UI regressions. Run `git diff --check`.

Expected: no findings and no whitespace errors, or fix findings and repeat Steps 1-4.

- [ ] **Step 5: Push and open the pull request**

Push the issue branch to `origin`, create a PR referencing `Closes #6`, and wait for required checks. Do not use the local `no-mistakes` remote because the user limited work to this repository and GitHub.

- [ ] **Step 6: Merge and verify closure**

Merge the PR through GitHub after checks pass, verify issue #6 is closed, update local `main` from `origin/main`, and then inspect the remaining open issues for the next unblocked pipeline item.

## Self-Review

- Spec coverage: path resolution, schema validation, malformed-line isolation, deterministic Today/Current Week aggregation, deployment retention, transactional SQLite replacement, calculated pricing compatibility, diagnostics, Finder reveal, and unsupported limits each map to a task.
- Placeholder scan: no incomplete markers or deferred implementation steps remain.
- Type consistency: parser, importer, report, store replacement, and snapshot names are consistent across producer and consumer tasks.
- Scope check: Azure management APIs, event cursor persistence, raw event storage, file watching, and unrelated provider work remain excluded.
