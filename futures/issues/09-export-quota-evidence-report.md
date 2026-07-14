# 09 - Export Quota Evidence Report

## Parent

Source plan: `futures/01-quota-doctor.md`.

## What to build

Extend LimitBar's existing privacy-safe diagnostic export with a bounded Quota Doctor evidence report.
The report must summarize selected quota evidence, derived findings, provenance, method metadata, limitations, resets, and evidence gaps through the existing positive allow-list.
The user must preview the exact report content before choosing a destination and explicitly saving it.
LimitBar must never upload the report automatically.

## Confirmed starting point

The existing Quota Insights foundation described by the parent already contributes coarse quota findings to the privacy-safe diagnostic export.
The existing export is governed by a positive allow-list and has automated export tests.
The parent specification requires Quota Doctor to extend that existing export rather than introduce an unrestricted evidence dump.
The parent specification requires the exact export to be previewed before the user chooses a destination.
The parent specification prohibits automatic upload of an evidence report.
Ticket 03 is expected to provide Claude Code explanation evidence when a trustworthy explicitly identified source exists.
Ticket 04 is expected to provide one documented API-provider quota path or a factual unavailable decision when no candidate satisfies the evidence contract.
Ticket 05 is expected to provide privacy-safe project and agent attribution, Observed Local Breakdowns, optional inferred allocation, and preserved unattributed movement.
Ticket 06 is expected to provide versioned and evaluated forecast results with traceable method metadata.
Ticket 07 is expected to provide versioned anomaly findings and explicit unavailable outcomes.
The final report format, field inventory, and bounds must be confirmed against representative fixtures and the existing export's privacy contract.

## Scope

- Extend the existing diagnostic export through its positive allow-list rather than adding a general serializer for quota storage.
- Add a bounded Quota Doctor section that is useful for user-reviewed support and forensic investigation.
- Preserve the existing export's exact preview-before-save workflow.
- Generate one immutable in-memory report candidate for preview and save that exact candidate after explicit user confirmation.
- Do not regenerate, refresh, enrich, reorder, or otherwise change the report between preview and save.
- Require the user to inspect the preview before destination selection becomes available.
- Require an explicit user action to choose a destination and a separate explicit confirmation to save when that distinction is part of the existing workflow.
- Return to preview when the underlying selected evidence or export options change so the user can review the newly generated exact content.
- Make the report generation time and selected evidence range clear without implying that generation time is a provider observation.
- Include only normalized, privacy-safe fields individually approved by the positive allow-list.
- Include the selected provider product only in a privacy-safe canonical form that does not expose an account label.
- Include exact selected time-range boundaries and the relevant timezone or calendar basis.
- Include provider-reported quota-window boundaries and reset boundaries only when they are present in normalized evidence.
- Represent missing exact boundaries as unavailable rather than inferred timestamps.
- Include bounded quota movement summaries with units and provenance.
- Include Observed Local Breakdowns only as separate explanatory evidence and never add them to an authoritative provider total.
- Include bounded unattributed movement so missing attribution is not silently assigned to known local activity.
- Include inferred allocation only when its method version, qualification, and limitations are included alongside it.
- Include qualified forecast ranges with observation count, observation span, evidence age, method version, reset interaction, and limitations.
- Include anomaly findings with current comparison period, baseline period, measured inputs, method version, result, qualification, and limitations.
- Include explicit unavailable reasons where omission would make the remaining evidence misleading.
- Include reset markers, relevant client or adapter versions when available, and privacy-safe evidence-gap descriptions.
- Distinguish a Gap from an Observed Zero in the exported representation.
- Distinguish no finding from analysis unavailable.
- Include stable bounded input-range identities or privacy-safe evidence references sufficient to trace a derived finding without exporting raw source records.
- Bound observations, findings, attribution entries, model or operation summaries, method metadata, limitations, and text lengths by explicit tested limits.
- Define deterministic ordering and truncation behavior so the preview is stable and omitted content is declared.
- State the applicable item limits and omitted-item counts when report content is truncated.
- Prefer aggregate summaries over event-level detail when both answer the same forensic question.
- Exclude optional fields by default unless their forensic value and privacy safety are demonstrated with fixtures.
- Maintain explicit provenance language in every report section.
- Label values supplied directly by a provider as Reported.
- Label values directly observed from supported sources as Measured.
- Label deterministic derived movement, rates, ranges, scores, and summaries as Calculated.
- Label estimates and allocations from incomplete evidence as Inferred.
- Never describe an Inferred value as a provider-reported quota.
- Preserve limitations and missing evidence next to the affected finding rather than placing all caveats in an unrelated footer.
- Provide a clear local success result after saving and a clear local error result if saving fails.
- Keep the reviewed report candidate available after a recoverable destination or write failure so retry does not silently change its contents.
- Avoid retaining an additional unbounded report history merely because a report was previewed or saved.
- Ensure cancellation at preview, destination selection, or save leaves no report at an unconfirmed destination.
- Preserve existing deletion and retention boundaries for source evidence independently of the saved user-directed report.

## Acceptance criteria

- [ ] Quota Doctor evidence is added only through explicit fields in the existing export positive allow-list.
- [ ] The export does not serialize quota storage records or derived findings wholesale.
- [ ] The user sees the exact complete report candidate before choosing a save destination.
- [ ] The bytes or textual content saved are exactly the content approved in preview.
- [ ] The report is not regenerated or refreshed between preview approval and save.
- [ ] Changing the selected evidence or export options invalidates approval and requires preview of the new exact report.
- [ ] No report is saved without explicit user action.
- [ ] No report is uploaded automatically or sent to any network destination.
- [ ] The report includes an exact selected range, relevant boundary information, provenance, and report generation time with unambiguous meanings.
- [ ] Missing reset or window boundaries remain unavailable and are never replaced by inferred exact timestamps.
- [ ] Authoritative provider totals and Observed Local Breakdowns are exported as separate concepts.
- [ ] Unattributed movement is preserved and is not forced onto known local activity.
- [ ] Inferred allocation includes its method, qualification, and limitations.
- [ ] Qualified forecasts include their range, evidence age, observation count, observation span, method version, reset interaction, and limitations.
- [ ] Anomaly findings include their current period, baseline period, measured inputs, result, method version, qualification, and limitations.
- [ ] Unsafe forecast, denominator, or baseline comparisons export unavailable with no numerical finding.
- [ ] Gaps and Observed Zero values have distinct exported representations.
- [ ] No finding and analysis unavailable have distinct exported representations.
- [ ] Relevant client or adapter versions are included only when available through approved normalized fields.
- [ ] Reported, Measured, Calculated, and Inferred classifications remain explicit throughout the report.
- [ ] Inferred values are never described as provider-reported or directly measured.
- [ ] Every exported derived finding includes a privacy-safe trace reference and its method version.
- [ ] Every variable-length collection and text field has a tested upper bound.
- [ ] Deterministic truncation preserves the most relevant evidence according to a documented rule and declares omitted-item counts.
- [ ] Equivalent inputs produce byte-for-byte identical report content apart from explicitly documented generation metadata.
- [ ] A recoverable destination or write failure can be retried without changing the already reviewed report candidate.
- [ ] Cancellation at any stage does not create a report at an unconfirmed destination.
- [ ] Raw prompts, code, model responses, terminal output, request bodies, credentials, private paths, account labels, and raw payloads are absent from previewed and saved reports.
- [ ] Preview rendering, accessibility content, error messages, and save results also exclude prohibited content.
- [ ] Existing non-Quota-Doctor diagnostic export behavior remains intact.

## Privacy and safety constraints

- The positive allow-list is the sole field-admission boundary for the report.
- Absence from the prohibition list is not sufficient reason to export a field.
- Raw prompts are prohibited.
- Source code and code excerpts are prohibited.
- Model responses are prohibited.
- Terminal output is prohibited.
- Request bodies are prohibited.
- Credentials, authorization material, browser cookies, and secrets are prohibited.
- Private paths and file locations are prohibited.
- Account labels and account-identifying aliases are prohibited.
- Raw provider, client, adapter, telemetry, and source payloads are prohibited.
- Free-form source error text is prohibited unless transformed into a fixed allow-listed category that cannot contain source data.
- Report content must remain local unless the user independently chooses what to do with the saved file after export.
- LimitBar must not automatically upload, attach, email, synchronize, or transmit the report.
- The destination chooser must not default to or reveal a private source path derived from evidence.
- Boundedness must apply before preview rendering so oversized evidence cannot bypass the report limits through the interface.
- A failed safety validation must block preview approval and saving rather than silently dropping an unknown field without explanation.
- Saved reports are user-directed artifacts and must not weaken retention or deletion controls for LimitBar's internal quota evidence.

## Explicit non-goals

- Exporting raw quota database rows or complete source records.
- Adding a general-purpose data dump, backup, or migration format.
- Exporting prompts, code, responses, terminal output, request bodies, credentials, private paths, account labels, or raw payloads.
- Automatically uploading or transmitting a report.
- Adding support-ticket submission, email delivery, cloud synchronization, or third-party sharing.
- Replacing the forensic investigation view.
- Recomputing attribution, forecasts, or anomalies inside export presentation logic.
- Claiming that an exported report is an official provider billing record.
- Exporting unsupported causal explanations for quota movement.
- Expanding retention of internal quota evidence after a user saves a report.
- Selecting new anomaly thresholds or analytical methods without fixture evidence.

## Verification

- Add an end-to-end export test that starts from representative quota evidence, opens the diagnostic export, previews the complete report, chooses a destination, saves, and compares the saved content with the approved preview.
- Verify the exact candidate remains unchanged when time passes or a background refresh publishes new evidence after preview.
- Verify a changed provider, time range, or export option invalidates the prior approval and requires a new preview.
- Verify cancellation before destination selection, during destination selection, and before save creates no output.
- Verify a recoverable write failure and retry use the same reviewed report candidate.
- Verify deterministic report ordering, field formatting, bounds, truncation rules, and omitted-item counts.
- Verify representative Reported, Measured, Calculated, Inferred, unavailable, no-finding, Observed Zero, and Gap states.
- Verify provider-reported resets and missing reset boundaries remain distinct.
- Verify authoritative totals, Observed Local Breakdowns, inferred allocations, and unattributed movement remain separate.
- Verify forecast and anomaly sections preserve exact periods, qualification, method versions, trace references, and limitations.
- Seed every prohibited content category with unique sentinels and verify none appears in preview content, saved content, accessibility content, error messages, logs, or destination defaults.
- Verify unknown and newly added source fields are excluded until explicitly added to the positive allow-list.
- Verify malformed, oversized, duplicate, out-of-order, and partially available normalized evidence cannot bypass bounds or safety validation.
- Verify no network request occurs during report generation, preview, destination selection, save, cancellation, or failure handling.
- Verify existing diagnostic sections remain stable when Quota Doctor evidence is absent.
- Run native application acceptance for preview, destination selection, save, cancellation, and write failure behavior.
- Document that fixture validation proves report behavior against the tested evidence contract but does not prove real-account provider semantics.

## Blocked by

- 03 - [#26](https://github.com/talibilat/limit-bar/issues/26) - Explain Claude Code Quota Movement.
- 04 - [#27](https://github.com/talibilat/limit-bar/issues/27) - Add API Provider Quota Path.
- 05 - [#28](https://github.com/talibilat/limit-bar/issues/28) - Attribute Project And Agent Work.
- 06 - [#25](https://github.com/talibilat/limit-bar/issues/25) - Version And Validate Quota Forecasts.
- 07 - [#29](https://github.com/talibilat/limit-bar/issues/29) - Detect Quota Consumption Anomalies.

## Status

ready-for-agent
