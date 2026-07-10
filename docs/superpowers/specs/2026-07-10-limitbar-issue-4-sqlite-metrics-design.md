# LimitBar Issue 4 SQLite Metrics Design

## Context

Issue #4 replaces purely in-memory demo rows with local durable storage for normalized usage metrics.
The store may persist normalized usage metadata, but it must never persist prompts, responses, raw provider responses, terminal output, source code, API keys, access tokens, or refresh tokens.

## Approved Approach

Add a deep concrete module named `SQLiteUsageMetricStore` in `LimitBarCore`.
Its interface will stay small: open a database, save metrics, query metrics, mark retained metrics stale after refresh failure, prune old metrics, inspect schema column names for tests, and report health.
The SQLite schema and mapping details remain inside the adapter implementation.

## Store Interface

The store will support in-memory and file-backed databases.
Tests will use in-memory or temporary file databases.
The app will use `~/Library/Application Support/LimitBar/usage-metrics.sqlite`.

`save(_:)` will upsert normalized `UsageMetric` rows.
`metrics(for:)` will query by selected time window.
`allMetrics()` will query across all providers for popover rendering.
`deleteMetrics(olderThan:)` will remove rows older than the 90-day retention cutoff.
`markMetricsStale(timeWindow:missedRefreshes:)` will preserve last confirmed values while marking retained rows stale after refresh failure.
`health()` will report whether the database opened successfully.

## App Integration

The popover will no longer read `DemoUsageData.metrics` directly.
It will load metrics through a `StoredUsageMetrics` helper that opens the app SQLite store, seeds demo metrics when empty, and returns all stored metrics.
If opening the local store fails, the helper will return demo metrics and a failed health state rather than crashing the popover.

## Privacy Boundary

The SQLite table will include only normalized metadata columns: provider, time window, account label, project label, model label, deployment label, input tokens, output tokens, cost fields, limit fields, refresh timestamp, and freshness fields.
Tests will assert forbidden columns such as prompt, response, raw response, request body, terminal output, source code, API key, access token, and refresh token are absent.

## Out Of Scope

Live provider refresh is out of scope.
Provider credentials are out of scope.
Provider API response storage is out of scope.
Pricing calculation is out of scope.
Full settings diagnostics UI is out of scope beyond basic database health plumbing.

## Acceptance Mapping

SQLite save/query covers normalized metric persistence.
Time-window queries support popover filtering.
`allMetrics()` supports querying across all providers for popover rendering.
Store seeding supports local stored demo metrics instead of direct hardcoded popover rows.
Retention deletion covers the 90-day policy.
Refresh failure staleness keeps retained metric values visible.
Schema tests verify normalized fields and privacy boundaries.
Health reporting supports basic diagnostics.
