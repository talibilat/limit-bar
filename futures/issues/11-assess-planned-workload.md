# 11 - Assess Planned Workload

## Parent

Source plan: `futures/01-quota-doctor.md`.

## What to build

Allow a user to describe or select a planned workload and receive an explainable assessment of whether comparable measured historical runs indicate that the workload is likely to finish before quota exhaustion or reset.
The assessment must combine a range derived from comparable measured historical runs with current qualified quota evidence.
The result must state the estimated requirement range, available quota, expected reset interaction, confidence or qualification state, comparison sample, and explicit reasons for the conclusion.
When suitable comparable history or current qualified quota evidence is absent, incompatible, or insufficient, planning must be unavailable rather than fabricated.
Any options offered to the user must be rules-based, traceable to measured constraints, and clearly presented as user choices rather than automatic actions or guarantees.

## Confirmed starting point

Ticket 05 is expected to establish correlation between quota movement and trustworthy local usage evidence.
Ticket 06 is expected to provide current qualified quota forecasts with exact quota-window boundaries and explicit unavailable states.
The parent specification requires workload estimates to use comparable historical runs and current qualified quota evidence.
The parent specification requires unavailable output when comparable history is insufficient.
The parent specification permits rules-based options such as reducing parallel agents, deferring optional work, or choosing a lower-weight model only when supported evidence demonstrates the tradeoff.
Provider weighting may be undisclosed and must not be invented.
No universal denominator is known to safely compare every workload across providers, products, models, clients, or task types.
The product's initial workload description vocabulary and the fields that define one historical run are unknown.
The precise comparability rules, minimum sample qualification, confidence categories, and requirement-range method are unknown and must be documented and versioned before the feature can produce an available assessment.
The supported providers and source adapters may expose different measured dimensions, so availability may legitimately differ by provider product.

## Scope

- Define a bounded workload description or selection model that contains only fields required for evidence-based comparison.
- Define a measured historical run as a bounded comparison unit with traceable evidence, exact timing, relevant workload characteristics, outcome state, and source provenance.
- Exclude incomplete or failed historical runs unless a versioned method explicitly supports their use and explains their effect.
- Establish versioned comparability rules before matching a planned workload to historical runs.
- Require comparison dimensions to be measured or explicitly selected rather than inferred from prompts, code, terminal output, or other prohibited content.
- Consider provider product, workload kind, relevant model or execution mode, concurrency, measured work units, client or adapter version, and evidence completeness only where those fields are available and demonstrably relevant.
- Avoid requiring every possible dimension when evidence shows a smaller, documented comparison key is sufficient.
- Reject samples whose quota units, provider products, exact-window semantics, client behavior, or measured workload dimensions are incompatible.
- Detect material adapter or client-version boundaries that make older runs unsafe to compare.
- Derive an estimated requirement range from comparable measured runs using a documented and versioned rules-based method.
- Keep the requirement estimate classified as calculated or inferred according to the evidence and method used.
- Use the current qualified forecast and its exact active quota boundary when assessing available quota and likely exhaustion.
- Do not infer undisclosed provider capacity from a percentage when the available evidence does not support a safe conversion to the workload requirement's unit.
- Explain whether the evidence indicates likely completion before exhaustion, likely reset before exhaustion, likely insufficiency, or an unavailable assessment.
- Represent indeterminate overlap between ranges without collapsing it into a confident yes or no answer.
- Show the comparison sample's size, relevant span, compatibility dimensions, method version, exclusions, and known limitations.
- Show the current evidence age, exact reset boundary, forecast qualification, and any interaction between the requirement range and reset.
- Preserve measured, calculated, inferred, unavailable, Observed Zero, and Gap distinctions wherever they affect the assessment.
- Explain every conclusion using stable reason categories backed by the displayed evidence.
- Produce rules-based options only when measured comparison evidence supports the stated tradeoff.
- Present options as explicit user choices and describe the evidence, expected direction, and limitation behind each option.
- Report unavailable when no suitable historical runs exist.
- Report unavailable when a historical sample exists but is too incomplete or incompatible for the documented method.
- Report unavailable when current quota evidence is stale, unqualified, boundary-less, expired, or cannot be compared safely with the estimated requirement.
- Report unavailable when provider weighting prevents a defensible mapping between historical workload consumption and current available quota.
- Determine the initial set of supported workload kinds from evidence available through completed source adapters rather than claiming universal workload planning.
- Determine qualitative or quantitative qualification boundaries through documented validation rather than inventing unsupported numeric success thresholds.

## Acceptance criteria

- [ ] A user can describe or select a planned workload using a bounded, privacy-safe input model.
- [ ] The planning method considers only comparable measured historical runs.
- [ ] Every included historical run is traceable to its measured evidence and provenance.
- [ ] Comparability rules are documented, versioned, and exposed in the assessment's method metadata.
- [ ] Incompatible provider products, quota units, window semantics, or materially different client or adapter versions are not silently combined.
- [ ] The assessment includes an estimated requirement range when evidence is sufficient.
- [ ] The assessment includes current available quota evidence without claiming knowledge of undisclosed provider capacity.
- [ ] The assessment explains whether exhaustion or the provider-reported reset is expected first.
- [ ] The assessment never projects an exact quota boundary that the provider did not report.
- [ ] The assessment includes a confidence or qualification state.
- [ ] The assessment identifies the comparison sample, sample size, relevant span, exclusions, and known limitations.
- [ ] The assessment provides explicit, traceable reasons for its conclusion.
- [ ] Overlapping or inconclusive ranges produce an appropriately uncertain conclusion rather than a guaranteed answer.
- [ ] No suitable historical runs produces an unavailable assessment.
- [ ] An insufficient historical sample produces an unavailable assessment.
- [ ] An incompatible historical sample produces an unavailable assessment.
- [ ] Stale, unqualified, expired, or exact-boundary-less current quota evidence produces an unavailable assessment.
- [ ] Unsafe conversion between historical requirements and current quota evidence produces an unavailable assessment.
- [ ] Observed Zero, Gap, and unavailable evidence remain distinct in the planning inputs and explanation.
- [ ] Any suggested option is generated by a documented rule and cites the measured constraint and comparison evidence that activated the rule.
- [ ] Options are omitted when evidence does not demonstrate the stated tradeoff.
- [ ] Options require explicit user action and do not alter provider or account configuration automatically.
- [ ] The result does not promise completion, quota availability, provider capacity, or a provider's future behavior.
- [ ] Automated tests cover comparable, incompatible, incomplete, and insufficient historical samples.
- [ ] Automated tests cover stable, flat, bursty, reset, stale, missing-boundary, version-change, and indeterminate-range conditions where they affect planning.
- [ ] Automated tests cover each rules-based option and prove that it is absent when its evidence prerequisites are absent.
- [ ] The chosen workload vocabulary, comparability dimensions, qualification rules, and method limitations are documented before an available assessment can be released.

## Privacy and safety constraints

All workload descriptions, historical comparison, and assessment processing must remain local by default.
The planning feature must not store or inspect raw prompts, code, model responses, terminal output, request bodies, credentials, browser cookies, or raw provider payloads.
Workload comparison fields must come from a positive allow-list.
Project paths must be replaced with configured names or privacy-safe stable identifiers before persistence.
Historical runs must not be joined across identities or source boundaries in a way that exposes or implies private account information.
An inferred requirement or outcome must never be presented as provider-reported capacity.
The interface must avoid false precision and must show ranges, evidence age, sample characteristics, reset boundaries, and limitations where they affect interpretation.
No assessment or supporting report may be uploaded automatically.
Planning inputs and derived assessments must follow bounded retention and independent deletion requirements established for Quota Doctor evidence.

## Explicit non-goals

- Guaranteeing that a planned workload will finish.
- Claiming knowledge of undisclosed provider capacity, weighting, scheduling, or future availability.
- Producing an estimate without comparable measured historical runs.
- Treating a merely similar label or user description as proof that historical runs are comparable.
- Using one denominator as universally valid across providers, products, models, clients, or workload kinds.
- Rotating accounts or recommending account rotation to evade provider controls.
- Automatically changing providers, provider products, plans, accounts, models, or configuration.
- Automatically purchasing credits.
- Automatically starting, stopping, rescheduling, or modifying the planned workload.
- Scraping private provider pages to fill missing planning evidence.
- Treating local attribution as an authoritative provider total.
- Replacing official provider billing or quota records.
- Offering rules-based options when the measured evidence does not demonstrate the claimed tradeoff.

## Verification

- Build anonymized or synthetic historical-run sets covering comparable, incompatible, incomplete, insufficient, version-divergent, stable, flat, bursty, and reset-affected evidence.
- Verify the method includes only runs allowed by its documented comparability rules.
- Verify every available assessment is reproducible from its identified sample, current qualified quota evidence, and method version.
- Verify requirement ranges, available quota evidence, reset interaction, confidence, sample description, reasons, and limitations are present together.
- Verify no-history, unsafe-conversion, stale-current-evidence, missing-boundary, and incompatible-history cases are unavailable.
- Verify Observed Zero, Gap, and unavailable states remain distinguishable in outputs and tests.
- Verify each option activates only from its documented measured prerequisites and remains a user-controlled choice.
- Verify prohibited-content sentinels cannot enter workload storage, planning evidence, or displayed explanations.
- Perform signed-app manual acceptance with supported real local sources after adapter support is established.
- Record unsupported workload kinds, provider-specific limitations, and any comparability questions that remain unresolved.

## Blocked by

- 05 - [#28](https://github.com/talibilat/limit-bar/issues/28) - Attribute Project And Agent Work.
- 06 - [#25](https://github.com/talibilat/limit-bar/issues/25) - Version And Validate Quota Forecasts.

## Status

ready-for-agent
