# Claude Code OpenTelemetry Evidence

Last verified: **2026-07-15**

## Decision

Current first-party Claude Code documentation establishes an opt-in structured source that explicitly identifies Claude Code activity.
Claude Code can export the metric named `claude_code.token.usage` through OpenTelemetry, including OTLP over HTTP/JSON.
The documented metric has token `type` and `model` datapoint attributes and shares standard `session.id`, `app.version`, and `user.account_uuid` datapoint attributes when their documented metric-cardinality controls are enabled.

This is sufficient to recognize measured Claude Code token activity through a strict adapter.
It is not evidence that token totals authoritatively decompose subscription quota movement.
Anthropic does not document a token-to-quota percentage weighting method, complete account coverage, or a statement that every activity affecting subscription quota appears in these metrics.
LimitBar therefore keeps all provider-reported movement unattributed and labels qualifying telemetry only as an **Observed Local Breakdown**.

## Supported Boundary

The adapter identity is `claude-code-otlp-http-json-2.1.207-v1`.
The supported producer version is exactly Claude Code `2.1.207` with `app.version` included in metric attributes.
The installed version was confirmed directly with `claude --version`; no private Claude Code data was read.
The supported transport shape is the standard OTLP Export Metrics Service HTTP/JSON request containing delta, monotonic sum points for `claude_code.token.usage`.
The confidence classification is **documented-compatible** because support is based on current first-party documentation and synthetic fixtures, not a captured real-account export.

The required Claude Code configuration is:

```sh
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/json
export OTEL_METRICS_INCLUDE_SESSION_ID=true
export OTEL_METRICS_INCLUDE_VERSION=true
export OTEL_METRICS_INCLUDE_ACCOUNT_UUID=true
```

Claude Code's exporter sends to a user-configured OTLP endpoint.
Exporter authentication, when required by that endpoint, is configured by the user through `OTEL_EXPORTER_OTLP_HEADERS` or Claude Code's documented dynamic header helper.
The core adapter is a verification seam over supplied OTLP bytes and does not read Claude Code credentials, exporter headers, browser cookies, or private provider pages.
LimitBar does not currently run an OTLP receiver or automatically configure Claude Code.
LimitBar also has no trustworthy binding between the Claude quota credential and telemetry `user.account_uuid`.
Existing retained quota observations contain no account identity, so production movement and local attribution both remain unavailable rather than joining observations across a possible account transition.

## Positive Allow-List

The adapter accepts only these normalized inputs:

| Input | Use |
| --- | --- |
| Metric name `claude_code.token.usage` | Explicit Claude Code product identity. |
| Delta monotonic sum temporality | Prevent cumulative points from being summed as deltas. |
| `startTimeUnixNano` and `timeUnixNano` | Required complete delta interval `(start,end]`. |
| `asInt` | Non-negative measured token count. |
| `type` | `input`, `output`, `cacheRead`, or `cacheCreation`. |
| `model` | Bounded model grouping. |
| Datapoint `session.id` | Locally keyed session identity and session count. |
| Datapoint `user.account_uuid` | Locally keyed account identity for the verification seam. |
| Datapoint `app.version` | Exact supported producer-version gate. |

Raw account and session UUIDs are transformed with a caller-supplied local HMAC key before normalized evidence is returned.
Normalized evidence has no public unchecked initializer or decoder.
Its throwing factory requires finite increasing interval boundaries, non-negative counts, a bounded safe model, exact supported source and adapter versions, and 64-character lowercase hexadecimal keyed identities for the evidence, account, and session.
The adapter ignores all unknown resource, scope, metric, point, and value fields.
It never copies prompts, code, responses, tool details, terminal output, request or response bodies, credentials, authorization headers, email addresses, account labels, workspace paths, private paths, or raw OTLP payloads into normalized evidence or persistence.
Generic Anthropic API metrics do not match the required `claude_code.token.usage` metric identity and cannot become Claude Code evidence.

## Explanation And Retention

The core enumerates bounded adjacent observation intervals within one exact `QuotaWindowIdentity` and supports explicit selection of active or completed retained windows.
Active intervals are preferred only for default selection; completed intervals remain valid historical candidates and are labeled completed rather than stale or alert-eligible.
Movement is calculated only when both quota observations have the same verified account scope and percentage unit.
Production observations currently lack that scope, so production calculation fails closed with `quota_account_scope_unavailable`.
Duplicate observation identities are removed, out-of-order inputs are sorted by measured time, and account transitions, counter decreases, incompatible units, gaps, partial evidence coverage, missing boundaries, and unsupported evidence remain distinct limitations.
Any counter decrease anywhere in one exact quota identity invalidates every candidate interval for that identity; a new reported reset boundary creates a distinct identity that can recover independently.
An OTLP point contributes only when its complete `(start,end]` interval is contained in the selected quota-observation interval.
The union of accepted contained intervals must begin at the selected start, have no internal gaps, and end at the selected end.
Overlaps are allowed when their union is complete.
Observed Zero requires that complete coverage and zero normalized totals.
Leading, trailing, internal, crossing, and missing-boundary gaps can never become Observed Zero.

The method identity is `claude-code-quota-explanation-v2`.
It performs subtraction of provider-reported percentages only.
It never converts token counts to quota percentage and never allocates reported movement among models or sessions.

`claude-explanations.sqlite` retains at most 100 normalized findings for 30 days.
It stores status, exact interval and reset boundary, measured percentage movement, bounded token totals and model counts when available, evidence and observation counts, source and method versions, and fixed reason categories.
It stores no raw payload, account or session UUID, prompt, code, response, tool detail, terminal output, credential, path, or account label.
Evidence age is recalculated from the selected interval end at every read and is not treated as frozen persisted evidence.
The UI always displays the exact selected start and end, a stable privacy-safe interval trace digest, observation and evidence trace counts, method version, and Reported/Calculated/Measured provenance, even when only one interval exists.
Settings deletes this database's findings independently from quota observations, current provider reports, usage, credentials, alert rules, and notification delivery state.

## Verification And Limitations

Automated fixtures cover qualifying Claude Code metrics, generic Anthropic API overlap, unsupported source versions, compatible movement, missing evidence, flat movement, resets, counter decreases, duplicates, out-of-order inputs, cross-account evidence, normalized persistence, independent deletion, and prohibited-content sentinels.
These fixtures prove adapter and privacy behavior only.
They do not prove that Claude Code `2.1.207` emitted identical bytes for a real account.

Signed-app verification is **unavailable**, not passed.
A future acceptance attempt requires a supported local receiver, a user-owned Claude Code `2.1.207` installation, and a trustworthy quota-account binding.
That verification must confirm the exact displayed interval and provider-reported reset, confirm the metric and required attributes are emitted, and confirm withholding telemetry produces unavailable attribution rather than fallback correlation to generic Anthropic API usage.
No real account, receiver, quota-account binding, signed acceptance run, or canonical producer-generated fixture was available during this implementation.
Claude explanation evidence is intentionally omitted from diagnostic export until a dedicated positive allow-list is accepted; therefore prohibited evidence values cannot enter diagnostics or exported artifacts through this feature.

## Primary Sources

- [Claude Code Monitoring](https://code.claude.com/docs/en/monitoring-usage), first-party Anthropic documentation for OpenTelemetry configuration, metric names, standard attributes, metric cardinality controls, authentication headers, prompt and response logging gates, and token metric attributes.
- [Claude Code Data Usage](https://code.claude.com/docs/en/data-usage), first-party Anthropic documentation for local data, telemetry, and content privacy behavior.
- [OpenTelemetry OTLP Exporter Configuration](https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/), upstream transport configuration referenced by the Claude Code documentation.

All sources were last verified on 2026-07-15.
