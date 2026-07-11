# LimitBar

LimitBar is a free, open-source macOS menu bar app for watching your AI coding usage in one place: Claude Code, Codex, Azure OpenAI, and any OpenAI-compatible provider you configure.
It runs entirely on your machine.
There is no account, no cloud sync, and no telemetry - everything it shows comes from your own local logs, Keychain, or the provider APIs you connect yourself.

The menu bar icon is a small gauge that changes color (green, yellow, red) as your busiest rate limit fills up, so you can tell your status at a glance without opening anything.
Click it to open the popover, which has two tabs:

- **Rate Limit** - live percent-used, percent-remaining, and time-to-reset for Claude Code and Codex, read the same way each CLI reads its own limits.
- **Usage** - confirmed token counts and cost, per provider and per model, for Today and the Current Week.

## Features

- **Claude Code rate limits** - session (5 hour) and weekly windows, reusing the login `claude` already stores in Keychain. No new sign-in, no token copied anywhere.
- **Codex rate limits** - read straight from Codex's own local session logs, no network call. Individual plans (Plus, Free) see the same percent-used windows Codex itself tracks. Business/team seats pool usage instead of exposing personal percentages, so LimitBar shows a calculated company-pool credits estimate instead (see below).
- **Confirmed token usage** for Anthropic, Azure OpenAI, and Codex, broken out per model, sourced from your own local CLI logs - so a Claude Pro/Max subscription or a ChatGPT-login Codex account is tracked with zero API keys.
- **Provider API integration** (optional) for teams with Admin API keys: Anthropic organization usage/cost reports, OpenAI organization usage reports, and a local JSONL feed for Azure OpenAI.
- **Cost estimates**, either provider-reported or from prices you configure yourself, clearly labeled so you always know which is which.
- **Reset times shown the useful way**: less than a day away shows a countdown ("4h 12m", "25m"); a day or more away shows the day and time ("Tuesday 7:00") instead of a moving-target relative estimate.

## Quick Start

Requirements: macOS 14+, Xcode.

```sh
git clone <this repo>
cd LimitBar
open LimitBar.xcodeproj
```

Run the `LimitBar` scheme in Xcode. The gauge icon appears in your menu bar - click it to open the popover.
If you already use `claude` or `codex` on this machine, the Rate Limit tab works immediately with no setup.

## Using LimitBar

### Rate Limit tab

**Claude** shows every window the Claude Code `/usage` endpoint reports for your login: a session (5 hour) window, an account-wide weekly window, and, on individual plans, any scoped weekly window (for example a specific model's weekly allowance). Team and Enterprise seats share a pooled allowance rather than a personal one, so LimitBar shows only the account-wide windows for those plans and hides the per-model scoped breakdown, since a scoped number there would describe the seat's slice of a shared pool, not a personal limit.

**Codex** reads the `rate_limits` payload Codex already logs locally to `~/.codex/sessions` after every response - no request is made on your behalf. What you see depends on your plan:
- **Individual (Plus, Free, or similar)**: the same session and weekly percent-used windows Codex's own CLI shows you.
- **Business/team seats**: Codex does not report personal percent-used windows for pooled plans (verified against real session logs: both come back empty). Instead LimitBar shows your calculated company-pool credit usage for Today and the Current Week, built from a rate you calibrate once from an admin-exported CSV - see [Codex Company-Pool Credits Estimate](#codex-company-pool-credits-estimate) below.

Every reset time uses the same rule: under 24 hours away shows a countdown (`4h 12m`, `25m`); 24 hours or more away shows the weekday and time (`Tuesday 7:00`) instead of a countdown that would just keep climbing.

### Usage tab

Shows Anthropic, Azure OpenAI, and Codex as separate cards, each broken down per model, for Today or Current Week (segmented control). Numbers come from confirmed local logs by default (see [Local Usage Events](#local-usage-events-jsonl-integration)), or from a provider's API if you configure a credential in Settings (see [Provider Configuration](#provider-configuration)).

## Local Usage Events JSONL Integration

Confirmed local usage for Anthropic, Azure OpenAI, and Codex (OpenAI) is imported from:

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

## Claude Rate Limits

LimitBar reuses the login Claude Code already maintains in the macOS Keychain (`Claude Code-credentials`) and calls the same `api.anthropic.com/api/oauth/usage` endpoint Claude Code uses for `/usage`.
No separate OAuth flow runs, and the token is never copied or stored by LimitBar.
macOS may ask once to allow LimitBar to read the Keychain item.
If the login is missing or expired, the tab says so; running `claude` refreshes it.
This endpoint is not part of Anthropic's public API surface and may change without notice.

Individual plans (`pro`, `max`) see every window the API reports, including scoped, per-model windows.
Any other plan value (`team`, `enterprise`, or unrecognized) is treated as pooled/shared and only shows the account-wide session and weekly windows, since Anthropic's own scoped-window semantics for shared seats have not been verified against a real Team/Enterprise account - this project only has a Pro account to test against, so that branch is a conservative default, not a confirmed behavior.

## Codex Rate Limits

Codex writes a `rate_limits` object to its local session logs (`~/.codex/sessions/**/*.jsonl`) as a side effect of every response, including `plan_type`, percent-used session/weekly windows when the plan has personal limits, and a `credits` object for plans that meter individually. LimitBar reads the freshest one already on disk - there is no documented endpoint to poll, and no request is made.

`plan_type: "business"` (verified against a real business-seat account) reports null windows and an empty credits object, because the credit ledger for pooled seats lives entirely in the org admin console, not in anything the CLI is told. For that plan type, LimitBar shows only the calculated credits estimate described below. Any other plan type is treated as individual and shows the percent-used windows directly, plus a raw credits balance line if Codex reports one.

## Provider Configuration

Anthropic supports an Admin API key and an OAuth-compatible future configuration path.
Validate & Refresh calls the Anthropic organization usage and cost reports and stores only normalized metrics.

OpenAI (shown as the Codex card) supports OAuth feasibility validation and an admin/platform API-key fallback.
LimitBar does not report OpenAI as Connected until the credential can access the required organization usage endpoint.
Unsupported OAuth, expired credentials, and admin-required access remain explicit in Settings and the Codex card.

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

## Codex Company-Pool Credits Estimate

Codex on a seat-based org plan does not expose a personal credits balance locally - the CLI's own rate-limit payload reports `has_credits: false` and a zero balance for accounts like this, because the credit ledger lives entirely in the workspace admin analytics export, not in anything the client is told.

If you're on a business/team Codex seat and want your credit usage, ask your workspace admin to export the analytics CSV bundle from the Codex admin console, and place it under a local `codex/` folder in this repo (already git-ignored - never commit it, since it contains coworker names, emails, and per-person productivity data). Then run:

```sh
tools/calibrate-codex-credits.py --email you@yourcompany.com
```

The script finds your row in `leaderboard-users_*.csv`, computes your personal blended credits-per-1M-tokens rate from your own `Credits` and `Tokens` totals for that export window, and writes a `currencyCode: "credits"` entry into LimitBar's existing Pricing store (the same mechanism as manual dollar pricing in Settings), scoped to `provider: openAI` and every Codex model label already tracked locally. No app code or UI change is needed - both the Usage tab's `Calculated estimate` cost rendering and the Rate Limit tab's business-plan credits section pick it up automatically.

This is a personal blended average (input, output, and cached input combined), not a per-model rate, because the export's per-model credit breakdown (`analytics-credits-by-model`, `analytics-credits-by-metered-item`) is workspace-wide, not per-user, so a personal per-model split cannot be recovered from this data.
Re-run the script whenever a new monthly export lands to recalibrate; it replaces only the prior `openAI` + `credits` entries, leaving other pricing untouched.

## Limits And Freshness

`Unsupported by provider API` means the selected provider source did not return a confirmed denominator.
LimitBar does not invent five-hour, weekly, TPM, quota, or rate-limit values.
It does not estimate live burn rate.

When a refresh fails, the last confirmed values remain visible and are marked Stale.
Unsupported, admin-required, expired, failed, disconnected, and missing states never imply healthy capacity.

## Project Layout

- `LimitBar.xcodeproj` contains the native menu bar app target.
- `LimitBar` contains the SwiftUI menu, popover, settings, Keychain-backed configuration, and production HTTP adapters.
- `LimitBarCore` contains testable provider mapping, persistence, pricing, diagnostics, and status logic.
- `tools/` contains the local usage exporter, its LaunchAgent installer, and the Codex credits calibration script.

## Build And Test

Run the core suite:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore
```

Build the native app:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build
```

## QA

See [`docs/QA.md`](docs/QA.md) for the final acceptance checklist and verification evidence.
