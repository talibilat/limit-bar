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
Values beginning with common credential forms such as `sk-`, `ghp_`, `github_pat_`, `Bearer `, or `AKIA` are rejected case-insensitively.
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

The Active Usage File is the retained event evidence.
Its existing age and byte bounds apply equally to v1 and v2, and rotation removes project and agent values with their event.
Importing a removed or empty file removes the corresponding current breakdown result without changing provider settings, credentials, alerts, or delivery state.
Archives remain outside ingestion.

## Producer Support And Verification

The supported producer contract is LimitBar collector schema v2, not an inferred native runtime format.
No Codex, Claude Code, or other third-party runtime is integrated as a measured project or agent producer in this change.
The Codex evidence review in [CODEX_SESSION_EVIDENCE.md](CODEX_SESSION_EVIDENCE.md), last verified 2026-07-15 against first-party OpenAI Codex 0.144.4 source, establishes that Codex rollout token records have no explicit privacy-safe project identifier or token-to-agent link.
LimitBar therefore does not read `cwd`, Git metadata, prompts, responses, commands, or nearby turn metadata to populate schema v2.

Automated fixtures verify the LimitBar producer boundary and local aggregation.
Real-producer manual verification remains unavailable until a producer intentionally implements this documented schema and explicitly supplies bounded project and agent values.
That limitation must not be represented as evidence that any current third-party runtime emits measured attribution.

Last verified: **2026-07-15**.
