# 06 - Version and Validate Quota Forecasts

## Parent

Source plan: `futures/01-quota-doctor.md`.

This ticket validates and versions the quota forecast behavior established by the landed foundation.

## What to build

Make every burn-rate and exhaustion forecast reproducible from explicit versioned methods, input identities, and qualification rules.
Create a held-out fixture evaluation process that measures forecast behavior on completed observed quota windows without tuning and scoring on the same examples.
Use the resulting evidence to define defensible product language and limitations.

This ticket must not promise or invent a forecast quality threshold before evaluation evidence exists.
If the available fixtures are too sparse or unrepresentative to support a quality claim, the outcome must state that limitation and retain conservative qualified or unavailable product language.

## Confirmed starting point

- Ticket 01 is required because current `main` lacks the PR #22 Quota Insights foundation.
- PR #22 is open and unmerged on branch `ticket-14-quota-insights`.
- PR #22 had green CI at the last inspection.
- PR #22 provides measured Claude Code and Codex percentages and exact quota-window reset identities once landed.
- PR #22 provides calculated burn-rate and exhaustion ranges from sufficiently recent measured observations.
- PR #22 provides unavailable states for insufficient, stale, decreasing, flat, reset, and expired evidence.
- The parent specification requires forecasts to expose observation count, observation span, method version, and confidence or qualification state.
- The parent specification requires forecast quality to be evaluated against held-out observed windows before stronger predictive claims are made.
- Provider weighting and exact capacity may be undisclosed.
- A percentage trajectory can be evaluated without claiming knowledge of the provider's hidden token weighting.
- The available number, diversity, and representativeness of completed observed quota windows are not established in the parent specification.
- No evidence-backed forecast error threshold is currently specified.
- No evidence-backed minimum qualification threshold beyond the foundation's current rules is specified in this ticket description.
- It is unknown whether separate forecast profiles would improve user decisions.
- Conservative, balanced, or responsive profiles must not be introduced unless each has a distinct documented and testable meaning supported by evidence.

## Scope

- Assign a stable version to each forecast method that can affect burn-rate or exhaustion output.
- Version the complete method semantics rather than only a display label.
- Define the normalized inputs required by each method, including exact quota-window identity, provider-reported reset boundary, observation timestamps, measured values, and relevant source or adapter version metadata.
- Record exact input observation identities or a stable bounded input-range identity for every calculated forecast finding.
- Define qualification rules for observation count, observation span, recency, positive movement, counter stability, exact active boundary, and reset interaction.
- Define deterministic outcomes for insufficient, stale, flat, decreasing, reset, expired, out-of-order, duplicate, and incompatible evidence.
- Preserve a distinction between an unavailable forecast and a qualified forecast that projects no exhaustion before reset.
- Ensure forecast calculations never combine observations from different Quota windows or Exact boundaries.
- Ensure an exhaustion range never crosses the provider-reported reset boundary.
- Ensure all forecast outputs identify their creation time without presenting it as a provider event.
- Establish a fixture corpus of completed quota windows suitable for replay.
- Separate method-development fixtures from held-out evaluation fixtures before using evaluation results to make quality claims.
- Include stable, flat, bursty, reset, decreasing, sparse, stale, duplicate, out-of-order, and missing-data cases.
- Include multiple supported provider products when sufficient trustworthy fixtures exist.
- Keep provider-product results separate when source behavior or quota semantics are not safely comparable.
- Define evaluation metrics before scoring the held-out set.
- Measure exhaustion-range coverage when an exhaustion outcome is observable.
- Measure timing error or interval error in units that match the forecast output and exact window boundary.
- Measure qualification coverage, unavailable frequency, false exhaustion-before-reset projections, and reset-boundary violations.
- Report sample counts and fixture composition with every aggregate evaluation result.
- Report results separately for materially different evidence conditions rather than hiding them in one average.
- Preserve failed, unavailable, and non-exhausting windows in evaluation reporting.
- Document limitations caused by small samples, synthetic fixtures, censored outcomes, provider changes, client-version changes, or incomplete observation cadence.
- Use evaluation evidence to decide whether existing product language remains appropriate or must become more conservative.
- Introduce additional forecast profiles only when their semantics, qualification rules, and comparative held-out results are documented.
- Keep evaluation and product claims independent of undisclosed provider capacity or weighting assumptions.

## Acceptance criteria

- [ ] Every burn-rate and exhaustion finding records a stable forecast method version.
- [ ] Every finding is traceable to exact input observation identities or a stable bounded input-range identity.
- [ ] Every finding records the exact provider product, exact quota-window identity, provider-reported reset boundary, observation count, observation span, evidence age, qualification state, and creation time.
- [ ] Method documentation defines the calculation, required inputs, excluded inputs, qualification rules, unavailable outcomes, limitations, and version-change policy.
- [ ] Any change that can alter qualification or numerical output requires a new method version.
- [ ] Display-only changes that do not alter semantics do not create a misleading new analytical method identity.
- [ ] Forecast calculations use observations from only one exact active quota window.
- [ ] Duplicate observations do not change the effective sample or forecast result.
- [ ] Out-of-order inputs produce deterministic results or a documented unavailable state.
- [ ] Counter decreases and reset transitions cannot be interpreted as positive burn.
- [ ] Missing exact reset boundaries cannot produce an exhaustion forecast that pretends to know the reset interaction.
- [ ] Exhaustion ranges never cross a provider-reported reset boundary.
- [ ] A qualified trajectory that does not exhaust before reset is distinct from an unavailable forecast.
- [ ] Flat, stale, expired, sparse, incompatible, and otherwise insufficient evidence produce explicit, versioned qualification outcomes.
- [ ] The fixture corpus identifies which cases are synthetic, anonymized, or derived from observed completed windows.
- [ ] Fixture provenance is privacy-safe and does not include prohibited raw content or private identifiers.
- [ ] Development fixtures and held-out evaluation fixtures are selected separately before final evaluation scoring.
- [ ] The held-out set is not used to tune the method revision reported against it.
- [ ] Evaluation metrics and their interpretations are documented before final held-out results are calculated.
- [ ] Evaluation reports include sample count, provider-product composition, quota-window characteristics, observation cadence, missingness, and outcome availability.
- [ ] Evaluation reports include qualification coverage and unavailable frequency.
- [ ] Evaluation reports include exhaustion-range coverage and timing or interval error where the observed outcome permits those measurements.
- [ ] Evaluation reports count false exhaustion-before-reset projections and any reset-boundary violations explicitly.
- [ ] Non-exhausting and censored windows are not silently removed from the reported sample.
- [ ] Results for incompatible provider products or evidence conditions are not combined into a misleading aggregate.
- [ ] No quality threshold is declared passed unless the threshold, rationale, sample sufficiency, and decision rule are established from evidence outside the scored held-out set.
- [ ] If evidence is insufficient to establish a threshold, the evaluation says so explicitly and does not block publication on an invented number.
- [ ] Stronger predictive product claims are enabled only when held-out evidence supports the exact claim.
- [ ] Weak or inconclusive evidence results in conservative language, tighter qualification, or unavailable behavior rather than unsupported confidence.
- [ ] Conservative, balanced, or responsive profiles are absent unless each has documented semantics and held-out comparative evidence.
- [ ] Automated replay produces deterministic results for a fixed fixture set and method version.
- [ ] Signed-application acceptance verifies that visible method metadata, qualification, reset interaction, and limitations match the evaluated implementation.

## Privacy and safety constraints

- Forecast inputs and evaluation fixtures must remain local by default.
- Fixtures and reports must exclude raw prompts, code, model responses, terminal output, request bodies, credentials, browser cookies, private paths, account labels, and raw provider payloads.
- Observed fixtures must be anonymized or normalized before inclusion in a durable corpus.
- Stable fixture identities must not encode private account, project, session, or filesystem information.
- Evaluation reports may contain aggregate error and coverage metrics but must not expose prohibited source content.
- Forecast output must remain classified as calculated.
- A quality evaluation must not cause a calculated or inferred result to be relabeled as provider-reported.
- Exact reset boundaries must be provider-reported rather than guessed.
- Missing outcomes and censored windows must be represented honestly rather than imputed as successful forecasts.
- Small or unrepresentative samples must be disclosed wherever they affect interpretation.
- Validation must not weaken bounded retention or independent deletion requirements for live quota observations and findings.

## Explicit non-goals

- Promising a numerical quality threshold before evidence supports one.
- Claiming knowledge of undisclosed provider capacity or token weighting.
- Forecasting across a provider-reported reset boundary.
- Treating fixture replay as proof of all real-account or future provider behavior.
- Tuning a method on the same held-out fixtures used for its final score.
- Combining incompatible provider products into one headline metric.
- Adding anomaly detection.
- Adding quota attribution or Codex token correlation.
- Adding workload planning or recommendations.
- Adding alert delivery.
- Forecasting monetary cost without a versioned price source.
- Creating multiple forecast profiles solely as presentation choices.
- Replacing official provider quota or billing records.

## Verification

- Replay each method version against deterministic unit fixtures for stable, flat, bursty, reset, decreasing, sparse, stale, duplicate, out-of-order, expired, and missing-boundary cases.
- Verify that input order and duplicate delivery do not create undocumented output changes.
- Verify that every result can be reproduced from its recorded method version and input identities.
- Verify that no result combines Quota windows or Exact boundaries or crosses a provider-reported reset boundary.
- Freeze the held-out fixture membership before final scoring of the candidate method version.
- Run the defined metrics once against the frozen held-out set after method changes settle.
- Review the report for omitted unavailable, censored, non-exhausting, and failed cases.
- Compare provider products and materially different observation cadences separately.
- Confirm that the report includes enough sample and composition detail to interpret every quality statement.
- Confirm that product labels and explanatory copy make only claims directly supported by the held-out results.
- Confirm that inconclusive results retain conservative qualification and explicit limitations.
- Run prohibited-content sentinel checks across fixtures, persisted method metadata, evaluation reports, UI details, and privacy-safe exports.
- Exercise the signed application with stable, non-exhausting, insufficient, stale, reset, and exhaustion-likely scenarios and compare visible results with fixture replay.
- Record unknown representativeness, provider-version drift, and sample limitations as validation findings rather than filling them with assumptions.

## Blocked by

01 - [#23](https://github.com/talibilat/limit-bar/issues/23) - Land Quota Insights Foundation.

## Status

ready-for-agent
