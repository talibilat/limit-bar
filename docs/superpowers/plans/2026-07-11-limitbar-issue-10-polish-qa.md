# LimitBar Issue 10 Polish Documentation And QA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an honest, polished private daily-driver with complete integration/privacy documentation and QA evidence.

**Architecture:** Remove runtime fixture seeding, add a dynamic menu label sourced from normalized metrics, refine the existing SwiftUI hierarchy, and document/verify every acceptance path without adding new product scope.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, SQLite3, Markdown, macOS 14+.

## Global Constraints

- Runtime surfaces show confirmed/local-integration data only, never demo fixtures.
- Provider order and Today/Current Week behavior remain unchanged.
- No new notifications, sounds, telemetry, management APIs, scraping, proxying, or estimates.
- QA must not write credentials or usage files outside the repository.

---

### Task 1: Remove Runtime Demo Data

**Files:** Modify `StoredUsageMetrics.swift` and `StoredUsageMetricsTests.swift`.

- [ ] Replace the existing seeded-demo test with a failing test that a fresh initialized store returns no metrics and remains empty on repeated loads.
- [ ] Run the focused test and verify it fails on current seeding.
- [ ] Remove `DemoUsageData` writes from both load paths while preserving initialization and retention.
- [ ] Run full tests and commit `Remove runtime demo seeding`.

### Task 2: Dynamic Menu Status And Popover Polish

**Files:** Modify `LimitBarApp.swift`, `MonitoringPopoverView.swift`, and relevant core/status tests.

- [ ] Add a `MenuBarStatusLabel` SwiftUI view that asynchronously loads `StoredUsageMetrics`, derives `AppStatus.from(menuBarStatus:)`, and reloads on provider notifications.
- [ ] Replace static app status with the dynamic label.
- [ ] Update popover copy, provider badges, status banners, diagnostics placement, cost-only rows, spacing, and frame while preserving fixed order and time picker behavior.
- [ ] Run tests/build and commit `Polish monitoring surfaces`.

### Task 3: Settings Ergonomics

**Files:** Modify `LimitBarSettingsView.swift` and `ProviderSettingsView.swift` only where necessary.

- [ ] Increase settings dimensions and refine section/help copy so Authentication, Diagnostics, Azure Integration, and Pricing remain clearly separated and scrollable.
- [ ] Keep JSONL path selectable/revealable and secret behavior unchanged.
- [ ] Build the app and commit `Polish settings ergonomics`.

### Task 4: README And QA Documentation

**Files:** Rewrite `README.md`; create `docs/QA.md`.

- [ ] Document project behavior, JSONL path/schema/example, Keychain and local persistence, privacy exclusions, cost labels, unsupported limits, provider feasibility, and operational commands.
- [ ] Record QA matrix with automated commands and manual/native smoke evidence for every issue criterion, noting repository-only constraints for real credentials.
- [ ] Keep each Markdown sentence on its own line.
- [ ] Commit `Document integrations privacy and QA`.

### Task 5: Final Verification And Delivery

- [ ] Run full core tests, native build, diff check, privacy searches, and repository-scoped executable launch smoke.
- [ ] Request independent code/spec review and fix Critical/Important findings.
- [ ] Push, create PR with `Closes #10`, merge, verify closure, and confirm no open GitHub issues remain.

## Self-Review

- Every issue #10 acceptance criterion maps to runtime, UI, settings, documentation, or QA tasks.
- No placeholders or new scope remain.
- The plan preserves existing provider and privacy architecture.
