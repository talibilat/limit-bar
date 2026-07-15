# 04 - Add API Provider Quota Path

## Parent

Source plan: `futures/01-quota-doctor.md`.

## What to build

Select and implement one trustworthy API-provider quota evidence path for Quota Doctor.
The path must use a currently documented provider source that reports quota consumption and exact quota-window boundaries suitable for the canonical quota observation model.
Selection is part of the ticket because the available evidence and stability of provider interfaces must be established from current primary documentation rather than assumed.
The resulting adapter must isolate provider-specific acquisition and parsing from normalized quota observations and analytics.
If no candidate meets the evidence contract, deliver a documented unavailable result and do not fabricate an adapter or claim adapter acceptance.

## Confirmed starting point

The existing `ProviderProduct` distinction includes Claude Code, Codex, Anthropic API, OpenAI API, and Azure OpenAI.
The parent requires at least one stable, tested API-provider adapter in the completed product.
The parent prioritizes documented provider APIs, response headers, and usage endpoints over structured local events and imported files.
The canonical quota model requires a provider product, stable observation identity, exact observation timestamp, exact quota-window identity, and provider-reported reset boundary.
It also requires a reported percentage, count, or monetary unit, source provenance, classification, and the adapter and client versions needed to interpret the observation.
The collector schema v1 accepts exactly one provider or custom source identity, a timestamp, a model, an optional Azure deployment, and input and output token deltas.
Collector schema v1 has no provider-product, trace, project, session, agent, operation, or tool fields.
Existing usage aggregates can carry an optional project label and model.
Their calendar windows are not exact provider quota windows.
No API provider, endpoint, response header, SDK, authentication path, quota unit, or payload format is confirmed for this ticket.
OpenAI is one possible provider product already represented by the domain, but it is not a predetermined selection.

## Scope

- Evaluate API-provider candidates represented by the current provider-product model using current first-party documentation.
- Prefer a documented API, response header, or usage endpoint that supplies an exact provider-reported quota reset boundary and a stable interpretation of quota consumption.
- Select exactly one API-provider path only after its evidence satisfies the canonical observation requirements.
- Record the primary documentation URL or document identity, publication or revision information when available, access date, and last verified date.
- Document why the selected source is stable enough to support a maintained adapter.
- Include documented versioning guarantees, field semantics, authentication mechanism, availability scope, rate limits, deprecation policy, and observed compatibility where primary sources provide them.
- State each unknown explicitly when primary documentation does not answer it.
- Define the supported provider product, API or client versions, account or project scope, quota dimensions, units, exact reset-boundary semantics, and known omissions.
- Use a positive allow-list that maps only the minimum documented fields into normalized observations.
- Reject or ignore unrecognized provider fields rather than retaining raw payloads for future interpretation.
- Preserve provider-reported quota values and exact boundaries without translating them into an undisclosed capacity or weighting model.
- Generate stable observation identity from documented stable evidence or a documented deterministic normalization method.
- Keep acquisition, authentication, transport, provider parsing, normalization, persistence, and analytics responsibilities separated at the adapter boundary.
- Represent authorization failure, permission denial, unsupported account scope, rate limiting, malformed response, partial response, missing boundary, changed format, and unavailable service as explicit outcomes.
- Fail closed when a required exact boundary or required semantic field is absent or ambiguous.
- Ensure that calendar windows and local token aggregates are never substituted for a missing provider-reported quota window.
- Preserve immutable source observations and use explicit supersession for corrections.
- Apply bounded retention, count limits, deduplication, deletion, and unknown-schema safety consistent with the parent contract.
- Provide synthetic and anonymized fixtures for documented successful and failure responses without preserving raw real-account payloads.
- Add signed-app verification against the selected real provider source when a trustworthy candidate is implemented.

Candidate research must not assume OpenAI or any other provider before evidence is reviewed.
Marketing pages, community examples, reverse-engineered clients, and observed but undocumented fields are not sufficient primary evidence for stable adapter acceptance.
An exact reset boundary must be reported by the provider and must not be inferred from timestamps, conventional periods, calendar boundaries, or polling cadence.
If every candidate lacks a trustworthy source, exact boundary, stable field contract, permissible authentication path, or safe data boundary, implementation must stop at an unavailable decision record.
That outcome must identify the rejected candidates, evidence reviewed, unmet requirements, and conditions that would permit reconsideration.
It must not include a fake adapter, guessed fixture contract, or acceptance claim.

## Acceptance criteria

- [ ] Candidate selection is based on current first-party provider documentation rather than an assumed OpenAI or other provider format.
- [ ] Exactly one API-provider path is selected for implementation when and only when it satisfies the required evidence contract.
- [ ] The selected source reports an exact quota reset boundary that LimitBar does not infer.
- [ ] The selected source reports a quota value with documented units and scope that can be represented without inventing capacity or weighting.
- [ ] The selected provider product, supported versions, account or project scope, fields, omitted fields, authentication access, confidence classification, limitations, and last verified date are documented.
- [ ] The stability rationale cites primary evidence and explains versioning, deprecation, or compatibility guarantees that are actually documented.
- [ ] Unknown provider behavior is labeled unknown and is not converted into a product guarantee.
- [ ] A positive allow-list admits only fields required by the normalized quota observation contract.
- [ ] Unknown and prohibited fields are not persisted, logged, exported, or made available to analytics.
- [ ] Provider-specific payload structures do not leak into provider-neutral analytics or product presentation.
- [ ] Normalized observations preserve provider product, observation identity, timestamp, exact window identity, provider-reported reset boundary, value, unit, scope, provenance, and adapter version.
- [ ] Duplicate retrieval produces one logical immutable observation and materially different corrections use explicit supersession.
- [ ] Missing or ambiguous exact boundaries fail closed and do not produce normalized quota observations.
- [ ] Calendar windows, billing periods without exact boundaries, and local aggregate periods are not substituted for provider-reported quota windows.
- [ ] Authorization failure, permission denial, unsupported scope, rate limiting, malformed data, missing required fields, format changes, and provider unavailability are distinct tested outcomes.
- [ ] The adapter declares a safe authentication boundary and does not persist credentials or raw authorization material.
- [ ] Retention and deletion behavior are bounded and independently testable.
- [ ] Synthetic and anonymized fixtures cover every accepted field and required failure mode.
- [ ] Fixture tests are not presented as proof of current real-account behavior.
- [ ] Signed-app acceptance confirms current real-provider behavior, exact boundaries, authentication behavior, and the positive allow-list for the documented supported version.
- [ ] If no candidate satisfies the requirements, the result states that the API-provider path is unavailable and records the primary evidence and unmet criteria.
- [ ] If no candidate satisfies the requirements, no adapter acceptance criterion is marked complete and no guessed adapter or provider format is shipped.

## Privacy and safety constraints

All acquisition, normalization, storage, and analysis must remain local by default.
Authentication must use the narrowest documented access required by the selected source.
Credentials, authorization headers, request bodies, raw responses, browser cookies, account labels, private paths, prompts, code, model responses, and terminal output are prohibited from persistence and export.
Logs and errors must pass through a positive allow-list and must not reproduce raw provider content.
Account aliases must be user-defined and must never contain credentials.
The adapter must not read outside its configured source or authentication boundary.
No browser automation or private-page scraping may be introduced as the core path.
No evidence report may be sent without explicit user action and preview.
Provider terms, documented access restrictions, and rate limits must be respected.
An inability to access trustworthy data safely must produce an unavailable result rather than a broader or undocumented collection method.

## Explicit non-goals

- Predetermining OpenAI, Anthropic API, Azure OpenAI, or any other provider before primary-source evaluation.
- Supporting more than one API-provider path in this ticket.
- Inferring Quota windows or Exact boundaries from calendar periods, billing labels, timestamps, or conventional reset schedules.
- Reverse-engineering undocumented provider payloads or private client behavior.
- Scraping private provider pages or automating a browser.
- Treating billing usage as quota evidence unless primary documentation supplies the required quota semantics and exact boundaries.
- Converting token usage into quota consumption through a guessed provider weighting formula.
- Adding project or agent attribution to collector schema v1.
- Building anomaly detection, workload planning, alerts, or cross-provider aggregation.
- Claiming adapter acceptance when only fixtures or secondary sources are available.
- Retaining raw provider payloads to simplify future compatibility work.

## Verification

Research verification must preserve a reviewable list of first-party sources, access dates, supported versions, exact quoted field semantics where licensing permits, and unresolved unknowns.
Contract tests must prove that only allow-listed documented fields can reach normalized observations.
Fixture tests must cover a valid observation, duplicates, a correction, missing reset boundary, ambiguous units, unsupported scope, authorization denial, rate limiting, malformed content, partial content, unknown fields, and a documented format-version transition.
Privacy tests must seed prohibited values into every untrusted field and prove that those values do not reach persistence, logs, diagnostics, or export.
Persistence tests must cover immutable observations, explicit supersession, bounded retention, independent deletion, and unknown-schema failure.
Signed-app verification must exercise the current documented source with a real user-controlled account and compare the normalized value and exact boundary with provider-reported evidence.
The verification record must state the provider product, source version, account scope, authentication behavior, observation units, last verified date, and all deviations from the primary documentation.
If real-provider verification cannot establish the required semantics, the adapter must remain unavailable regardless of fixture results.

## Blocked by

02 - [#24](https://github.com/talibilat/limit-bar/issues/24) - Explain Codex Quota Movement.

## Status

ready-for-agent
