# 05 - Attribute Project And Agent Work

## Parent

Source plan: `futures/01-quota-doctor.md`.

## What to build

Evolve the normalized ingestion contract so user-owned producers can supply bounded project and agent attribution alongside usage evidence.
The evolution must use a new versioned ingestion path while preserving collector schema v1 behavior, identity rules, and idempotency.
The resulting evidence must support Observed Local Breakdowns by project and agent without turning local labels into provider-reported quota attribution.
Optional allocation of an account-level quota delta across concurrent work may be added only as a separately labeled inferred result with a documented method and limitations.

## Confirmed starting point

Collector schema v1 accepts exactly one source identity, which is either a provider or a custom source.
Collector schema v1 also accepts a timestamp, a model, an optional Azure deployment, and input and output token deltas.
Collector schema v1 has no provider-product, trace, project, session, agent, operation, or tool fields.
Collector Usage Events use an opaque producer-generated UUID as the Event ID.
An identical retry within the Idempotency Horizon is a Duplicate.
Reusing an Event ID for different Usage Event content is an Event ID Conflict.
Existing usage aggregates can carry an optional project label and model.
Existing usage aggregate calendar windows are not Quota windows and do not establish Exact boundaries.
The parent requires optional trace, project, session, agent, model, operation, and tool identifiers only when they come from allow-listed sources.
The parent requires authoritative provider totals, Observed Local Breakdowns, inferred allocation, and unattributed usage to remain distinct.
No canonical producer format, project identifier, agent identifier, trace convention, or concurrent-allocation formula is confirmed by the parent.

## Scope

- Define a new explicit schema version for normalized usage ingestion rather than changing the meaning of schema v1 fields.
- Preserve acceptance, validation, duplicate detection, conflict detection, rate capacity, rotation, and Active Retention behavior for schema v1.
- Preserve the schema v1 rule that each event has exactly one Provider or Custom Source identity.
- Preserve Event ID as the idempotency identity across identical retries.
- Define how schema version participates in event validation and canonical content comparison without allowing the same Event ID to represent different content silently.
- Add optional bounded project attribution and optional bounded agent attribution to the new ingestion version.
- Define each field's semantics, allowed character set, normalization, byte or character limit, empty-value behavior, and rejection behavior.
- Distinguish a user-facing label from a privacy-safe stable identifier where both are needed.
- Require labels and identifiers to be supplied explicitly by the producer or configured by the user.
- Do not derive project identity from a raw filesystem path or derive agent identity from prompt, response, command, process arguments, or terminal output.
- Ensure that project and agent values are opaque attribution dimensions and are not interpreted as provider products, account identities, quota scopes, or credentials.
- Preserve the original Usage Event timestamp and per-event input and output token deltas.
- Carry source identity, model, optional Azure deployment, project attribution, and agent attribution through validation, persistence, aggregation, retention, and deletion without changing their provenance.
- Define behavior for missing project attribution, missing agent attribution, unknown identifiers, invalid values, and values that exceed bounds.
- Aggregate measured usage by project and agent only within compatible source, provider-product, model, time, and evidence scopes.
- Prevent project and agent breakdowns from being added to their parent total as additional usage.
- Present project and agent totals as Observed Local Breakdowns based on measured Usage Events.
- Keep usage aggregate calendar windows distinct from exact provider quota windows.
- Define the correlation boundary by which attributed Usage Events can support a quota explanation without claiming that token deltas equal quota consumption.
- Preserve unattributed consumption when provider quota movement cannot be matched safely to measured local work.
- Support independent deletion and bounded retention of project and agent attribution evidence.
- Version any derived attribution or allocation method and retain traceability to its exact input events or a stable bounded input-range identity.
- Document producer guidance for stable Event IDs, bounded labels, privacy-safe identifiers, retries, conflicts, and version negotiation.

The source and semantics of project and agent identity vary by producer and are currently unknown.
The implementing agent must use primary documentation for any integrated runtime or producer before declaring its fields measured.
Undocumented or inferred runtime metadata must not be normalized as measured project or agent identity.
The minimal required delivery is measured project and agent attribution from an explicitly versioned producer contract.
Allocation of provider-reported quota movement across concurrent work is optional.
If concurrent allocation is implemented, it must remain a derived inferred finding and must never mutate or replace measured Usage Events or provider quota observations.

## Acceptance criteria

- [ ] A new ingestion schema version accepts optional project and agent attribution under an explicit documented contract.
- [ ] Collector schema v1 remains accepted with exactly its existing source identity, timestamp, model, optional Azure deployment, and input and output token delta semantics.
- [ ] Schema v1 does not gain implicit defaults or reinterpretation for provider product, trace, project, session, agent, operation, or tool fields.
- [ ] Existing schema v1 producers continue to receive the same validation, duplicate, conflict, rate-capacity, rotation, and retention behavior.
- [ ] An identical retry of a new-version event with the same Event ID is a Duplicate rather than new usage.
- [ ] Reusing an Event ID with any materially different normalized content, including project or agent attribution, is an Event ID Conflict.
- [ ] A version change cannot be used to submit different event content under an existing Event ID without conflict.
- [ ] Project and agent labels and identifiers have documented, enforced bounds and a restricted privacy-safe character policy.
- [ ] Empty, malformed, overlong, control-character, path-like, credential-like, and otherwise prohibited attribution values are rejected or omitted according to a documented deterministic rule.
- [ ] Raw filesystem paths are never persisted as project labels or identifiers.
- [ ] Prompts, code, responses, terminal output, command lines, process arguments, credentials, and raw provider payloads cannot populate project or agent attribution.
- [ ] Missing project and agent attribution remains unknown and is not replaced with an inferred label.
- [ ] Measured project and agent breakdowns retain source provenance and can be traced to exact Usage Event identities or a stable bounded input-range identity.
- [ ] Project and agent breakdowns are labeled as Observed Local Breakdowns rather than provider-reported totals.
- [ ] Breakdown values are not added to their parent usage total as additional consumption.
- [ ] Existing optional aggregate project labels are not treated as event-level project attribution unless compatible semantics and provenance are explicitly established.
- [ ] Calendar usage aggregates are not treated as exact provider quota windows.
- [ ] Correlation with quota movement requires compatible provider-product evidence and an exact provider quota window from another qualified source.
- [ ] Token deltas are not converted into quota percentages without a documented evidence-supported method.
- [ ] Provider quota movement that cannot be attributed safely retains an explicit unattributed portion.
- [ ] Concurrent work does not force an allocation of all provider quota movement across observed projects or agents.
- [ ] If concurrent allocation is implemented, it is labeled inferred, uses a versioned documented method, records inputs and limitations, and remains distinct from measured evidence.
- [ ] If concurrent allocation is not implemented, measured project and agent breakdowns remain complete for the scope of this ticket.
- [ ] Retention and deletion remove attribution evidence according to the same bounded local policy without changing provider settings, credentials, alert rules, or delivery state.
- [ ] Integrated producer semantics and supported versions are backed by current primary-source evidence and a recorded last-verified date.
- [ ] Unknown producer metadata remains unknown rather than being guessed from unstable or undocumented fields.
- [ ] Automated tests cover both schema versions, retries, conflicts, invalid attribution, missing attribution, aggregation, retention, deletion, concurrency, and provenance separation.

## Privacy and safety constraints

All ingestion, persistence, aggregation, and attribution must remain local by default.
Project and agent labels must be bounded values explicitly supplied by a producer or configured by the user.
Stable identifiers must be opaque, bounded, and privacy-safe.
Raw filesystem paths must be replaced before ingestion with configured names or privacy-safe stable identifiers.
The ingestion contract must use a positive field allow-list.
Raw prompts, code, model responses, terminal output, request bodies, command lines, process arguments, environment values, credentials, browser cookies, private paths, account labels, and raw provider payloads are prohibited.
Validation errors, logs, diagnostics, and exports must not reproduce rejected sensitive values.
One configured source must not read outside its configured file boundary.
Retention must remain bounded by age and count.
Users must be able to delete attribution evidence without deleting provider settings or credentials.
No report may be sent without explicit user action and preview.
Labels must not be treated as authorization boundaries or trusted instructions.

## Explicit non-goals

- Removing, replacing, or silently changing collector schema v1.
- Requiring existing schema v1 producers to emit project or agent metadata.
- Adding all optional trace, session, operation, or tool dimensions in this ticket.
- Discovering project identity from filesystem paths, repository contents, prompts, code, commands, or process inspection.
- Discovering agent identity from free-form text or undocumented runtime internals.
- Treating project or agent labels as provider-reported quota scopes.
- Claiming that token contribution equals quota contribution.
- Forcing complete allocation of account-level quota movement across concurrent local work.
- Treating inferred allocation as measured evidence.
- Inferring exact quota boundaries from usage aggregate calendar windows.
- Building anomaly detection, forecasting, workload planning, alerts, or a complete forensic interface.
- Persisting raw producer payloads for later extraction.

## Verification

Contract tests must submit valid schema v1 and new-version events through the same user-visible collector boundary.
Those tests must verify acceptance, stable Event ID behavior, identical retries, Event ID conflicts, and unchanged schema v1 semantics.
Boundary tests must cover absent values, maximum accepted lengths, overlong values, control characters, Unicode handling under the documented ASCII policy, path-like values, credential-like values, and malformed identifiers.
Aggregation tests must prove that project and agent breakdowns reconcile only within their measured local scope and are not double-counted with parent totals.
Correlation tests must prove that calendar aggregates do not become Quota windows with Exact boundaries and that incompatible provider products cannot be joined.
Concurrency tests must cover multiple projects and agents active during one account-level quota interval while preserving unattributed movement.
If inferred allocation is implemented, deterministic tests must verify method version, exact inputs, limitations, inferred labeling, and preservation of measured source records.
Privacy sentinel tests must place prohibited content in accepted, unknown, and rejected input fields and prove that it does not reach storage, logs, diagnostics, or export.
Retention and deletion tests must cover both schema versions and must prove that unrelated settings, credentials, alert rules, and delivery state remain intact.
Manual verification must use at least one explicitly supported producer that emits bounded project and agent values under the new versioned contract.
The verification record must cite current primary documentation for producer semantics, list supported versions, state the last verified date, and identify all unknown or omitted fields.

## Blocked by

02 - [#24](https://github.com/talibilat/limit-bar/issues/24) - Explain Codex Quota Movement.

## Status

ready-for-agent
