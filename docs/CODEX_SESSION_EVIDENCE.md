# Codex Local Session JSONL Evidence for Issue #24

Last verified: **2026-07-15**

This note records the narrow local Codex session format that LimitBar can support for issue [#24](https://github.com/talibilat/limit-bar/issues/24).
It is based on first-party OpenAI source for the current stable Codex release and does not use or reproduce any real `~/.codex` data.

## Executive Conclusion

OpenAI does **not** publish a stable, versioned contract for local rollout JSONL files.
The files are an internal persistence format whose Rust types and first-party tests provide strong evidence for one pinned release, but each `token_count` record has no schema version, producer version, event ID, turn ID, model ID, or project ID.
The only client version is `cli_version` in the file's initial `session_meta` record, and a later Codex release can resume and append to that file without replacing the initial metadata.

The current stable release verified here is Codex **0.144.4**, tag `rust-v0.144.4`, source commit [`8c68d4c87dc54d38861f5114e920c3de2efa5876`](https://github.com/openai/codex/commit/8c68d4c87dc54d38861f5114e920c3de2efa5876), released 2026-07-14.
The pinned workspace manifest reports `0.144.4`, and new session metadata writes that compiled package version as `cli_version`.[S1][S2]

For issue #24, the safest support boundary is therefore an explicitly versioned LimitBar adapter for the **observed 0.144.4 shape**, not a claim that Codex exposes a stable Usage Event feed.
Even within that boundary, LimitBar must reject unmarked estimated token payloads, derive supporting activity only from validated cumulative transitions, and avoid model or project attribution.

## Source Status

### Source facts

- OpenAI's release page names `0.144.4` as the current release and points to commit `8c68d4c87dc54d38861f5114e920c3de2efa5876`.[S1]
- The pinned source sets the workspace package version to `0.144.4`.[S2]
- The local rollout types derive serialization and JSON-schema traits in source, but the repository does not distribute a standalone, versioned rollout-file schema or document a compatibility policy for external rollout consumers.
- The public Codex configuration reference documents `history.jsonl` through `history.persistence` and `history.max_bytes`; that is a separate transcript-history file and is not the per-session rollout format studied here.[D1]

### LimitBar decision

Treat local rollout JSONL as an **undocumented, release-observed input**, fail closed on unknown versions or incompatible shapes, and re-verify the adapter against pinned first-party source and synthetic fixtures before adding another Codex version.
Do not describe this input as an OpenAI-supported integration contract.

## Exact Record Envelope

### Source facts

Every persisted rollout line has a top-level `timestamp` and a flattened tagged `RolloutItem`.
`RolloutItem` uses `type` plus `payload`, and `EventMsg` is itself tagged by `type`.
The resulting `token_count` envelope is:[S3]

```json
{
  "timestamp": "2026-07-15T00:00:00.000Z",
  "type": "event_msg",
  "payload": {
    "type": "token_count",
    "info": null,
    "rate_limits": null
  }
}
```

The example is synthetic and contains no prompt, response, path, or private payload.
The outer protocol's live `Event` type has a submission `id`, but rollout persistence stores the inner `EventMsg` directly, so that `id` is absent from the JSONL envelope.[S4][S5]

`TokenCountEvent` has exactly two optional values in the pinned Rust type:

```text
info: Option<TokenUsageInfo>
rate_limits: Option<RateLimitSnapshot>
```

Neither field has `skip_serializing_if`, so all four structural combinations serialize:

| Variant | `info` | `rate_limits` | Meaning established by source |
| --- | --- | --- | --- |
| Usage and limits | object | object | Current token state and the session's latest retained rate-limit state |
| Usage only | object | `null` | Token state exists but no rate-limit state has been retained |
| Limits only | `null` | object | Rate-limit state exists but token state is unknown |
| Empty update | `null` | `null` | Both values are unknown |

First-party tests explicitly construct both populated and `null` `info` values, and source emission always takes the current pair from session state.[S6][S7]

### LimitBar decision

Accept a line for issue #24 only when all of these conditions hold:

- It is terminated by LF in a stable byte snapshot.
- Its top-level `type` is exactly `event_msg`.
- Its payload `type` is exactly `token_count`.
- It has a valid UTC/RFC 3339 timestamp.
- Required accepted scalar fields have the expected type and safe range.
- Unknown fields are ignored in memory and never copied to persistence, diagnostics, or exports.
- Unknown event types and malformed or unsupported variants do not become evidence.

## Token Payload

### Source facts

When `info` is present, its shape is:[S5]

```json
{
  "total_token_usage": {
    "input_tokens": 0,
    "cached_input_tokens": 0,
    "output_tokens": 0,
    "reasoning_output_tokens": 0,
    "total_tokens": 0
  },
  "last_token_usage": {
    "input_tokens": 0,
    "cached_input_tokens": 0,
    "output_tokens": 0,
    "reasoning_output_tokens": 0,
    "total_tokens": 0
  },
  "model_context_window": null
}
```

The five token fields are signed 64-bit integers in Rust:

| JSON field | Source meaning |
| --- | --- |
| `input_tokens` | Response API input tokens |
| `cached_input_tokens` | `input_tokens_details.cached_tokens`, defaulting to zero when absent |
| `output_tokens` | Response API output tokens |
| `reasoning_output_tokens` | `output_tokens_details.reasoning_tokens`, defaulting to zero when absent |
| `total_tokens` | Response API total tokens |

The mapping from a completed Responses API usage object copies those values directly.[S8]
Cached input is a subset of input, and reasoning output is a subset of output; source display helpers calculate non-cached input by subtraction and do not add reasoning output on top of output.[S9]

`last_token_usage` is normally the per-response delta.
`total_token_usage` is normally the element-wise cumulative sum for the session: `append_last_usage` adds every field from the latest response into the total and stores that response as `last_token_usage`.[S5][S10]
On resume, Codex restores the newest non-null `info` found in the rollout and continues from that state.[S11]

However, the same unversioned shape also carries values that are **not direct response usage**:

- After local recomputation, Codex writes an estimated `last_token_usage.total_tokens` while setting its four component fields to zero; no provenance flag marks the estimate.[S7]
- When forcing a full context window, Codex replaces cumulative usage with only `total_tokens = context_window` and writes a synthetic last delta; again, no provenance flag distinguishes it.[S5][S12]
- A rate-limit update can emit a new `token_count` while reusing unchanged token information, so blindly summing every `last_token_usage` double-counts.[S7][S13]

### LimitBar decision

Do **not** convert every `token_count` line into a LimitBar Usage Event.
The Codex record is a mutable session snapshot, not an immutable per-operation delta contract.

For supporting activity, accept only transitions between consecutive validated `info` snapshots in the same logical rollout when:

- All cumulative token values are non-negative.
- Cumulative `cached_input_tokens <= input_tokens`.
- Cumulative `reasoning_output_tokens <= output_tokens`.
- Cumulative `total_tokens == input_tokens + output_tokens`.
- Every cumulative component is monotonic.
- No malformed, unsupported, truncated, replaced-prefix, or unvalidated record interrupts the evidence segment.

If every cumulative component is unchanged, classify the record as a repeated or state-only publication and derive no activity from `last_token_usage`.
If any cumulative component increased, additionally require a non-negative `last_token_usage` with valid subset relationships, `last_token_usage.total_tokens == input_tokens + output_tokens`, and an exact component-wise match between the cumulative difference and `last_token_usage`.
These checks deliberately exclude the two known unmarked synthetic forms from counted activity and prevent repeated rate-limit-only emissions from being counted again.
A transition that fails them is an evidence barrier, not zero usage.
Persist only the validated normalized delta and a bounded evidence identity, never either raw usage object.

An initial snapshot without a prior validated snapshot may establish a baseline but must not be counted as interval activity.
This means LimitBar can miss activity before its baseline; it must represent that as incomplete coverage rather than infer usage.

## Rate-Limit Coupling

### Source facts

`rate_limits`, when present, has this pinned shape:[S5]

```text
limit_id: string | null
limit_name: string | null
primary: RateLimitWindow | null
secondary: RateLimitWindow | null
credits: CreditsSnapshot | null
individual_limit: SpendControlLimitSnapshot | null
plan_type: PlanType | null
rate_limit_reached_type: RateLimitReachedType | null
```

Each `primary` or `secondary` window has:

```text
used_percent: number
window_minutes: integer | null
resets_at: Unix-seconds integer | null
```

Source comments define `used_percent` as 0 through 100 consumed, `window_minutes` as a rolling duration, and `resets_at` as the Unix reset timestamp.[S14]

The core stores one `latest_rate_limits` snapshot in session state and emits it beside the current token state.[S13]
During a normal response stream, a `RateLimits` response updates state but emission is deferred to avoid a duplicate `token_count` before response token usage arrives.[S15]
Other call paths can update limits and emit immediately.[S7]
Missing `credits`, `individual_limit`, and `plan_type` may be carried forward from the previous snapshot, and a missing `limit_id` is defaulted to `codex`.[S13]

Therefore co-location in one `token_count` payload does not prove that the token delta caused the quota percentage or that every nested rate-limit field was newly reported at that line's timestamp.
It is a publication of the session's current token state plus latest retained rate-limit state.

### LimitBar decision

- Treat rate-limit windows as provider-reported quota observations, separate from local token evidence.
- Use `limit_id`, window duration, and exact `resets_at` boundary to identify a quota window; fail closed when the exact boundary required for comparison is absent.
- Never convert token counts to quota percentages or add an Observed Local Breakdown to authoritative percentage movement.
- Do not claim that co-located fields establish causation or complete account coverage.
- Treat carried or repeated identical quota state as a snapshot publication, not a new provider event with a unique identity.
- Correlate only validated local deltas whose record timestamps lie inside the interval between two compatible quota observations, and retain an unattributed remainder.

## Session, Model, and Project Identity

### Source facts

The first `session_meta` record contains both `session_id` and `id` (`ThreadId`), optional parent/fork identities, a session timestamp, `cwd`, originator, `cli_version`, source classification, optional model provider, optional instructions, and optional Git metadata.[S16]
For a newly created ordinary session, `session_id` defaults to the conversation/thread ID, while the types permit them to differ.[S17]
The rollout filename also embeds the conversation/thread ID.[S18]

The exact model is **not** in `token_count` or necessarily in session metadata.
It is recorded in per-turn `turn_context` records, which have an optional `turn_id`, a `model`, and a `cwd`.[S19]
Token events themselves have no `turn_id`, so associating a token transition with the nearest turn context would be temporal inference rather than an explicit foreign-key relationship.

There is no dedicated project ID in `token_count` or `session_meta`.
`cwd`, turn workspace roots, and optional Git repository metadata may reveal a project, but they are private paths or repository information.

Prompts and other private content coexist in the same rollout file.
The persistence policy stores response messages, reasoning, tool calls, turn context, and, in legacy history mode, user and agent message events alongside `token_count`.[S20]
Session metadata may also contain base instructions.[S16]

### LimitBar decision

- Allow-list only `session_meta.payload.session_id`, `session_meta.payload.id`, and `session_meta.payload.cli_version` for source validation and bounded evidence identity.
- Do not read or retain `cwd`, workspace roots, Git fields, base instructions, prompts, responses, reasoning, tool arguments, terminal output, or arbitrary payloads.
- Do not provide model attribution for the 0.144.4 adapter because `token_count` has no explicit model or turn link.
- Do not provide project attribution because no privacy-safe project identifier is present.
- A configured privacy-safe project mapping would require a separate, explicit design; raw path or repository values must never enter LimitBar persistence while attempting that mapping.

## Duplicate and Event Identity

### Source facts

Neither `RolloutLine` nor `TokenCountEvent` has an event ID.[S3][S5]
The live protocol's submission ID is lost when only `EventMsg` is persisted.[S4]
The millisecond timestamp is assigned when the background writer serializes a line, not by the provider response, and is not documented as unique.[S21]
Identical token/rate-limit snapshots can be emitted legitimately.

### LimitBar decision

Use a storage-position identity for repeated scans, not payload equality:

```text
(session/thread identity, complete-line ordinal, SHA-256 of exact complete-line bytes)
```

The digest is internal bounded evidence metadata and the raw line must not be retained.
Track a validated content prefix or equivalent checkpoint so append-only growth continues safely.
If an earlier line changes, a file shrinks, the initial metadata changes, or the same ordinal has a different digest, treat the source as replaced and rebuild only from the bounded configured scan range.

Do not collapse two distinct complete lines merely because their timestamps and payloads match.
Without a producer event ID, LimitBar cannot prove that such lines are duplicates rather than repeated publications.
Component-wise cumulative transition validation, rather than event deduplication, prevents repeated snapshots from becoming extra token activity.

## Ordering and Timestamps

### Source facts

The live recorder sends canonical items through one bounded channel and writes queued items sequentially.[S2][S22]
Source comments require live sessions to use that recorder so writes stay ordered with the session stream.[S23]
Each line receives a UTC timestamp formatted to milliseconds immediately before serialization and append.[S21]

The timestamp is wall-clock publication time.
It is not a provider event time, has only millisecond precision, and has no source-backed monotonicity or uniqueness guarantee.
Ordering is therefore the complete-line order within one file, not a global timestamp order across session files.

### LimitBar decision

- Preserve validated record timestamps as local observation times.
- Use physical complete-line order as the within-session ordering authority.
- Sort cross-session evidence by timestamp only for interval comparison, while detecting equal or decreasing timestamps and refusing unsafe ordering assumptions.
- Do not use filename time, file modification time, or directory date as the event time.
- Do not claim sub-millisecond ordering or global total order across concurrent sessions.

## Partial Writes and Malformed Lines

### Source facts

The writer serializes one object, appends LF, calls `write_all`, and flushes.[S21]
Items remain pending until a write reports success; after an I/O failure, Codex reopens the file in append mode and retries pending items.[S24]
This is not an atomic record transaction: an interrupted `write_all` can leave a partial suffix, and retry is append-only.
Codex's own readers operate line by line, and first-party tests recognize empty or partial rollout files as cases to skip.[S25]

### LimitBar decision

- Read a stable bounded byte snapshot without locking or modifying the Codex file.
- Parse only LF-terminated records.
- Always ignore an unterminated final fragment, even if it happens to be valid JSON at the instant read.
- Treat malformed terminated lines as an evidence barrier for completeness; do not silently bridge token deltas across them.
- Never concatenate a malformed fragment with a later line or attempt JSON repair.
- A later scan may accept a formerly partial final record only after it is observed as a complete, valid LF-terminated line and the prior validated prefix is unchanged.

## File Layout, Archive, and Compression

### Source facts

New files use this layout, with date directories based on local session-start time:[S18][S26]

```text
$CODEX_HOME/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDThh-mm-ss-<thread-uuid>.jsonl
```

There is one appendable rollout file per thread/session identity in the observed implementation; source shows no size- or time-based intra-file rotation.
Resuming opens the existing file in append mode and does not write a new `session_meta` record.[S2]

Archiving moves a rollout out of `sessions` into `$CODEX_HOME/archived_sessions` while retaining its filename.[S27]
Cold active and archived `.jsonl` files at least seven days old may be replaced by Zstandard-compressed `.jsonl.zst` files.
Codex's own reader transparently handles both forms, and resuming materializes a compressed file back to plain JSONL.[S28][S29]

### LimitBar decision

- Keep issue #24's configured boundary explicit.
- If the boundary remains `$CODEX_HOME/sessions`, archived files are outside coverage and must not be treated as observed.
- A current-release scanner must either safely support `.jsonl.zst` or declare compressed rollouts unsupported; scanning only `.jsonl` is not complete for records older than seven days.
- Normalize `.jsonl` and `.jsonl.zst` as representations of the same logical rollout identity.
- Ignore compression temporary files and never decompress into `$CODEX_HOME`.
- Do not infer retention or deletion guarantees from this layout.
- Bound traversal, decompressed bytes, file count, line count, age, and retained evidence count.

## Version and Stability Boundary

### Source facts

`cli_version` is written only in new-session metadata from the compiled package version.[S2]
On resume, Codex opens and appends to the existing rollout without replacing metadata.[S2]
Individual rollout lines and `token_count` payloads have no producer version or schema version.[S3][S5]
The source itself contains compatibility fields and legacy modes for older rollout readers, demonstrating active format evolution rather than an immutable external contract.[S19][S20]

Consequently, `session_meta.cli_version == "0.144.4"` proves the creator version, not necessarily the version that appended every later record.
There is no source-backed way to establish exact mixed-version authorship after a session has been resumed by another release.

### LimitBar decision

The adapter support label should be:

```text
codex-rollout-observed-0.144.4
```

It may accept only files whose initial metadata says `cli_version == "0.144.4"` and whose accepted records match all structural and semantic checks in this note.
That remains a confidence classification of **observed-compatible**, not proof that every line was authored by 0.144.4.

Fail closed to `unsupported_version_or_mixed_authorship` when:

- `cli_version` is missing or different.
- Initial metadata is malformed or not first.
- A supported file later presents an incompatible record.
- Safe source replacement or prefix continuity cannot be established.
- Product behavior requires certainty that every event came from exactly 0.144.4.

A stronger release range requires canonical fixtures generated by each exact release artifact and explicit cross-version resume tests.
Source inspection alone cannot establish that range.

## Recommended Positive Allow-List

### Read transiently for validation

| Record | Fields |
| --- | --- |
| `session_meta` | outer `timestamp`, `type`; payload `session_id`, `id`, `cli_version` |
| `token_count` | outer `timestamp`, `type`; payload `type`, `info`, `rate_limits` |
| `info` | `total_token_usage`, `last_token_usage`; `model_context_window` only for validation, not explanation evidence |
| each token usage | `input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`, `total_tokens` |
| rate limits | `limit_id`, `primary`, `secondary`; `plan_type` only if already needed by the existing quota presentation |
| each quota window | `used_percent`, `window_minutes`, `resets_at` |

### Persist after normalization

- Adapter version and creator `cli_version`.
- Privacy-safe session/thread identity, preferably a keyed local digest rather than the raw UUID if cross-component joins do not require the UUID.
- Complete-line ordinal and line digest for bounded traceability.
- Observation timestamp.
- Validated per-transition input, cached input, output, reasoning output, and total token deltas.
- Exact accepted quota-window identity and observation values needed by the explanation.
- Evidence-gap or unsupported reason codes.

### Never persist or export

- Raw JSONL lines or arbitrary payload fragments.
- Prompts, code, responses, reasoning, instructions, tool calls, terminal output, request bodies, or credentials.
- `cwd`, workspace roots, local paths, Git remotes, branches, commit hashes, account labels, or repository labels.
- Unknown fields, even when JSON decoding tolerates them.

## Safely Testable Support Boundary

The minimum safe fixture matrix for `codex-rollout-observed-0.144.4` is:

1. A canonical synthetic 0.144.4 session with baseline, valid cumulative transition, and compatible rate limits.
2. All four `info`/`rate_limits` nullability combinations.
3. Cached and reasoning subset counts with valid totals.
4. Repeated unchanged token snapshots caused by a rate-limit publication.
5. Estimated recomputation and full-context synthetic forms, both rejected as activity.
6. Component decrease, inconsistent total, and last-versus-cumulative mismatch barriers.
7. Unknown fields containing prohibited-content sentinels, proving they never reach persistence, logs, diagnostics, UI, or exports.
8. Unknown event types and unknown `token_count` variants.
9. Unterminated final JSON, malformed terminated lines, partial-write prefixes, and a later completed append.
10. Repeated scans, append growth, source truncation, atomic replacement, archive move, plain-to-zstd replacement, and compression temporary files.
11. Equal timestamps, decreasing wall-clock timestamps, and concurrent files.
12. Missing, older, newer, and malformed `cli_version` values.
13. A 0.144.4-created file resumed by a deliberately changed producer fixture, proving that creator version cannot authorize incompatible appended records.
14. Prompts, paths, Git data, and private payload sentinels coexisting in ignored records.

Release-level validation should generate canonical fixtures with the exact `0.144.4` release artifact.
Handwritten fixtures remain adversarial/unit fixtures and are not proof of the release's emitted bytes.
Signed-application acceptance may inspect a user-selected or synthetic configured source, but must not copy private records and must not be represented as proof of complete account activity.

## Known Unknowns

- Whether OpenAI intends any local rollout field to be stable for third-party consumers.
- Which earlier releases share the exact safe subset; this note verifies only 0.144.4 source.
- Whether a 0.144.4-created file was later appended by another Codex version.
- Whether every model/provider path emits direct response usage with the same completeness.
- Whether provider-returned token usage includes every activity that affects Codex quota.
- The provider's undisclosed weighting from tokens or other activity to quota percentage.
- Whether account-level quota movement came from this machine, another machine, another client, concurrent sessions, background work, or activity absent from local files.
- Whether a co-located rate-limit snapshot was newly received for that response or retained from earlier session state.
- Whether equal payloads are retries or legitimate repeated publications.
- Whether wall-clock timestamps are accurate or monotonic.
- Whether local files were deleted, archived outside the configured boundary, compressed beyond scanner support, disabled, damaged, or unavailable during an interval.
- Whether temporal association with `turn_context.model` is always correct; the lack of an explicit token-to-turn link prevents a safe claim.
- Whether any privacy-safe project identity can be obtained without reading prohibited paths or repository metadata.

These unknowns require LimitBar to call the result an **Observed Local Breakdown**, preserve unattributed quota movement, and show unavailable when coverage or compatibility cannot be established.

## Primary Sources

All GitHub source links below are pinned to commit `8c68d4c87dc54d38861f5114e920c3de2efa5876`.
All were last verified 2026-07-15.

- **[S1] Release 0.144.4:** [official OpenAI Codex release](https://github.com/openai/codex/releases/tag/rust-v0.144.4) and [pinned release commit](https://github.com/openai/codex/commit/8c68d4c87dc54d38861f5114e920c3de2efa5876).
- **[S2] Package version, new-session metadata, and resume append behavior:** [`codex-rs/Cargo.toml#L132-L139`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/Cargo.toml#L132-L139), [`rollout/src/recorder.rs#L744-L825`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/recorder.rs#L744-L825).
- **[S3] `RolloutItem` and `RolloutLine` serialization:** [`protocol/src/protocol.rs#L3130-L3145`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L3130-L3145), [`protocol/src/protocol.rs#L3325-L3330`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L3325-L3330).
- **[S4] Live `Event.id` and `EventMsg::TokenCount`:** [`protocol/src/protocol.rs#L1264-L1279`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L1264-L1279), [`protocol/src/protocol.rs#L1329-L1337`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L1329-L1337).
- **[S5] Token and rate-limit structs and cumulative methods:** [`protocol/src/protocol.rs#L2016-L2113`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L2016-L2113).
- **[S6] First-party null/populated token-count variants and resume selection test:** [`core/src/session/tests.rs#L2207-L2282`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/core/src/session/tests.rs#L2207-L2282).
- **[S7] Direct usage update, estimated recomputation, limit update, and pair emission:** [`core/src/session/mod.rs#L3676-L3810`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/core/src/session/mod.rs#L3676-L3810).
- **[S8] Responses API usage-to-token mapping:** [`codex-api/src/sse/responses.rs#L112-L157`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/codex-api/src/sse/responses.rs#L112-L157).
- **[S9] Cached/reasoning subset handling:** [`protocol/src/protocol.rs#L2171-L2187`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L2171-L2187).
- **[S10] Session history appends response usage cumulatively:** [`core/src/context_manager/history.rs#L281-L290`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/core/src/context_manager/history.rs#L281-L290).
- **[S11] Resume restores newest non-null token information:** [`core/src/session/mod.rs#L1496-L1501`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/core/src/session/mod.rs#L1496-L1501), plus test [S6].
- **[S12] Full-context synthetic token state:** [`core/src/context_manager/history.rs#L111-L117`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/core/src/context_manager/history.rs#L111-L117), [`protocol/src/protocol.rs#L2071-L2094`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L2071-L2094).
- **[S13] Latest-state pairing and carried rate-limit fields:** [`core/src/state/session.rs#L200-L218`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/core/src/state/session.rs#L200-L218), [`core/src/state/session.rs#L314-L334`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/core/src/state/session.rs#L314-L334).
- **[S14] Rate-limit window semantics:** [`protocol/src/protocol.rs#L2141-L2151`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L2141-L2151).
- **[S15] Response-stream coupling and deferred emission:** [`core/src/session/turn.rs#L2263-L2305`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/core/src/session/turn.rs#L2263-L2305).
- **[S16] Session metadata fields and legacy compatibility:** [`protocol/src/protocol.rs#L3008-L3127`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L3008-L3127).
- **[S17] Default session/thread identity:** [`rollout/src/recorder.rs#L167-L193`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/recorder.rs#L167-L193).
- **[S18] File path and filename construction:** [`rollout/src/recorder.rs#L1487-L1527`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/recorder.rs#L1487-L1527).
- **[S19] Turn-context model, turn ID, and private path fields:** [`protocol/src/protocol.rs#L3204-L3252`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/protocol/src/protocol.rs#L3204-L3252).
- **[S20] Persisted record policy:** [`rollout/src/policy.rs#L7-L19`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/policy.rs#L7-L19), [`rollout/src/policy.rs#L36-L115`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/policy.rs#L36-L115).
- **[S21] Timestamping, serialization, LF append, and flush:** [`rollout/src/recorder.rs#L1800-L1833`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/recorder.rs#L1800-L1833).
- **[S22] Ordered writer channel processing:** [`rollout/src/recorder.rs#L829-L870`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/recorder.rs#L829-L870), [`rollout/src/recorder.rs#L1718-L1749`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/recorder.rs#L1718-L1749).
- **[S23] Ordered live append requirement:** [`rollout/src/recorder.rs#L1782-L1797`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/recorder.rs#L1782-L1797).
- **[S24] Pending-item retry behavior:** [`rollout/src/recorder.rs#L1545-L1554`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/recorder.rs#L1545-L1554), [`rollout/src/recorder.rs#L1610-L1715`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/recorder.rs#L1610-L1715).
- **[S25] First-party partial-rollout handling test:** [`rollout/src/session_index_tests.rs#L119-L146`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/session_index_tests.rs#L119-L146).
- **[S26] First-party documented directory layout in source:** [`rollout/src/list.rs#L420-L423`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/list.rs#L420-L423).
- **[S27] Archive moves the rollout:** [`thread-store/src/local/archive_thread.rs#L11-L60`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/thread-store/src/local/archive_thread.rs#L11-L60).
- **[S28] Transparent plain/zstd reading and rematerialization:** [`rollout/src/compression.rs#L18-L120`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/compression.rs#L18-L120).
- **[S29] Seven-day cold-file compression and atomic replacement checks:** [`rollout/src/compression.rs#L244-L254`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/compression.rs#L244-L254), [`rollout/src/compression.rs#L600-L705`](https://github.com/openai/codex/blob/8c68d4c87dc54d38861f5114e920c3de2efa5876/codex-rs/rollout/src/compression.rs#L600-L705).

### Official documentation

- **[D1] Codex configuration reference:** [OpenAI Codex configuration reference](https://developers.openai.com/codex/config-reference), live documentation last verified 2026-07-15.
  It describes `history.jsonl` controls but does not define the per-session rollout JSONL contract.
