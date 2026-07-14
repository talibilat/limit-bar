# Configurable Refresh Cadence

## Status

Proposed, not committed, and blocked on profiling.

## Problem

The fixed five-second local refresh may not be the best latency and power tradeoff for every workload.

## User Outcome

Users can choose a documented local freshness and power tradeoff without accidentally increasing provider or Keychain traffic.

## Proposed Scope

Offer a small validated set of local refresh intervals after profiling establishes safe bounds.
Keep immediate refresh and coalescing behavior.
Make clear that the cadence applies only to local JSONL, custom files, SQLite snapshots, and Codex scanning.

## Explicit Non-Goals

The setting will not schedule provider API calls or Keychain polling.
It will not accept unbounded or sub-second values.

## Privacy And Security

The cadence remains local and is stored as a non-secret preference.
No usage content or timing telemetry leaves the device.

## Data Model Impact

Add one versioned preference with a safe default and validated allowed values.
No usage-metric schema change is expected.

## Open Questions

- Which intervals satisfy latency and power budgets?
- Should cadence change while on battery or while files are unchanged?
- Should filesystem events complement or replace some polling?

## Exit Criteria

- Representative I/O and power profiles exist for each offered interval.
- Tests verify timing, coalescing, cancellation, restart, and no provider or Keychain polling.
- Invalid persisted values return to the documented default.
