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

Launch the signed debug executable with all file writes denied:

```sh
sandbox-exec -p '(version 1) (allow default) (deny file-write*)' <DerivedData>/Build/Products/Debug/LimitBar.app/Contents/MacOS/LimitBar
```

Result: the native app process remained alive for the three-second smoke interval and terminated cleanly on request.
The sandbox prevented writes to Keychain, Application Support, caches, and other user resources.

## Acceptance Matrix

| Area | Evidence |
| --- | --- |
| App launch and menu bar compilation | Native app build plus successful three-second sandboxed executable smoke. |
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

## Native Surface Review

- Menu item: reviewed dynamic title/icon/color source and compact label style; native process launch succeeded.
- Popover: reviewed 440 x 600 scroll layout, title, segmented time control, fixed provider cards, stale/failed banners, token pills, cost-only rows, and cost labels; native build succeeded.
- Settings: reviewed 620 x 720 grouped scroll layout with separate Authentication, Diagnostics, Azure Integration, and Pricing sections; native build succeeded.
- Secure fields: reviewed save/clear/auth-switch paths; fields clear and no path reads Keychain values back into UI bindings.
- Finder reveal: reviewed present-file selection and absent-file directory opening branches.
- Time switching: deterministic core tests confirm Today default, Current Week boundaries, and provider order.

Real-account, real-Keychain prompt, Finder activation, and click-through visual interaction remain intentionally unexecuted because repository-only execution must not modify user resources or require Accessibility control.
