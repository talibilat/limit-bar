# LimitBar

LimitBar is a private macOS 14+ menu bar utility for monitoring confirmed Anthropic, Azure OpenAI, and OpenAI usage.
It presents a compact menu bar status and a SwiftUI popover with provider cards in fixed order: Anthropic, Azure OpenAI, OpenAI.
Today is selected by default, and Current Week is available from the segmented control.

## Requirements

- macOS 14 or newer.
- Full Xcode for native app builds with `xcodebuild`.
- Swift 6 command line tools for core package tests.

## Project Layout

- `LimitBar.xcodeproj` contains the native menu bar app target.
- `LimitBar` contains the SwiftUI menu, popover, settings, Keychain-backed configuration, and production HTTP adapters.
- `LimitBarCore` contains testable provider mapping, persistence, pricing, diagnostics, and status logic.

## Build And Test

Run the core suite:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore
```

Build the native app:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build
```

Open `LimitBar.xcodeproj` in Xcode and run the `LimitBar` scheme.
The app appears in the menu bar and opens the monitoring popover when selected.

## Local Usage Events JSONL Integration

Confirmed local usage for Anthropic, Azure OpenAI, and OpenAI is imported from:

```text
~/Library/Application Support/LimitBar/usage-events.jsonl
```

The path is visible and revealable in Settings.
Tools write one JSON object per line after receiving confirmed response usage.

Each event supports these fields:

| Field | Required | Type | Meaning |
| --- | --- | --- | --- |
| `provider` | Yes | String | `anthropic`, `azureOpenAI`, or `openAI`. |
| `timestamp` | Yes | ISO-8601 string | Time of the confirmed response usage. |
| `model` | Yes | Non-empty string | Returned or configured model identity. |
| `inputTokens` | Yes | Nonnegative integer | Confirmed input token count. |
| `outputTokens` | Yes | Nonnegative integer | Confirmed output token count. |
| `deployment` | No | Non-empty string | Optional Azure deployment identity. |

Example:

```json
{"provider":"azureOpenAI","timestamp":"2026-07-11T09:30:00Z","model":"gpt-4.1","deployment":"team-tools","inputTokens":1200,"outputTokens":340}
```

Malformed lines are skipped independently and reported by line number in Diagnostics.
Invalid input never prevents later valid lines from importing.
LimitBar reparses the file as its source of truth, so repeated refreshes do not double-count events.
Imported metrics are aggregated per provider, model, and time window.
Anthropic and OpenAI local metrics carry the `Local logs` account label so they coexist with provider-API metrics instead of replacing them.

## Local Agent Exporter

`tools/export-local-usage.py` regenerates `usage-events.jsonl` atomically from three local sources, covering the last nine days, which spans the Today and Current Week windows.
The exporter rewrites the file on every run, so it is idempotent and never double-counts; it owns the file, so other writers should be merged into the exporter instead of appending.

- Opencode (`~/.local/share/opencode/opencode.db`): `azure` provider messages become `azureOpenAI` events. `inputTokens` adds `tokens.cache.read` and `tokens.cache.write` to `tokens.input`, and `outputTokens` adds `tokens.reasoning` to `tokens.output`, because Opencode stores those separately.
- Claude Code (`~/.claude/projects/**/*.jsonl`): assistant messages become `anthropic` events, so Pro or Max subscription usage is tracked without any API credential. Input adds cache creation and cache read tokens; duplicate transcript lines for one message are deduplicated by message and request identity.
- Codex (`~/.codex/sessions/**/*.jsonl`): `token_count` events become `openAI` events, so ChatGPT-organization Codex usage is tracked without a platform API key. Per-turn usage is derived from cumulative session totals so repeated snapshots never double-count.

Install the exporter as a LaunchAgent that runs at login and every five minutes:

```sh
tools/install-local-usage-export.sh
```

The script is copied to `~/Library/Application Support/LimitBar/` because launchd cannot read TCC-protected folders such as Documents.
Logs are written to `~/Library/Logs/LimitBar/usage-export.log`.

Usage from Opencode's `google` and `opencode` providers has no matching LimitBar provider and is intentionally not remapped.

## Provider Configuration

Anthropic supports an Admin API key and an OAuth-compatible future configuration path.
Validate & Refresh calls the Anthropic organization usage and cost reports and stores only normalized metrics.

OpenAI supports OAuth feasibility validation and an admin/platform API-key fallback.
LimitBar does not report OpenAI as Connected until the credential can access the required organization usage endpoint.
Unsupported OAuth, expired credentials, and admin-required access remain explicit in Settings and the OpenAI card.

Azure OpenAI usage remains a local JSONL integration.
LimitBar does not call Azure management, quota, or rate-limit APIs.

## Credentials And Privacy

API keys and OAuth access or refresh tokens are stored only as generic-password items in macOS Keychain.
Settings never read a saved secret back into a text field.
Non-secret settings such as auth method, endpoint, organization identity, and structured connection state are stored in UserDefaults.

Normalized usage metrics are stored in a local SQLite database under Application Support and retained for 90 days.
The database contains provider identity, account/project/model/deployment labels, time window, confirmed token totals, cost, limit state, refresh time, and freshness.

LimitBar does not store or export API keys, access tokens, refresh tokens, prompts, responses, request bodies, terminal output, source code, or raw provider responses.
Diagnostics use fixed typed states and safe summaries rather than underlying provider errors.
There is no hosted telemetry, cloud sync, or backend.

## Cost Labels

`Provider reported` means the amount came from a provider cost endpoint.
`Calculated estimate` means LimitBar applied a manually configured, effective-date-aware price to confirmed token counts.
Provider-reported cost takes precedence over calculated pricing.
If neither provider spend nor matching pricing is available, no cost is shown.

## Limits And Freshness

`Unsupported by provider API` means the selected provider source did not return a confirmed denominator.
LimitBar does not invent five-hour, weekly, TPM, quota, or rate-limit values.
It does not estimate live burn rate.

When a refresh fails, the last confirmed values remain visible and are marked Stale.
Unsupported, admin-required, expired, failed, disconnected, and missing states never imply healthy capacity.

## QA

See [`docs/QA.md`](docs/QA.md) for the final acceptance checklist and verification evidence.
