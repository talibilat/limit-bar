# LimitBar PRD

Status: ready-for-agent
Labels: ready-for-agent

## Problem Statement

The user runs parallel AI-assisted workflows across Anthropic, Azure OpenAI, and OpenAI/Codex Enterprise.
They need a trustworthy way to see how much capacity and cost they are consuming without opening multiple provider dashboards or guessing from terminal sessions.
The most disruptive failure mode is discovering too late that a quota or rate-sensitive resource is exhausted, but cost and usage visibility are equally important.
The user specifically wants a polished Mac menu bar app in the upper-right system menu area, near Siri and Wi-Fi, that stays out of the way while making provider usage visible at a glance.

Today, there is no single local surface that shows Anthropic model usage, Azure OpenAI token usage from teamwork scripts, and OpenAI project/model usage together.
Provider dashboards differ in data freshness, terminology, reporting windows, and API support.
Some desired limits, such as 5-hour quota or weekly quota, may not be exposed through official APIs.
The product must therefore be honest about which values are confirmed, which costs are calculated from confirmed token counts, and which limits are unsupported by the provider API.

## Solution

Build LimitBar, a private daily-driver native macOS 14+ menu bar app.
LimitBar shows a compact menu bar status indicator with a color-coded icon and the worst confirmed supported percentage, such as `82%`.
Clicking the menu bar item opens a modern, calm SwiftUI popover with fixed provider cards in this order: Anthropic, Azure OpenAI, OpenAI.

LimitBar uses confirmed data only for usage and limits.
It never estimates live burn rate or invents unsupported quotas.
When a provider does not expose a desired limit or denominator, LimitBar shows `Unsupported by provider API`.
When a refresh fails, LimitBar keeps the last confirmed values visible, marks them stale, and records the error in diagnostics.

Anthropic usage comes from the Anthropic Admin/usage API where available and is grouped by model or returned usage dimension.
Azure OpenAI usage comes from explicit local tool/script integration that appends normalized JSONL events containing response usage metadata.
OpenAI usage shows model/project/org identity, input tokens, output tokens, and spend where available, with an explicit OAuth feasibility validation step because the required usage endpoints may require admin or platform credentials.

Cost is shown from provider-returned cost when available.
If cost is not returned, LimitBar calculates cost from confirmed input/output token counts using bundled, manually editable, versioned pricing tables.
Calculated values are labeled `Calculated estimate`; provider-returned values are labeled `Provider reported`.

LimitBar stores credentials only in macOS Keychain.
It stores normalized usage metrics in local SQLite for 90 days.
It does not store prompts, response text, request bodies, terminal output, source code, or raw provider responses.

## User Stories

1. As a Mac user, I want a menu bar app that sits in the upper-right menu bar, so that I can monitor AI usage without switching applications.
2. As a Mac user, I want the menu bar item to show a compact colored status icon, so that I can understand overall health at a glance.
3. As a Mac user, I want the menu bar item to show the most constrained confirmed percentage, so that I can quickly see whether any supported limit is close to exhaustion.
4. As a Mac user, I want the menu bar indicator to turn green below 70%, so that normal usage feels calm and non-disruptive.
5. As a Mac user, I want the menu bar indicator to turn yellow at 70%, so that I have time to slow down before a limit becomes risky.
6. As a Mac user, I want the menu bar indicator to turn red at 90%, so that I can recognize critical usage immediately.
7. As a Mac user, I want the menu bar indicator to turn gray when data is stale, disconnected, or unsupported, so that the app does not imply false confidence.
8. As a Mac user, I want no notifications or sounds when status changes, so that the app remains a low-noise monitoring utility.
9. As a Mac user, I want to click the menu bar item and open a polished popover, so that detailed usage is one click away.
10. As a Mac user, I want the popover to use a fixed provider order, so that I can build scanning muscle memory.
11. As a Mac user, I want Anthropic to appear first, so that my primary Claude usage is immediately visible.
12. As a Mac user, I want Azure OpenAI to appear second, so that teamwork and terminal-script token usage is visible near the top.
13. As a Mac user, I want OpenAI to appear third, so that Codex Enterprise and OpenAI project usage is still tracked without dominating the dashboard.
14. As a Mac user, I want the popover to default to Today, so that the first view matches my current workday.
15. As a Mac user, I want a Current Week tab, so that I can understand weekly usage patterns and quota context.
16. As a Mac user, I want all metrics to clearly belong to the selected time window, so that I do not confuse daily and weekly totals.
17. As an Anthropic admin user, I want LimitBar to connect to the Anthropic Admin/usage API, so that the app can show organization-level usage where my account exposes it.
18. As an Anthropic user, I want usage grouped by model or returned usage dimension, so that I can see how much Haiku, Sonnet, Opus, Fable, and Cloud Design consume when those dimensions are available.
19. As an Anthropic user, I want to see input tokens by model, so that I can understand prompt-side usage.
20. As an Anthropic user, I want to see output tokens by model, so that I can understand generation-side usage.
21. As an Anthropic user, I want to see total tokens by model, so that I can compare overall model consumption.
22. As an Anthropic user, I want to see accumulated price when available, so that I can understand cost impact.
23. As an Anthropic user, I want unsupported Anthropic limits to be shown explicitly, so that I do not mistake missing limits for safe capacity.
24. As an Azure OpenAI user, I want usage grouped by model, so that usage from multiple deployments can be understood by model family.
25. As an Azure OpenAI user, I want scripts to append usage events to a local JSONL file, so that LimitBar can ingest response usage metadata without scraping arbitrary logs.
26. As an Azure OpenAI user, I want the JSONL file to live under Application Support, so that it follows macOS app data conventions.
27. As an Azure OpenAI user, I want each JSONL event to include provider, timestamp, model, deployment, input tokens, and output tokens, so that imported usage is normalized and auditable.
28. As an Azure OpenAI user, I want malformed JSONL events to be ignored safely and counted in diagnostics, so that bad integrations do not crash the app.
29. As an Azure OpenAI user, I want Azure cost calculated from confirmed token counts, so that I can track spend without using Azure management APIs.
30. As an Azure OpenAI user, I want Azure quotas and rate limits to show unsupported in v1, so that the app does not pretend it is calling Azure management APIs.
31. As an Azure OpenAI user, I want deployment metadata to be retained when an event supplies it, so that I can trace model usage back to the source deployment.
32. As an OpenAI user, I want OpenAI usage grouped by model and project, so that I can understand where OpenAI consumption is coming from.
33. As an OpenAI user, I want organization identity displayed, so that I can tell which account or organization a metric belongs to.
34. As an OpenAI user, I want project identity displayed, so that I can attribute usage to Codex Enterprise or another project.
35. As an OpenAI user, I want input tokens shown, so that I can measure prompt-side usage.
36. As an OpenAI user, I want output tokens shown, so that I can measure generation-side usage.
37. As an OpenAI user, I want spend shown when available, so that I can understand OpenAI cost impact.
38. As an OpenAI user, I want OAuth support to be validated before the app claims a full connection, so that I am not misled by insufficient scopes.
39. As an OpenAI user, I want the app to explain if an admin or platform credential is required, so that I know why OAuth is insufficient.
40. As a user running parallel AI sessions, I want the app to avoid estimated live burn-rate projections, so that I only make decisions from confirmed data.
41. As a user running parallel AI sessions, I want provider data freshness visible, so that I know whether the displayed values are current enough to trust.
42. As a user running parallel AI sessions, I want the app to keep last confirmed values after refresh failure, so that transient errors do not erase useful context.
43. As a user running parallel AI sessions, I want stale values marked clearly, so that I understand they are no longer current.
44. As a user running parallel AI sessions, I want refresh errors shown in diagnostics, so that I can troubleshoot provider connectivity.
45. As a user tracking costs, I want provider-reported cost labeled as provider-reported, so that I know it came from the provider.
46. As a user tracking costs, I want calculated cost labeled as calculated estimate, so that I know it came from pricing tables and confirmed tokens.
47. As a user tracking costs, I want bundled pricing defaults, so that the app can ship with a known pricing structure.
48. As a user tracking costs, I want to manually edit pricing tables, so that I can update pricing when providers change rates.
49. As a user tracking costs, I want pricing entries to be versioned, so that old usage is not recalculated with new prices.
50. As a privacy-conscious user, I want API keys stored only in Keychain, so that credentials are not written into local files.
51. As a privacy-conscious user, I want OAuth tokens stored only in Keychain, so that refresh tokens are not exposed in exports or logs.
52. As a privacy-conscious user, I want normalized usage metrics stored in SQLite, so that local history is queryable without retaining sensitive prompt data.
53. As a privacy-conscious user, I want raw provider responses not to be stored, so that API responses do not accidentally leak sensitive metadata.
54. As a privacy-conscious user, I want prompt text never stored, so that the app cannot expose private work content.
55. As a privacy-conscious user, I want response text never stored, so that model outputs remain outside the monitoring database.
56. As a privacy-conscious user, I want terminal output never stored, so that command results remain private.
57. As a privacy-conscious user, I want source code never stored, so that project code does not leak into the monitoring app.
58. As a privacy-conscious user, I want exports to exclude secrets, so that diagnostics or backups cannot disclose credentials.
59. As a daily user, I want 90 days of local metric retention, so that recent trends remain available without unbounded database growth.
60. As a daily user, I want a settings window separate from the popover, so that setup and diagnostics do not crowd the monitoring view.
61. As a daily user, I want the popover to stay compact and scan-friendly, so that I can check usage quickly.
62. As a daily user, I want provider settings in the settings window, so that credentials and account state are managed outside the monitoring view.
63. As a daily user, I want pricing settings in the settings window, so that calculated cost can be configured deliberately.
64. As a daily user, I want diagnostics in the settings window, so that refresh errors and malformed events are discoverable.
65. As a daily user, I want the JSONL path visible in settings, so that I can point tools and scripts at the right integration file.
66. As a daily user, I want a Reveal in Finder action for the JSONL path, so that I can inspect integration files easily.
67. As an implementer, I want provider logic separated from SwiftUI views, so that provider behavior can be tested without UI automation.
68. As an implementer, I want a shared normalized metric model, so that Anthropic, Azure OpenAI, and OpenAI data render through one UI path.
69. As an implementer, I want provider clients behind a refresh interface, so that refresh failure semantics are consistent across providers.
70. As an implementer, I want an HTTP abstraction around URLSession, so that provider response mapping can be tested with fixtures.
71. As an implementer, I want Azure JSONL parsing isolated, so that malformed event behavior can be tested directly.
72. As an implementer, I want cost calculation isolated, so that pricing behavior can be tested independently of provider APIs.
73. As an implementer, I want Keychain access isolated, so that credential handling stays behind a narrow seam.
74. As an implementer, I want SQLite storage isolated behind a usage store, so that persistence behavior can be tested without SwiftUI.
75. As an implementer, I want retention policy isolated, so that 90-day deletion behavior is deterministic and testable.

## Implementation Decisions

- Build a native macOS 14+ app using SwiftUI for the popover/settings UI and AppKit or `MenuBarExtra` for menu bar integration.
- Keep the app private daily-driver quality rather than App Store quality.
- Use a compact menu bar status that displays a colored symbol and the worst confirmed supported percentage.
- Use green below 70%, yellow at 70%, red at 90%, and gray when stale, disconnected, or unsupported.
- Do not send notifications, play sounds, or issue urgent alerts.
- Use a fixed popover provider order: Anthropic, Azure OpenAI, OpenAI.
- Use Today and Current Week as the only initial time windows, with Today selected by default.
- Treat confirmed provider data as the only source for displayed usage and limits unless an explicit local integration supplies confirmed response usage metadata.
- Do not estimate live burn rate.
- Do not infer missing 5-hour quota, weekly quota, or TPM values.
- Show `Unsupported by provider API` whenever a desired limit or denominator is unavailable from the chosen source.
- Keep last confirmed values visible after refresh failure and mark them stale.
- Store refresh errors and malformed integration events in diagnostics.
- Model usage as normalized metric rows containing provider, account/org label, project label, model label, optional deployment label, time window, input tokens, output tokens, total tokens, cost, cost source, limit status, refresh timestamp, and stale state.
- Store credentials only in macOS Keychain.
- Store normalized metrics in local SQLite.
- Retain local metric snapshots for 90 days.
- Never store prompt text, response text, request bodies, raw provider responses, terminal output, or source code.
- Never export API keys, OAuth access tokens, OAuth refresh tokens, or other Keychain material.
- Prefer provider-returned cost when available.
- Calculate cost from confirmed token counts when provider cost is unavailable.
- Label calculated cost as `Calculated estimate` and provider-returned cost as `Provider reported`.
- Use bundled default pricing tables that can be manually edited in settings.
- Version pricing entries so historical usage is not recalculated using later prices.
- Use Anthropic Admin/usage API as the Anthropic source where available.
- Group Anthropic usage by model or returned usage dimension.
- Display Anthropic dimensions such as Haiku, Sonnet, Opus, Fable, and Cloud Design only when returned by the API.
- Treat Anthropic limits as unsupported unless the Admin/usage API exposes a confirmed denominator.
- Do not use Azure management APIs in v1.
- Do not display Azure OpenAI quota or rate-limit state in v1.
- Ingest Azure OpenAI token usage from explicit local tool/script integration rather than arbitrary log scraping or a local proxy.
- Use an append-only JSONL file under Application Support as the Azure OpenAI ingestion mechanism.
- Require Azure JSONL events to include provider, timestamp, model, input tokens, output tokens, and optional deployment.
- Group Azure OpenAI usage by model.
- Calculate Azure OpenAI cost from confirmed JSONL token counts and pricing tables.
- Show OpenAI usage by organization, project, and model.
- Validate whether OpenAI OAuth can access the required organization/project usage endpoints before marking OpenAI fully connected.
- If OpenAI OAuth cannot access required usage endpoints, show an explicit unsupported or requires-admin-credential state.
- Use a separate settings window for provider auth, pricing tables, diagnostics, retention, exports, and JSONL path visibility.
- Keep the monitoring popover optimized for fast scanning rather than configuration.
- Use a local markdown issue tracker for this new project under `.scratch/`.

## Testing Decisions

- The primary test seam is the core package boundary.
  Provider mapping, usage normalization, pricing, status computation, retention, storage, refresh failure behavior, and Azure event parsing should be tested without SwiftUI or real provider APIs.
- The highest-value end-to-end seam is the menu bar app shell loading normalized metrics from the local store and rendering provider cards in fixed order.
  This seam should be validated with a small native app smoke test or manual QA checklist until an automated UI harness exists.
- Tests should assert externally visible behavior, not implementation details.
  For example, test that a 90% supported limit produces a red menu bar status, not which private helper computed the number.
- Menu bar status tests should cover green below 70%, yellow at 70%, red at 90%, gray after 2 missed refreshes, and gray when only unsupported statuses exist.
- Time window tests should cover Today and Current Week boundaries using a deterministic calendar.
- Cost calculator tests should cover input/output token cost calculation, latest effective pricing at usage time, missing price behavior, and cost source labels.
- Azure JSONL parser tests should cover valid events, unsupported provider values, malformed JSON, missing fields, negative token counts, and optional deployment metadata.
- Azure importer tests should cover conversion from a valid event into a normalized metric with unsupported Azure limit state.
- Retention policy tests should cover deletion cutoff at 90 days.
- Refresh coordinator tests should cover successful refresh, failed refresh retaining last confirmed metrics, stale marking, missed refresh counts, and error text for diagnostics.
- Provider mapping tests should use fixtures for Anthropic and OpenAI responses rather than live APIs.
- OpenAI OAuth feasibility tests should cover supported, unsupported, and requires-admin-credential outcomes.
- Storage tests should use a temporary SQLite database and verify only normalized fields are persisted.
- Keychain behavior should be isolated behind a credential store interface so tests can use an in-memory fake rather than the real user Keychain.
- Settings behavior should be tested at the view-model level where possible, with manual QA for the native Keychain prompts and Finder reveal action.
- Manual QA should verify launch on macOS 14+, menu bar rendering, popover provider order, Today default tab, Current Week tab switching, JSONL event ingestion, malformed JSONL diagnostics, refresh failure staleness, and absence of secrets in exports.

## Out of Scope

- App Store distribution is out of scope for v1.
- Public onboarding polish is out of scope for v1.
- Cloud backend, sync, team accounts, or hosted telemetry are out of scope.
- Notifications, sounds, and urgent alerts are out of scope.
- Estimated live burn-rate projections are out of scope.
- Local proxy capture is out of scope.
- Arbitrary log scraping is out of scope.
- Azure management API integration is out of scope.
- Azure OpenAI quota or rate-limit tracking is out of scope for v1.
- Manual user-defined limits that masquerade as provider limits are out of scope.
- Storing prompts, responses, raw provider responses, terminal output, request bodies, or source code is out of scope.
- Exporting secrets or encrypted full credential backups is out of scope.
- Supporting macOS versions older than macOS 14 is out of scope.
- Supporting non-Mac platforms is out of scope.
- Automatically updating pricing tables from a remote feed is out of scope for v1.
- Implementing full live provider network adapters before validating exact account API access is out of scope.

## Further Notes

The project should start by validating provider API access because OpenAI OAuth may not expose the desired usage endpoints and Anthropic Admin/usage API dimensions may differ from the user's labels.
The product must remain honest when a desired metric cannot be confirmed.
The preferred implementation sequence is to build the tested core first, then the native menu bar shell, then provider adapters behind fixtures and validated credentials.

The detailed implementation plan created during planning is available at `~/docs/superpowers/plans/2026-07-09-limitbar.md`.
