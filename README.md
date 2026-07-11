# LimitBar

A free, open-source macOS menu bar app for AI coding usage: Claude Code, Codex, Azure OpenAI, and OpenAI-compatible providers you configure. Everything runs locally — no account, cloud sync, or telemetry.

The menu bar gauge turns green, yellow, or red as your busiest rate limit fills up. Click it for two tabs:

- **Rate Limit** — percent used, remaining, and reset time for Claude Code and Codex.
- **Usage** — confirmed token counts and cost per provider and model, for Today or Current Week.

![LimitBar Rate Limit tab showing Claude session and weekly windows](docs/ss3.png)

## Features

- **Claude Code** — session and weekly limits from your existing Keychain login.
- **Codex** — limits from local session logs; pooled team seats can show credits estimates when pricing is configured in Settings.
- **Usage tracking** — Anthropic, Azure OpenAI, and Codex from local CLI logs, with optional Admin API keys. A provider's card only appears once it actually has usage or a configured credential — nothing shows for tools you don't use.
- **Any other tool** — add a custom local log source in Settings (name + file path) to track usage from any tool with no built-in support: Aider, Cursor, Windsurf, or anything else that can write a JSON line per response.
- **Cost labels** — provider-reported or calculated estimates, clearly marked.
- **Privacy-first** — credentials in Keychain, metrics in local SQLite, no prompts or telemetry stored.

## Prerequisites

- **macOS 14 (Sonoma) or later** — LimitBar is a native menu bar app and does not run on iOS, Linux, or Windows.
- **Xcode 16 or later** — required to build and run LimitBar from source (the core package targets Swift 6). There is no pre-built download yet; install Xcode from the Mac App Store, then open it once so command-line tools are set up.
- **Git** — to clone this repository.

Optional, for zero-setup rate limits: if you already use **Claude Code** (`claude`) or **Codex** (`codex`) on this Mac, the Rate Limit tab works immediately after launch — Claude from your existing Keychain login, Codex from local session logs at `~/.codex/sessions`.

## Run It

```sh
git clone https://github.com/talibilat/limit-bar.git
cd LimitBar
open LimitBar.xcodeproj
```

1. In the Xcode toolbar, choose the **LimitBar** scheme and destination **My Mac**.
2. Press **⌘R** (or click **Run**).
3. After the build finishes, the gauge icon appears in the menu bar (upper-right, near Wi‑Fi and battery). Click it to open the popover.
4. On first launch, macOS may ask to allow LimitBar to read the **Claude Code** Keychain item — approve if you want Claude rate limits without signing in again.

To stop the app while debugging, press **⌘.** in Xcode or quit LimitBar from the menu bar icon.

## Usage

**Rate Limit** reuses Claude Code's login and reads Codex limits from `~/.codex/sessions`. Reset times show a countdown under 24 hours, otherwise the weekday and time.

**Usage** shows one card per provider, broken down by model.

**Today** rolls up confirmed token counts per model across every connected provider:

![LimitBar Usage tab — Today, Anthropic models from local logs](docs/ss2.png)

**Current Week** uses the same layout with a wider window — handy when you want a running total instead of a single-day snapshot:

![LimitBar Usage tab — Current Week, Azure OpenAI models](docs/ss1.png)

Confirmed usage can also be imported from `~/Library/Application Support/LimitBar/usage-events.jsonl` — the path is shown in Settings.

### Tracking any other tool

Settings has a **Custom Usage Sources** section for tools with no built-in adapter. Point it at a local log file where each line is JSON with `timestamp`, `model`, `inputTokens`, and `outputTokens`:

```json
{"timestamp":"2026-07-12T10:00:00Z","model":"gpt-4o","inputTokens":100,"outputTokens":20}
```

Give the source a name (e.g. "Aider") and LimitBar shows it as its own card on the Usage tab, broken down by model, the same as any built-in provider — as soon as the file has matching events, and not before.

## Build & Test

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build
```

## More Detail

See [`docs/QA.md`](docs/QA.md) for acceptance checks and verification notes.

---

Maintained by [Md Talib](https://github.com/talibilat) at Factor. If LimitBar is useful, star the repo or share it with your team.
