# Claude Code OpenTelemetry Evidence

Last verified: **2026-07-15**

## Decision

Current first-party Claude Code documentation establishes an opt-in structured source that explicitly identifies Claude Code activity.
Claude Code can export the metric named `claude_code.token.usage` through OpenTelemetry, including OTLP over HTTP/JSON.
The documented metric has token `type` and `model` attributes and shares standard `session.id`, `app.version`, and `user.account_uuid` attributes when their documented metric-cardinality controls are enabled.

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
LimitBar does not currently run an OTLP receiver or automatically configure Claude Code, so the production UI reports local attribution as unavailable while still showing deterministic movement between retained compatible quota observations.

## Positive Allow-List

The adapter accepts only these normalized inputs:

| Input | Use |
| --- | --- |
| Metric name `claude_code.token.usage` | Explicit Claude Code product identity. |
| Delta monotonic sum temporality | Prevent cumulative points from being summed as deltas. |
| `timeUnixNano` | Evidence observation time. |
| `asInt` | Non-negative measured token count. |
| `type` | `input`, `output`, `cacheRead`, or `cacheCreation`. |
| `model` | Bounded model grouping. |
| `session.id` | Locally keyed session identity and session count. |
| `user.account_uuid` | Locally keyed account binding used to prevent cross-account correlation. |
| `app.version` | Exact supported producer-version gate. |

Raw account and session UUIDs are transformed with a caller-supplied local HMAC key before normalized evidence is returned.
The adapter ignores all unknown resource, scope, metric, point, and value fields.
It never copies prompts, code, responses, tool details, terminal output, request or response bodies, credentials, authorization headers, email addresses, account labels, workspace paths, private paths, or raw OTLP payloads into normalized evidence or persistence.
Generic Anthropic API metrics do not match the required `claude_code.token.usage` metric identity and cannot become Claude Code evidence.

## Explanation And Retention

Quota movement is calculated only between two measured Claude Code observations with the same exact `QuotaWindowIdentity` and strictly increasing observation times.
Duplicate observation identities are removed, out-of-order inputs are sorted by their measured timestamps, counter decreases reject that exact window, and session windows win deterministic ties over weekly windows.
Resets, expiration, stale inputs, incompatible windows, insufficient observations, flat movement, missing telemetry, unsupported telemetry, unverified account binding, and Observed Zero are distinct states.

The method identity is `claude-code-quota-explanation-v1`.
It performs subtraction of provider-reported percentages only.
It never converts token counts to quota percentage and never allocates reported movement among models or sessions.

`claude-explanations.sqlite` retains at most 100 normalized findings for 30 days.
It stores status, exact interval and reset boundary, measured percentage movement, bounded token totals and model counts when available, evidence and observation counts, source and method versions, and fixed reason categories.
It stores no raw payload, account or session UUID, keyed evidence identity, prompt, code, response, tool detail, terminal output, credential, path, or account label.
Settings deletes this database's findings independently from quota observations, current provider reports, usage, credentials, alert rules, and notification delivery state.

## Verification And Limitations

Automated fixtures cover qualifying Claude Code metrics, generic Anthropic API overlap, unsupported source versions, compatible movement, missing evidence, flat movement, resets, counter decreases, duplicates, out-of-order inputs, cross-account evidence, normalized persistence, independent deletion, and prohibited-content sentinels.
These fixtures prove adapter and privacy behavior only.
They do not prove that Claude Code `2.1.207` emitted identical bytes for a real account.

Signed-app verification remains required with a user-owned Claude Code `2.1.207` installation and user-configured OTLP HTTP/JSON collector.
That verification must confirm the exact displayed interval and provider-reported reset, confirm the metric and required attributes are emitted, and confirm withholding telemetry produces unavailable attribution rather than fallback correlation to generic Anthropic API usage.
No real account, signed application, or canonical producer-generated fixture was available during this implementation.

## Primary Sources

- [Claude Code Monitoring](https://code.claude.com/docs/en/monitoring-usage), first-party Anthropic documentation for OpenTelemetry configuration, metric names, standard attributes, metric cardinality controls, authentication headers, prompt and response logging gates, and token metric attributes.
- [Claude Code Data Usage](https://code.claude.com/docs/en/data-usage), first-party Anthropic documentation for local data, telemetry, and content privacy behavior.
- [OpenTelemetry OTLP Exporter Configuration](https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/), upstream transport configuration referenced by the Claude Code documentation.

All sources were last verified on 2026-07-15.
