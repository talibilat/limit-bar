# Budget And Rate-Limit Alerts

## Status

Proposed, not committed.

## Problem

Users must open the popover to notice a high confirmed rate limit or an approaching local cost budget.

## User Outcome

Users receive timely local notifications at thresholds they choose, with clear freshness and estimate labels.

## Proposed Scope

Add opt-in local alerts for confirmed rate-limit percentages and normalized cost thresholds.
Deduplicate alerts per exact window and reset notification state at the next exact boundary.
Keep provider-reported and calculated costs visibly distinct.

## Explicit Non-Goals

Alerts will not infer unsupported limits, claim estimates are invoices, trigger provider API polling, or send notifications to a server.
They will not inspect conversation content.

## Privacy And Security

Notification text should default to coarse provider and threshold information and avoid project, model, source, and account labels on the lock screen.
Raw prompts, code, responses, terminal output, credentials, and provider payloads are prohibited.

## Data Model Impact

Store local threshold preferences and per-exact-window deduplication state.
Legacy rows without exact boundaries are ineligible for alerts.

## Open Questions

- Which thresholds and quiet-hours controls are necessary?
- Should stale metrics suppress or qualify alerts?
- How should multiple currencies and calculated estimates behave?

## Exit Criteria

- Alerts fire once per configured threshold and exact window.
- Stale, unsupported, legacy, and malformed values cannot create misleading alerts.
- Lock-screen copy passes privacy review.
- All state remains local and is user-resettable.
