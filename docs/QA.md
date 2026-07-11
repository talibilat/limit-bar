# LimitBar QA

Date: 2026-07-11.
Target: macOS 14 or newer.
Scope: private daily-driver release verification for issue #10.

## Automated Verification

Run the complete core suite:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore
```

Build the native app:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build
```

Check branch whitespace:

```sh
git diff --check origin/main...HEAD
```

## Acceptance Matrix

| Area | Evidence |
| --- | --- |
| App launch and menu bar compilation | Native app build and repository-scoped launch smoke. |
| Compact menu status | `AppStatusTests` and dynamic `MenuBarStatusLabel` loading normalized metrics. |
| Popover rendering and provider order | `UsageModelTests` and `DemoUsageDataTests` exercise fixed cards and row presentation models. |
| Today default and Current Week switching | `UsageModelTests` cover default selection, local-day boundaries, week boundaries, and stable order. |
| Settings rendering | Native build compiles authentication, diagnostics, Azure integration, and pricing sections. |
| Azure JSONL ingestion | `AzureUsageEventImporterTests` cover valid events, deployment metadata, idempotency, malformed lines, invalid UTF-8, oversized lines, and transactional replacement. |
| Anthropic provider behavior | `AnthropicUsageProviderTests` cover official request grouping, pagination, nested cache tokens, exact labels, provider costs, safe failures, and stale retention. |
| OpenAI OAuth feasibility | `OpenAIUsageProviderTests` cover Supported, Unsupported, Admin credential required, Expired, safe failures, explicit organization/project/model identity, and provider costs. |
| Refresh staleness | SQLite, Anthropic, and OpenAI persistence tests retain confirmed values and mark only the failed provider stale. |
| Cost labels | `PricingTests` cover Provider reported precedence, Calculated estimate, effective dates, and missing-price behavior. |
| Unsupported limits | Usage and provider tests assert `Unsupported by provider API` unless a confirmed denominator exists. |
| Privacy boundaries | SQLite schema tests and diagnostics encoding tests exclude credentials, prompts, responses, raw provider data, terminal output, and source code. |

## Repository-Only Boundary

The user required all work to remain within the repository and GitHub.
QA therefore does not write test credentials to the real user Keychain or append fixture events to the real Application Support path.
Keychain behavior is verified through the fake credential store and injected Keychain operations seam.
Provider behavior is verified through injected HTTP fixtures rather than production accounts.
Application Support behavior is verified with temporary test file managers and in-memory or temporary SQLite databases.

## Manual Visual Checklist

- Confirm the menu item remains readable beside standard macOS status items.
- Confirm the popover title, segmented time control, fixed provider cards, stale badges, unsupported banners, token pills, and cost labels fit without clipping.
- Confirm the Settings window scrolls and clearly separates Authentication, Diagnostics, Azure Integration, and Pricing.
- Confirm saved secure fields clear immediately and never repopulate.
- Confirm Reveal JSONL in Finder selects the file when present and opens its directory when absent.

The native build proves these surfaces compile.
Real-account and real-Keychain visual interaction remains a final human smoke check because repository-only execution intentionally avoids modifying user resources.
