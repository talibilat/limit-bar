# LimitBar Issue 2 Usage Model Design

## Context

Issue #2 defines the shared usage model and status rules that provider adapters, persistence, and SwiftUI surfaces will use.
The implementation belongs in `LimitBarCore` and should not add provider integrations, persistence, credentials, notifications, sounds, or urgent alerts.

## Approved Approach

Add focused core value types instead of one large struct or provider-specific models.
The shared model will represent provider identity, time windows, token usage, costs, limit status, freshness, normalized usage metrics, and menu bar status.
All status decisions will be pure functions that can be tested without SwiftUI or provider APIs.

This keeps issue #2 centered on the domain seam needed by later issues.
It avoids speculative provider-specific models before real provider mapping exists.

## Core Model

`ProviderKind` will support Anthropic, Azure OpenAI, and OpenAI.
It will expose a fixed ordering of Anthropic, Azure OpenAI, then OpenAI.

`TimeWindow` will support Today and Current Week.
It will compute deterministic date intervals from an injected `Calendar` and reference `Date`.
Today starts at the start of the reference day and ends at the next day boundary.
Current Week starts at the calendar week interval containing the reference date and ends at that interval's end.

`TokenUsage` will hold input tokens, output tokens, and a computed total.
The model will keep input and output confirmed values separate so later cost calculation can use the correct price side.

`Cost` and `CostSource` will represent optional cost values and whether the cost is provider reported or a calculated estimate.
Issue #2 only defines the labels and data shape; cost calculation itself remains for issue #5.

`LimitStatus` will represent confirmed usage percentages, unsupported provider limits, and disconnected or unavailable states.
Only confirmed supported limits can contribute a percentage to menu bar urgency.
Unsupported, disconnected, and unavailable states must remain explicit and must not be treated as safe usage.

`Freshness` will represent fresh and stale metric states.
A helper will mark data stale after two missed refreshes.

`UsageMetric` will combine provider, account or organization identity, project identity, model label, optional deployment label, selected time window, token usage, optional cost, limit status, refresh timestamp, and freshness.
This is normalized usage metadata only and contains no prompt text, response text, request bodies, raw provider responses, terminal output, source code, API keys, access tokens, or refresh tokens.

## Menu Bar Status Rules

`MenuBarStatus` will expose a display color and optional confirmed percentage.
The color rules are:

- Green below 70% confirmed usage.
- Yellow at 70% confirmed usage.
- Red at 90% confirmed usage.
- Gray when data is stale.
- Gray when only unsupported, disconnected, or unavailable statuses exist.

When multiple metrics have confirmed supported limits, the menu bar status uses the worst confirmed percentage.
If any relevant metric is stale, the status is gray rather than implying current confidence.
The model must not estimate live burn rate or invent missing 5-hour quota, weekly quota, or TPM values.

## AppStatus Bridge

`AppStatus` remains the small shell-facing model used by the macOS app.
Issue #2 will add a bridge from `MenuBarStatus` to `AppStatus` so the app shell can later render real status without coupling SwiftUI to the full usage model.
The existing `AppStatus.initial` remains available for the empty shell state.

## Testing

Unit tests will cover fixed provider order, today and current-week boundaries with a deterministic calendar, token total calculation, cost source labels, supported and unsupported limit states, stale-after-two-missed-refreshes behavior, and menu bar threshold colors.
Tests will assert behavior through public `LimitBarCore` APIs and will not use SwiftUI.

## Out Of Scope For Issue #2

Provider refresh is out of scope.
SQLite persistence is out of scope.
Cost calculation is out of scope.
Popover provider-card rendering is out of scope.
Credential storage and diagnostics UI are out of scope.
Estimated live burn-rate projection is out of scope.

## Acceptance Mapping

The core model supports Anthropic, Azure OpenAI, and OpenAI through `ProviderKind`.
Fixed provider order is exposed by `ProviderKind.orderedCases`.
Today and Current Week are represented by `TimeWindow` and deterministic interval calculation.
Input tokens, output tokens, total tokens, cost, cost source, limit status, refresh timestamp, and stale state are represented by the model types.
Green, yellow, red, and gray menu bar status rules are implemented by `MenuBarStatus`.
Unit tests cover the issue's required ordering, time-window, threshold, stale, and unsupported behavior.
