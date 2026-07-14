# 12 - Harden and Validate Quota Doctor

## Parent

Source plan: `futures/01-quota-doctor.md`.

## What to build

Harden the completed Quota Doctor capability across source compatibility, malformed input, persistence lifecycle, privacy boundaries, signed distribution, documented limitations, and real-user usefulness.
Every supported adapter must declare its compatibility and evidence contract and must be exercised with anonymized or synthetic fixtures for supported behavior and failure modes.
Quota observations and derived findings must survive supported schema migrations, obey bounded retention, support independent deletion, and fail safely for unknown schemas.
The signed LimitBar application must pass native acceptance against real supported local sources without treating fixture tests as proof of real-account behavior or macOS authorization policy.
A pilot with heavy coding-agent users must produce reviewable evidence about usefulness, forecast error, attribution coverage, false positives, and report quality without inventing numeric success thresholds absent from the parent specification.

## Confirmed starting point

The parent specification requires source adapters to remain isolated from normalization and analytics.
Each adapter must declare supported client or API versions, captured fields, omitted fields, authentication access, confidence classification, and last verified date.
The completed product must support at least two subscription clients and one API provider with stable, tested adapters.
Quota Doctor processing and storage remain local by default.
Retention must be bounded by age and count.
Users must be able to delete quota observations and derived findings independently from current usage, alert rules, Delivery Ledger state, provider settings, and credentials.
The parent specification requires synthetic and anonymized fixtures for every supported adapter and failure mode.
The parent specification requires signed-app native acceptance with real supported local sources.
The parent specification requires pilot evaluation of usefulness, forecast error, attribution coverage, false-positive rate, and report quality.
The parent specification does not define numeric success thresholds for the pilot or those evaluation dimensions.
Ticket 08 is expected to provide the forensic experience.
Ticket 09 is expected to provide the privacy-safe evidence export.
Ticket 10 is expected to integrate qualified findings with the existing alert architecture.
Ticket 11 is expected to provide evidence-based workload assessment.
The final adapter set, supported version ranges, fixture formats, distributed schema baseline, migration matrix, signed-app test environment, pilot cohort, pilot duration, and evidence collection protocol are unknown until the blocked work and release context are established.

## Scope

- Inventory every adapter that will be supported at release and assign an explicit stability status.
- Require every supported adapter to declare supported client or API versions.
- Require every supported adapter to declare captured fields and omitted fields.
- Require every supported adapter to declare authentication access and whether access can produce user-visible operating-system interaction.
- Require every supported adapter to declare confidence classification and last verified date.
- Require every supported adapter to declare its configured read boundary and verify that it cannot read outside that boundary.
- Document provider-specific quota units, exact-boundary availability, known weighting uncertainty, attribution limits, format risks, and authorization behavior.
- Define behavior for unsupported, newer, older, malformed, partially written, corrupted, and structurally changed source data.
- Fail closed when an adapter cannot safely recognize or normalize a supported source version.
- Keep adapter-specific parsing and access behavior isolated from normalized evidence and analytics.
- Create anonymized or synthetic fixtures for every supported adapter and every applicable success, edge, and failure mode.
- Include fixtures for missing fields, unknown fields, malformed records, corrupted data, partial writes, duplicates, out-of-order observations, counter decreases, resets, concurrent agents, version changes, and format changes where applicable.
- Ensure fixtures contain no copied credentials, prompts, code, model responses, terminal output, private paths, account labels, raw provider payloads, or other private source values.
- Mark fixture-derived results as test evidence rather than proof of real-account behavior.
- Verify immutable source observations and explicit supersession rather than silent historical rewrites.
- Define the schema migration matrix from every supported distributed schema and any explicitly supported pre-release schema.
- Preserve supported records and fields through migration transactions before unrelated retention or visibility policies run.
- Verify unknown-schema handling fails safely without destructive writes or misleading recovery claims.
- Verify retention bounds by both age and count for quota observations and derived findings.
- Verify quota observations and derived findings can be deleted independently where the product contract requires independent deletion.
- Verify deletion does not mutate current usage, alert rules, Delivery Ledger state, provider settings, or credentials.
- Verify application restart, interrupted writes, and supported migration paths do not violate deduplication, immutability, supersession, or deletion guarantees.
- Exercise the full forensic experience with measured, calculated, inferred, unavailable, Observed Zero, Gap, unattributed, and superseded evidence states.
- Exercise export preview, positive allow-list behavior, prohibited-content sentinels, explicit destination selection, and the prohibition on automatic upload.
- Exercise alert freshness, exact-boundary qualification, threshold deduplication, durable Delivery Ledger behavior, coarse notification copy, and quota-history deletion independence.
- Exercise workload planning with comparable, incompatible, incomplete, and insufficient historical samples.
- Verify the signed application through the existing LimitBar distribution process rather than accepting only an unsigned source build.
- Perform native acceptance with real supported local sources for each supported provider product where access is available.
- Verify relevant macOS authorization behavior from the signed application, including passive checks and explicit interactive authorization where an adapter requires them.
- Distinguish unavailable real-source access from a passed acceptance result.
- Document unsupported versions, missing evidence, provider-specific limitations, known false-positive conditions, known forecast limitations, and unsupported workload comparisons.
- Define a privacy-safe pilot protocol for heavy coding-agent users.
- Collect pilot evidence about whether users can explain quota movement or change scheduling decisions.
- Collect pilot evidence about forecast error using observed completed quota windows where comparison is valid.
- Collect pilot evidence about attribution coverage without forcing unattributed usage onto local activity.
- Collect pilot evidence about false-positive behavior for anomaly and alert findings.
- Collect pilot evidence about whether exported reports are understandable, useful, and free of prohibited content.
- Record evidence gaps, participant-visible limitations, adapter versions, method versions, and product versions with pilot observations.
- Analyze pilot outcomes qualitatively and quantitatively where the evidence supports quantification.
- Do not invent a pass threshold, sample size, forecast error target, attribution target, or false-positive target that is not established by an approved specification or validation decision.
- Convert unresolved pilot or acceptance failures into explicit release blockers or documented limitations based on user safety and claim validity.
- Confirm that the completed product supports at least two subscription clients and one API provider with stable, version-tested adapters before declaring Quota Doctor complete.

## Acceptance criteria

- [ ] Every release-supported adapter declares supported client or API versions, captured fields, omitted fields, authentication access, confidence classification, and last verified date.
- [ ] Every release-supported adapter has a documented configured read boundary and automated boundary-enforcement coverage.
- [ ] Adapter parsing and access behavior remain isolated from normalization and analytics.
- [ ] Unsupported or unrecognized source versions fail safely without manufacturing normalized evidence.
- [ ] Every supported adapter has anonymized or synthetic fixtures for its supported behavior and applicable failure modes.
- [ ] Fixtures cover malformed, corrupted, partially written, duplicate, out-of-order, reset, counter-decrease, version-change, and provider-format-change conditions where applicable.
- [ ] Fixtures and test artifacts contain no prohibited private source content.
- [ ] Fixture tests are not represented as proof of real-account behavior or macOS authorization policy.
- [ ] Source observations remain immutable and corrections use explicit supersession.
- [ ] Supported migration paths preserve supported quota observations, derived findings, provenance, method versions, exact boundaries, and supersession relationships through the migration transaction.
- [ ] Unknown schemas fail safely without destructive writes.
- [ ] Retention is bounded by both age and count and is covered by automated tests.
- [ ] Quota observations and derived findings support the required independent deletion behavior.
- [ ] Deletion does not mutate current usage, alert rules, Delivery Ledger state, provider settings, or credentials.
- [ ] Automated tests cover stable, flat, bursty, reset, decreasing-counter, missing-data, duplicate, out-of-order, concurrent-agent, version-change, malformed-file, and partial-write behavior.
- [ ] Automated tests prove traceability from each derived finding to its method and inputs or stable bounded input-range identity.
- [ ] Automated tests preserve distinct measured, calculated, inferred, unavailable, Observed Zero, Gap, unattributed, and superseded states.
- [ ] Export tests verify positive allow-list behavior, preview, prohibited-content sentinels, explicit user action, and no automatic upload.
- [ ] Alert tests verify freshness, exact active boundaries, threshold deduplication, restart durability, history-deletion independence, and coarse privacy-safe copy.
- [ ] Workload-planning tests verify comparable, incompatible, incomplete, and insufficient historical samples.
- [ ] The final signed application passes native acceptance against real supported local sources for each provider product claimed as supported.
- [ ] Signed-app acceptance verifies observation ingestion, deduplication, reset behavior, forecast qualification, attribution states, anomaly qualification, forensic explanation, deletion, export, alert integration, and workload-planning availability boundaries where supported evidence exists.
- [ ] Signed-app acceptance records unavailable source access or untestable authorization paths as unresolved rather than passed.
- [ ] Provider-specific limitations, supported versions, last verified dates, evidence gaps, and known failure behavior are documented for users and maintainers.
- [ ] A privacy-safe pilot with heavy coding-agent users is completed and its product version, adapter versions, method versions, and evidence limitations are recorded.
- [ ] Pilot evidence addresses usefulness, forecast error, attribution coverage, false-positive behavior, report quality, and whether users changed scheduling decisions.
- [ ] Pilot reporting does not claim unsupported statistical certainty or use invented numeric success thresholds.
- [ ] Pilot findings that invalidate a product claim or expose a privacy or safety defect block release until resolved or until the claim or support boundary is corrected.
- [ ] At least two subscription clients and one API provider have stable, version-tested adapters before Quota Doctor is declared complete.
- [ ] The completed capability is packaged through the existing signed LimitBar distribution.

## Privacy and safety constraints

All processing, fixtures, acceptance evidence, and pilot evidence must remain local by default unless a participant explicitly chooses an approved privacy-safe export.
Raw prompts, code, model responses, terminal output, request bodies, credentials, browser cookies, private paths, account labels, and raw provider payloads are prohibited from Quota Doctor storage, fixtures, exports, pilot evidence, and validation reports.
Adapters must use positive field allow-lists and must not read outside their configured boundaries.
Anonymization must remove private values rather than merely relabel a copied raw payload.
Synthetic fixtures are preferred whenever realistic behavior can be represented without real user data.
Project paths must be replaced with configured names or privacy-safe stable identifiers before persistence.
Account aliases must be user-defined and must never contain credentials.
No evidence report may be uploaded or sent automatically.
Pilot participation and any report sharing must be explicit and informed.
Pilot evidence must not weaken product retention or deletion guarantees.
Signed-app acceptance must not capture credentials or private source content in logs, screenshots, test artifacts, or reports.
Failed parsing, migration, authorization, or validation must not expose prohibited data or destroy the original evidence set.

## Explicit non-goals

- Adding new Quota Doctor product capabilities beyond the parent specification solely to satisfy hardening.
- Claiming support for an adapter version that has not been declared and verified.
- Treating synthetic or anonymized fixtures as proof of real-account behavior.
- Treating unsigned source-build behavior as signed-app acceptance.
- Inventing numeric pilot success thresholds, cohort sizes, forecast targets, attribution targets, or false-positive targets absent from an approved specification.
- Circumventing provider quotas, rotating accounts, or evading provider controls.
- Scraping private provider pages as a default capability.
- Persisting or exporting prohibited content.
- Replacing official billing or quota records.
- Claiming knowledge of undisclosed provider capacity or weighting.
- Automatically purchasing credits, changing plans, switching accounts, or changing provider configuration.
- Hiding unsupported versions, evidence gaps, failed acceptance paths, or known limitations to broaden a support claim.
- Declaring Quota Doctor complete with fewer than two stable subscription-client adapters and one stable API-provider adapter.

## Verification

- Run the complete automated core, persistence, schema, analytics, adapter, export, alert, planning, and privacy test suites.
- Run every supported adapter against its anonymized or synthetic success and failure fixtures.
- Run boundary-enforcement tests proving each adapter cannot read beyond its configured source boundary.
- Run migration tests from every supported distributed schema and explicitly supported pre-release schema.
- Run unknown-schema and interrupted-migration tests against preserved copies of the original database set.
- Run retention and independent-deletion tests across quota observations, derived findings, current usage, alert rules, Delivery Ledger state, provider settings, and credentials.
- Scan fixtures, logs, exports, screenshots, pilot artifacts, and validation reports for prohibited-content sentinels.
- Build and install the final signed application through the existing distribution path.
- Perform and record native acceptance with each real supported local source and relevant macOS authorization state.
- Record the exact app, adapter, client, API, schema, and method versions used for acceptance.
- Execute the privacy-safe pilot protocol and retain reviewable aggregate findings and limitations.
- Compare forecast ranges with held-out observed windows only where exact boundaries and sufficient evidence make comparison valid.
- Review attribution coverage while preserving unattributed consumption rather than forcing complete allocation.
- Review anomaly and alert false positives against the method's qualification rules and available evidence.
- Review exported reports for usefulness, comprehensibility, provenance language, limitations, and prohibited content.
- Produce a release validation record that identifies passed checks, failed checks, unavailable checks, supported versions, and unresolved limitations without inventing numeric thresholds.

## Blocked by

- 08 - [#32](https://github.com/talibilat/limit-bar/issues/32) - Add Forensic Investigation View.
- 09 - [#31](https://github.com/talibilat/limit-bar/issues/31) - Export Quota Evidence Report.
- 10 - [#33](https://github.com/talibilat/limit-bar/issues/33) - Alert On Qualified Findings.
- 11 - [#30](https://github.com/talibilat/limit-bar/issues/30) - Assess Planned Workload.

## Status

ready-for-agent
