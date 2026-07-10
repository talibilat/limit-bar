# LimitBar Issue 4 SQLite Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist normalized usage metrics in local SQLite with query, retention, stale-retention, and health behavior.

**Architecture:** Add `SQLiteUsageMetricStore` as a deep concrete module in `LimitBarCore`, hiding schema and SQL behind a small interface. Update the SwiftUI popover to load stored seeded metrics rather than directly reading demo fixture rows.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation, SQLite3.

## Global Constraints

- Persist normalized usage metadata only.
- Do not persist prompts, responses, request bodies, raw provider responses, terminal output, source code, API keys, access tokens, or refresh tokens.
- Keep refresh failure values visible and mark them stale rather than clearing them to zero.
- Retain only 90 days of local metric history.
- Do not add live provider integrations, credentials, or pricing calculation.

---

## Tasks

### Task 1: SQLite Store Core

- Write failing tests for save/query by time window, all-provider query, schema privacy, retention deletion, stale marking, and health.
- Implement `SQLiteUsageMetricStore` and `UsageStoreHealth` in `LimitBarCore/Sources/LimitBarCore/SQLiteUsageMetricStore.swift`.
- Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`.
- Commit with `Add SQLite usage metric store`.

### Task 2: Popover Store Loading

- Write failing core tests for store seeding from demo metrics.
- Add `StoredUsageMetrics` in `LimitBarCore` to open the application-support store, seed demo metrics when empty, and return all metrics with health.
- Update `MonitoringPopoverView` to use stored metrics state instead of `DemoUsageData.metrics` directly.
- Run core tests and native build.
- Commit with `Load popover metrics from local store`.

### Task 3: Final Verification

- Run full core tests.
- Run native app build.
- Run launch smoke check.
- Run formal code review against `main`.
- Attempt `no-mistakes`; record the tool limitation if it still cannot start this repo's first branch run.

## Self-Review

- Spec coverage: tasks cover SQLite persistence, time-window query, all-provider query, local seeded metrics, retention, stale refresh failure behavior, privacy schema tests, and health reporting.
- Completion-marker scan: no unfinished markers or vague implementation steps remain.
- Type consistency: `SQLiteUsageMetricStore`, `UsageStoreHealth`, and `StoredUsageMetrics` are consistently named.
