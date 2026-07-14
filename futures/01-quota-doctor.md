# Quota Doctor

## Status

Planned as the single remaining future initiative.
This document owns the complete product plan until the work is deliberately split into implementation sub-tickets.

PR [#22](https://github.com/talibilat/limit-bar/pull/22) contains an unmerged Quota Insights foundation.
That foundation is useful prerequisite work, but it does not complete Quota Doctor.

## Product Decision

LimitBar will not compete as another menu-bar quota gauge.
Quota Doctor will be a provider-neutral forensic and forecasting capability that explains quota consumption, identifies meaningful changes, estimates exhaustion, and helps users decide whether planned work can finish within available quota.

The product must distinguish information that was measured, calculated, and inferred.
An inferred value must never be presented as a provider-reported quota.

## Problem

Provider quota displays answer how much quota remains but rarely explain why it changed.
Developers cannot reliably determine which project, session, model, agent, or operation consumed a quota window.
They also lack trustworthy answers to whether recent consumption is abnormal, when an active window is likely to exhaust, and whether a planned workload can finish before exhaustion or reset.

Provider weighting is often undisclosed.
Quota Doctor must therefore preserve evidence and communicate uncertainty rather than inventing capacity or presenting estimates as facts.

## User Outcome

Users can answer these questions from locally retained, privacy-safe evidence:

- What consumed the latest portion of this quota window?
- Which project, session, model, agent, or operation contributed to the change?
- Is recent consumption materially different from an appropriate historical baseline?
- When is the active quota window likely to exhaust, and how uncertain is that forecast?
- Will a selected workload likely finish before exhaustion or reset?
- Is an observed failure more consistent with quota exhaustion, provider capacity, provider authentication, or unavailable evidence?
- Can I export a reviewable evidence report without exposing prompts, code, credentials, or raw provider payloads?

## Existing Foundation

PR #22 currently provides the following bounded foundation:

- Measured percentage observations for supported Claude Code and Codex quota windows.
- Exact identities based on provider product, stable window identifier, and provider-reported reset boundary.
- A dedicated SQLite observation store with deduplication, 30-day retention, a 500-observation per-window cap, and explicit deletion.
- Burn-rate and exhaustion ranges calculated from sufficiently recent measured observations.
- Explicit unavailable states for insufficient, stale, decreasing, flat, reset, or expired evidence.
- Measured and calculated labels in the existing rate-limit rows.
- Coarse quota findings in the privacy-safe diagnostic export.
- Automated core, persistence, schema, analytics, and export tests.

The foundation does not yet provide attribution, token correlation, anomaly detection, explanations, workload planning, a forensic interface, or alert integration.
It also has not completed signed-app manual acceptance and is not present on `main` until PR #22 is merged.

## Required Capabilities

### 1. Attribution

Quota Doctor must correlate provider quota changes with trustworthy local usage evidence.
Attribution should support project, session, model, agent, operation, and tool type when those identifiers are explicitly available from a supported source.

Attribution must retain the distinction between an authoritative provider total and an Observed Local Breakdown.
Local attribution must never be added to an authoritative provider total as if it were additional usage.

When a provider reports only an account-wide percentage change, attribution may allocate the observed delta across concurrent local work only when an explicit, documented method is available.
Any such allocation must be labeled inferred and include its limitations.

The system must represent unattributed consumption instead of forcing every provider delta onto known local activity.

### 2. Forecasting

Quota Doctor must calculate a burn-rate range from observations within one exact provider quota window.
It must estimate an exhaustion range only when evidence is sufficiently recent, spans a meaningful interval, and produces a stable positive rate.

The forecast must never cross a provider-reported reset boundary.
If the quota is expected to reset first, the UI must say that exhaustion is not projected before reset.

Forecasts must expose observation count, observation span, method version, and confidence or qualification state.
The implementation should support conservative, balanced, and responsive profiles only if each profile has a documented and testable meaning.

Forecast quality must be evaluated against held-out observed windows before the product makes stronger predictive claims.

### 3. Anomaly Detection

Quota Doctor must compare current consumption with an appropriate trailing baseline.
Initial anomaly methods should be robust and explainable, such as a ratio to trailing median or a median-absolute-deviation score.

Comparisons may use quota change per input token, request, agent step, completed task, accepted code change, or active minute when the denominator is measured reliably.
No single denominator should be treated as universal because provider weighting may depend on model, caching, reasoning, service tier, or undisclosed factors.

Every anomaly must show the current comparison period, baseline period, measured inputs, method version, and known limitations.
An anomaly must not be emitted when missing or incompatible evidence makes the comparison unsafe.

### 4. Evidence And Explanation

Users need a forensic view that explains a selected provider and time range.
The view must summarize quota movement, supporting local usage, attribution, anomalies, resets, relevant client-version changes, and evidence gaps.

The first product surface should integrate with LimitBar rather than create a separate menu-bar gauge.
A CLI may be added when it provides a better automation boundary, but the core analysis must remain independent of presentation.

Quota Doctor must extend the existing privacy-safe diagnostic export through its positive allow-list.
The export must contain bounded findings and method metadata, not raw prompts, code, responses, terminal output, credentials, private paths, account labels, or raw provider payloads.

The user must preview the exact export before choosing a destination.
LimitBar must never upload an evidence report automatically.

### 5. Workload Planning

Users must be able to describe or select a planned workload and receive an explainable completion assessment.
The estimate should use comparable historical runs and current qualified quota evidence.

The result must include an estimated requirement range, available quota, expected reset interaction, confidence, comparison sample, and explicit reasons for the conclusion.
If comparable history is insufficient, the product must report that planning is unavailable rather than fabricate an estimate.

Recommendations must be rules-based and traceable to measured constraints.
Examples include reducing parallel agents, deferring optional work, or choosing a lower-weight model when supported evidence demonstrates the tradeoff.

Quota Doctor must not rotate accounts, evade provider controls, automatically purchase credits, or make provider changes without explicit user action.

## Source Requirements

Source adapters must be isolated from normalization and analytics.
Each adapter must declare supported client or API versions, captured fields, omitted fields, authentication access, confidence classification, and last verified date.

Source priority is:

1. Documented provider APIs, response headers, and usage endpoints.
2. Structured local client events owned by the user.
3. Normalized LimitBar Usage Events and explicitly integrated agent-runtime events.
4. OpenTelemetry spans emitted by the user's runtime.
5. Explicitly imported structured files.

Browser automation and scraping of private provider pages are outside the core product.
They may be considered only as separately maintained optional adapters with clear breakage, privacy, and terms warnings.

The completed product must support at least two subscription clients and one API provider with stable, tested adapters.

## Canonical Model

The model must keep source observations immutable.
A correction must add a superseding record rather than silently rewriting history.

A quota observation must be able to represent:

- Stable observation identity.
- Provider product and privacy-safe account alias when explicitly configured.
- Exact observation timestamp.
- Exact quota-window identity and provider-reported reset boundary.
- Reported percentage, count, or monetary unit.
- Source provenance and measured, calculated, or inferred classification.
- Optional trace, project, session, agent, model, operation, and tool identifiers from allow-listed sources.
- Optional normalized token and request measurements.
- Adapter and client versions needed to interpret the observation.

A derived finding must record:

- Finding type and method version.
- Exact input observation identities or a stable bounded input-range identity.
- Comparison and baseline windows.
- Value or range.
- Confidence or qualification state.
- Limitations and missing evidence.
- Creation time without pretending it is a provider event.

Quota windows must use provider-reported reset boundaries.
LimitBar must not infer an exact reset when the provider did not report one.

## Privacy And Security

All processing and storage remain local by default.
Raw prompts, code, model responses, terminal output, request bodies, credentials, browser cookies, and raw provider payloads are prohibited from Quota Doctor storage and exports.

Adapters must use positive field allow-lists.
Project paths must be replaced with configured names or privacy-safe stable identifiers before persistence.
Account aliases must be user-defined and must never contain credentials.

Retention must be bounded by age and count.
Users must be able to delete quota observations and derived findings independently from current usage, alert rules, delivery state, provider settings, and credentials.

One adapter must not read outside its configured file boundary.
No report may be sent without an explicit user action.

## Product Experience

The existing rate-limit rows may continue to show concise measured usage and qualified forecast summaries.
Quota Doctor must add a deeper forensic surface for explanations, attribution, anomalies, and evidence gaps.

Every value must carry visible provenance language:

- Reported for a value supplied directly by a provider.
- Measured for a value directly observed from a supported source.
- Calculated for a deterministic result from measured data and a versioned method.
- Inferred for an estimate from incomplete evidence.

The interface must avoid false precision.
Ranges, observation counts, evidence age, reset boundaries, and limitations should be visible where they affect interpretation.

Unavailable evidence, an Observed Zero, and a Gap must remain distinct states.

## Alert Integration

Quota Doctor must consume the existing alert-rule and delivery-ledger architecture rather than create a second notification system.
Only fresh, qualified findings with exact active boundaries may become alert candidates.

Forecast and anomaly alerts must use coarse lock-screen-safe copy.
Notifications must not include account, project, session, agent, model, token, percentage, exact spend, or private source values.

Alert deduplication must use the exact subject window and rule threshold.
Deleting quota history must not silently consume or recreate delivery-ledger state.

## Delivery Plan

### Phase 1: Land And Validate The Foundation

Review PR #22 against this ticket and retain only work that supports the canonical direction.
Resolve the local Xcode launcher problem or run native tests in a working environment.
Complete signed-app manual acceptance for observation deduplication, forecast qualification, reset behavior, deletion, and diagnostic export.
Merge the foundation without declaring the full ticket complete.

### Phase 2: Establish Provenance And Correlation

Deepen the observation interface so adapters provide normalized evidence without exposing provider-specific internals to analytics.
Add versioned provenance and traceable derived inputs.
Connect normalized usage and supported agent-runtime identifiers to quota observations.
Represent authoritative totals, Observed Local Breakdowns, inferred allocation, and unattributed usage explicitly.

### Phase 3: Build Explainable Analytics

Validate and version the burn forecast method.
Add baseline construction and robust anomaly detection.
Test missing data, resets, counter decreases, out-of-order observations, client-version changes, concurrency, and provider-format changes.
Measure forecast and anomaly quality before enabling stronger product claims.

### Phase 4: Deliver The Forensic Experience

Add provider and time-range explanation workflows.
Present attribution, quota movement, anomalies, evidence gaps, and method limitations without adding another redundant gauge.
Extend the diagnostic export with the minimum allow-listed evidence needed for a useful incident report.

### Phase 5: Add Alerts And Planning

Route qualified forecast and anomaly candidates through the existing alert engine and delivery ledger.
Add workload descriptions and historical-run comparison.
Produce explainable completion assessments and rules-based options only when evidence is sufficient.

### Phase 6: Harden And Validate

Add synthetic and anonymized fixtures for every supported adapter and failure mode.
Document provider-specific limitations and supported versions.
Run a pilot with heavy coding-agent users and evaluate usefulness, forecast error, attribution coverage, false-positive rate, and report quality.
Package the completed capability through the existing signed LimitBar distribution.

## Required Test Coverage

Tests must cover:

- Stable, flat, and bursty consumption.
- Reset events and percentage counters moving backwards.
- Missing token, request, reset, attribution, and version data.
- Duplicate and out-of-order observations.
- Concurrent agents under one account-level quota.
- Provider-format and client-version changes.
- Corrupted and partially written structured files.
- Immutable observations and explicit supersession.
- Traceability from every finding to its method and inputs.
- Distinct measured, calculated, inferred, unavailable, Observed Zero, and Gap states.
- Retention, deletion, schema migration, and unknown-schema failure.
- Adapter file-boundary enforcement.
- Export allow-list and prohibited-content sentinels.
- Alert freshness, exact-boundary deduplication, and privacy-safe notification copy.
- Workload planning with comparable, incompatible, and insufficient historical samples.

Native acceptance must verify the signed application with real supported local sources.
Fixture tests must not be presented as proof of real-account behavior or macOS authorization policy.

## Explicit Non-Goals

- Circumventing provider quotas or rotating accounts to evade limits.
- Claiming to know undisclosed provider capacity or weighting.
- Replacing official billing records.
- Forecasting monetary cost without an explicit versioned price source.
- Scraping private provider pages as a default capability.
- Persisting or exporting raw prompts, code, responses, terminal output, credentials, or raw provider payloads.
- Automatically purchasing credits, changing plans, switching accounts, or changing provider configuration.
- Treating local attribution as an authoritative provider total.
- Releasing another menu-bar-first quota display without the forensic capabilities in this ticket.

## Definition Of Done

Quota Doctor is complete only when all of the following are true:

- At least two subscription clients and one API provider have stable, version-tested adapters.
- Users can explain quota movement over a selected interval using measured evidence and clearly labeled attribution.
- Authoritative provider totals, Observed Local Breakdowns, inferred allocations, unattributed usage, Observed Zero, and Gaps remain distinct.
- Qualified forecasts provide bounded exhaustion estimates with evidence age, sample size, reset interaction, and method version.
- Explainable anomaly detection identifies meaningful changes against explicit baselines without producing findings from unsafe comparisons.
- A forensic product surface presents attribution, forecasts, anomalies, evidence gaps, and limitations.
- The privacy-safe export produces a useful, previewable incident report through a complete positive allow-list.
- Qualified alerts use the existing alert engine and delivery ledger without exposing private values.
- Workload planning produces evidence-based ranges and reports unavailable when comparable history is insufficient.
- Retention, independent deletion, migration, adapter isolation, and prohibited-data boundaries are verified by automated tests.
- Native and signed-app acceptance passes for supported sources.
- Pilot evidence shows the product helps users explain consumption or change scheduling decisions, rather than merely displaying another percentage.

## Future Decomposition

This plan intentionally remains one ticket for now.
When implementation sequencing is approved, it can be divided along the delivery phases without changing the product outcome, privacy boundary, canonical model, or definition of done.
