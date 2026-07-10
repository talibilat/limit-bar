# LimitBar Issue 5 Cost Pricing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add provider-reported and calculated cost display with editable model pricing.

**Architecture:** Put pricing and cost selection in `LimitBarCore`; keep app persistence of editable pricing as a small `UserDefaults` JSON adapter. The popover asks the core calculator for displayable row costs.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, UserDefaults JSON, Foundation `Date` and `Decimal`.

## Global Constraints

- Prefer provider-reported cost over calculated estimates.
- Only calculate costs from confirmed input/output token counts and configured pricing.
- Missing pricing must not produce fake non-zero cost.
- Pricing entries are effective-date aware.
- Do not add automatic pricing updates or live provider integrations.

---

## Tasks

### Task 1: Core Pricing And Cost Calculator

- Write failing `PricingTests` for input/output calculation, provider-reported preference, effective-date selection, missing pricing, and source labels.
- Add `LimitBarCore/Sources/LimitBarCore/Pricing.swift` with `PricingEntry`, `PricingTable`, and `CostCalculator`.
- Run core tests and commit `Add pricing cost calculator`.

### Task 2: Settings Adapter And Popover Cost Rendering

- Add `LimitBar/PricingSettingsStore.swift` for JSON-backed `UserDefaults` pricing entries.
- Update `LimitBarSettingsView` with manual pricing fields and a save action.
- Update `MonitoringPopoverView` to read pricing entries and display `Cost` amount plus `CostSource.displayLabel` per metric.
- Add provider-reported cost to at least one demo metric while leaving calculated rows dependent on configured pricing.
- Run core tests and native build, then commit `Render pricing and cost labels`.

### Task 3: Final Verification

- Run core tests.
- Run native build.
- Run launch smoke check.
- Run formal code review against `main`.
- Attempt `no-mistakes`; record the repo gate limitation if it still cannot start first branch runs.

## Self-Review

- Spec coverage: core cost calculation, preference, effective dates, missing price behavior, labels, editable settings, and popover display are covered.
- Completion-marker scan: no unfinished markers remain.
- Type consistency: `PricingEntry`, `PricingTable`, `CostCalculator`, and `PricingSettingsStore` are consistently named.
