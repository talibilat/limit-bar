# 02 - Explain Codex Quota Movement

## Parent

Source plan: `futures/01-quota-doctor.md`.

This ticket delivers a narrow, complete Codex explanation path after the Quota Insights foundation is landed.

## What to build

Build an end-to-end Codex explanation path that correlates movement in one exact Codex quota window with trustworthy structured local evidence.
The path must ingest only explicitly allow-listed fields, preserve enough bounded evidence for correlation, produce a traceable Observed Local Breakdown when correlation is safe, preserve unattributed quota movement, and display unavailable when the evidence cannot support a safe comparison.

The explanation must keep authoritative quota movement distinct from local token or activity evidence.
It must not add an Observed Local Breakdown to an authoritative provider total or imply that local tokens have the same unit or weighting as provider-reported percentage movement.

## Confirmed starting point

- Ticket 01 is required because current `main` lacks the PR #22 Quota Insights foundation.
- PR #22 is open and unmerged on branch `ticket-14-quota-insights`.
- PR #22 had green CI at the last inspection.
- PR #22 provides measured Codex quota percentages and exact reset identities once landed.
- The current Codex scanner searches a bounded set of recent JSONL files and extracts only the freshest `rate_limits` report.
- The current Codex scanner does not retain `token_count` events.
- Existing Usage Aggregates cover daily, weekly, and provider billing windows.
- Existing Usage Aggregates cannot by themselves explain exact intra-window Codex quota deltas.
- Codex quota percentage movement is authoritative for its quota window, while local structured activity is supporting evidence rather than an authoritative allocation.
- Provider weighting may depend on undisclosed factors, so token counts cannot be converted directly into quota percentage consumption without a documented and validated method.
- The exact structured `token_count` variants, field stability, client-version coverage, and identifier availability across supported Codex versions are not yet established by this ticket description.
- It is unknown whether every quota movement interval has complete local event coverage.
- It is unknown whether concurrent activity from other clients, machines, or sessions can contribute to the same account-level quota window.
- It is unknown whether available local identifiers are sufficient to attribute movement below the level supported by each event.

## Scope

- Establish the supported Codex client versions and structured event variants before accepting fields from them.
- Define a positive allow-list for the minimum local structured fields needed to correlate activity with quota observations.
- Reject or ignore all fields that are not explicitly required for the explanation path.
- Preserve exact event timestamps and only the privacy-safe identifiers and normalized counts proven necessary for correlation.
- Replace private project paths with configured names or privacy-safe stable identifiers before persistence when project identity is supported.
- Keep local evidence retention bounded by age and count.
- Handle duplicate events and repeated scans without double-counting supporting activity.
- Handle partially written files, malformed lines, unsupported event variants, unsupported client versions, and source replacement without treating incomplete evidence as complete.
- Enforce the scanner's bounded file-search behavior and configured file boundary.
- Correlate local evidence only with quota observations from the same provider product and exact provider-reported quota window.
- Use observation timestamps to define the exact interval whose quota movement is being explained.
- Treat a reset, counter decrease, missing boundary, non-overlapping evidence, or incompatible evidence as a barrier to direct correlation.
- Record the exact quota observations and bounded local evidence identity used by each explanation.
- Present authoritative quota movement separately from the Observed Local Breakdown.
- Represent the remainder of authoritative quota movement as unattributed when local evidence does not account for all activity safely.
- Avoid assigning provider percentage units to local token counts unless a separately documented and validated allocation method exists.
- If an allocation method is introduced, classify its output as inferred and expose its method version, assumptions, limitations, and unattributed remainder.
- Display unavailable when event coverage, timestamps, exact window identity, source compatibility, or correlation safety is insufficient.
- Show evidence gaps and unsupported-source reasons in language that does not imply zero usage.
- Deliver the result through the Quota Doctor forensic experience available at implementation time rather than adding another standalone quota gauge.
- Extend privacy-safe diagnostics only with bounded explanation findings and approved metadata needed to review failures.
- Make source interpretation independent from normalized correlation and presentation so unsupported provider-specific details do not leak into analytics.

## Acceptance criteria

- [ ] A supported Codex structured source can supply the minimum allow-listed local evidence needed for an explanation interval.
- [ ] Supported Codex client versions, accepted event variants, accepted fields, omitted fields, confidence classification, and last verified date are documented.
- [ ] Unknown event types and unknown fields are ignored or rejected without entering persistent explanation evidence.
- [ ] Raw prompts, code, responses, terminal output, request bodies, credentials, private paths, account labels, and raw event payloads are not persisted or exported.
- [ ] Repeated bounded scans do not double-count identical local evidence.
- [ ] Partially written records and malformed records do not become trusted supporting evidence.
- [ ] Unsupported client versions and incompatible event variants produce an explicit unavailable or unsupported state.
- [ ] Correlation uses two measured quota observations from the same exact active Codex quota window.
- [ ] Correlation never spans a provider-reported reset boundary.
- [ ] Counter decreases and reset transitions do not produce a positive consumption explanation.
- [ ] The explanation identifies the exact observation interval and the bounded supporting-evidence interval.
- [ ] The authoritative Codex quota movement is displayed separately from the Observed Local Breakdown.
- [ ] Local token counts remain in their measured local units and are not presented as authoritative quota percentage consumption.
- [ ] The Observed Local Breakdown is not added to the authoritative quota movement as extra consumption.
- [ ] Concurrent local activity is represented only at the granularity supported by explicit, trustworthy identifiers.
- [ ] Quota movement not safely attributable to observed local evidence remains explicitly unattributed.
- [ ] Missing local evidence is represented as a Gap or unavailable evidence rather than Observed Zero.
- [ ] A trustworthy interval containing supported local evidence with normalized zero counts can remain distinct as an Observed Zero.
- [ ] Missing exact boundaries, incomplete coverage, incompatible timestamps, unsupported formats, or unsafe comparisons display unavailable with a factual reason.
- [ ] No project, session, model, agent, operation, or tool attribution is shown unless the corresponding identifier is explicitly available from an allow-listed supported source.
- [ ] Any inferred allocation is visibly labeled inferred and includes a versioned method, input identities, assumptions, limitations, and an unattributed remainder.
- [ ] Every explanation is traceable to its exact quota observation identities and a stable bounded identity for the local supporting evidence.
- [ ] Explanation evidence and derived findings obey bounded age and count retention.
- [ ] Users can delete retained Codex explanation evidence and derived findings without deleting unrelated current usage, settings, credentials, alert rules, or delivery state.
- [ ] The user-facing result explains what is known, what is locally observed, what remains unattributed, and why any requested correlation is unavailable.
- [ ] Privacy-safe diagnostic output contains only allow-listed bounded findings and method metadata.
- [ ] Automated tests cover complete, incomplete, duplicate, out-of-order, malformed, partially written, reset-crossing, counter-decreasing, concurrent, unsupported-version, and unattributed scenarios.
- [ ] Signed-application acceptance confirms the path with a supported real Codex source and does not present fixture behavior as proof of all real-account behavior.

## Privacy and safety constraints

- Processing and storage must remain local by default.
- The Codex source adapter must use a positive field allow-list.
- The adapter must not read outside its configured file boundary.
- Raw JSONL records must not be copied into Quota Doctor storage or diagnostics.
- Raw prompts, code, responses, terminal output, request bodies, credentials, browser data, private paths, account labels, and raw provider payloads are prohibited.
- Project paths must be replaced before persistence by configured names or privacy-safe stable identifiers when project attribution is supported.
- Retention must be bounded by both age and count.
- A user must be able to delete retained explanation evidence and findings independently of unrelated application data.
- Exports must remain previewable and must never be uploaded automatically.
- Local activity must not be represented as proof of complete account-level activity.
- Inferred allocation must never be labeled reported or measured.
- Missing evidence must never be converted into zero consumption.
- Unsupported or unsafe evidence must fail closed to unavailable rather than producing a speculative explanation.

## Explicit non-goals

- Discovering or claiming Codex's undisclosed quota weighting formula.
- Converting local token counts directly into authoritative quota percentages without validated evidence.
- Forcing every provider-observed quota delta onto known local activity.
- Treating daily or weekly Usage Aggregates as exact intra-window evidence.
- Reading raw prompt, response, code, terminal, credential, or private-path content.
- Scanning unbounded local history.
- Supporting every historical or future Codex event format without explicit version verification.
- Attributing remote, concurrent, or otherwise unobserved account activity to the local machine.
- Building Claude Code attribution in this ticket.
- Adding anomaly detection, workload planning, or alert delivery.
- Creating another menu-bar quota gauge.
- Scraping private provider pages.

## Verification

- Build fixtures from synthetic or safely anonymized structured records for every declared supported Codex version and event variant.
- Verify the positive allow-list by placing prohibited-content sentinels in all ignored fields and confirming that none reaches persistence, UI findings, logs intended for support, or exports.
- Verify bounded scans, configured file boundaries, repeated scans, append behavior, atomic replacement, malformed lines, and partially written final records.
- Verify duplicate detection across identical retries and repeated application refreshes.
- Verify correlation against quota observations in one exact window and reject evidence across resets or mismatched windows.
- Verify safe behavior for out-of-order quota observations and out-of-order local events.
- Verify intervals with complete local evidence, partial local evidence, no local evidence, measured zero local evidence, unsupported versions, and concurrent sessions.
- Verify that displayed authoritative movement, Observed Local Breakdown, inferred allocation if any, and unattributed usage remain visually and semantically distinct.
- Verify that no local count is added to a provider percentage total.
- Verify that every displayed explanation can be traced to versioned source interpretation and bounded input identities.
- Verify independent retention and deletion without changing unrelated state.
- Verify the exact privacy-safe diagnostic preview and confirm that no automatic transmission occurs.
- Run signed-application acceptance with a supported real Codex source and compare observed behavior with the declared adapter version support.
- Record remaining coverage limitations, including activity from other machines or unsupported clients, as limitations rather than assuming completeness.

## Blocked by

01 - [#23](https://github.com/talibilat/limit-bar/issues/23) - Land Quota Insights Foundation.

## Status

ready-for-agent
