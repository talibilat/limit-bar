# Historical Usage Trends

## Status

Proposed, not committed.

## Problem

Current snapshots answer what happened today or this week but do not show longer-term changes.

## User Outcome

Users can understand local token and cost trends over time without sending usage data elsewhere.

## Proposed Scope

Add local daily and weekly aggregate views built from normalized bounded metrics.
Define retention, gap, timezone-change, source-overlap, and pricing-version semantics before rendering charts.

## Explicit Non-Goals

The feature will not display individual conversations or reconstruct raw events.
It will not provide cloud backup, team comparison, or provider billing reconciliation.

## Privacy And Security

Only normalized counts, costs, source identifiers, model labels, and exact windows may be retained.
Raw prompts, code, responses, terminal output, credentials, and raw provider payloads are prohibited.
Users must be able to delete historical aggregates locally.

## Data Model Impact

The SQLite model may need immutable aggregate periods distinct from current snapshots and an explicit retention version.
Legacy rows without exact bounds must not be silently assigned historical dates.

## Open Questions

- What is the default retention period?
- How should timezone changes and pricing revisions appear?
- How are overlapping provider API and local-log measurements deduplicated?

## Exit Criteria

- Window and deduplication semantics are specified and tested.
- Storage growth is bounded and deletion is verified.
- Charts never require or reveal raw event content.
- Migration from current snapshot-only storage is reversible or recoverable.
