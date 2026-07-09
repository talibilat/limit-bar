# Finish Private Daily-Driver Polish, Documentation, And QA

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Finish LimitBar as a private daily-driver macOS utility.
This issue hardens the assembled app rather than adding new scope.
It should polish the monitoring UI, complete settings ergonomics, document the local integration contract, verify privacy boundaries, and run manual QA on macOS 14+.

The result should feel modern, calm, and trustworthy.
It should not add App Store distribution, notifications, sounds, cloud sync, hosted telemetry, Azure management API integration, local proxy capture, arbitrary log scraping, automatic pricing updates, or estimated live burn-rate projections.

## Acceptance criteria

- [ ] The menu bar item is compact and readable in normal macOS menu bar conditions.
- [ ] The popover uses a clear visual hierarchy for provider cards, token metrics, costs, stale states, and unsupported states.
- [ ] Provider cards remain in fixed order: Anthropic, Azure OpenAI, OpenAI.
- [ ] Today is selected by default and Current Week remains available.
- [ ] Settings clearly separate provider auth, pricing, diagnostics, and integration details.
- [ ] The Azure JSONL path is documented and visible in settings.
- [ ] README documents the JSONL event schema and example event.
- [ ] README documents credential storage, privacy boundaries, cost labels, and unsupported-limit behavior.
- [ ] Manual QA verifies app launch, menu bar rendering, popover rendering, settings rendering, time window switching, Azure JSONL ingestion, malformed event diagnostics, Anthropic fixture/provider behavior, OpenAI OAuth feasibility states, refresh staleness, and cost labels.
- [ ] Manual QA verifies diagnostics and exports do not include API keys, access tokens, refresh tokens, prompts, responses, terminal output, source code, or raw provider responses.
- [ ] The final app builds and core tests pass on macOS 14+.

## Blocked by

- https://github.com/talibilat/limit-bar/issues/6
- https://github.com/talibilat/limit-bar/issues/8
- https://github.com/talibilat/limit-bar/issues/9
