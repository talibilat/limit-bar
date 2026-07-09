# Persist Metrics Locally With SQLite And 90-Day Retention

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Replace purely in-memory demo data with local durable storage for normalized usage metrics.
The app should store normalized metric rows in SQLite, query them by provider and time window, load them into the popover, and apply 90-day retention.

This issue must preserve the privacy boundary from the PRD.
The store may persist normalized usage metadata, but it must not persist prompts, response text, request bodies, raw provider responses, terminal output, source code, API keys, access tokens, or refresh tokens.
Refresh failure semantics should keep last confirmed values visible and mark them stale rather than clearing them to zero.

## Acceptance criteria

- [ ] Normalized usage metrics can be saved to local SQLite.
- [ ] Metrics can be queried by selected time window.
- [ ] Metrics can be queried across all providers for popover rendering.
- [ ] Seeded local metrics appear in the popover instead of hardcoded demo rows.
- [ ] Metrics older than 90 days are removed or marked eligible for retention cleanup.
- [ ] Refresh failure keeps the last confirmed values visible.
- [ ] Refresh failure marks retained values stale.
- [ ] Storage tests verify normalized fields are persisted correctly.
- [ ] Storage tests verify sensitive content and raw provider responses are not part of the persistence model.
- [ ] The settings or diagnostics surface can report basic database health, such as whether the store opened successfully.

## Blocked by

- https://github.com/talibilat/limit-bar/issues/2
- https://github.com/talibilat/limit-bar/issues/3
