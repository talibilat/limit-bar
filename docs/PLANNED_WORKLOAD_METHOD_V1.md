# Planned Workload Method V1

## Release State

The analytical interfaces are implemented, but no merged source adapter currently establishes measured completed workload runs.
The integrated Rate Limit surface therefore accepts bounded planning input and reports the assessment as unavailable.
LimitBar does not derive runs from prompts, code, terminal output, model responses, paths, or labels.

## Method Identities

Comparability uses `strict_measured_operations_v1`.
Requirement and duration ranges use `interquartile_per_unit_v1`.
Any change to included dimensions, exclusion order, minimum sample size, scaling, percentile calculation, current-evidence qualification, conclusion ordering, or option rules requires a new method identity.
Display-only changes do not require a new analytical identity.

## Bounded Vocabulary

The only V1 workload kind is `coding_agent_operations`.
One work unit is one explicitly completed logical coding-agent operation supplied by a future normalized adapter.
This kind was selected because merged attribution evidence already identifies immutable logical Usage Events, while no trustworthy merged evidence defines tasks, accepted code changes, prompt complexity, or provider work weights.

The positive allow-list contains provider product, session or weekly quota-window kind, interactive execution mode, concurrency, operation count, adapter version, and client version.
It contains no free-form description, prompt, code, response, terminal output, request body, credential, account label, project path, or raw provider payload.
Concurrency is explicit user or adapter input and is never inferred.

V1 supports Claude Code and Codex model types analytically because both expose provider-reported percentage windows with exact reset boundaries.
Neither product has a live completed-run adapter in this release, so live planning remains unavailable for both.

## Measured Historical Run

A run records one privacy-safe ID, the same comparison dimensions as the plan, completed operation count, exact start and end, measured provider-reported percentage movement, outcome, adapter and client versions, and bounded evidence IDs.
The percentage movement must be measured for that run in one exact quota window rather than allocated from token counts or inferred from provider weighting.

`completed`, `observed_zero`, `incomplete`, `failed`, `gap`, and `unavailable` are distinct outcomes.
V1 includes only completed runs with positive measured movement.
Observed Zero remains explicit but is excluded because the synthetic corpus does not establish that zero movement can safely estimate future requirements.
Incomplete, failed, Gap, and unavailable runs are reported under separate exclusion categories.

Planning input and derived assessment are ephemeral.
No new persistence is needed, so planning creates no additional retention or deletion surface.
Historical evidence remains owned by its bounded source store and independent deletion policy.

## Strict Comparability

An included run must exactly match provider product, workload kind, quota-window semantics, execution mode, concurrency, quota unit, client version, and adapter version.
Only the provider-reported percentage unit is accepted.
Version divergence fails closed because no fixture evidence establishes compatibility across client or adapter behavior changes.
Runs from different products, percentage semantics, or execution dimensions are never pooled.

Every result lists included run IDs, supporting evidence IDs, sample span, exclusions by stable category, comparison method, range method, and limitations.
Identical repeated run IDs are excluded as duplicates, while reuse of one run ID for different content is excluded as an identity conflict.

## Qualification And Range

V1 requires four compatible completed runs.
Four is the smallest sample on which the linearly interpolated 25th and 75th percentiles exercise distinct interior positions in the frozen synthetic examples.
This is an operational qualification boundary, not an empirical confidence threshold or success claim.

For every run, V1 divides measured percentage movement and elapsed duration by completed operations.
It takes the linearly interpolated 25th and 75th percentiles of each sorted per-operation sample, then multiplies both bounds by the planned operation count.
The resulting requirement and duration ranges are calculated.
Linear scaling is a disclosed limitation and not a provider capacity model.

The checked tests use synthetic stable, variable, insufficient, incompatible, version-divergent, reset-affected, stale, and overlapping examples.
These fixtures establish deterministic behavior only.
They contain no observed held-out completed runs and establish no probability, forecast quality, provider representativeness, or completion success rate.

## Current Evidence

An assessment requires a qualified `pairwise_positive_slope_interquartile_v2` finding and its latest measured observation.
Both must identify the same exact active quota window, and the observation identity must appear in the forecast inputs.
The provider product and session or weekly semantics must match the planned workload.
Freshness uses the existing source-specific limits: 15 minutes for Claude Code and 6 hours for Codex.

Available percentage is `100 - measured percentage used`.
This arithmetic does not infer hidden provider capacity because historical requirements use the same provider-reported percentage unit under strict product and version compatibility.
Any other unit or unsafe conversion is unavailable.

Missing, unqualified, stale, expired, boundary-less, identity-mismatched, or product-mismatched current evidence is unavailable.
LimitBar never projects an unreported reset boundary.

## Outcomes

Available conclusions are limited to evidence indicating completion before exhaustion, insufficient current-window percentage, reset before completion, or calculated exhaustion before completion.
If requirement overlaps available percentage, duration overlaps reset, or duration overlaps calculated exhaustion, the result is indeterminate rather than yes or no.
All wording remains qualified and never promises completion, provider capacity, a fresh post-reset allowance, or future provider behavior.

## User-Controlled Options

Options never change configuration or start work automatically.
A lower-concurrency option appears only when at least four otherwise compatible completed runs at a lower explicit concurrency have an upper requirement bound below the current sample's lower bound.
A reduced-operation option appears only when the same qualified per-operation range yields a positive lower count whose upper requirement fits current measured available percentage.
A defer-until-reset option can identify the exact reported current reset as a user choice, but states that next-window availability is unknown.
No model, provider, account, or plan switch is suggested because merged evidence does not demonstrate those tradeoffs.

## Limitations

Provider weighting and future behavior are unknown.
The method cannot separate unrelated account-level consumption unless a future adapter measures the run boundary safely.
The method does not establish causal attribution from local tokens to provider percentage.
Synthetic fixtures are not real-account validation.
Signed-app acceptance with real supported run evidence remains blocked until such an adapter exists.
