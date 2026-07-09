# LimitBar Issue 2 Usage Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define LimitBar's normalized usage model and status rules in `LimitBarCore`.

**Architecture:** Add focused Swift value types in `LimitBarCore` and keep status decisions as pure functions. Keep SwiftUI out of the core package, and bridge the resulting menu bar status back to the existing shell-facing `AppStatus` type.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation `Date`, `Calendar`, and `DateInterval`.

## Global Constraints

- The implementation belongs in `LimitBarCore`.
- Do not add provider integrations, persistence, credentials, notifications, sounds, or urgent alerts.
- Do not estimate live burn rate or invent missing 5-hour quota, weekly quota, or TPM values.
- Use confirmed supported limits only for menu bar percentages.
- Keep tests independent from SwiftUI and provider APIs.

---

## File Structure

- Create `LimitBarCore/Sources/LimitBarCore/UsageModel.swift` for normalized usage domain types and pure status functions.
- Create `LimitBarCore/Tests/LimitBarCoreTests/UsageModelTests.swift` for issue #2 behavior tests.
- Modify `LimitBarCore/Sources/LimitBarCore/AppStatus.swift` to bridge `MenuBarStatus` into the existing app-shell status model.
- Modify `LimitBarCore/Tests/LimitBarCoreTests/AppStatusTests.swift` to cover the bridge while preserving the initial shell status.

---

### Task 1: Provider Kinds And Time Windows

**Files:**
- Create: `LimitBarCore/Sources/LimitBarCore/UsageModel.swift`
- Create: `LimitBarCore/Tests/LimitBarCoreTests/UsageModelTests.swift`

**Interfaces:**
- Produces: `public enum ProviderKind`, `public enum TimeWindow`, `ProviderKind.orderedCases`, `ProviderKind.displayName`, `TimeWindow.displayName`, `TimeWindow.interval(containing:calendar:)`.

- [ ] **Step 1: Write the failing tests**

Create `LimitBarCore/Tests/LimitBarCoreTests/UsageModelTests.swift`:

```swift
import Foundation
import Testing
@testable import LimitBarCore

@Suite("Usage model")
struct UsageModelTests {
    @Test("providers use the fixed display order")
    func providersUseFixedDisplayOrder() {
        #expect(ProviderKind.orderedCases == [.anthropic, .azureOpenAI, .openAI])
        #expect(ProviderKind.orderedCases.map(\.displayName) == ["Anthropic", "Azure OpenAI", "OpenAI"])
    }

    @Test("today window covers the local day containing the reference date")
    func todayWindowCoversReferenceDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try #require(calendar.date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 7, day: 10, hour: 15, minute: 30)))

        let interval = TimeWindow.today.interval(containing: reference, calendar: calendar)

        #expect(interval.start == calendar.startOfDay(for: reference))
        #expect(interval.end == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)))
        #expect(TimeWindow.today.displayName == "Today")
    }

    @Test("current week window uses the calendar week containing the reference date")
    func currentWeekWindowUsesCalendarWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let reference = try #require(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 7, day: 10, hour: 15)))

        let interval = TimeWindow.currentWeek.interval(containing: reference, calendar: calendar)
        let expected = try #require(calendar.dateInterval(of: .weekOfYear, for: reference))

        #expect(interval == expected)
        #expect(TimeWindow.currentWeek.displayName == "Current Week")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: FAIL because `ProviderKind` and `TimeWindow` are not defined.

- [ ] **Step 3: Add minimal implementation**

Create `LimitBarCore/Sources/LimitBarCore/UsageModel.swift`:

```swift
import Foundation

public enum ProviderKind: String, CaseIterable, Codable, Equatable, Sendable {
    case anthropic
    case azureOpenAI
    case openAI

    public static let orderedCases: [ProviderKind] = [.anthropic, .azureOpenAI, .openAI]

    public var displayName: String {
        switch self {
        case .anthropic:
            "Anthropic"
        case .azureOpenAI:
            "Azure OpenAI"
        case .openAI:
            "OpenAI"
        }
    }
}

public enum TimeWindow: String, CaseIterable, Codable, Equatable, Sendable {
    case today
    case currentWeek

    public var displayName: String {
        switch self {
        case .today:
            "Today"
        case .currentWeek:
            "Current Week"
        }
    }

    public func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        case .currentWeek:
            return calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, end: date)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: PASS with existing tests plus 3 new usage model tests.

- [ ] **Step 5: Commit**

Run: `git add LimitBarCore/Sources/LimitBarCore/UsageModel.swift LimitBarCore/Tests/LimitBarCoreTests/UsageModelTests.swift && git commit -m "Add provider and time window model"`

---

### Task 2: Normalized Usage And Menu Bar Status Rules

**Files:**
- Modify: `LimitBarCore/Sources/LimitBarCore/UsageModel.swift`
- Modify: `LimitBarCore/Tests/LimitBarCoreTests/UsageModelTests.swift`

**Interfaces:**
- Consumes: `ProviderKind`, `TimeWindow`.
- Produces: `TokenUsage`, `CostSource`, `Cost`, `LimitStatus`, `Freshness`, `UsageMetric`, `MenuBarStatusColor`, `MenuBarStatus`.

- [ ] **Step 1: Append failing tests**

Append these tests inside `UsageModelTests` before the closing brace:

```swift
    @Test("token usage keeps input and output confirmed and computes total")
    func tokenUsageComputesTotal() {
        let usage = TokenUsage(inputTokens: 120, outputTokens: 80)

        #expect(usage.inputTokens == 120)
        #expect(usage.outputTokens == 80)
        #expect(usage.totalTokens == 200)
    }

    @Test("cost source labels stay honest")
    func costSourceLabelsStayHonest() {
        #expect(CostSource.providerReported.displayLabel == "Provider reported")
        #expect(CostSource.calculatedEstimate.displayLabel == "Calculated estimate")
    }

    @Test("freshness becomes stale after two missed refreshes")
    func freshnessBecomesStaleAfterTwoMissedRefreshes() {
        #expect(Freshness.from(missedRefreshes: 0) == .fresh)
        #expect(Freshness.from(missedRefreshes: 1) == .fresh)
        #expect(Freshness.from(missedRefreshes: 2) == .stale(missedRefreshes: 2))
    }

    @Test("unsupported limits do not expose confirmed percentages")
    func unsupportedLimitsDoNotExposeConfirmedPercentages() {
        #expect(LimitStatus.unsupportedByProviderAPI.confirmedUsagePercentage == nil)
        #expect(LimitStatus.disconnected.confirmedUsagePercentage == nil)
        #expect(LimitStatus.confirmed(used: 82, limit: 100).confirmedUsagePercentage == 82)
    }

    @Test("menu bar status uses threshold colors from worst confirmed supported limit")
    func menuBarStatusUsesThresholdColors() {
        #expect(MenuBarStatus.from(metrics: [metric(used: 69)]).color == .green)
        #expect(MenuBarStatus.from(metrics: [metric(used: 70)]).color == .yellow)
        #expect(MenuBarStatus.from(metrics: [metric(used: 90)]).color == .red)
        #expect(MenuBarStatus.from(metrics: [metric(used: 40), metric(used: 82)]).confirmedUsagePercentage == 82)
    }

    @Test("menu bar status is gray for stale or unsupported data")
    func menuBarStatusIsGrayForStaleOrUnsupportedData() {
        let stale = metric(used: 80, freshness: .stale(missedRefreshes: 2))
        let unsupported = metric(limitStatus: .unsupportedByProviderAPI)

        #expect(MenuBarStatus.from(metrics: [stale]).color == .gray)
        #expect(MenuBarStatus.from(metrics: [stale]).confirmedUsagePercentage == 80)
        #expect(MenuBarStatus.from(metrics: [unsupported]).color == .gray)
        #expect(MenuBarStatus.from(metrics: [unsupported]).confirmedUsagePercentage == nil)
    }

    @Test("usage metric excludes sensitive content by shape")
    func usageMetricExcludesSensitiveContentByShape() {
        let usageMetric = metric(used: 42)

        #expect(usageMetric.provider == .anthropic)
        #expect(usageMetric.accountLabel == "Personal")
        #expect(usageMetric.projectLabel == "LimitBar")
        #expect(usageMetric.modelLabel == "claude-sonnet")
        #expect(usageMetric.deploymentLabel == nil)
        #expect(usageMetric.tokenUsage.totalTokens == 30)
    }

    private func metric(
        used: Double = 50,
        limitStatus: LimitStatus? = nil,
        freshness: Freshness = .fresh
    ) -> UsageMetric {
        UsageMetric(
            provider: .anthropic,
            accountLabel: "Personal",
            projectLabel: "LimitBar",
            modelLabel: "claude-sonnet",
            deploymentLabel: nil,
            timeWindow: .today,
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 20),
            cost: Cost(amount: Decimal(string: "1.23")!, currencyCode: "USD", source: .providerReported),
            limitStatus: limitStatus ?? .confirmed(used: used, limit: 100),
            refreshedAt: Date(timeIntervalSince1970: 1_783_683_200),
            freshness: freshness
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: FAIL because the new usage/status types are not defined.

- [ ] **Step 3: Append implementation**

Append to `LimitBarCore/Sources/LimitBarCore/UsageModel.swift`:

```swift
public struct TokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int

    public var totalTokens: Int { inputTokens + outputTokens }

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum CostSource: String, Codable, Equatable, Sendable {
    case providerReported
    case calculatedEstimate

    public var displayLabel: String {
        switch self {
        case .providerReported:
            "Provider reported"
        case .calculatedEstimate:
            "Calculated estimate"
        }
    }
}

public struct Cost: Codable, Equatable, Sendable {
    public let amount: Decimal
    public let currencyCode: String
    public let source: CostSource

    public init(amount: Decimal, currencyCode: String, source: CostSource) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.source = source
    }
}

public enum LimitStatus: Codable, Equatable, Sendable {
    case confirmed(used: Double, limit: Double)
    case unsupportedByProviderAPI
    case disconnected
    case unavailable

    public var confirmedUsagePercentage: Int? {
        guard case let .confirmed(used, limit) = self, limit > 0 else {
            return nil
        }

        return Int(((used / limit) * 100).rounded())
    }
}

public enum Freshness: Codable, Equatable, Sendable {
    case fresh
    case stale(missedRefreshes: Int)

    public var isStale: Bool {
        if case .stale = self { true } else { false }
    }

    public static func from(missedRefreshes: Int) -> Freshness {
        missedRefreshes >= 2 ? .stale(missedRefreshes: missedRefreshes) : .fresh
    }
}

public struct UsageMetric: Codable, Equatable, Sendable {
    public let provider: ProviderKind
    public let accountLabel: String?
    public let projectLabel: String?
    public let modelLabel: String
    public let deploymentLabel: String?
    public let timeWindow: TimeWindow
    public let tokenUsage: TokenUsage
    public let cost: Cost?
    public let limitStatus: LimitStatus
    public let refreshedAt: Date?
    public let freshness: Freshness

    public init(
        provider: ProviderKind,
        accountLabel: String?,
        projectLabel: String?,
        modelLabel: String,
        deploymentLabel: String?,
        timeWindow: TimeWindow,
        tokenUsage: TokenUsage,
        cost: Cost?,
        limitStatus: LimitStatus,
        refreshedAt: Date?,
        freshness: Freshness
    ) {
        self.provider = provider
        self.accountLabel = accountLabel
        self.projectLabel = projectLabel
        self.modelLabel = modelLabel
        self.deploymentLabel = deploymentLabel
        self.timeWindow = timeWindow
        self.tokenUsage = tokenUsage
        self.cost = cost
        self.limitStatus = limitStatus
        self.refreshedAt = refreshedAt
        self.freshness = freshness
    }
}

public enum MenuBarStatusColor: String, Codable, Equatable, Sendable {
    case green
    case yellow
    case red
    case gray
}

public struct MenuBarStatus: Codable, Equatable, Sendable {
    public let color: MenuBarStatusColor
    public let confirmedUsagePercentage: Int?

    public init(color: MenuBarStatusColor, confirmedUsagePercentage: Int?) {
        self.color = color
        self.confirmedUsagePercentage = confirmedUsagePercentage
    }

    public static func from(metrics: [UsageMetric]) -> MenuBarStatus {
        let percentages = metrics.compactMap(\.limitStatus.confirmedUsagePercentage)
        let worstPercentage = percentages.max()

        guard let worstPercentage else {
            return MenuBarStatus(color: .gray, confirmedUsagePercentage: nil)
        }

        if metrics.contains(where: { $0.freshness.isStale }) {
            return MenuBarStatus(color: .gray, confirmedUsagePercentage: worstPercentage)
        }

        if worstPercentage >= 90 {
            return MenuBarStatus(color: .red, confirmedUsagePercentage: worstPercentage)
        }

        if worstPercentage >= 70 {
            return MenuBarStatus(color: .yellow, confirmedUsagePercentage: worstPercentage)
        }

        return MenuBarStatus(color: .green, confirmedUsagePercentage: worstPercentage)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: PASS with existing tests plus all usage model tests.

- [ ] **Step 5: Commit**

Run: `git add LimitBarCore/Sources/LimitBarCore/UsageModel.swift LimitBarCore/Tests/LimitBarCoreTests/UsageModelTests.swift && git commit -m "Add normalized usage status model"`

---

### Task 3: AppStatus Bridge

**Files:**
- Modify: `LimitBarCore/Sources/LimitBarCore/AppStatus.swift`
- Modify: `LimitBarCore/Tests/LimitBarCoreTests/AppStatusTests.swift`

**Interfaces:**
- Consumes: `MenuBarStatus`, `MenuBarStatusColor`.
- Produces: `AppStatus.statusColorName`, `AppStatus.from(menuBarStatus:)`.

- [ ] **Step 1: Add failing bridge test**

Append this test inside `AppStatusTests` before the closing brace:

```swift
    @Test("app status can be derived from menu bar status")
    func appStatusCanBeDerivedFromMenuBarStatus() {
        let appStatus = AppStatus.from(menuBarStatus: MenuBarStatus(color: .yellow, confirmedUsagePercentage: 82))

        #expect(appStatus.menuBarText == "82%")
        #expect(appStatus.symbolName == "gauge.with.dots.needle.bottom.50percent")
        #expect(appStatus.statusColorName == "yellow")
        #expect(appStatus.accessibilityDescription == "LimitBar usage monitor, 82%, yellow")
    }
```

Update the existing `initialStatusIsCompactAndNeutral` test with this additional assertion:

```swift
        #expect(status.statusColorName == "gray")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: FAIL because `AppStatus.statusColorName` and `AppStatus.from(menuBarStatus:)` are not defined.

- [ ] **Step 3: Update AppStatus implementation**

Replace `LimitBarCore/Sources/LimitBarCore/AppStatus.swift` with:

```swift
public struct AppStatus: Equatable, Sendable {
    public let menuBarText: String
    public let symbolName: String
    public let statusColorName: String
    public let accessibilityDescription: String

    public init(
        menuBarText: String,
        symbolName: String,
        statusColorName: String = "gray",
        accessibilityDescription: String
    ) {
        self.menuBarText = menuBarText
        self.symbolName = symbolName
        self.statusColorName = statusColorName
        self.accessibilityDescription = accessibilityDescription
    }

    public static let initial = AppStatus(
        menuBarText: "LimitBar",
        symbolName: "gauge.with.dots.needle.bottom.50percent",
        statusColorName: "gray",
        accessibilityDescription: "LimitBar usage monitor"
    )

    public static func from(menuBarStatus: MenuBarStatus) -> AppStatus {
        let text = menuBarStatus.confirmedUsagePercentage.map { "\($0)%" } ?? "LimitBar"
        let colorName = menuBarStatus.color.rawValue
        let accessibilityDescription = "LimitBar usage monitor, \(text), \(colorName)"

        return AppStatus(
            menuBarText: text,
            symbolName: "gauge.with.dots.needle.bottom.50percent",
            statusColorName: colorName,
            accessibilityDescription: accessibilityDescription
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`

Expected: PASS.

- [ ] **Step 5: Run native build**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

Run: `git add LimitBarCore/Sources/LimitBarCore/AppStatus.swift LimitBarCore/Tests/LimitBarCoreTests/AppStatusTests.swift && git commit -m "Bridge menu bar status to app status"`

---

## Final Verification

- Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`.
- Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build`.
- Run `git status --short` and verify no uncommitted changes remain except intentional commits.
- Run the code review workflow against `main` before pushing.
- Run `no-mistakes axi` and then the available no-mistakes gate command before pushing if the gate can start a run for this branch.

## Self-Review

- Spec coverage: Task 1 covers provider order and time windows, Task 2 covers normalized usage fields, cost labels, limit statuses, stale behavior, and menu bar thresholds, and Task 3 covers the `AppStatus` bridge.
- Completion-marker scan: no unfinished markers, vague implementation steps, or unspecified tests remain.
- Type consistency: `ProviderKind`, `TimeWindow`, `TokenUsage`, `CostSource`, `Cost`, `LimitStatus`, `Freshness`, `UsageMetric`, `MenuBarStatusColor`, `MenuBarStatus`, and `AppStatus.from(menuBarStatus:)` are named consistently across tasks.
