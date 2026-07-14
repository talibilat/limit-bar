# 03 - Explain Claude Code Quota Movement

## Parent

Source plan: `futures/01-quota-doctor.md`.

## What to build

Build the first end-to-end explanation of movement within an exact Claude Code quota window.
The explanation must connect measured Claude Code quota observations to explicitly identified Claude Code evidence collected during a user-selected interval.
It must show what changed, which evidence can support that change, which consumption remains unattributed, and why any requested explanation is unavailable or incomplete.
The result is an evidence explanation rather than another quota gauge.
It must preserve the distinction between a provider-reported quota value, measured local evidence, a calculated comparison, and an inferred allocation.

## Confirmed starting point

The parent Quota Doctor specification identifies Claude Code as a subscription provider product and requires exact provider-reported quota boundaries.
The existing `ProviderProduct` distinction includes Claude Code, Codex, Anthropic API, OpenAI API, and Azure OpenAI.
The Quota Insights foundation described by the parent has measured percentage observations for supported Claude Code quota windows.
That foundation identifies windows using provider product, a stable window identifier, and a provider-reported reset boundary.
The foundation also provides immutable observations, deduplication, bounded retention, deletion, and qualified unavailable states.
The collector schema v1 accepts exactly one provider or custom source identity, a timestamp, a model, an optional Azure deployment, and input and output token deltas.
Collector schema v1 has no provider-product, trace, project, session, agent, operation, or tool fields.
Existing usage aggregates can carry an optional project label and model.
Their calendar windows are not exact Claude Code quota windows and cannot be treated as such.
No confirmed fact in the parent establishes that generic Anthropic API usage consumes a Claude Code subscription quota.
No confirmed fact establishes a provider weighting formula that converts local token deltas into Claude Code quota percentage movement.

## Scope

- Define a Claude Code explanation interval as a bounded portion of one exact active or completed Claude Code quota window.
- Select quota observations by the Claude Code provider-product identity and exact quota-window identity, not merely by company name or overlapping timestamps.
- Calculate quota movement only between compatible measured observations from the same exact quota window.
- Treat resets, counter decreases, expired windows, stale observations, out-of-order observations, and incompatible observation units as explicit explanation states.
- Associate supporting evidence only when its source explicitly identifies the activity as Claude Code activity and its timestamp falls within the explanation interval.
- Keep generic Anthropic API evidence outside the Claude Code explanation even when models, credentials, timestamps, or account ownership appear related.
- Present supporting local activity as an Observed Local Breakdown rather than as an authoritative decomposition of provider-reported quota movement.
- Show measured dimensions that are actually available, such as model and normalized token deltas, without implying that they explain provider weighting.
- Represent the part of observed quota movement not supported by attributable evidence as unattributed consumption.
- Distinguish an Observed Zero from a Gap and from unavailable attribution.
- Report unavailable when no explicitly identified Claude Code evidence exists for the interval.
- Report partial evidence when qualifying Claude Code evidence exists but cannot account authoritatively for the provider-reported movement.
- Include the identities or bounded range of input observations, the explanation interval, source provenance, evidence age, and relevant limitations.
- Ensure that every calculated or inferred statement identifies its method version and its measured inputs.
- Support a deterministic explanation for flat movement without claiming that no Claude Code work occurred.
- Support a deterministic explanation for measured movement with no qualifying local evidence by preserving the movement and marking its cause unavailable.
- Provide a product-facing explanation suitable for the deeper Quota Doctor forensic surface described by the parent.
- Extend privacy-safe diagnostic evidence only through a positive allow-list and only when that extension is part of the selected product presentation.

The exact structured source that can explicitly identify Claude Code activity is not confirmed by the parent specification.
The implementing agent must establish that source from current primary documentation, source ownership, or direct verified behavior before accepting it as measured Claude Code evidence.
The implementing agent must record supported source versions, captured fields, omitted fields, authentication access, confidence classification, and last verified date.
If primary-source evidence does not establish a trustworthy Claude Code activity source, the explanation must remain unavailable and the ticket must not claim attribution acceptance.

## Acceptance criteria

- [ ] A user can select an interval contained within one exact Claude Code quota window and see the measured quota movement between compatible observations.
- [ ] The explanation visibly identifies Claude Code as the provider product and identifies the exact provider-reported reset boundary.
- [ ] The explanation never combines observations from different quota windows, provider products, accounts, or incompatible units.
- [ ] Only evidence explicitly identified as Claude Code activity can appear as supporting local activity.
- [ ] Generic Anthropic API usage is never correlated to Claude Code quota movement.
- [ ] Shared company identity, model identity, credential ownership, or timestamp overlap is insufficient to classify evidence as Claude Code activity.
- [ ] When explicitly identified Claude Code evidence is absent, attribution is shown as unavailable rather than zero, inferred, or attributed to generic Anthropic API usage.
- [ ] Supporting local activity is labeled as an Observed Local Breakdown and is not added to or presented as an authoritative provider total.
- [ ] Provider-reported movement, measured supporting evidence, calculated summaries, inferred allocations, and unattributed consumption have distinct visible provenance.
- [ ] The explanation does not convert token deltas into quota percentage without a documented, versioned, evidence-supported method.
- [ ] Any optional allocation across concurrent Claude Code activity is labeled inferred, identifies the allocation method, and preserves an unattributed remainder when the evidence does not justify complete allocation.
- [ ] The explanation records or exposes the exact input observation identities or a stable bounded input-range identity.
- [ ] The explanation exposes observation count, observation span, source versions, method versions, evidence gaps, and limitations where they affect interpretation.
- [ ] Flat movement, counter decrease, reset, stale evidence, incompatible evidence, missing local evidence, Observed Zero, and Gap produce distinct tested outcomes.
- [ ] Out-of-order and duplicate observations do not create duplicate movement or a false explanation.
- [ ] A quota movement with no qualifying evidence remains visible and is marked unattributed or unavailable as appropriate.
- [ ] A local activity interval with no measured quota movement does not produce a claim that the activity consumed no quota.
- [ ] Calendar usage aggregates are not relabeled or treated as exact Claude Code quota windows.
- [ ] Source support is backed by current primary-source evidence and a recorded last-verified date.
- [ ] If no trustworthy source explicitly identifies Claude Code activity, the implementation reports unavailable and does not claim that attribution acceptance has passed.
- [ ] Automated tests cover compatible movement, reset boundaries, decreasing counters, missing evidence, concurrent activity, source-version changes, and prohibited cross-product correlation.
- [ ] Signed-app acceptance verifies the supported source with real user-owned Claude Code evidence and does not present fixture tests as proof of real-account behavior.

## Privacy and safety constraints

All processing and storage must remain local by default.
Only positively allow-listed fields needed for explanation may be retained or exported.
Raw prompts, code, model responses, terminal output, request bodies, credentials, browser cookies, private paths, account labels, and raw provider payloads are prohibited.
Project paths must be replaced with configured names or bounded privacy-safe stable identifiers before persistence.
Source access must remain within the configured source boundary.
Retention must be bounded by age and count.
Users must be able to delete quota explanation evidence independently from provider settings, credentials, alert rules, and delivery state.
No evidence report may be uploaded or sent without explicit user action and preview of the exact contents.
The explanation must not expose unsupported provider weighting or capacity as fact.

## Explicit non-goals

- Correlating Anthropic API usage with Claude Code quota consumption.
- Reverse-engineering an undisclosed Claude Code weighting formula.
- Treating token totals as an authoritative explanation of quota percentage movement.
- Forcing all measured movement onto known local activity.
- Inferring exact quota boundaries from calendar windows or date labels.
- Adding anomaly detection, workload planning, alerts, or cross-provider explanations in this ticket.
- Scraping private provider pages or automating a browser as the default evidence source.
- Persisting raw client or provider payloads for later interpretation.
- Claiming real-account support based only on synthetic fixtures.
- Changing collector schema v1 as part of this ticket.

## Verification

Automated verification must exercise exact-window selection, compatible observation comparison, evidence qualification, provenance labels, unavailable outcomes, unattributed movement, and privacy filtering.
Fixtures must include movement with qualifying Claude Code evidence, movement without evidence, generic Anthropic API evidence at overlapping timestamps, flat movement, a reset, a counter decrease, duplicates, out-of-order observations, and a source-version change.
A prohibited-content sentinel test must prove that raw prompts, code, responses, terminal output, credentials, private paths, account labels, and raw payloads do not enter persistence or export.
Manual verification must use the signed application and a currently supported, user-owned Claude Code source.
Manual verification must confirm that the displayed interval and reset boundary match provider-reported evidence.
Manual verification must confirm that removing or withholding explicitly identified Claude Code evidence changes the result to unavailable rather than causing fallback correlation to Anthropic API usage.
The verification record must identify the primary sources consulted, supported versions, last verified date, and any unresolved source limitations.

## Blocked by

02 - [#24](https://github.com/talibilat/limit-bar/issues/24) - Explain Codex Quota Movement.

## Status

ready-for-agent
