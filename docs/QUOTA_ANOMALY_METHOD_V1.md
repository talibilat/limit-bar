# Quota Anomaly Method V1

## Identity

The production method identity is `trailing_median_ratio_v1`.
Any change to baseline construction, cadence, sample count, qualification order, threshold meaning, normalization, Observed Zero behavior, or output meaning requires a new method version.
Display-only wording does not require a new method version.

## Supported Comparison

V1 compares direct quota movement, or quota movement divided by an explicitly selected Measured denominator, within one active Quota window.
It does not compare across completed Quota windows.
Cross-window evidence is unavailable rather than joined across a provider-reported reset.

The current comparison period is the latest exact ten-minute interval.
The trailing baseline contains the five immediately preceding contiguous ten-minute intervals.
The baseline therefore spans exactly fifty minutes and excludes the current comparison period.
Each movement interval uses the half-open inclusion rule `(start, end]`, represented as `start_exclusive_end_inclusive`, because movement is Calculated from cumulative observations at its two boundaries.

Seven boundary observations are required to form five baseline movements and one current movement.
Observations are sorted by time and stable identity before exact duplicates are removed.
The selected observations must use one provider product, one Quota window identity, one provider-reported reset boundary, one interpretation version, one adapter version, one client version, and one provider-format version.
Every adjacent observation must be exactly ten minutes apart.
Partial intervals and unresolved Gaps are unavailable.

## Calculation

The baseline summary is the Calculated median of the five baseline movement values.
The current movement is Calculated from its two boundary observations.
The ratio is the current movement divided by the baseline median.
A higher-consumption finding is emitted when the ratio is at least `3.0`.
V1 does not emit lower-consumption findings because the frozen fixture evidence selected and validated only the higher-consumption meaning.

Production and replay call the same deterministic scoring function for trailing-median ratio and zero-median handling.
Replay also calls that function with the median-absolute-deviation candidate after production analytics has qualified the observations and produced the exact baseline values.
This prevents replay and production ratio semantics from drifting independently.

## Observed Zero

Observed Zero is emitted only when all seven selected cumulative percentage observations are zero.
Unchanged nonzero cumulative usage is an ordinary qualified no-finding outcome with zero current movement, a zero baseline median, and no ratio.
A positive current movement against a zero median is unavailable because division would be unstable.
A Gap is never substituted with zero.

## Qualification

V1 returns unavailable without a finding for invalid evaluation metadata, insufficient observations, insufficient span, stale evidence, an expired boundary, incompatible Quota windows or versions, conflicting same-time observations, a counter decrease, a Gap, or an unstable zero baseline.
Exact duplicates do not alter output.
Out-of-order delivery does not alter output because sorting precedes qualification.
Explicitly superseded observations are excluded, and the limitation is retained only when a supplied superseded identity actually matches and removes an input observation.
A correction therefore produces a new calculation referencing the superseding immutable observation without rewriting an earlier result.

Adapter, client, and provider-format incompatibilities are evaluated independently.
Unavailable results identify each incompatible version dimension as a separate limitation.
Evidence-version construction accepts only supported adapter/client/provider-format triples.
Analytics additionally verifies that each supplied triple is compatible with the observation's provider product and source.

## Denominators

V1 accepts only the typed denominator kinds `input_tokens`, `requests`, `agent_steps`, `completed_tasks`, `accepted_code_changes`, and `active_minutes`.
It accepts only the typed Measured sources `local_usage_events`, `codex_rollout_evidence`, and `collector_usage_events`.
The fixed denominator method identity is `measured_interval_aggregate_v1`.
No arbitrary denominator name, unit, source, version, label, path, or content field can enter an anomaly input or result.

Optional normalization requires one denominator input for every current and baseline interval.
Each denominator records its exact aggregation period, typed kind and unit, typed source provenance, method version, optional value, observation time, optional Measured classification, and coverage state.
Coverage is exactly one of complete, partial with a bounded fraction, or Gap.
Missing periods are materialized as typed Gap inputs with no value or evidence classification in unavailable metadata rather than replaced with zero.
The public denominator initializer applies the same rule, so a Gap can never be classified as Measured.
Missing, zero, stale, partial, incompatible, or differently typed denominators make analysis unavailable.
Direct quota comparison remains available when no optional denominator is requested.

## Result Metadata

Finding, no-finding, Observed Zero, and unavailable results share `QuotaAnomalyResultMetadata`.
The metadata records method, qualification, creation time, implicated Quota windows, exact current and baseline periods, ordered source observation identities, interpretation versions, typed adapter/client/provider-format versions, input provenance classifications, denominator inputs, and limitations.
This shared representation keeps trace and provenance behavior consistent across every result state.

Every finding additionally records its type, direction, identity, current value, all five baseline values, baseline median, ratio, threshold, normalization summary, Calculated classification, and unattributed state.
No-finding outcomes retain the same Calculated values without manufacturing a finding.
Observed Zero retains its exact trace and zero baseline values as a distinct state.
Unavailable outcomes retain every safely known input and reason without manufacturing a numerical score.

Provider-supplied Claude values are classified as Reported inputs.
Directly observed supported Codex values and accepted denominators are classified as Measured inputs.
Movement, median, ratio, and threshold evaluation are Calculated.
V1 creates no Inferred values and cannot silently promote one to Reported or Measured.

## Privacy And Limits

Analysis is local and presentation-independent.
Inputs are limited to normalized percentages, stable digests, exact timestamps, fixed provider and Quota window identifiers, closed version enums, and typed denominator evidence.
The anomaly types contain no free-form prompt, code, response, terminal output, request body, credential, browser cookie, private path, account label, raw provider payload, or arbitrary display-value field.
Findings remain unattributed and do not claim that a project, model, session, agent, operation, or tool caused account-level quota movement.
Provider weighting and capacity remain unknown.

Findings are derived on demand and are not persisted separately in V1.
Deleting or aging out source observations therefore prevents recalculation and cannot leave a persisted finding that falsely appears supported.
The public analytics result is the shared seam for later forensic presentation and alert consumers.

## Fixture Selection

The frozen corpus is `quota_anomaly_corpus_v3` with SHA-256 digest `4628d5ed511f7c4ed7ab85542ac0c03664df919e3023d6a0b9cfc4ed0d3c6b60`.
Every fixture contains normalized immutable observations, a real Quota window identity and reset boundary, an evaluation time, maximum evidence age, typed version evidence, and a labeled outcome.
It covers stable, gradual, flat nonzero, Observed Zero, bursty, mixed-intensity, baseline-shape, sparse, reset, and changing-version evidence.

The sparse fixture contains six boundary observations and proves that one missing boundary is insufficient for the five-sample baseline.
The baseline-shape fixture has a five-sample median that produces the labeled finding while the trailing three-sample median does not.
The reset fixture contains seven boundary observations and evaluates after its reported reset.
The changing-version fixture contains seven boundary observations split across adapter, client, and provider-format versions.
These fixtures execute production qualification rather than using placeholder empty movement arrays.

The same production-derived baseline values evaluate trailing-median ratio thresholds `2.0`, `3.0`, and `4.0`, plus median-absolute-deviation thresholds `2.5` and `3.5`.
Ratio `2.0` produces one labeled false positive on mixed-intensity evidence.
Ratio `4.0` produces one labeled false negative on bursty evidence.
Ratio `3.0` matches all ten labels with no false positive, false negative, or unsafe availability mismatch.
Both median-absolute-deviation candidates have at least two unsafe availability mismatches because a zero dispersion estimate cannot score the bursty and mixed-intensity fixtures safely.

After method and threshold selection, replay independently evaluates four coherent baseline shapes directly from fixture timestamps and observations.
The candidates are five-minute cadence with five baseline samples, ten-minute cadence with three baseline samples, ten-minute cadence with five baseline samples, and fifteen-minute cadence with five baseline samples.
Their baseline durations are respectively 25, 30, 50, and 75 minutes, and their minimum observation spans are respectively 30, 40, 60, and 90 minutes.
The five-minute and fifteen-minute candidates reject labeled available fixtures because their cadence is incompatible with measured fixture intervals.
The ten-minute three-sample candidate misses the baseline-shape finding and incorrectly qualifies the sparse fixture.
Only ten-minute cadence with five baseline samples, a fifty-minute baseline, and a sixty-minute minimum observation span matches all labels.
Production constants are checked against this selected shape only after replay scoring; they are not inputs to shape candidate evaluation.

The corpus is synthetic and establishes deterministic behavior, not real-account provider behavior or population-level statistical performance.
Changing fixture membership or content requires a corpus version or digest review.
