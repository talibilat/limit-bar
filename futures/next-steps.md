# Reliability And Distribution Next Steps

## Status

Proposed and prioritized.
This document records follow-up work and residual risks rather than commitments.

## Problem

Core behavior and critical native fixture flows have deterministic test coverage, but distribution identity, real-account authorization, operational performance, sandbox policy, and release migration behavior need broader evidence.

## User Outcome

Users receive a predictable signed app whose local refresh, authorization, migrations, and privacy boundaries have been tested under realistic release conditions.

## Proposed Scope

1. Produce a stable signed and notarized distribution identity so Keychain access behavior is tested against an identity users will keep.
2. Run real-account Keychain QA for passive checks, Connect, Check Again, Always Allow, app updates, changed identity, and a recreated Claude item.
3. Profile five-second refresh I/O, CPU, memory, wakeups, and power with unchanged and changing JSONL files.
4. Make an explicit App Sandbox decision, including security-scoped bookmarks or a documented unsandboxed distribution if arbitrary files remain required.
5. Run binary-to-binary migration acceptance using databases from every distributed schema after the first public release exists.

## Explicit Non-Goals

This work does not add telemetry, cloud synchronization, raw event upload, or automatic provider credential discovery.
It does not treat passing fixture tests as a substitute for signed release QA.

## Privacy And Security

Real-account QA must use designated test accounts and must not commit credentials, Keychain exports, private paths, or provider responses.
Profiling artifacts must contain aggregate timings and statuses only.
No raw prompts, code, responses, terminal output, credentials, or raw provider payloads may be captured.

## Data Model Impact

No product data-model change is required for signing or profiling.
Sandbox bookmarks or migration metadata may require separately reviewed schemas with explicit lifecycle and deletion rules.

## Open Questions

- Which signing identity and release channel will remain stable across updates?
- Does public distribution require App Sandbox, and can security-scoped bookmarks support all intended local sources?
- Which database versions must be represented in release fixtures?
- What power and latency budgets should gate the five-second cadence?

## Exit Criteria

- A signed update preserves expected Keychain behavior, with documented exceptions for identity and item changes.
- Profiling records an accepted refresh budget on representative files.
- The sandbox decision and migration test matrix are documented and approved.
