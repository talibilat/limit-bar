# Planned Workload Method V2

## Release State

The analytical boundary is implemented, but no merged adapter currently establishes measured completed workload runs.
The Rate Limit surface therefore reports an explicitly unsupported historical-run adapter and does not show no-op planning controls.
LimitBar does not fabricate historical runs from attribution aggregates, prompts, code, responses, terminal output, paths, labels, or token counts.

Planning input, completed-run values supplied by an adapter, and derived assessments remain ephemeral.
This feature adds no database, retention schedule, or deletion state.
Any future adapter remains responsible for bounded retention and deletion independent from current usage, quota observations, settings, credentials, and alert delivery state.

## Method Identities

Comparability uses `strict_measured_operations_v2`.
Requirement and duration ranges use `interquartile_per_unit_v1`.
V2 replaces arbitrary run, evidence, and version strings with typed UUID-backed opaque identities, adds exact historical quota windows, and canonicalizes immutable correction chains before comparison or option generation.

Any change to accepted fields, correction qualification, comparison dimensions, minimum sample size, scaling, percentile calculation, latest-observation qualification, boundary ordering, or option rules requires a new method identity.
Display-only wording does not require a new analytical identity.

## Bounded Vocabulary

The only initial workload kind is `coding_agent_operations`.
One work unit is one explicitly completed logical coding-agent operation supplied by a normalized completed-run adapter.
No merged adapter supplies that unit yet, so neither Claude Code nor Codex currently enables planning controls.

The positive allow-list contains provider product, session or weekly quota-window semantics, interactive execution mode, concurrency, operation count, source provenance, and typed adapter, client, and provider-format versions.
Concurrency is explicit and is never inferred.
There is no free-form workload description.

## Historical Runs

Every immutable run revision contains:

- An opaque run identity and revision identity.
- An optional typed superseded revision identity.
- One exact `QuotaWindowIdentity`, including the provider-reported reset boundary.
- An exact quota-window start and an exact run interval wholly contained in that window.
- Workload kind, execution mode, concurrency, and completed operation count.
- Measured provider-reported percentage movement and an explicit outcome.
- Typed source provenance and adapter, client, and provider-format versions.
- Typed immutable quota-observation identities and opaque supporting-evidence identities.

Construction rejects a run before its exact window, after its reported reset, or spanning outside one window.
It also rejects duplicate observation or evidence identities and invalid Observed Zero or completed values.

`completed`, `observed_zero`, `incomplete`, `failed`, `gap`, and `unavailable` remain distinct.
V2 includes only completed runs with positive measured movement.
Observed Zero remains explicit but excluded because fixture evidence does not establish zero movement as a safe future requirement estimate.

## Corrections And Retries

Analysis groups revisions by opaque run identity before applying comparison rules.
An identical revision retry is counted once.
Reuse of one revision identity for different content disqualifies the affected run.

A valid correction history has exactly one root, internal predecessor references, no branch, no cycle, and one terminal revision.
Only the terminal revision can enter a sample.
Superseded revision identities and exclusion counts remain in result metadata so the selected evidence is reproducible.
Malformed, branching, cyclic, or conflicting histories fail closed.

The same canonicalized terminal-revision set feeds both the primary comparison and lower-concurrency option analysis.
Retries, conflicts, and superseded revisions can never satisfy either minimum sample.

## Strict Comparability

An included run must exactly match provider product, workload kind, quota-window kind, execution mode, concurrency, quota unit, source provenance, adapter version, client version, and provider-format version.
Only provider-reported percentage movement is accepted.
Different exact historical reset boundaries are expected, but every run must retain its own exact identity and remain within its own window.

Provider products, session and weekly semantics, source boundaries, versions, and quota units are never silently pooled.
Version divergence fails closed because no evidence establishes compatibility across those changes.

Every assessment reports included run and revision identities, superseded revisions, observation and evidence identities, sample span, exclusions, method versions, reasons, and limitations.

## Qualification And Range

V2 requires four canonical compatible completed runs.
Four is the smallest sample on which the linearly interpolated 25th and 75th percentiles occupy distinct interior positions in the synthetic fixtures.
This is an operational qualification boundary, not an empirical confidence threshold or success claim.

For each run, V2 divides measured percentage movement and elapsed duration by completed operations.
It takes the linearly interpolated 25th and 75th percentiles of each sorted per-operation sample and multiplies both bounds by the planned operation count.
The resulting requirement and duration ranges are calculated.
Linear scaling remains a disclosed limitation rather than a provider capacity model.

## Current Evidence

An available or indeterminate assessment requires a qualified `pairwise_positive_slope_interquartile_v2` finding and the exact latest measured observation represented by that finding.
The forecast now records its latest observation identity and timestamp explicitly.
Planning requires both fields to equal the supplied latest observation and requires that identity to be the final ordered forecast input.
Passing an older observation that merely appears in the forecast inputs is incompatible.

The observation and forecast must identify the same exact active quota window and match the planned provider product and window semantics.
Freshness uses the existing source-specific limits: 15 minutes for Claude Code and 6 hours for Codex.
Available percentage is `100 - measured percentage used`.

Unavailable stale, expired, unqualified, or incompatible results retain safely known current metadata: exact identity and reset boundary, latest observation identity and timestamp, evidence age when finite, forecast qualification, method, input identities, and unavailable reason.
Missing evidence remains absent rather than invented.

## Exhaustion And Reset

Planning does not interpret a nil bounded forecast exhaustion range as no exhaustion.
It combines the qualified burn range with the exact latest observation and measured remaining percentage to calculate an unbounded earliest-through-latest exhaustion range.
This uses the same percentage unit and burn method as the qualified forecast and does not infer provider capacity.

The complete calculated exhaustion range is compared with the provider-reported reset:

- Exhaustion is expected first only when its latest bound is strictly before reset.
- Reset is expected first only when reset is strictly before its earliest bound.
- Straddling or equality is indeterminate overlap.

The workload completion range is then compared with the boundary expected first.
Completion is before a boundary only when its latest bound is strictly earlier.
A boundary is before completion only when its latest possible point is strictly earlier than completion's earliest bound.
Touching closed-range bounds and all overlaps are indeterminate.

Results expose `exhaustion_expected_first`, `reset_expected_first`, or `indeterminate_overlap` and never project an unreported reset.

## User-Controlled Options

Options never modify configuration or start work.
A lower-concurrency option requires four canonical otherwise-compatible terminal revisions and a demonstrated lower requirement range.
A reduced-operation option uses only the included canonical sample and cites its typed revision, observation, and evidence identities.

Deferral is not unconditional.
It appears only when current quota is insufficient and qualified evidence shows the exact reported reset strictly before the calculated exhaustion range.
It cites the latest measured quota observation and comparison evidence and states `post_reset_capacity_unknown`.
No model, provider, account, or plan switch is suggested because merged evidence does not demonstrate those tradeoffs.

## Application Boundary

`CompletedWorkloadRunProviding` is the future adapter seam.
It supplies one typed support declaration and ephemeral immutable run revisions.
The default production implementation supplies no support and no runs.

`LiveWorkloadPlanningData` combines that seam with actual current Codex or Claude observations and the application's qualified forecast map.
The SwiftUI surface receives an injected data provider and renders available, indeterminate, and unavailable states generically.
Controls appear only when the provider declares real support.

## Limitations

Provider weighting and future behavior remain unknown.
The method cannot separate unrelated account-level consumption unless a future adapter measures the run boundary safely.
It does not establish causal attribution from local tokens to provider percentage.
Synthetic fixtures establish deterministic behavior only, not real-account representativeness, forecast quality, or completion success.
Signed-app acceptance with real completed-run evidence remains blocked until a supported adapter exists.
