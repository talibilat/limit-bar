# LimitBar Issue 10 Polish Documentation And QA Design

## Context

Issue #10 turns the assembled feature slices into an honest private daily-driver.
Runtime demo seeding and a static menu status are incompatible with that goal because they present fabricated or stale confidence.

## Approved Approach

Prioritize truthful behavior over a broad redesign.
Remove runtime demo seeding, derive menu status from stored confirmed metrics, refine the established popover/settings hierarchy, complete documentation, and record reproducible QA evidence.

## Runtime Truthfulness

A fresh store remains empty and marks itself initialized without inserting `DemoUsageData`.
Demo fixtures remain available to unit tests and previews only.
Provider cards always remain present in Anthropic, Azure OpenAI, OpenAI order and render honest empty/configuration states.

The menu bar label loads the same normalized snapshot as the popover.
It displays the existing compact icon/text rules and refreshes when provider settings or provider refreshes publish a change notification.
Store failure and unsupported-only data remain gray.

## Popover Polish

The header says Confirmed usage rather than demo usage.
Database and Azure import health move into compact secondary status copy rather than dominating the title.
Provider badges use structured settings state and usage freshness.
Unsupported, admin-required, expired, failed, and stale states remain visible when metrics exist or are empty.

Metric rows preserve organization/project/deployment metadata, token hierarchy, unsupported-limit copy, and cost source labels.
Cost-only rows omit meaningless zero-token pills.
Calculated estimates remain visually distinct from provider-reported cost.

## Settings Polish

The settings window grows to fit the assembled controls while remaining scrollable.
Authentication, Diagnostics, Azure Integration, and Pricing remain separate grouped sections.
The JSONL path stays selectable and revealable.
Secret fields continue to clear after operations and never display stored credentials.

## Documentation

README documents the exact Azure JSONL event fields and a valid example.
It documents Keychain-only secret storage, UserDefaults non-secret metadata, SQLite normalized metrics, 90-day retention, and prohibited stored/exported content.
It explains Provider reported and Calculated estimate cost labels.
It explains Unsupported by provider API and the absence of invented quotas or burn-rate estimates.

README also replaces obsolete bootstrap scope language with current project behavior and operational commands.

## QA Evidence

`docs/QA.md` records the date, macOS target, commands, and acceptance mapping.
Core tests provide deterministic evidence for time windows, Azure ingestion/malformed diagnostics, Anthropic/OpenAI fixtures and feasibility, stale refresh retention, cost labels, and privacy schemas.
Native build and launch smoke provide app-shell evidence.

The QA process must not write test credentials or usage events outside the repository.
Real Keychain prompts and production-account API calls remain explicitly unexecuted when they would violate the user's repository-only boundary; their fake-backed and fixture-backed equivalents are recorded.

## Testing

Update stored-metric tests to prove a fresh store remains empty and does not reseed after legitimate empty snapshots.
Add menu status label/model tests at the core status seam where possible.
Run the complete core suite, native build, executable launch smoke under repository-scoped constraints, privacy searches, and independent branch review.

## Out Of Scope

App Store distribution, onboarding redesign, notifications, sounds, cloud sync, hosted telemetry, Azure management APIs, proxies, arbitrary log scraping, automatic pricing updates, and burn-rate projections remain out of scope.

## Acceptance Mapping

Dynamic menu status, refined cards, and fixed-order empty states cover monitoring polish.
Larger grouped settings cover configuration ergonomics and integration visibility.
README covers integration and privacy contracts.
The QA report plus full verification covers launch, rendering, switching, ingestion, diagnostics, provider fixtures, staleness, costs, privacy, and macOS 14+ build health.
