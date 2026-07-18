# API Spend Reconciliation

## Scope

LimitBar's first reconciliation slice supports Anthropic organization cost reports only.
It does not claim that another provider has compatible grouping, billing, revision, or token semantics.

An explicit Anthropic **Validate & Refresh** action reads the existing admin API key from macOS Keychain and makes the organization requests.
No background task, Local Refresh Cycle, launch path, or passive Keychain check performs this refresh.

## Evidence Model

Each Provider-Reported Cost bucket retains its exact half-open UTC billing window, ISO currency, Anthropic provider product, model, and any dimensions actually returned by Anthropic.
The production request groups only by model, workspace identity, and API-key identity because those are the dimensions this slice can map explicitly to local evidence.
It does not request service tier, token class, or description grouping merely to create buckets the local side cannot attribute.
Raw organization, workspace, and API-key identities are discarded while the explicit response is imported.
Alias mappings are per exact raw identity and exist only during one explicit refresh.
An identity with no mapping is omitted before a persistable model exists.
Aliases equal to or deterministically derived from the raw identifier are rejected.
A configured workspace alias maps only to an exact schema v2 project alias, and a configured API-key alias maps only to an exact schema v2 agent alias.
No alias match is inferred.

Schema v2 project and agent events remain an Observed Local Breakdown.
During explicit reconciliation, an isolated API spend loader securely streams the configured Active Usage File and derives exact UTC-day breakdowns directly from strict schema v2 event timestamps.
The loader does not use `LocalUsageEventImporter` or `UsageDatabase` for local reconciliation evidence.
It never treats a local-calendar Today window as equal to an Anthropic UTC billing day.
Configured frozen pricing can produce a Calculated Cost for that local evidence.
Calculated Cost is explanatory and non-authoritative.
It is never added to Provider-Reported Cost.

The Reconciliation view displays these separate values:

- **Provider-Reported Cost** is the authoritative provider amount for one exact bucket.
- **Attributed Provider-Reported Cost** is at most the compatible local Calculated Cost and never exceeds Provider-Reported Cost.
- **Observed Local Calculated Cost** is the non-additive local explanation.
- **Unattributed Provider-Reported Cost** is the provider amount not explained by compatible local evidence.

## Compatibility

Reconciliation requires the same Provider product, Exact Usage Window, currency, model, service tier, token class, and configured identity aliases when those provider dimensions are present.
Service tier and token class remain unmatched when local evidence does not explicitly contain those semantics.
Missing, unmapped, incomplete, or incompatible evidence remains unattributed.
The UI reports typed barriers rather than assigning cost to a convenient project, agent, model, or alias.
Provider-Reported Cost and Calculated Cost are distinct in models, persistence input, rendering, CSV columns, and tests.

Costs across currencies, exact periods, Provider products, or provenance are never summed.
Provider buckets that differ only in a non-attributable cost description are aggregated within one otherwise exact authoritative identity before local evidence is applied.
One local Calculated Cost is never reused across multiple authoritative rows.

## Revisions And Retention

Sanitized refreshes are immutable revisions in `api-spend-reconciliation-v2.sqlite` using logical schema v3.
Each revision freezes its rendered reconciliation rows, Provider-Reported Cost buckets, pricing revision, exact local evidence digest and event count, and typed conclusion drift.
Later pricing or local-file changes do not reinterpret an earlier revision.
A late provider correction appends a revision, points to the superseded revision, and records Provider-Reported, attributed, Observed Local, unattributed, and status drift per compatible bucket.
It does not rewrite an earlier conclusion.

The dedicated store retains at most 366 revisions and 366 days.
Age and count pruning occur in the same transaction as a successful revision write.
Cancelled, failed, malformed, partial, and duplicate responses do not replace the latest revision.
An interrupted write rolls back.

Canonical pre-release schema v1 and v2 stores migrate transactionally to logical schema v3.
Every table and index SQL fingerprint is validated before any migration statement runs.
Lookalike, unknown, and malformed schemas fail closed without intentional mutation.
Legacy revisions are preserved as frozen, explicitly unavailable conclusions rather than being reinterpreted with current pricing.

**Delete Reconciliation Data** deletes only this dedicated store's rows.
It does not delete usage aggregates, schema v2 attribution, source files, pricing, settings, credentials, alerts, or delivery state.

## CSV Export

CSV export requires two explicit local actions: **Preview CSV**, then **Save CSV**.
The exact preview bytes are the bytes written to disk.
Schema v1 uses a positive allow-list defined by `SpendCSVArtifact.allowedColumns`.

The export can contain configured aliases, exact windows, supported normalized dimensions, separately labeled costs, reconciliation state, and compatibility barriers.
It cannot contain credentials, organization IDs, raw workspace IDs, raw API-key IDs or names, provider payloads, prompts, code, responses, traces, request bodies, paths, or arbitrary metadata.

## Anthropic Fixture

Tests use a synthetic organization fixture for one exact UTC day with model, workspace, API-key, service-tier, token-class, and cost-description dimensions.
The fixture is joined to schema v2 project and agent evidence for exact, partial, incompatible, and unattributed outcomes.
Production-path tests parse retained timestamped events under a non-UTC local calendar and verify the separate UTC-day evidence boundary.
Adversarial tests cover local-cost reuse, provider-only dimensions, per-identity aliases, frozen conclusions, canonical migrations, lookalike schemas, and prohibited-content persistence and CSV sentinels.

Last verified: **2026-07-18**.
