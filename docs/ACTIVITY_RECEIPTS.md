# Activity Receipts

Activity Receipts are an isolated, versioned record of explicitly imported local client lifecycle facts.
They explain measured local operation mix without widening quota evidence, reconstructing provider billing, or converting token classes into authoritative subscription-quota percentages.

## Privacy Boundary

Collection is disabled by default for every source.
LimitBar imports only a file that you explicitly select in Settings.
It does not scan Claude Code or Codex directories for Activity Receipts and does not add Activity Receipt work to the Local Refresh Cycle.

The parsers use a positive allow list.
The retained contract contains only a timestamp, an opaque local run UUID, pinned source and adapter versions, model, trusted import configuration, orthogonal lifecycle dimensions, bounded token counters, and fixed evidence limitations.

LimitBar never retains the selected raw file or its raw lines.
Prompts, responses, code, commands, tool arguments, file paths, project paths, terminal output, account identifiers, raw errors, arbitrary attributes, raw OTLP, and raw JSONL are not represented in the receipt contract or SQLite schema.

Activity Receipts use the dedicated `activity-receipts-v1.sqlite` database under LimitBar's Application Support directory.
The database is separate from usage, historical aggregates, quota observations, provider-reported cost, and explanation stores.

## Enable And Import

1. Open LimitBar Settings.
2. Find the Activity Receipts section.
3. Enable only the source you intend to use.
4. Select `Import Claude Code File...` or `Import Codex Exec File...`.
5. Choose a regular file no larger than 8 MB.
6. Open the Analysis tab and read the Activity Receipt debugger card.

Disabling a source prevents later imports but does not silently delete retained receipts.
Use `Delete Activity Receipts` to delete only this subsystem's normalized local records.
Deletion leaves source files, source preferences, usage, quota evidence, costs, credentials, alerts, and other explanation stores unchanged.

Mode and concurrency are not read from provider payload fields.
When supplied, they are trusted user-provided import configuration saved separately in LimitBar preferences.
Claude Code imports can omit this configuration, but those runs cannot be compared.
Codex imports require explicit client version, mode, and concurrency configuration because the documented JSONL stream does not report them.

## Version 1 Schemas

Version 1 intentionally pins exact native event semantics.
Unknown, newer, malformed, partial, duplicate, out-of-order, and changed schemas fail closed.
An ordinary token total without a supported lifecycle event is unavailable for Activity Receipt classification.
LimitBar does not infer normal work, retry, compaction, replay, failure, or subagent activity from token totals.
Imported `lifecycle`, `attempt`, `role`, or `outcome` fields are ignored and cannot declare a classification.

### Claude Code Lifecycle OTLP/JSON

The accepted adapter schema is `claude-code-otlp-logs-v1` for Claude Code client `2.1.207`.
The token semantics identity is `claude-code-api-request-tokens-v1`.
The parser accepts standard OTLP JSON `resourceLogs`, `scopeLogs`, and `logRecords` containers without requiring a particular instrumentation scope, resource attributes, trace ID, or span ID.
Each accepted record uses the documented standard attributes `session.id` and `app.version` plus event attributes `event.name`, `event.timestamp`, and `event.sequence`.
The documented `event.name` values are unprefixed values such as `api_request`, `api_error`, and `compaction`.
`api_request` supplies model, query source, and token categories but does not prove attempt count or success, so those dimensions remain unknown.
Only `api_error` supplies documented attempt evidence, and only an attempt greater than one is classified as retry evidence.
`api_error` supplies an explicit failed outcome.
`compaction` supplies a compaction lifecycle and an outcome only when its documented `success` attribute is present.
`query_source` maps only documented main or subagent evidence; other values remain unknown.
Other supported event names are retained as bounded unclassified activity so coverage is not silently discarded.

```json
{
  "resourceLogs": [{
    "resource": {"attributes": []},
    "scopeLogs": [{
      "scope": {"name":"provider-selected-scope"},
      "logRecords": [{
        "attributes":[
          {"key":"event.name","value":{"stringValue":"api_request"}},
          {"key":"event.timestamp","value":{"stringValue":"2026-07-18T10:00:00Z"}},
          {"key":"event.sequence","value":{"intValue":"1"}},
          {"key":"session.id","value":{"stringValue":"11111111-1111-4111-8111-111111111111"}},
          {"key":"app.version","value":{"stringValue":"2.1.207"}},
          {"key":"model","value":{"stringValue":"claude-sonnet-4"}},
          {"key":"query_source","value":{"stringValue":"repl_main_thread"}},
          {"key":"input_tokens","value":{"intValue":"100"}},
          {"key":"cache_read_tokens","value":{"intValue":"40"}},
          {"key":"cache_creation_tokens","value":{"intValue":"10"}},
          {"key":"output_tokens","value":{"intValue":"20"}}
        ]
      }]
    }]
  }]
}
```

### Codex Exec JSONL

The accepted adapter schema is `codex-exec-events-v1` for Codex client `0.144.4`.
The token semantics identity is `codex-exec-turn-usage-v1`.
The first complete line must be the documented native `thread.started` event with its thread identity.
Supported later lines are documented `turn.completed`, `turn.failed`, and `item.completed` events.
Turn event type derives only an explicit outcome and token categories.
Lifecycle, attempt, and role remain unknown because the documented events do not report those semantics.
Completed items are retained as bounded unclassified activity and content-bearing item fields are discarded.
The documented stream does not report client version, model, timestamps, or concurrency.
The user must explicitly supply the pinned client version, mode, and concurrency as trusted import configuration outside the JSONL payload.
Model remains `unknown`, and import time is retained with an explicit timestamp limitation.
Runs with an unknown model can produce one-run findings but cannot qualify for comparison.
The file must end with a newline so an in-progress final record cannot be accepted.

```json
{"type":"thread.started","thread_id":"11111111-1111-4111-8111-111111111111"}
{"type":"turn.started"}
{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":1}}
```

## Classification Dimensions

The dimensions are deliberately orthogonal.
One dimension cannot manufacture another.

| Dimension | Version 1 values |
| --- | --- |
| Lifecycle | `modelAttempt`, `compaction`, `recoveryReplay`, `cache`, `unknown` |
| Attempt | `normal`, `retry`, `unknown` |
| Role | `primary`, `subagent`, `unknown` |
| Outcome | `succeeded`, `failed`, `unknown` |

Unknown activity remains explicit.
Cache reads and cache creation are measured token categories and do not prove that an operation was wasteful, duplicated, successful, or failed.
If every retained dimension is unknown, the debugger is unavailable with `insufficientLifecycleSemantics`.
Findings are emitted only for observed nonzero classes.
An unknown dimension never produces a zero-valued finding.

## Findings And Comparisons

The debugger uses neutral association language such as retry-associated, compaction-associated, and subagent-associated.
An explicit failed outcome may be described as failed, but the debugger does not call retry, replay, caching, reasoning, compaction, or subagent work avoidable.

Runs can be compared only when source, adapter schema, client version, model, mode, concurrency, and token semantics match exactly.
An incompatible comparison returns a typed unavailable state instead of normalizing unlike evidence.
Compatible runs produce checked measured deltas for input, retry-associated input, compaction, subagent activity, and explicit failed outcomes.
Delta text describes only what the later compatible run had more, fewer, or the same number of and does not claim causality.
Where both runs expose the same dimension, comparison also reports normalized shares for compaction lifecycle, retry evidence, subagent role, and explicit failed outcome.
When client version, model, mode, concurrency, adapter schema, or token semantics changed, the Analysis surface names the changed dimensions and states that values were not compared.

The Analysis card always states that Activity Receipt evidence is separate from provider quota movement and provider-reported cost.
No finding claims a provider billing error, causal quota allocation, or official quota weighting.

## Retention And Recovery

The store retains at most 10,000 normalized operation records and at most 30 days by default.
Age and count retention run transactionally during reads and writes.
Records survive app restart because they are stored in the dedicated SQLite database.
Identical operation identities return `duplicateRecord`, changed reuse returns `conflictingRecord`, older additions return `outOfOrder`, and changed run compatibility returns `incompatibleRuns`.
Timestamps more than five minutes in the future return `futureTimestamp`.
Per-category and aggregate token totals are checked against a fixed safe bound and overflow returns `tokenOverflow`.

The first schema has SQLite `user_version` 1 and an exact schema fingerprint.
An unknown newer version, unexpected object, or malformed known-version schema is left unchanged and reported as unavailable.
There is no destructive fallback or automatic clean-database replacement for Activity Receipts.
