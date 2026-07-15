# Quota Forecast Frozen Synthetic Replay Baseline

Method: `pairwise_positive_slope_interquartile_v2`
Corpus: `quota_forecast_corpus_v1`
Freeze digest: `45288bb930da7b86f07cf27a9d9b197994b35f9eaf460bffd211de5ec1d07acb`

This report records deterministic algorithm replay behavior from the checked-in synthetic corpus.
It is not empirical forecast quality validation and does not relabel calculated output as provider-reported information.

## Quality Assessment

- Observed held-out completed windows: 0
- Quality assessment: `unavailable_no_observed_held_out_completed_windows`
- Forecast quality threshold: `unavailable`
- Stronger product claim enabled: false

## Partition

- Development fixtures excluded from scoring: 2
- Held-out fixtures: 12
- Held-out origins: synthetic=12

## Development Algorithm Replay Metrics

- Development qualification coverage: 2/2 (100.0%)
- Development unavailable frequency: 0/2 (0.0%)
- Development observable exhaustion samples: 0
- Development interval coverage: 0/0 (not applicable)
- Development interval errors: none
- Development false projections: 0
- Development reset violations: 0
- Development non-exhausting outcomes: 0
- Development censored outcomes: 2

## Synthetic Algorithm Replay Metrics

- Qualification coverage: 4/12 (33.3%)
- Unavailable frequency: 8/12 (66.7%)
- Observable exhaustion samples: 3
- Exhaustion interval coverage: 2/3 (66.7%)
- Observable exhaustion interval errors: 0.0 minutes, 0.0 minutes, 30.0 minutes
- False exhaustion-before-reset projections: 0
- Reset-boundary violations: 0
- Non-exhausting outcomes: 3
- Censored outcomes: 6

### Unavailable Outcomes

- `conflicting_observations`: 1
- `counter_decreased`: 1
- `incompatible_evidence`: 1
- `insufficient_observations`: 2
- `no_positive_burn`: 1
- `reset_or_expired`: 1
- `stale_evidence`: 1

## Fixture Composition

- Claude Code, `bursty`, `synthetic`: 1; observation counts [4]; spans [30] minutes; cadence [10,10,10] minutes; missing 0; windows [session]; first-observation-to-reset [300] minutes; outcomes [exhausted=1]
- Claude Code, `decreasing`, `synthetic`: 1; observation counts [4]; spans [30] minutes; cadence [10,10,10] minutes; missing 0; windows [session]; first-observation-to-reset [240] minutes; outcomes [censored=1]
- Claude Code, `flat`, `synthetic`: 1; observation counts [4]; spans [30] minutes; cadence [10,10,10] minutes; missing 0; windows [session]; first-observation-to-reset [240] minutes; outcomes [non_exhausting=1]
- Claude Code, `incompatible_window`, `synthetic`: 1; observation counts [2]; spans [10] minutes; cadence [10] minutes; missing 0; windows [session]; first-observation-to-reset [240] minutes; outcomes [censored=1]
- Claude Code, `out_of_order`, `synthetic`: 1; observation counts [4]; spans [30] minutes; cadence [10,10,10] minutes; missing 0; windows [session]; first-observation-to-reset [240] minutes; outcomes [non_exhausting=1]
- Claude Code, `stale`, `synthetic`: 1; observation counts [4]; spans [30] minutes; cadence [10,10,10] minutes; missing 0; windows [session]; first-observation-to-reset [240] minutes; outcomes [censored=1]
- Codex, `conflicting_observations`, `synthetic`: 1; observation counts [5]; spans [30] minutes; cadence [10,10,10] minutes; missing 0; windows [session]; first-observation-to-reset [240] minutes; outcomes [censored=1]
- Codex, `exact_duplicate`, `synthetic`: 1; observation counts [5]; spans [30] minutes; cadence [10,10,10] minutes; missing 0; windows [session]; first-observation-to-reset [240] minutes; outcomes [exhausted=1]
- Codex, `missing`, `synthetic`: 1; observation counts [0]; spans [0] minutes; cadence [] minutes; missing 1; windows []; first-observation-to-reset [] minutes; outcomes [censored=1]
- Codex, `reset_expired`, `synthetic`: 1; observation counts [4]; spans [30] minutes; cadence [10,10,10] minutes; missing 0; windows [session]; first-observation-to-reset [30] minutes; outcomes [non_exhausting=1]
- Codex, `sparse`, `synthetic`: 1; observation counts [2]; spans [20] minutes; cadence [20] minutes; missing 0; windows [session]; first-observation-to-reset [240] minutes; outcomes [censored=1]
- Codex, `stable`, `synthetic`: 1; observation counts [4]; spans [30] minutes; cadence [10,10,10] minutes; missing 0; windows [session]; first-observation-to-reset [240] minutes; outcomes [exhausted=1]

## Provider and evidence-condition segments

- Claude Code, `bursty`: 1/1 qualified (100.0%); unavailable 0.0% []; interval coverage 1/1 (100.0%); errors [0.0 minutes]; false projections 0; reset violations 0; non-exhausting 0; censored 0
- Claude Code, `decreasing`: 0/1 qualified (0.0%); unavailable 100.0% [counter_decreased=1]; interval coverage 0/0 (not applicable); errors [none]; false projections 0; reset violations 0; non-exhausting 0; censored 1
- Claude Code, `flat`: 0/1 qualified (0.0%); unavailable 100.0% [no_positive_burn=1]; interval coverage 0/0 (not applicable); errors [none]; false projections 0; reset violations 0; non-exhausting 1; censored 0
- Claude Code, `incompatible_window`: 0/1 qualified (0.0%); unavailable 100.0% [incompatible_evidence=1]; interval coverage 0/0 (not applicable); errors [none]; false projections 0; reset violations 0; non-exhausting 0; censored 1
- Claude Code, `out_of_order`: 1/1 qualified (100.0%); unavailable 0.0% []; interval coverage 0/0 (not applicable); errors [none]; false projections 0; reset violations 0; non-exhausting 1; censored 0
- Claude Code, `stale`: 0/1 qualified (0.0%); unavailable 100.0% [stale_evidence=1]; interval coverage 0/0 (not applicable); errors [none]; false projections 0; reset violations 0; non-exhausting 0; censored 1
- Codex, `conflicting_observations`: 0/1 qualified (0.0%); unavailable 100.0% [conflicting_observations=1]; interval coverage 0/0 (not applicable); errors [none]; false projections 0; reset violations 0; non-exhausting 0; censored 1
- Codex, `exact_duplicate`: 1/1 qualified (100.0%); unavailable 0.0% []; interval coverage 0/1 (0.0%); errors [30.0 minutes]; false projections 0; reset violations 0; non-exhausting 0; censored 0
- Codex, `missing`: 0/1 qualified (0.0%); unavailable 100.0% [insufficient_observations=1]; interval coverage 0/0 (not applicable); errors [none]; false projections 0; reset violations 0; non-exhausting 0; censored 1
- Codex, `reset_expired`: 0/1 qualified (0.0%); unavailable 100.0% [reset_or_expired=1]; interval coverage 0/0 (not applicable); errors [none]; false projections 0; reset violations 0; non-exhausting 1; censored 0
- Codex, `sparse`: 0/1 qualified (0.0%); unavailable 100.0% [insufficient_observations=1]; interval coverage 0/0 (not applicable); errors [none]; false projections 0; reset violations 0; non-exhausting 0; censored 1
- Codex, `stable`: 1/1 qualified (100.0%); unavailable 0.0% []; interval coverage 1/1 (100.0%); errors [0.0 minutes]; false projections 0; reset violations 0; non-exhausting 0; censored 0

## Limitations

- The frozen corpus is synthetic and its algorithm replay metrics are not empirical forecast quality evidence.
- There are zero observed held-out completed windows, so forecast quality assessment and any quality threshold are unavailable.
- No stronger product claim is enabled.
- Provider weighting and capacity behavior are unknown, so provider products and evidence conditions remain separate.
- Censored outcomes, observation cadence, missing evidence, and provider or client changes limit interpretation.
- The corpus digest is a drift-review boundary, not statistical independence.
- Corpus membership or content changes require a corpus version or digest review before scoring.
- No additional conservative, balanced, or responsive forecast profiles were evaluated.
