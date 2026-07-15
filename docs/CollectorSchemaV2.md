# LimitBar Local Usage Collector Schema v2

Schema v2 is the smallest explicit extension of [collector schema v1](CollectorSchemaV1.md) for producer-supplied project and agent attribution.
It preserves v1 source identity, timestamp, model, Azure deployment, token-delta, file, rate, rotation, and retention semantics.
It does not reinterpret or add fields to schema v1.

## Request Contract

Every v1 field remains required or optional exactly as documented for v1, except `schemaVersion` must be the integer `2`.
Schema v2 adds only these allow-listed optional fields:

| Field | Contract |
| --- | --- |
| `projectID` | Optional privacy-safe stable project identifier supplied explicitly by the producer or configured by the user. |
| `projectLabel` | Optional display label that requires `projectID`. |
| `agentID` | Optional privacy-safe stable agent identifier supplied explicitly by the producer or configured by the user. |
| `agentLabel` | Optional display label that requires `agentID`. |

An omitted project or agent remains unknown.
LimitBar does not invent an identifier or label.
Labels are display metadata and identifiers are opaque grouping dimensions.
Neither is a provider product, provider account, quota scope, credential, or authorization boundary.

Example:

```json
{"schemaVersion":2,"eventID":"fa2d37c5-1c49-49c8-88c4-6eebe339c6c7","provider":"openAI","timestamp":"2026-07-12T10:00:00Z","model":"gpt-5","inputTokens":100,"outputTokens":20,"projectID":"limitbar","projectLabel":"LimitBar","agentID":"reviewer-1","agentLabel":"Reviewer 1"}
```

## Bounds And Privacy

Identifiers are 1 through 64 ASCII bytes.
They must start with an ASCII letter or digit and may then contain only ASCII letters, digits, `.`, `_`, and `-`.

Labels are 1 through 64 ASCII bytes.
They must start and end with an ASCII letter or digit and may contain only ASCII letters, digits, spaces, `.`, `_`, `(`, `)`, and `-`.

Values are not trimmed or otherwise normalized.
Empty, overlong, non-ASCII, control-character, path-like, and malformed values are rejected.
Values beginning with common credential forms such as `sk-`, `ghp_`, `github_pat_`, `Bearer `, `AKIA`, or `xox` are rejected case-insensitively.
Values are also split on the allowed separators, and components equal to `password`, `passwd`, `secret`, `token`, `apikey`, `credential`, `credentials`, `privatekey`, or `accesskey` are rejected.
An adjacent `api` and `key` component is rejected as well.
This deterministic policy catches declared credential forms but does not claim to detect every arbitrary secret-looking string.
Validation errors identify only the rejected field and never reproduce its value.

The positive field allow-list rejects prompts, code, responses, terminal output, command lines, process arguments, environment values, credentials, request bodies, raw provider payloads, and arbitrary metadata.
Producers must not transform those prohibited inputs into labels or identifiers.
Raw filesystem paths and repository metadata must be replaced before submission with a user-configured label or a privacy-safe stable identifier.
LimitBar does not inspect a path, prompt, process, command, or runtime payload to derive attribution.

## Identity And Retries

Generate and persist the opaque Event ID before submission.
Retry the same complete event with the same Event ID.
An identical schema v2 retry is a Duplicate and consumes neither usage nor additional rate capacity.
Changing project or agent attribution under the same Event ID is an Event ID Conflict.
Schema version is material canonical content, so changing between v1 and v2 under one Event ID is also a conflict even when the shared usage fields match.
Idempotency remains bounded to the Active Usage File.

The CLI defaults to schema v1 for compatibility.
Use `--schema-version 2` explicitly before supplying any project or agent option.
When `--schema-version` is present, only the exact values `1` and `2` are accepted; malformed or unsupported values never default to v1.

```sh
swift run --package-path LimitBarCore limitbar-collect \
  --schema-version 2 \
  --event-id fa2d37c5-1c49-49c8-88c4-6eebe339c6c7 \
  --provider openAI \
  --timestamp 2026-07-12T10:00:00Z \
  --model gpt-5 \
  --input-tokens 100 \
  --output-tokens 20 \
  --project-id limitbar \
  --project-label LimitBar \
  --agent-id reviewer-1 \
  --agent-label "Reviewer 1"
```

## Aggregation And Provenance

Validated schema v2 events contribute once to the existing parent Usage Aggregate, exactly like schema v1 events.
Attributed events also produce a separate `ObservedLocalAttributionBreakdown` grouped only by compatible source identity, provider product, model, deployment, exact calendar window, project attribution, and agent attribution.
Each breakdown retains its exact Event IDs and measured token deltas.
The breakdown is not another Usage Aggregate and must not be added to its parent total.
Existing aggregate `projectLabel` values are not treated as event-level schema v2 attribution.

These calendar aggregates are not exact provider quota windows.
Token counts are not converted to quota percentages.
LimitBar does not allocate account-level quota movement among concurrent projects or agents.
The Codex explanation path therefore continues to preserve provider-reported quota movement as unattributed even when local measured breakdowns exist.

The Active Usage File remains the retained event evidence.
Its existing age and byte bounds apply equally to v1 and v2, and rotation removes project and agent values with their event.
Normalized attribution breakdowns are durably retained in the separate `usage-metrics-attribution.sqlite` store rather than changing the distributed Usage Aggregate schema.
The attribution store retains at most 10,000 rows and removes rows whose latest measured event is older than 30 days.
It stores only source identity, a bounded SHA-256 source revision, exact calendar scope, model and deployment, validated attribution, token deltas, exact Event IDs, and timestamps.
The importer computes that revision incrementally from the exact file-descriptor bytes it parses; it never rereads the path after import, so atomic path replacement cannot pair one file's breakdown with another file's revision.
It never stores a raw JSONL line, unknown field, prompt, response, command, path, credential, or provider payload.

A failed built-in or custom import has no source revision and never replaces durable attribution.
The last valid parent Usage Aggregates and attribution breakdowns remain available together.
Attribution store open, schema, read, or write failures mark snapshot health unavailable with fixed safe copy while preserving main metrics and the last valid in-memory attribution snapshot.

Deleting attribution evidence deletes only that separate normalized store.
It does not delete parent Usage Aggregates, current usage, Active Usage Files, provider settings, credentials, alert rules, or Delivery Ledger state.
Deletion also records each source's current content revision so an unchanged file cannot recreate deleted attribution on refresh or restart.
A changed Active Usage File has a different SHA-256 revision and can produce new measured attribution.
Deletion suppressions use the same 30-day and 10,000-record bounds, so they do not become unbounded lifetime state.
Importing a removed or empty file clears the corresponding current breakdowns.
Archives remain outside ingestion.

Settings provides a destructive **Delete Project And Agent Attribution** action with confirmation and explicit success or failure state.
Failure leaves durable and in-memory attribution available.
Clean database recovery archives `usage-metrics.sqlite`, `usage-metrics-attribution.sqlite`, and each database's WAL and SHM files as one recovery set before creating clean stores.

## Producer Support And Verification

The supported producer is the repository's `limitbar-collect` CLI implementing LimitBar collector schema v2, not an inferred native runtime format.
No Codex, Claude Code, or other third-party runtime is integrated as a measured project or agent producer in this change.
The Codex evidence review in [CODEX_SESSION_EVIDENCE.md](CODEX_SESSION_EVIDENCE.md), last verified 2026-07-15 against first-party OpenAI Codex 0.144.4 source, establishes that Codex rollout token records have no explicit privacy-safe project identifier or token-to-agent link.
LimitBar therefore does not read `cwd`, Git metadata, prompts, responses, commands, or nearby turn metadata to populate schema v2.

Manual and automated end-to-end verification invoked `limitbar-collect` from this repository, wrote a temporary Active Usage File, and loaded it through `UsageDatabase` and the production importer and attribution store.
The verified command shape was the schema v2 example above with `provider=openAI`, `model=gpt-5`, project ID and label, agent ID and label, input and output token deltas, and an explicit output path.
Verification confirmed `accepted`, an identical `duplicate`, an Event ID Conflict after changing project attribution, two exact-calendar breakdowns, durable restart loading, and independent deletion without changing the parent metrics, Active Usage File, settings markers, credential marker, alert-rule marker, or Delivery Ledger satisfaction.
The verified schema version is LimitBar collector schema v2.
The verification date is 2026-07-15.

No trace, session, operation, tool, provider quota percentage, credential, path, prompt, response, command, environment value, or raw provider field was supplied or persisted.
This verifies the supported LimitBar CLI producer only.
It is not evidence that any current third-party runtime emits measured project or agent attribution.

Last verified: **2026-07-15**.
