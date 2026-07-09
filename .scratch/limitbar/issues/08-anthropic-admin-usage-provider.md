# Validate And Display Anthropic Admin Usage

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Build the Anthropic provider slice using the Anthropic Admin/usage API as the intended source.
The implementation should first validate the API surface and then map fixture-backed Admin usage responses into normalized metrics.
Anthropic usage should appear in the first provider card, grouped by model or returned usage dimension.

The provider must display returned labels such as Haiku, Sonnet, Opus, Fable, and Cloud Design when the API returns them.
It must not invent those labels if the API does not return them.
Anthropic limits should be shown as unsupported unless the Admin/usage API returns a confirmed denominator.

## Acceptance criteria

- [ ] Anthropic provider settings can validate whether configured credentials can reach the intended Admin/usage API surface.
- [ ] Fixture-backed Anthropic Admin usage responses map into normalized metrics.
- [ ] Anthropic metrics are grouped by model or returned usage dimension.
- [ ] Returned labels such as Haiku, Sonnet, Opus, Fable, and Cloud Design appear when present in the source data.
- [ ] Missing labels are not invented by the app.
- [ ] Anthropic rows show input tokens, output tokens, total tokens, and cost when available.
- [ ] Provider-reported cost is labeled `Provider reported`.
- [ ] Calculated cost is labeled `Calculated estimate` when provider cost is unavailable and pricing is configured.
- [ ] Anthropic limits show `Unsupported by provider API` unless a confirmed denominator is returned.
- [ ] Refresh success stores latest confirmed Anthropic metrics.
- [ ] Refresh failure keeps last confirmed Anthropic values visible and marks them stale.
- [ ] Diagnostics show Anthropic refresh errors without exposing credentials or raw provider responses.

## Blocked by

- https://github.com/talibilat/limit-bar/issues/4
- https://github.com/talibilat/limit-bar/issues/5
- https://github.com/talibilat/limit-bar/issues/7
