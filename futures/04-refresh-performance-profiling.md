# Refresh Performance Profiling

## Status

Implementation ready for representative hardware measurement.

## Problem

The five-second Local Refresh Cycle lacks accepted I/O, CPU, memory, wakeup, and power budgets.

## User Outcome

Users receive predictable local freshness without unmeasured battery or performance costs.

## Scope

Profile complete Local Refresh Cycles and diagnostic components with fingerprint-stable and event-append synthetic sources.
Record Publication Latency, I/O, CPU, memory, wakeups, and power at the current cadence on representative supported hardware.
Define accepted budgets that constrain later cadence choices.

## Explicit Non-Goals

This ticket does not change refresh cadence or add telemetry.
It does not profile Provider Refresh or Claude Refresh operations.
It does not infer power from latency or one CI runner.

## Privacy And Security

Use generated synthetic fixtures in temporary directories.
Retain aggregate timings, resource values, fixture dimensions, environment classes, and statuses only.
Do not retain identifying paths, fixture contents, or unreviewed Instruments traces.

## Data Model Impact

No product data-model change is required.
Canonical local-refresh language is recorded in `CONTEXT.md`.

## Remaining Measurement Decisions

- Accept final numeric resource and power budgets after the representative measurement matrix is complete.
- Confirm the oldest supported hardware class used as the cadence gate.
- Confirm whether Intel remains part of the distributed architecture matrix.

## Exit Criteria

- The versioned profiler reproduces complete production-cycle and component scenarios from a clean checkout.
- Representative fingerprint-stable, event-append, and bounded-stress profiles are recorded.
- Accepted latency, CPU, memory, I/O, wakeup, and power budgets are documented with their device and workload matrix.
- Sustained results report Cadence Overruns.
- Results and retained artifacts contain no usage content or identifying paths.
- The resulting constraints are sufficient to evaluate every interval proposed by configurable-cadence work.
