# Quota Forecast Method V2

## Identity

The current analytical method identity is `pairwise_positive_slope_interquartile_v2`.
V2 adds canonical stable-identity deduplication, deterministic exact-window incompatibility, invalid-evaluation qualification, ordered implicated-window traceability, and typed source interpretation versions around the existing pairwise-IQR numerical calculation.
V1 remains recognized only when decoding diagnostic artifacts produced by the earlier method contract; current analytics, replay, export, and UI use V2.
Any future change that can alter input qualification, deduplication, numerical burn output, exhaustion output, trace semantics, or reset interaction requires V3.
Display-only wording and layout changes do not create a new method identity.

Normalized measured observations use normalization version `quota_observation_normalization_v1` and identity version `normalized_quota_observation_v1`.
The stable identity is a SHA-256 digest over a length-prefixed or fixed-width binary encoding of normalization version, source interpretation version, provider product, exact quota-window identifier, provider-reported reset boundary, observation time, measured percentage, and observation source.
Identifiers use Unicode canonical composition before hashing, and every date or percentage `Double` canonicalizes signed zero to positive zero.
The digest contains no account, project, model, session, filesystem, or other user-provided label.
Identical normalized content has the same identity, while any materially different allow-listed field has a different identity.

## Required Inputs

Each observation must contain one supported provider product, one exact quota-window identity, one provider-reported reset boundary, one finite observation time no later than that boundary, one measured percentage from 0 through 100, one allow-listed observation source, and the fixed normalization version.
Claude provider reports use interpretation version `claude_provider_report_v1`, and Codex local reports use `codex_local_report_v1`.
The interpretation version is derived losslessly from the persisted source, so no persistence migration is required.
Any future change in how a source is interpreted requires a new typed interpretation-version case and changes the stable observation identity.
Claude Code accepts only account-wide provider reports.
Codex accepts only supported individual-plan local reports.
The calculation also requires an explicit creation time and a finite nonnegative maximum evidence age.

Private labels, raw provider payloads, prompts, model responses, request data, terminal output, credentials, and filesystem paths are excluded before normalization and cannot contribute to identity or calculation.
Observations from different exact quota windows are never combined.

## Qualification Order

The method applies these rules in order.

1. Return `invalid_evaluation` without a creation time when analytical evaluation time is non-finite.
2. Sort observations by observation time and stable observation identity, then remove exact duplicates by stable identity.
3. Return `incompatible_evidence` when observations or expected context identify more than one exact quota window.
4. Return `conflicting_observations` when one observation time has different measured percentages.
5. Return `insufficient_observations` when no normalized observation is present, retaining expected exact-window context when supplied.
6. Return `reset_or_expired` when the provider-reported reset boundary is not later than creation time.
7. Return `stale_evidence` when maximum age is invalid, the latest observation is in the future, or its age exceeds maximum age.
8. Require at least four distinct observation times, otherwise return `insufficient_observations`.
9. Require at least 15 minutes from first through latest observation, otherwise return `insufficient_span`.
10. Return `counter_decreased` when any adjacent measured percentage decreases.
11. Calculate every positive pairwise percentage slope in percent per hour and return `no_positive_burn` when none exists.
12. Qualify the finding when all preceding rules pass.

Out-of-order delivery is deterministic because sorting precedes qualification.
Exact duplicate delivery does not change the effective sample or output.
A counter decrease or transition to another reset boundary is never interpreted as positive burn.

## Calculation

The calculated burn range is the linearly interpolated 25th through 75th percentile of all positive pairwise slopes.
The latest measured percentage supplies remaining percentage to 100.
The upper burn bound gives the earlier calculated exhaustion time and the lower burn bound gives the later calculated exhaustion time.
An exhaustion range is published only when its later endpoint is strictly before the provider-reported reset boundary.
Otherwise burn remains qualified and exhaustion is explicitly not projected before reset.
No exhaustion range can cross the reset boundary.

Every qualified finding records its exact quota-window identity, ordered distinct input observation identities, explicit latest observation identity and timestamp, interpretation versions, method identity, creation time, observation count, observation span, evidence age, calculated burn range, and optional reset-bounded exhaustion range.
Every unavailable finding records the same versioned method and creation metadata, interpretation versions, the ordered distinct inputs considered, count, span, evidence age when present, and reason.
Qualification is derived from the enclosing finding state rather than stored redundantly.
Creation time is analytical metadata and is not a provider event.
Valid qualified findings always have an exact finite creation time.
An invalid evaluation has no creation time or evidence age rather than retaining non-finite metadata.

## Evaluation Metrics

The deterministic synthetic baseline uses the following fixed aggregate and segment formulas.
Qualification coverage is qualified valid fixtures divided by all valid held-out fixtures in the same report scope.
Unavailable frequency is unavailable valid fixtures divided by that same denominator, so the two rates sum to one when the scope is nonempty.
Both rates are not applicable for an empty scope rather than reported as zero.
Exhaustion interval coverage is observable exhausted outcomes whose calculated interval contains the exact observed exhaustion time divided by all observable exhausted outcomes.
Each observable exhausted outcome contributes one interval-error entry: zero when covered, distance in minutes to the nearest interval endpoint when missed, and not available when no interval was produced.
A false exhaustion-before-reset projection is a calculated exhaustion interval beginning before the exact reset for a fixture declared not to exhaust before reset.
A reset-boundary violation is any calculated exhaustion interval whose upper endpoint exceeds the exact reported reset.
Non-exhausting and censored fixtures remain in qualification and unavailable denominators; non-exhausting fixtures contribute to false-projection checks, while censored fixtures do not contribute to exhaustion coverage or error.
Every provider-product and evidence-condition segment reports these same metrics without provider weighting or cross-condition averaging.
Invalid fixture construction, duplicate fixture identity, corpus construction failure, or freeze-digest mismatch aborts evaluation and is reported as evaluator failure.
An invalid fixture is not a scored unavailable sample because no valid evaluation exists; it is never silently omitted or imputed.

## Reset Behavior

The reset boundary must be reported by the provider adapter rather than inferred.
Missing boundaries cannot create normalized observations or exhaustion forecasts.
An expired boundary is unavailable.
A different exact boundary creates a different quota-window identity and cannot be combined with the prior window.

## Limitations

The method uses measured percentage trajectories and does not know provider capacity, token weighting, future workload, provider-side changes, or unobserved activity.
The interquartile range is a deterministic robust summary, not a probability interval or confidence claim.
Sparse cadence, bursts between observations, censored outcomes, and source-version changes can limit interpretation.
Findings remain calculated and do not replace official provider quota information.
The frozen synthetic replay does not establish real-user representativeness or empirical forecast quality.
Synthetic held-out membership is versioned and frozen as a deterministic baseline.
The corpus version and digest are only a drift and review boundary and do not establish statistical independence.
Because the corpus contains zero observed held-out completed windows, empirical forecast quality assessment and any forecast quality threshold are unavailable, and no stronger product claim is enabled.
Changing membership, normalized content, partitions, evaluation parameters, or outcomes requires a new corpus version or an explicit digest review before scoring.
No conservative, balanced, or responsive profiles are defined.
