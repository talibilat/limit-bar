# Quota Anomaly Method V1

## Identity

The production method identity is `trailing_median_ratio_v1`.
Any change to baseline construction, cadence, sample count, qualification order, threshold meaning, normalization, Observed Zero behavior, or output meaning requires a new method version.
Display-only wording does not require a new method version.

## Supported Comparison

V1 compares direct quota movement, or quota movement divided by an explicitly selected Measured denominator, within one active Exact Quota Window.
It does not compare across completed quota windows.
Cross-window evidence is unavailable rather than joined across a provider-reported reset.

The current comparison period is the latest exact ten-minute interval.
The trailing baseline contains the five immediately preceding contiguous ten-minute intervals.
The baseline therefore spans exactly fifty minutes and excludes the current comparison period.
Each movement interval uses the half-open inclusion rule `(start, end]`, represented as `start_exclusive_end_inclusive`, because the movement is calculated from cumulative observations at its two boundaries.

Seven boundary observations are required to form the five baseline movements and one current movement.
Observations are sorted by time and stable identity before exact duplicates are removed.
The selected observations must use one provider product, one quota context, one provider-reported reset boundary, one normalization interpretation, one adapter version, one client version, and one provider-format version.
Every adjacent observation must be exactly ten minutes apart.
Partial intervals and unresolved Gaps are unavailable.

## Calculation

The baseline summary is the Calculated median of the five baseline movement values.
The current movement is Calculated from its two boundary observations.
The ratio is the current movement divided by the baseline median.
A higher-consumption finding is emitted when the ratio is at least `3.0`.
V1 does not emit lower-consumption findings because the frozen fixture evidence selected and validated only the higher-consumption meaning.

An all-zero baseline with zero current movement is a qualified no-finding Observed Zero outcome with no ratio.
A positive current movement against a zero median is unavailable because division would be unstable.
A Gap is never substituted with zero.

## Qualification

V1 returns unavailable without a finding for invalid evaluation metadata, insufficient observations, insufficient span, stale evidence, an expired boundary, incompatible exact windows or versions, conflicting same-time observations, a counter decrease, a Gap, or an unstable zero baseline.
Exact duplicates do not alter output.
Out-of-order delivery does not alter output because sorting precedes qualification.
Explicitly superseded observations are excluded and the limitation is retained.
A correction therefore produces a new calculation referencing the superseding immutable observation without rewriting an earlier result.

Optional normalization requires exactly one Measured denominator aggregate for every current and baseline interval.
The denominator name, unit, version, exact period, coverage, value, and observation time are allow-listed.
Missing, zero, stale, partial, incompatible, non-Measured, or differently versioned denominators make analysis unavailable.
Direct quota comparison remains available when no optional denominator is requested.

## Traceability

Every finding records its type, direction, method version, qualification, creation time, exact current period, exact baseline period, quota-window identity, ordered source observation identities, interpretation versions, adapter/client/provider-format versions, input provenance classifications, current value, baseline median, ratio, threshold, normalization summary, and limitations.
No-finding outcomes retain the same periods, trace, values, method, and limitations.
Unavailable outcomes retain every safely known identity, period, version, limitation, and reason without manufacturing a score.

Provider-supplied Claude values are classified as Reported inputs.
Directly observed supported Codex values and accepted denominators are classified as Measured inputs.
Movement, median, ratio, and threshold evaluation are Calculated.
V1 creates no Inferred values.

## Privacy And Limits

Analysis is local and presentation-independent.
Inputs are limited to normalized percentages, stable digests, exact timestamps, fixed provider product and quota identifiers, allow-listed version strings, and optional allow-listed denominator metadata.
The types cannot retain prompts, code, responses, terminal output, request bodies, credentials, browser cookies, private paths, account labels, or raw provider payloads.
Findings remain unattributed and do not claim that a project, model, session, agent, operation, or tool caused account-level quota movement.
Provider weighting and capacity remain unknown.

Findings are derived on demand and are not persisted separately in V1.
Deleting or aging out source observations therefore prevents recalculation and cannot leave a persisted finding that falsely appears supported.
The public analytics result is the shared seam for later forensic presentation and alert consumers.

## Fixture Selection

The frozen corpus is `quota_anomaly_corpus_v1` with SHA-256 digest `3b0d7641e652b5c2ddeaf612ca05dfe56ea424ebd8d057c684ca029fe5f3dcab`.
It labels stable, gradual, flat, Observed Zero, bursty, mixed-intensity, sparse, reset, and changing-version evidence.
The same fixtures evaluate trailing-median ratio thresholds `2.0`, `3.0`, and `4.0`, plus median-absolute-deviation thresholds `2.5` and `3.5`.

Ratio `2.0` produces one labeled false positive on mixed-intensity evidence.
Ratio `4.0` produces one labeled false negative on bursty evidence.
Ratio `3.0` matches all nine labels with no false positive, false negative, or unsafe availability mismatch.
Both median-absolute-deviation candidates have at least two unsafe availability mismatches because a zero dispersion estimate cannot score the bursty and mixed-intensity fixtures safely.

The corpus is synthetic and establishes deterministic behavior, not real-account provider behavior or population-level statistical performance.
Changing fixture membership or content requires a corpus version or digest review.
