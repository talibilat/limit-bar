# Provider Incident Correlation

LimitBar can compare official public provider incident times with exact local failure times.
This comparison is temporal evidence only.
It does not establish that an incident caused a failure.

## Supported Status Sources

LimitBar queries only these public endpoints:

- Anthropic: `https://status.anthropic.com/api/v2/summary.json`
- OpenAI: `https://status.openai.com/api/v2/summary.json`

Anthropic components are mapped only when they identify Claude Code, Claude API, Claude Console, or claude.ai.
OpenAI components are mapped only when they identify Codex, the Codex VS Code surface, Codex in ChatGPT, or the OpenAI API.
Unknown components remain unsupported and are not assigned to a known product.
OpenAI mapping uses an exact allow-list of official component names and known official component IDs.
Names containing fragments such as `api` or `codex` do not qualify by substring.
An incident is associated with a product only when the official payload explicitly links that incident to a supported component.
LimitBar does not associate an unlinked OpenAI incident with a degraded component merely because both appear in the same response.
An unlinked incident is still retained as bounded normalized provider-level history with empty product coverage.
Provider-level history never enters product correlation or capacity publication without an official component link.

## Manual Check

Open the rate-limit analysis, choose **Investigate**, and select **Check Provider Status**.
The action checks both official endpoints once.
It does not start a provider usage refresh or a Local Refresh Cycle.

The incident lane shows the last check time, observation age, and outcome.
Endpoint unavailable, malformed payload, unsupported schema, unsupported component, stale observation, and no published incident are separate states.

## Optional Subscription

Open LimitBar settings and find **Official Provider Status**.
Enable **Check every six hours** to subscribe.

The subscription is disabled by default.
Its fixed six-hour cadence is deliberately independent from the Local Refresh cadence and explicit provider refreshes.
On relaunch or wake, LimitBar checks only when the last retained check is due.
Disabling the subscription cancels its task and Local Refresh Cycles do not produce status network activity.

## Four Evidence Lanes

The forensic investigation presents four independent lanes:

- **Provider incident** contains normalized official incident evidence.
- **Quota state** contains normalized quota observations and gaps.
- **Typed local failure** contains a captured local failure class and exact time when available.
- **Authentication** contains authentication evidence when available.

No lane overwrites, suppresses, or infers another lane.
For example, a published incident does not replace quota evidence, and an authentication failure does not imply that no incident existed.
OpenAI API credentials are not Codex authentication evidence.
The Codex authentication lane remains unavailable unless LimitBar has genuine Codex-specific authentication evidence.

When an official incident interval contains an exact local failure time, LimitBar says:

> Official incident overlapped this failure. Temporal overlap does not establish causation.

When no published incident interval contains that time, LimitBar says that the absence does not establish provider health or quota exhaustion.
An incident with an exact reported resolution is half-open: it includes its start instant and excludes its resolved instant.
An unresolved incident is historical evidence only from its reported start through a check that actually listed it.
It is not extended past the latest confirming observation.
A later check where the incident disappears retires current evidence without deleting the earlier bounded observation used for historical correlation.

## Privacy

Status requests are anonymous `GET` requests with no body and no application-supplied headers.
LimitBar sends no credentials, cookies, account identifiers, account labels, local failure details, quota evidence, client identifiers, prompts, code, paths, or other local context.
The dedicated URL session disables cookie storage and response caching.
It rejects redirects outside the original approved HTTPS status origin, including HTTPS downgrades and alternate ports.

LimitBar does not persist raw status payloads or arbitrary incident prose.
It retains only bounded normalized incident identifiers, mapped products, component states, impact, status, start/update/resolution timestamps, and latest update state.
Every supplied incident-update timestamp must parse and have a non-decreasing created/update order or the complete payload is marked malformed and unavailable.

## Retention And Deletion

Status observations are retained locally for at most 14 days and 96 checks.
Each check stores at most 64 incidents, 128 components, and 32 update-state entries per incident during normalization.
The current file is `provider-status-v2.json` in LimitBar's Application Support directory and is written with owner-only permissions.

The pre-release version 1 incident envelope has no trustworthy check timestamp and is rejected without rewriting rather than fabricating `checkedAt` provenance.
Unknown persistent schema versions fail closed and are not interpreted as current evidence.
A persisted incident whose Provider Status Service differs from its containing observation rejects the complete read without rewriting the file.

Use **Delete Provider Status History** in settings to remove only retained status observations.
Deletion does not alter quota evidence, local failures, authentication evidence, usage, settings, credentials, alert state, or provider refresh history.

## Capacity Publication

Only a supported incident explicitly linked to a qualifying component in that service's latest fresh successful check can enter the privacy-safe capacity publication.
Recognized active incident status, recognized active update state, recognized degraded component state, and minor or greater impact are all required.
The publication contains only product and bounded observation/expiry times.
Expired, resolved, unknown-status, unknown-impact, unknown-component-status, unsupported-product, stale, unlinked, and absent incidents are excluded.
A newer no-incident, unavailable, malformed, unsupported-component, or unsupported-schema outcome retires earlier active capacity evidence while retaining bounded history for forensic correlation.
Capacity decisions still preserve quota and incident reasons independently and do not claim causation.
