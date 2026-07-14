# LimitBar

A free macOS menu bar app for AI coding usage from Claude Code, Codex, Azure OpenAI, Anthropic, OpenAI, and local tools you configure.
LimitBar stores its settings and normalized metrics locally and requires no LimitBar account, cloud sync, or telemetry.
Opening the Claude rate-limit view with an accessible login and triggering explicit provider refreshes make network requests to the relevant provider APIs.

The menu bar gauge turns green, yellow, or red as the busiest confirmed rate limit fills up.
Click it for two tabs:

- **Rate Limit** shows percent used, remaining, and reset time for Claude Code and Codex.
- **Usage** shows confirmed token counts and costs by provider and model for Today or Current Week.
- **History** shows local 30-day and 12-week token trends, exact gaps, in-progress periods, and costs grouped by currency.

![LimitBar Rate Limit tab showing Claude session and weekly windows](docs/ss3.png)

## Features

- **Claude Code** reads rate limits from the existing Claude Code Keychain login after an explicit or passive authorization check.
- **Codex** reads limits from local session logs, and pooled team seats can show credit estimates when pricing is configured in Settings.
- **Usage tracking** imports normalized LimitBar JSONL events and can fetch supported provider usage after an explicit action in Settings.
- **Custom local tools** can be added as a name and a JSONL file that already follows LimitBar's custom event schema.
- **Cost labels** distinguish provider-reported values from calculated estimates.
- **Local alerts** can notify at configurable Claude Code and Codex quota thresholds or exact-period API cost-budget thresholds.
- **Privacy-first storage** keeps configured secrets in macOS Keychain and normalized metrics in local SQLite without storing prompts, code, responses, or raw provider payloads.

## Prerequisites

- **macOS 14 (Sonoma) or later** is required.
- **Xcode 16 or later** is required to build the app from source because the core package targets Swift 6.
- **Git** is required to clone the repository.

There is no pre-built download yet.
If Claude Code or Codex is already used on this Mac, the Rate Limit tab can reuse those local resources without another LimitBar account.

## Run It

```sh
git clone https://github.com/talibilat/limit-bar.git
cd limit-bar
open LimitBar.xcodeproj
```

1. In the Xcode toolbar, choose the **LimitBar** scheme and destination **My Mac**.
2. Press **Command-R** or click **Run**.
3. Click the gauge icon that appears in the menu bar.
4. Use **Connect** if macOS says LimitBar must be authorized to read the Claude Code Keychain item.

To stop the app while debugging, press **Command-.** in Xcode or quit LimitBar from the menu bar icon.

## Refresh Behavior

LimitBar starts one local refresh immediately and schedules another every five seconds.
That loop only imports the built-in local JSONL file, refreshes configured custom JSONL files, reads the SQLite snapshot, and scans local Codex sessions.
Concurrent ticks are coalesced, and a failed local component keeps its last successful in-process component in the published refresh snapshot.

The five-second loop does not call Anthropic, OpenAI, Azure OpenAI, or Claude provider APIs.
It also does not poll macOS Keychain.
Provider API requests happen only through explicit provider actions in Settings, except for the Claude behavior described below.

Explicit Anthropic API and OpenAI API usage and cost refreshes record a local, privacy-safe outcome history in `provider-refresh-history.sqlite`.
Entries contain only the provider product, fixed operation and outcome categories, start time, a duration bucket, and affected exact windows.
History is limited to 30 days and 200 entries per provider product; Settings shows the latest outcome and last full success and can clear this history without changing usage, settings, or credentials.
History persistence is best effort and never changes the provider refresh result.

Alert evaluation runs after these existing refreshes and does not add provider API polling or Keychain reads.
Claude Code alerts can be evaluated after the same view-triggered or explicit fetches described below, while Codex and cost-budget alerts use the local refresh loop.

## Local Alerts

Alerts are disabled by default.
Settings lets you explicitly request macOS notification permission and configure unique percentage thresholds from 1% through 100%, with 70% and 90% suggested.

Quota alerts require a fresh Claude Code or Codex observation with a provider-reported future reset boundary.
Cost budgets specify an API product, currency, provider-reported or calculated provenance, exact period, cap, and percentage thresholds.
Provider-reported costs use their UTC billing week, while calculated estimates use local Today or Current Week windows.

LimitBar sends at most one notification for each configured threshold and exact subject window.
If one observation newly passes several thresholds, only the highest notification is shown and all passed thresholds are recorded.
The delivery ledger is stored locally in `usage-metrics.sqlite` so relaunching does not repeat an accepted notification.

Lock-screen text contains only the coarse provider product, threshold, currency when relevant, and reported or estimated provenance.
It excludes exact spend, budget caps, account, organization, project, model, deployment, and source labels.
Stale, unhealthy, unsupported, legacy, expired, malformed, and inferred observations do not alert.
Cost measurements older than 24 hours are stale for alerting even when their exact budget window remains active.

### Claude Authorization

Opening the Claude rate-limit view and pressing **Check Again** or **Refresh** performs a passive Keychain read.
Passive reads tell Keychain not to show authentication UI.
If authorization is required, LimitBar shows **Connect** instead of causing a background prompt.
Pressing **Connect** performs the interactive read that allows macOS to show its authorization UI, then fetches Claude limits if a credential is returned.

Choosing **Always Allow** is not an unconditional permanent grant.
macOS can require authorization again when LimitBar's signing identity or code requirement changes, which commonly happens across local debug builds, or when Claude Code deletes and recreates its `Claude Code-credentials` Keychain item.
The permission belongs to the particular Keychain item and the requesting code identity rather than to the LimitBar name alone.

Claude OAuth credentials with a future expiry can be retained only in the running LimitBar process.
The broker does not proactively remove a cached credential at the exact expiry instant; on the next broker access at or after expiry, it treats the cached value as invalid, clears it, and reads Keychain again.
Explicit invalidation clears the cached credential immediately.
Configured provider credentials remain in macOS Keychain and are read into process memory only to make an explicit request.
Secrets are not copied into UserDefaults, SQLite metrics, or diagnostics.

## Usage Windows And Snapshots

**Today** follows the current local calendar day, including daylight-saving transitions.
**Current Week** always begins at local midnight on Monday and ends at the next local Monday, regardless of the calendar's configured first weekday.

Provider-reported billing costs use a separate Monday-to-Monday UTC billing week.
UTC billing cost rows appear in their own **UTC Billing Week** section and are not mixed into local Today or Current Week cards.

Every current metric snapshot records an exact start, exclusive end, calendar basis, source, and aggregation version.
SQLite reads for the current UI only return bounded rows whose complete exact window matches the current local Today, current local week, or current UTC billing week.
This prevents a row with the same broad `today` or `currentWeek` label but different boundaries from being presented as current.

Older database rows that predate exact provenance migrate as **legacy** rows without invented boundaries.
Legacy JSON also decodes as legacy provenance when it has only a `timeWindow` value.
Legacy rows remain available to low-level storage reads and legacy replacement APIs, but current snapshots and provider cards intentionally exclude them.
Rows with a `refreshedAt` older than 90 days are deleted during snapshot loading.

Successful refreshes also preserve privacy-safe historical aggregates in `historical-usage-trends.sqlite`.
Historical periods retain exact boundaries and timezone identity, distinguish unavailable gaps from observed zero usage, and preserve corrected values as explicit revisions rather than silently rewriting them.
Provider API measurements are preferred for totals when local measurements cover the same provider, while local model attribution remains non-additive supporting detail.
Calculated historical costs are frozen against the configured price effective at the usage window start and retain a pricing revision.
Settings offers bounded 30, 90, 365, and 730-day retention, with 365 days as the default, plus deletion that leaves current usage, settings, credentials, and source files untouched.

If SQLite becomes unavailable after a valid snapshot, LimitBar returns that last valid in-process snapshot with unhealthy store status instead of replacing the display with empty data.
If no valid snapshot exists yet, it returns empty metrics with unhealthy status.
Custom-source failures similarly preserve that source's previously persisted metrics and emit a generic failure diagnostic.

Schema migrations accept only known schema fingerprints and run transactionally.
An unsupported database remains in place, and Settings provides retry and explicit archival recovery actions instead of silently replacing it.
See [`docs/MIGRATIONS_AND_RECOVERY.md`](docs/MIGRATIONS_AND_RECOVERY.md) for the release matrix and recovery procedure.

## Local Files And Custom Sources

The default local paths are:

- `~/.codex/sessions` for Codex session logs and local rate-limit snapshots.
- `~/Library/Application Support/LimitBar/usage-events.jsonl` for normalized LimitBar usage events.
- `~/Library/Application Support/LimitBar/usage-metrics.sqlite` for normalized usage metrics.
- `~/Library/Application Support/LimitBar/historical-usage-trends.sqlite` for revisioned historical aggregates.

The app is intentionally not App Sandbox constrained.
This is a deliberate file boundary because Codex data is outside the app container and custom sources may point to an arbitrary user-selected path.
LimitBar does not claim sandbox isolation from other files the running user can access.
Custom source paths are explicit configuration, and importers accept regular files only.
Each custom source UUID, display name, and file path is stored as JSON in UserDefaults under `LimitBar.customUsageSourcesJSON`.
Successfully imported custom aggregates are persisted in `usage-metrics.sqlite` with their custom source UUID and exact usage window.

### Normalized Usage Events

LimitBar does not read native Anthropic, Azure OpenAI, or OpenAI CLI log formats for usage totals.
New producers should use the supported [`limitbar-collect` CLI or reusable Swift collector](docs/CollectorSchemaV1.md).
The collector validates explicit schema v1, coordinates cooperating concurrent writers, rejects unknown fields, enforces resource limits, and rotates bounded local files.
Its token values are immutable per-operation deltas rather than cumulative counters.

The shapes below document the existing permissive ingestion boundary that collector v1 deliberately targets.
They remain available for compatibility, but direct JSONL writing is not the supported producer interface for new integrations.
An external producer or transform must append one normalized JSON object per line to `usage-events.jsonl`.
Every built-in event requires `provider`, `timestamp`, `model`, `inputTokens`, and `outputTokens`, and may include `deployment`:

```json
{"provider":"azureOpenAI","timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","deployment":"production-chat","inputTokens":100,"outputTokens":20}
```

The exact built-in schema is:

- `provider` is exactly `anthropic`, `azureOpenAI`, or `openAI`.
- `timestamp` is an ISO 8601 timestamp, with or without fractional seconds.
- `model` is a non-empty string after trimming whitespace.
- `inputTokens` and `outputTokens` are non-negative integers whose aggregate sums must not overflow.
- `deployment` is optional, but when present it must be a non-empty string after trimming whitespace.
- Unknown JSON fields are ignored.

Custom sources also require an external producer or transform because LimitBar does not parse a tool's native log format automatically.
The supported custom fields are `timestamp`, `model`, `inputTokens`, and `outputTokens`; unknown fields are ignored, and `provider` or `deployment` fields do not change custom identity:

```json
{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}
```

For custom events, `timestamp` must be ISO 8601, `model` must be non-empty after trimming whitespace, and both token fields must be non-negative integers.
The configured custom source name supplies the card label, and its persisted UUID supplies source identity.

Built-in and custom imports enforce the same resource and timestamp limits:

- The source must be a regular file no larger than 100 MiB.
- Each line may be at most 1 MiB.
- One load may create at most 10,000 distinct aggregate keys.
- A timestamp more than five minutes in the future is rejected, while the exact five-minute boundary is accepted.
- Token arithmetic overflow fails the load rather than wrapping.

Both importers check cancellation before loading and between streamed chunks.
The built-in importer also checks cancellation during line and aggregate processing and immediately before its transactional replacement.
When either importer observes cancellation, it stops without returning replacement metrics for that source; built-in pre-cancelled and mid-stream cases are covered by tests that verify the previous snapshot remains stored.

Malformed JSON, invalid UTF-8, overlong lines, and future timestamps are rejected without exposing their content.
Diagnostics retain the total rejected-line count and at most 20 samples containing only line number and typed reason.
The UI projection exposes aggregate custom failure and rejection counts, not raw lines or paths.

Successful built-in and custom imports may be reused from an in-process metadata cache when the file modification date, file size, and current local day and week boundaries are unchanged.
The built-in fingerprint also includes the standardized file path, while each custom fingerprint includes its complete source configuration.
This cache does not hash file contents, so a rewrite that preserves both file size and modification date may not be detected until the local day changes or LimitBar restarts.
Any future-timestamp rejection disables cache reuse for that import so the unchanged file can be reconsidered as time advances.

## Network And Privacy Boundary

Provider HTTP uses an ephemeral `URLSession` with no URL cache, no cookie storage, and cookie setting disabled.
Request timeout is 15 seconds and resource timeout is 30 seconds.
Redirects carrying `Authorization`, `Proxy-Authorization`, `x-api-key`, or `api-key` credentials are refused unless scheme, host, and effective port remain the same.
Uncredentialed requests may follow cross-origin redirects.

Diagnostics contain provider identity, coarse connection state, fixed failure reason, update time, database health, accepted or rejected event counts, and bounded allow-listed provider refresh outcomes.
They do not contain credentials, prompts, responses, request bodies, terminal output, source code, raw provider responses, or rejected JSONL content.
Errors shown for custom import failures are generic and do not include private file paths.

## Build And Test

```sh
export DEVELOPER_DIR="/Applications/Xcode_16.2.app/Contents/Developer"
scripts/check-toolchain.sh
swift test --package-path LimitBarCore
xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' test
git diff --check
```

The native test command runs app integration tests and hermetic UI automation without real credentials or accounts.
The terminal or CI agent launching UI tests must have macOS Developer Tools permission.

Pull requests and pushes to `main` run these checks on macOS 14 with Xcode 16.2.
To check committed branch changes from their merge base, run `git diff --check <base-commit>...HEAD`.

See [`docs/QA.md`](docs/QA.md) for acceptance checks and verification evidence.
See [`futures/README.md`](futures/README.md) for proposals that are not current commitments.

---

Maintained by [Md Talib](https://github.com/talibilat) at Factor.
If LimitBar is useful, star the repository or share it with your team.
