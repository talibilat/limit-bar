# 07 - Detect Quota Consumption Anomalies

## Parent

Source plan: `futures/01-quota-doctor.md`.

## What to build

Build explainable anomaly detection that compares consumption in a current comparison period with a compatible trailing baseline for the same provider product and quota context.
The capability must identify materially unusual quota consumption only when the underlying observations, baseline, and optional denominator support a safe comparison.
Each emitted anomaly finding must preserve its measured inputs, comparison period, baseline period, qualification state, limitations, and versioned method identity.
The first method must be selected from robust, explainable candidates such as a trailing-median ratio or a median-absolute-deviation score only after fixture evidence establishes which candidate behaves acceptably for the supported evidence shapes.

## Confirmed starting point

The parent specification requires current consumption to be compared with an appropriate trailing baseline.
The parent specification identifies a ratio to trailing median and a median-absolute-deviation score as initial candidates, but it does not select either method.
The existing Quota Insights foundation described by the parent stores measured percentage observations for supported quota windows and records exact window identities and provider-reported reset boundaries.
That foundation also distinguishes unavailable forecast states caused by insufficient, stale, decreasing, flat, reset, or expired evidence.
The foundation does not yet provide baseline construction, anomaly detection, or anomaly explanations.
Ticket 02 is expected to establish the first normalized Codex explanation evidence and safe direct quota comparison path.
Ticket 05 may later supply measured project and agent dimensions for optional normalized comparisons, but anomaly detection must remain safe when that attribution is absent.
Ticket 06 is expected to establish versioned forecast methods, traceable inputs, qualification metadata, and fixture-evaluation practices that anomaly findings must remain compatible with.
Provider weighting may be undisclosed and may vary by model, caching, reasoning, service tier, concurrency, or other unavailable factors.
No universal denominator, anomaly method, threshold, baseline duration, or minimum sample requirement has been validated yet.

## Scope

- Define a deterministic baseline-construction contract for observations that are compatible by provider product, quota-window kind, reported unit, source interpretation, and other evidence dimensions proven necessary by fixtures.
- Keep observations from different Quota windows or Exact boundaries separate unless the selected baseline method explicitly compares equivalent positions or intervals across completed compatible windows.
- Exclude evidence across a provider-reported reset when that evidence cannot be normalized into comparable periods without inventing a boundary.
- Treat a missing provider-reported reset boundary as missing evidence when an exact boundary is required for the comparison.
- Define the current comparison period and trailing baseline period with exact timestamps and a documented inclusion rule.
- Preserve the identities or stable bounded ranges of all observations used by each derived finding.
- Evaluate a trailing-median ratio and a median-absolute-deviation score against representative fixtures before selecting the first production method.
- Select one initial method only when fixture evidence demonstrates understandable behavior across stable, flat, bursty, sparse, reset, and changing-version cases.
- Record the selected method and baseline-construction rules under an explicit method version.
- Treat every later change to comparison semantics, exclusions, threshold interpretation, or output meaning as a method-version decision.
- Determine alerting or display thresholds from labeled fixture evidence and documented false-positive and false-negative tradeoffs.
- Do not encode an arbitrary threshold merely to complete the ticket.
- Treat unresolved method selection, baseline length, minimum observations, minimum observation span, and threshold values as decisions requiring fixture evidence.
- Support direct comparison of measured quota movement when the quota unit and periods are compatible.
- Permit normalized comparisons such as quota movement per input token, request, agent step, completed task, accepted code change, or active minute only when that denominator is Measured reliably and is compatible across the current and baseline periods.
- Record the denominator name, provenance, aggregation period, coverage, and missingness when a normalized comparison is used.
- Produce an unavailable result with no anomaly finding when a denominator is zero, missing, stale, partially covered, incompatible, or otherwise unsafe.
- Produce an unavailable result with no anomaly finding when a baseline is empty, too small, stale, non-comparable, contaminated by an unresolved reset, or invalidated by a source interpretation change.
- Produce an unavailable result with no anomaly finding when the selected method has an undefined or unstable baseline calculation, including division by an unsafe zero baseline or an unusable dispersion estimate.
- Distinguish an Observed Zero from a Gap in both current and baseline evidence.
- Allow an Observed Zero to participate only according to explicit, versioned method semantics supported by fixture evidence.
- Never substitute zero for a Gap or other unavailable evidence.
- Detect and qualify duplicate observations, out-of-order observations, decreasing counters, superseded inputs, and partial intervals before constructing a finding.
- Account for relevant adapter or client-version changes when they can alter observation meaning.
- Refuse comparison across incompatible versions and expose the incompatibility as a limitation rather than interpreting it as an anomaly.
- Represent the result as a bounded derived finding that includes finding type, direction, magnitude or score, method version, qualification, creation time, input evidence, and limitations.
- Explain why a finding was emitted in terms of the current value, baseline summary, selected method, and threshold that was crossed.
- Explain why analysis is unavailable without manufacturing a finding when safety requirements are not met.
- Preserve unattributed quota movement as valid measured quota evidence while avoiding unsupported claims about which project, session, model, agent, operation, or tool caused the anomaly.
- Make anomaly analysis independent of presentation so later forensic and alert surfaces consume the same qualified result.
- Keep provenance language explicit in data exposed to consumers.
- Label provider-supplied values as Reported.
- Label directly observed supported-source values as Measured.
- Label deterministic baseline summaries, scores, and threshold evaluations as Calculated.
- Label estimates from incomplete evidence as Inferred, and do not silently promote them to Measured or Reported evidence.

## Acceptance criteria

- [ ] A current comparison period is evaluated only against a documented, compatible trailing baseline.
- [ ] Every comparison period and baseline period has exact boundaries and an explicit inclusion rule.
- [ ] The implementation evaluates trailing-median ratio and median-absolute-deviation candidates with representative fixtures before selecting and versioning the initial method.
- [ ] The selected method, threshold, baseline duration, minimum sample count, and minimum observation span are justified by fixture evidence rather than undocumented constants.
- [ ] A change to method semantics or threshold meaning produces a distinct method version.
- [ ] Every anomaly finding identifies its method version, exact current period, exact baseline period, measured inputs, input identities or bounded input range, result, qualification, and known limitations.
- [ ] Every finding presents enough intermediate evidence to explain why the selected threshold was crossed.
- [ ] Stable consumption fixtures do not generate findings beyond the documented false-positive tolerance.
- [ ] Materially bursty consumption fixtures generate the expected directional finding when the evidence is sufficient and compatible.
- [ ] Flat baselines, including valid Observed Zero cases, follow explicit versioned semantics and never cause unsafe division or fabricated magnitude.
- [ ] A Gap is never converted into an Observed Zero or included as a zero-valued sample.
- [ ] Missing, stale, sparse, partially covered, or incompatible baselines produce an unavailable result and no anomaly finding.
- [ ] Missing, zero, stale, partially covered, or incompatible denominators produce an unavailable result and no anomaly finding.
- [ ] Missing exact boundaries produce an unavailable result whenever the method requires an exact boundary.
- [ ] Counter decreases and provider-reported resets are not reported as consumption anomalies unless a separately defined and evidence-backed finding explicitly covers that condition.
- [ ] Duplicate, out-of-order, and superseded observations do not distort the current period or baseline.
- [ ] Incompatible provider formats, adapter versions, or client versions produce no cross-version anomaly finding.
- [ ] Concurrent local activity does not create unsupported causal attribution for an account-level quota change.
- [ ] Findings can use measured normalized denominators only when both periods have compatible denominator coverage.
- [ ] Direct quota comparisons remain available when safe even if optional attribution evidence is absent.
- [ ] Reported, Measured, Calculated, and Inferred classifications remain explicit and are not collapsed into a generic confidence label.
- [ ] An Inferred value is never presented as a provider-reported quota or as a Measured denominator.
- [ ] Unavailable analysis, no finding, Observed Zero, and Gap remain distinguishable outcomes.
- [ ] Every emitted finding can be traced back to immutable source observations or their stable bounded input-range identity.
- [ ] Recalculation after an explicit correction references the superseding evidence without silently rewriting the earlier finding.
- [ ] The analytics result is consumable by the forensic view without duplicating anomaly logic in presentation.

## Privacy and safety constraints

- All analysis must remain local by default.
- Anomaly inputs and findings must contain only normalized, allow-listed evidence.
- The capability must not persist raw prompts, code, model responses, terminal output, request bodies, credentials, browser cookies, private paths, account labels, or raw provider payloads.
- Project, session, model, agent, operation, and tool context may be retained only when supplied through an approved privacy-safe identifier or configured display value.
- Findings must not imply knowledge of undisclosed provider capacity or weighting.
- Findings must not turn correlation into causal attribution.
- Unsafe comparisons must return unavailable with no finding rather than a low-confidence numerical score.
- Retention and independent deletion behavior established for quota observations and derived findings must apply to anomaly findings.
- A deleted or unavailable source observation must not leave behind a finding that falsely appears fully supported.

## Explicit non-goals

- Building the forensic investigation interface.
- Exporting anomaly findings in the diagnostic evidence report.
- Delivering anomaly notifications or changing the existing alert delivery ledger.
- Selecting a universal denominator for all providers, products, quota kinds, or workloads.
- Claiming that local usage explains all provider-reported quota movement.
- Inferring undisclosed provider weighting, total capacity, or billing behavior.
- Treating a ratio or median-absolute-deviation method as chosen before fixture evaluation is complete.
- Detecting provider outages, authentication failures, or capacity incidents from quota anomalies alone.
- Scraping private provider pages or adding browser automation.
- Forecasting exhaustion or planning future workloads.

## Verification

- Add deterministic fixture tests for stable, gradually changing, flat, bursty, sparse, and mixed-intensity consumption.
- Add labeled candidate-method fixtures that compare the trailing-median ratio and median-absolute-deviation behavior on the same evidence.
- Record why the selected method and thresholds are acceptable for those fixtures, including known false positives and false negatives.
- Verify baseline eligibility at reset boundaries, across completed windows, and within an active window for every supported comparison shape.
- Verify missing observations, Gaps, Observed Zero values, duplicate observations, out-of-order observations, counter decreases, and explicit supersession.
- Verify safe behavior for a zero median, zero dispersion, zero denominator, partial denominator coverage, and incompatible denominator units.
- Verify that missing reset evidence and guessed boundaries cannot produce findings that require exact boundaries.
- Verify compatibility behavior across adapter versions, client versions, provider-format changes, and method versions.
- Verify account-level quota movement during concurrent project, session, model, agent, and operation activity without asserting unsupported causation.
- Verify that every finding exposes exact periods, input traceability, method metadata, qualification, and limitations.
- Verify prohibited-content sentinels cannot enter anomaly inputs, findings, logs, or diagnostic descriptions.
- Run the analytics test suite repeatedly with reordered equivalent inputs to prove deterministic results.
- Validate representative supported-source fixtures, while documenting that fixture tests do not prove real-account provider behavior.

## Blocked by

- 02 - [#24](https://github.com/talibilat/limit-bar/issues/24) - Explain Codex Quota Movement.
- 06 - [#25](https://github.com/talibilat/limit-bar/issues/25) - Version And Validate Quota Forecasts.

## Status

ready-for-agent
