# LimitBar QA

Date: 2026-07-13.
Target: macOS 14 or newer.
Scope: reliability, security, privacy, exact usage windows, local refresh behavior, local alerts, custom-source resource limits, and migration acceptance evidence.

## Verification Commands

Run the complete core suite:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore
```

Build the native app:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build
```

Optionally smoke the built executable for three seconds with cleanup that also runs when the shell is interrupted:

```sh
build_settings="$(DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' -showBuildSettings)"
target_build_dir="$(awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }' <<<"$build_settings")"
executable_path="$(awk -F ' = ' '/^[[:space:]]*EXECUTABLE_PATH = / { print $2; exit }' <<<"$build_settings")"
app_executable="$target_build_dir/$executable_path"
app_pid=""
cleanup() {
  if [ -n "${app_pid:-}" ]; then
    if kill -0 "$app_pid" 2>/dev/null; then
      kill "$app_pid"
    fi
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM
"$app_executable" &
app_pid=$!
sleep 3
kill -0 "$app_pid"
```

This optional smoke can access normal user resources and was not run as part of the recorded repository-only verification.
It proves only that the built process remains alive for the interval.

Check the worktree diff for whitespace errors:

```sh
git diff --check
```

Verification on 2026-07-13 completed with 268 tests in 22 suites passing, the native app build succeeding, and `git diff --check` reporting no errors.

Ticket 12 verification on 2026-07-14 completed with 288 tests in 24 suites passing, direct typechecking of every app Swift source passing, the Xcode project file validating, and `git diff --check` reporting no errors.
The native `xcodebuild` command was attempted with isolated Derived Data but could not reach build planning because this machine reported `DARWIN_USER_CACHE_DIR` I/O and FSEvents startup failures.

Inspect the app target's sandbox configuration and default paths:

```sh
grep -n "ENABLE_APP_SANDBOX\|CODE_SIGN_ENTITLEMENTS" LimitBar.xcodeproj/project.pbxproj
grep -R -n "\.codex/sessions\|usage-events.jsonl\|usage-metrics.sqlite" LimitBar LimitBarCore/Sources
```

The absence of `ENABLE_APP_SANDBOX`, `CODE_SIGN_ENTITLEMENTS`, and an entitlements file is acceptance evidence that this source target is intentionally unsandboxed.
This check is not evidence of filesystem isolation.

## Acceptance Matrix

| Area | Acceptance evidence |
| --- | --- |
| Five-second local refresh | `LocalRefreshCoordinatorTests` verifies immediate start, exact five-second scheduling, coalescing, cancellation, generation isolation, ordered snapshots, and last successful component retention; `LocalRefreshProductionWiringTests` verifies the production seam contains local usage refresh and Codex scanning. |
| No periodic provider or Keychain polling | `LimitBarState` wires only `ApplicationLocalUsageRefresher` and `CodexSessionScanner` into `LocalRefreshCoordinator`, provider clients are absent from `LocalRefreshDependencies`, and `ClaudeRateLimitsModelTests` verifies Claude work starts through view appearance or explicit model actions. |
| Claude passive and interactive authorization | `ClaudeCredentialBrokerTests` verifies passive reads use authentication-UI-fail and interactive reads use authentication-UI-allow, while `ClaudeRateLimitsModelTests` verifies appearance is passive, no API request occurs when interaction is required, and explicit Connect permits interaction before fetching. |
| Claude credential lifetime | `ClaudeCredentialBrokerTests` verifies future-expiry credentials are retained in process memory and explicit invalidation clears them, while `ClaudeCredentialBroker` checks expiry on each access and clears an expired cached value before rereading Keychain rather than proactively removing it at the expiry instant; `ProviderAuthenticationTests` verifies persisted settings exclude secret fields. |
| Local Monday week and UTC billing week | `UsageModelTests` verifies local Monday boundaries independent of `firstWeekday`, exclusive following-Monday ends, DST-aware local days, and Monday-midnight UTC billing boundaries, while `UsagePresentationTests` verifies UTC billing rows are separate from local cards. |
| Exact snapshots | `UsageModelTests`, `SQLiteUsageMetricStoreTests`, and `UsageDatabaseTests` verify validation, bounded provenance encoding, exact identity round trips, and selection of only current bounded rows. |
| Legacy behavior | `UsageModelTests`, `SQLiteUsageMetricStoreTests`, and `UsagePresentationTests` verify legacy JSON decoding, physical v1 migration without invented bounds, and exclusion from provider cards. |
| SQLite last-good behavior | `UsageDatabaseTests` verifies cancellation and exclusive-lock failures preserve the last valid metrics with unhealthy status before recovery and verifies failed custom refreshes preserve the prior source snapshot. |
| Built-in JSONL safety | `LocalUsageEventImporterTests` verifies the 100 MiB file cap, 1 MiB line cap, 10,000 aggregate-key cap, regular-file checks, malformed and invalid UTF-8 handling, checked token sums, five-minute future-skew boundary, cancellation before and during streaming, current exact-window replacement, and preservation of previous metrics on failure or cancellation. |
| Built-in JSONL schema | `LocalUsageEventImporterTests` verifies the normalized `provider`, timestamp, model, token, and optional deployment parser for `anthropic`, `azureOpenAI`, and `openAI`; there is no native Anthropic, Azure OpenAI, or OpenAI CLI log adapter. |
| Custom parser and bounds | `CustomUsageSourceTests` verifies the custom timestamp, model, and token schema, aggregation under the source identity, the 100 MiB file cap, 1 MiB line cap, 20 sampled diagnostics, 10,000 aggregate cap, regular-file requirement, overflow failure, and five-minute future-skew boundary. |
| Custom configuration | `CustomUsageSourceStore` encodes source UUIDs, names, and paths into UserDefaults and posts a refresh notification after changes; the native build compiles the Settings add and remove paths, but there is no dedicated app-target test for this store. |
| Custom persistence and visibility | `UsageDatabaseTests` verifies custom aggregates persist by source UUID in SQLite, survive failed refreshes, update after rename, and disappear after source removal; `ProviderUsageCard.cards` includes providers with metrics, while custom-specific card visibility remains a manual UI acceptance check. |
| Import metadata caches | `UsageDatabaseTests` verifies unchanged successful built-in and custom files reuse in-process results, local day changes invalidate built-in reuse, and future-timestamp rejection prevents reuse; the fingerprints use file modification date and size rather than a content hash, and the built-in test demonstrates that a same-size rewrite with a restored modification date remains cached until the day changes. |
| Custom diagnostics and caching | `UsageDatabaseTests` and `CustomUsageSourceTests` verify generic failures preserve prior metrics and future-timestamp rejection prevents cache reuse even when that diagnostic is outside the 20-sample set; `CustomUsageAggregator` checks cancellation before loading and between streamed chunks. |
| Unsandboxed file boundary | Project configuration has no App Sandbox entitlement, production defaults are `~/.codex/sessions`, `~/Library/Application Support/LimitBar/usage-events.jsonl`, and `~/Library/Application Support/LimitBar/usage-metrics.sqlite`, and custom sources can use explicit arbitrary regular-file paths. |
| Process-only secret use | `CredentialStoreTests` and `ProviderAuthenticationTests` verify dedicated Keychain storage, exact byte handling, and secret-free settings and diagnostics, while provider refresh services pass credentials directly to request clients and persist only normalized results and safe diagnostics. |
| HTTP isolation | `HTTPClientTests` verifies ephemeral configuration, no cache, no cookies, 15-second request timeout, 30-second resource timeout, same-origin enforcement for credentialed redirects, all protected credential header spellings, and URL-session invalidation. |
| Privacy-safe diagnostics | `ProviderAuthenticationTests` and `CustomUsageSourceTests` verify that diagnostics omit credential and content fields, typed errors do not leak private paths, and importer models retain only counts plus bounded line-number and reason samples. |
| Provider persistence safety | Anthropic and OpenAI provider tests verify cancellation preservation, scoped replacement, stale retained values after failure, exact local and UTC windows, and safe typed failure reasons. |
| Alert qualification | `AlertCoreTests` verifies configurable thresholds, provider-product separation, Claude and Codex reset-boundary adapters, stale and malformed suppression, source and currency separation, API-over-local precedence, checked monetary aggregation, and privacy-safe copy. |
| Alert deduplication | `SQLiteAlertDeliveryStoreTests` verifies atomic reservation, once-per-threshold delivery, retry after failure or lease expiry, exact-boundary pruning, persistence across relaunch, coexistence with usage tables, and user reset. |
| Failed-source suppression | `LocalRefreshCoordinatorTests` verifies retained last-good Codex display data is marked as not refreshed after a failed scan, and `LimitBarState` excludes that data plus failed built-in imports from alert evaluation. |
| Notification permission and privacy | Alert rules are disabled by default, `AlertSettingsView` requests permission only through an explicit action, and `AlertNotificationCoordinator` submits only core-generated coarse copy after durable reservation; real macOS presentation remains a manual check. |
| Native compilation | The Xcode build command compiles the menu bar app, popover, settings, Keychain integration, provider clients, and local refresh wiring, while repository inspection confirms no app UI test target is currently present. |

## Manual Acceptance

These checks require a local signed app and should not be inferred from fixture tests:

1. Launch the current signed build and confirm the menu bar item and popover render.
2. Open the Claude section without prior authorization and confirm no Keychain prompt appears from the passive check.
3. Press **Connect** and confirm macOS presents the Keychain authorization UI.
4. Choose **Always Allow**, relaunch the same signed build, and confirm the existing item can be read without another prompt.
5. Change the build's code identity or recreate the `Claude Code-credentials` item, then confirm macOS may request authorization again.
6. Press **Check Again** and confirm it remains a passive no-UI action.
7. Configure a custom JSONL path outside Application Support and confirm the unsandboxed build can read it.
8. Confirm a valid custom event produces a custom card and that removing the configured source removes its persisted metrics and card.
9. Disconnect the network and confirm the five-second local JSONL, custom, SQLite, and Codex refresh continues without provider polling.
10. Trigger explicit provider refreshes and confirm request failures retain the documented last-good metrics and safe status text.
11. Inspect Today, Current Week, and UTC Billing Week near local and UTC Monday boundaries.
12. Open Alerts settings and confirm no notification permission prompt appears before pressing **Enable Notifications**.
13. Enable notifications, configure a quota threshold below a fresh observed value, and confirm one coarse notification appears without account, project, model, source, exact spend, or budget-cap text.
14. Relaunch within the same quota window and confirm the accepted threshold does not notify again.
15. Clear notification history, accept the warning, and confirm an active threshold can notify again.
16. Deny notification permission and confirm Settings reports the denial without consuming delivery state or repeatedly prompting.
17. Configure provider-reported and calculated budgets in the same currency and confirm their notifications remain separately labeled.

## Repository-Only Boundary

Automated tests use fake Keychain operations, injected HTTP clients, temporary files, and temporary or in-memory SQLite databases.
They do not modify a real Claude Code Keychain item, use production provider accounts, or append events to the real Application Support file.
Real-account Keychain authorization, code-identity changes, Finder activation, power use, and click-through visual behavior remain manual acceptance work.

## Evidence Interpretation

Passing core tests proves the tested pure and injected behaviors, not macOS prompt policy across every signing and distribution identity.
A successful native build proves compilation, not visual correctness or real-account interoperability.
The unsandboxed configuration is intentional for current local-file requirements, but it remains a security boundary decision that should be revisited before distribution.
