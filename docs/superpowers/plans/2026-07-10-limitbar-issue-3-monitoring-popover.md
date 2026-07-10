# LimitBar Issue 3 Monitoring Popover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the monitoring popover with demo provider data driven by `LimitBarCore` normalized metrics.

**Architecture:** Add testable demo data and provider-card grouping to `LimitBarCore`, then update the SwiftUI popover to render that model. Keep persistence, provider refresh, credentials, and final visual polish out of scope.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, SwiftUI.

## Global Constraints

- Provider cards remain in fixed order: Anthropic, Azure OpenAI, OpenAI.
- Today is selected by default and Current Week is available.
- Demo data uses normalized `UsageMetric` values.
- Unsupported states render as `Unsupported by provider API`.
- Stale states are visually distinguishable.
- Empty provider states render without collapsing the layout.
- Do not add persistence, provider integrations, credentials, notifications, sounds, or urgent alerts.

---

## File Structure

- Modify `LimitBarCore/Sources/LimitBarCore/UsageModel.swift` for hashable provider and time-window values used by SwiftUI.
- Create `LimitBarCore/Sources/LimitBarCore/UsagePresentation.swift` for provider cards, default selection, and limit display text.
- Create `LimitBarCore/Sources/LimitBarCore/DemoUsageData.swift` for demo metrics.
- Create `LimitBarCore/Tests/LimitBarCoreTests/DemoUsageDataTests.swift` for core demo/card behavior.
- Modify `LimitBar/MonitoringPopoverView.swift` to render cards, rows, tabs, stale badges, unsupported text, and empty states.

---

### Task 1: Core Demo Card Model

**Files:**
- Modify: `LimitBarCore/Sources/LimitBarCore/UsageModel.swift`
- Create: `LimitBarCore/Sources/LimitBarCore/DemoUsageData.swift`
- Create: `LimitBarCore/Tests/LimitBarCoreTests/DemoUsageDataTests.swift`

**Interfaces:**
- Produces: `TimeWindow.defaultSelection`, `LimitStatus.displayText`, `ProviderUsageCard`, `ProviderUsageCard.cards(from:timeWindow:)`, `DemoUsageData.metrics`.

- [ ] **Step 1: Write failing core tests**

Create `LimitBarCore/Tests/LimitBarCoreTests/DemoUsageDataTests.swift`:

```swift
import Testing
@testable import LimitBarCore

@Suite("Demo usage data")
struct DemoUsageDataTests {
    @Test("today is the default selected window")
    func todayIsDefaultSelectedWindow() {
        #expect(TimeWindow.defaultSelection == .today)
    }

    @Test("provider cards are always in fixed provider order")
    func providerCardsAreAlwaysInFixedOrder() {
        let cards = ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: .today)

        #expect(cards.map(\.provider) == [.anthropic, .azureOpenAI, .openAI])
    }

    @Test("switching time windows does not reorder cards")
    func switchingTimeWindowsDoesNotReorderCards() {
        let today = ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: .today)
        let week = ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: .currentWeek)

        #expect(today.map(\.provider) == week.map(\.provider))
    }

    @Test("demo metrics include provider-specific row metadata")
    func demoMetricsIncludeProviderSpecificRowMetadata() throws {
        let cards = ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: .today)
        let anthropic = try #require(cards.first { $0.provider == .anthropic }?.metrics.first)
        let azure = try #require(cards.first { $0.provider == .azureOpenAI }?.metrics.first)
        let openAI = try #require(cards.first { $0.provider == .openAI }?.metrics.first)

        #expect(anthropic.modelLabel == "Claude Sonnet")
        #expect(anthropic.tokenUsage.totalTokens == anthropic.tokenUsage.inputTokens + anthropic.tokenUsage.outputTokens)
        #expect(azure.deploymentLabel == "team-tools")
        #expect(openAI.accountLabel == "Acme Org")
        #expect(openAI.projectLabel == "Codex Enterprise")
    }

    @Test("demo metrics include unsupported and stale states")
    func demoMetricsIncludeUnsupportedAndStaleStates() {
        let metrics = DemoUsageData.metrics

        #expect(metrics.contains { $0.limitStatus.displayText == "Unsupported by provider API" })
        #expect(metrics.contains { $0.freshness.isStale })
    }

    @Test("empty cards stay present")
    func emptyCardsStayPresent() {
        let cards = ProviderUsageCard.cards(from: [], timeWindow: .today)

        #expect(cards.count == 3)
        #expect(cards.allSatisfy(\.isEmpty))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`.

Expected: FAIL because `DemoUsageData`, `ProviderUsageCard`, `TimeWindow.defaultSelection`, and `LimitStatus.displayText` do not exist.

- [ ] **Step 3: Add core implementation**

Add presentation helpers to `LimitBarCore/Sources/LimitBarCore/DemoUsageData.swift`:

```swift
public extension TimeWindow {
    static let defaultSelection: TimeWindow = .today
}

public extension LimitStatus {
    var displayText: String {
        switch self {
        case .confirmed:
            confirmedUsagePercentage.map { "\($0)%" } ?? "Unavailable"
        case .unsupportedByProviderAPI:
            "Unsupported by provider API"
        case .disconnected:
            "Disconnected"
        case .unavailable:
            "Unavailable"
        }
    }
}
```

Create the remaining contents of `LimitBarCore/Sources/LimitBarCore/DemoUsageData.swift`:

```swift
import Foundation

public struct ProviderUsageCard: Equatable, Sendable {
    public let provider: ProviderKind
    public let metrics: [UsageMetric]

    public var isEmpty: Bool { metrics.isEmpty }

    public static func cards(from metrics: [UsageMetric], timeWindow: TimeWindow) -> [ProviderUsageCard] {
        ProviderKind.orderedCases.map { provider in
            ProviderUsageCard(
                provider: provider,
                metrics: metrics.filter { $0.provider == provider && $0.timeWindow == timeWindow }
            )
        }
    }
}

public enum DemoUsageData {
    public static let metrics: [UsageMetric] = [
        UsageMetric(provider: .anthropic, accountLabel: "Personal", projectLabel: nil, modelLabel: "Claude Sonnet", deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 18_420, outputTokens: 6_120), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(timeIntervalSince1970: 1_783_728_000), freshness: .fresh),
        UsageMetric(provider: .anthropic, accountLabel: "Personal", projectLabel: nil, modelLabel: "Claude Haiku", deploymentLabel: nil, timeWindow: .currentWeek, tokenUsage: TokenUsage(inputTokens: 42_000, outputTokens: 12_500), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(timeIntervalSince1970: 1_783_728_000), freshness: .fresh),
        UsageMetric(provider: .azureOpenAI, accountLabel: "Team Azure", projectLabel: nil, modelLabel: "gpt-4.1", deploymentLabel: "team-tools", timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 9_850, outputTokens: 3_210), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(timeIntervalSince1970: 1_783_724_400), freshness: .fresh),
        UsageMetric(provider: .azureOpenAI, accountLabel: "Team Azure", projectLabel: nil, modelLabel: "gpt-4.1-mini", deploymentLabel: "batch-review", timeWindow: .currentWeek, tokenUsage: TokenUsage(inputTokens: 88_000, outputTokens: 21_000), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(timeIntervalSince1970: 1_783_724_400), freshness: .fresh),
        UsageMetric(provider: .openAI, accountLabel: "Acme Org", projectLabel: "Codex Enterprise", modelLabel: "gpt-5.1-codex", deploymentLabel: nil, timeWindow: .today, tokenUsage: TokenUsage(inputTokens: 31_000, outputTokens: 8_700), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(timeIntervalSince1970: 1_783_720_800), freshness: .stale(missedRefreshes: 2)),
        UsageMetric(provider: .openAI, accountLabel: "Acme Org", projectLabel: "Codex Enterprise", modelLabel: "gpt-5.1-codex", deploymentLabel: nil, timeWindow: .currentWeek, tokenUsage: TokenUsage(inputTokens: 144_000, outputTokens: 39_500), cost: nil, limitStatus: .unsupportedByProviderAPI, refreshedAt: Date(timeIntervalSince1970: 1_783_720_800), freshness: .stale(missedRefreshes: 2))
    ]
}
```

Also update the declarations in `UsageModel.swift` to make `ProviderKind` and `TimeWindow` hashable for SwiftUI selection and identity:

```swift
public enum ProviderKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
```

```swift
public enum TimeWindow: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
```

- [ ] **Step 4: Run tests to verify pass**

Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`.

Expected: PASS.

- [ ] **Step 5: Commit**

Run `git add LimitBarCore/Sources/LimitBarCore/UsageModel.swift LimitBarCore/Sources/LimitBarCore/DemoUsageData.swift LimitBarCore/Tests/LimitBarCoreTests/DemoUsageDataTests.swift && git commit -m "Add demo provider usage data"`.

---

### Task 2: Popover Rendering

**Files:**
- Modify: `LimitBar/MonitoringPopoverView.swift`

**Interfaces:**
- Consumes: `TimeWindow.defaultSelection`, `ProviderUsageCard.cards(from:timeWindow:)`, `DemoUsageData.metrics`, `UsageMetric`, `LimitStatus.displayText`.

- [ ] **Step 1: Replace popover implementation**

Replace `LimitBar/MonitoringPopoverView.swift` with:

```swift
import SwiftUI
import LimitBarCore

struct MonitoringPopoverView: View {
    @State private var selectedWindow = TimeWindow.defaultSelection

    private var cards: [ProviderUsageCard] {
        ProviderUsageCard.cards(from: DemoUsageData.metrics, timeWindow: selectedWindow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Picker("Time window", selection: $selectedWindow) {
                ForEach(TimeWindow.allCases, id: \.self) { window in
                    Text(window.displayName).tag(window)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(cards, id: \.provider) { card in
                        ProviderUsageCardView(card: card, selectedWindow: selectedWindow)
                    }
                }
            }
            .scrollIndicators(.hidden)

            Divider()

            HStack {
                Text("Demo data only. Provider integrations arrive in later issues.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                SettingsLink {
                    Text("Settings")
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 540, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LimitBar")
                .font(.title2.weight(.semibold))
            Text("Confirmed demo usage by provider")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProviderUsageCardView: View {
    let card: ProviderUsageCard
    let selectedWindow: TimeWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.provider.displayName)
                    .font(.headline)
                Spacer()
                Text(card.isEmpty ? "Empty" : "Demo")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if card.isEmpty {
                Text("No usage for \(selectedWindow.displayName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(card.metrics.enumerated()), id: \.offset) { _, metric in
                        MetricRowView(metric: metric)
                    }
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
    }
}

private struct MetricRowView: View {
    let metric: UsageMetric

    private var metadata: String {
        [
            metric.accountLabel,
            metric.projectLabel,
            metric.deploymentLabel.map { "Deployment: \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric.modelLabel)
                    .font(.subheadline.weight(.semibold))
                if metric.freshness.isStale {
                    Text("Stale")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.14), in: Capsule())
                }
                Spacer()
            }

            if !metadata.isEmpty {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TokenPill(title: "In", value: metric.tokenUsage.inputTokens)
                TokenPill(title: "Out", value: metric.tokenUsage.outputTokens)
                TokenPill(title: "Total", value: metric.tokenUsage.totalTokens)
            }

            Text(metric.limitStatus.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(metric.freshness.isStale ? .orange.opacity(0.08) : .secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TokenPill: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview {
    MonitoringPopoverView()
}
```

- [ ] **Step 2: Run native build**

Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build`.

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run core tests**

Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`.

Expected: PASS.

- [ ] **Step 4: Commit**

Run `git add LimitBar/MonitoringPopoverView.swift && git commit -m "Render demo monitoring popover"`.

---

## Final Verification

- Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`.
- Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build`.
- Run a launch smoke check with the built app.
- Run formal code review against `main`.
- Attempt `no-mistakes`; if the local gate still cannot start first runs, record the failure and continue with manual review evidence.

## Self-Review

- Spec coverage: Task 1 covers default window, provider order, demo rows, unsupported/stale states, and empty cards; Task 2 covers the popover UI rendering.
- Completion-marker scan: no unfinished markers or vague implementation steps remain.
- Type consistency: `ProviderUsageCard`, `DemoUsageData`, `TimeWindow.defaultSelection`, and `LimitStatus.displayText` are consistently named across tests and implementation.
