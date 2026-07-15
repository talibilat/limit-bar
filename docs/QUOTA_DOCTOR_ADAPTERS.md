# Quota Doctor Adapter Inventory

Last verified: **2026-07-15**.

This is the release support inventory for Quota Doctor evidence.
"Tested" means synthetic contract tests passed and never means a signed real-account run passed.

| Provider product | Adapter | Stability | Version boundary | Confidence | Authentication and UI interaction | Configured read boundary | Last verified |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Codex subscription | `codex-rollout-observed-0.144.4` | Experimental, version-pinned; not stable | Creator metadata exactly `0.144.4`; resumed mixed authorship cannot be proven | Observed-compatible | None; reads no credential and causes no OS authorization UI | Configured `$CODEX_HOME/sessions` directory, canonical regular `.jsonl` files only; archives, compressed files, symlinks, oversize files, stale files, and paths outside the canonical root are excluded | 2026-07-15 |
| Claude Code subscription | `claude-code-otlp-http-json-2.1.207-v1` | Verification-only; not wired as a production source and not stable | Producer exactly `2.1.207`, OTLP HTTP/JSON delta monotonic sum | Documented-compatible | User configures the exporter and any exporter authentication; the adapter reads neither. No LimitBar receiver or OS authorization path exists | Caller-supplied in-memory request bytes, at most 8 MiB; no filesystem or network acquisition | 2026-07-15 |
| Claude Code quota report | `ClaudeOAuthUsageClient` plus `ClaudeUsageResponseMapper` | Existing product integration, but not declared stable for Quota Doctor release | Undocumented response shape behind `anthropic-beta: oauth-2025-04-20`; no client version is captured | Observed product behavior | Passive Keychain read forbids UI; only Connect permits interactive macOS authorization; bearer credential is memory-only | Claude Code Keychain item and `https://api.anthropic.com/api/oauth/usage` only | Not verified by a signed real-source run |
| Codex quota report | local `token_count.rate_limits` path | Experimental, version-pinned; not stable | Same observed `0.144.4` creator boundary and mixed-authorship limitation | Observed-compatible | No authentication and no OS interaction | Same canonical sessions boundary as the Codex rollout adapter | 2026-07-15 |
| Anthropic API | None | Unavailable | No qualifying contract | Unavailable | Reviewed Admin credentials are broader than a narrow quota-read operation | No configured boundary because no adapter ships | 2026-07-15 |
| OpenAI API | None | Unavailable | No qualifying contract | Unavailable | Reviewed Admin API authentication does not establish a narrow current-quota read | No configured boundary because no adapter ships | 2026-07-15 |
| Azure OpenAI | None | Unavailable | Stable control-plane API `2024-10-01` reports allocation, not consumption in an exact Quota window | Unavailable | Entra/ARM access exists but does not satisfy the evidence contract | No configured boundary because no adapter ships | 2026-07-15 |

## Captured And Omitted Fields

The Codex adapter transiently captures the initial session and thread UUIDs, creator version, record timestamp, cumulative and last token categories, quota percentage, window duration, reset timestamp, limit ID, plan type, and credits fields required to validate the supported shape.
It persists only keyed identities, complete-line ordinal and digest, validated token deltas, normalized quota observations, adapter version, creator version, typed barriers, and bounded findings.
It omits prompts, responses, reasoning, tool calls, terminal output, request bodies, paths, repository data, instructions, model and project attribution, arbitrary events, and unknown fields.

The Claude Code OTLP adapter captures the metric identity, delta temporality, interval boundaries, non-negative count, token type, bounded model, session UUID, account UUID, and exact producer version.
It returns only locally keyed identities and normalized measured fields.
It omits resource and scope metadata, content-bearing telemetry, account labels, paths, arbitrary attributes, headers, credentials, and raw payloads.

The Claude quota report captures supported percentage windows, reported reset timestamps, coarse scope classification, active status, and fetch time.
The normalized Quota Doctor observation omits display labels, account identity, credential data, and response payloads.
Because the source response has no declared stable schema or captured producer version, this path is not counted as a stable Quota Doctor adapter.

## Failure And Limitation Contract

Unknown producer versions, malformed envelopes, invalid scalars, missing exact boundaries required for comparison, unsafe token transitions, counter decreases, and structural changes produce typed unavailable or barrier outcomes rather than normalized evidence for the unsafe segment.
An unterminated Codex suffix is ignored until a later stable read observes its LF terminator.
Duplicate normalized identities are deduplicated, out-of-order observations are sorted only where the method permits it, and decreasing counters invalidate comparison.
Observed Local Breakdowns never become authoritative provider totals or provider weighting.
Gap, Observed Zero, unavailable, unattributed, Reported, Measured, Calculated, Inferred, and superseded states remain distinct in the feature-specific tests and release matrix.

## Release Count

Stable subscription-client adapters: **0**.
Stable API-provider adapters: **0**.
The observed Codex adapter and verification-only Claude adapter are valuable testable seams, but their declared stability and signed real-source evidence do not permit counting them as stable release adapters.
Issue #27 is unavailable and contributes zero API adapters.
Quota Doctor therefore does **not** meet the required two stable subscription clients plus one stable API provider and must not be declared complete.
