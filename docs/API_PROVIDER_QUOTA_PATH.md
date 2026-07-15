# API Provider Quota Path Decision

## Decision

Status: unavailable.

Decision date and last verified date: 2026-07-15.

None of the API provider products currently modeled by LimitBar has a first-party documented source that provides both safely acquirable quota consumption and an exact provider-reported reset boundary under the canonical quota observation contract.
LimitBar therefore does not ship an API-provider quota adapter, fixtures for an invented contract, persistence changes, or a signed-app acceptance claim.
This decision does not change existing API usage and cost collection.

Reconsider this decision when a provider documents a stable API or other source that can be acquired without generating artificial workload and that returns the quota value, its unit and scope, and an absolute reset boundary in the same semantically defined observation.

## Required Contract

A candidate must document all of the following:

- A quota consumption value with a documented unit and scope.
- An absolute provider-reported reset boundary for that consumption window.
- A safe acquisition path available to LimitBar without private scraping, interception of another process, reverse engineering, or artificial billable inference traffic.
- Authentication and authorization that can be narrowed to the documented read operation.
- Stable field semantics and version or compatibility information sufficient to maintain a strict positive allow-list.

Relative durations do not qualify because converting a duration to a date would make LimitBar infer the exact boundary from its local receipt time.
Usage-report bucket boundaries do not qualify unless the provider documents that the bucket is the quota window and reports its quota capacity or consumption semantics.
Configured quota allocation does not qualify as consumption within an active quota window.

## Anthropic API

### Sources

- [Rate limits](https://docs.anthropic.com/en/api/rate-limits), accessed 2026-07-15.
- [API overview](https://docs.anthropic.com/en/api/getting-started), accessed 2026-07-15.
- [Rate Limits API](https://docs.anthropic.com/en/manage-claude/rate-limits-api), accessed 2026-07-15.
- [Usage and Cost API](https://docs.anthropic.com/en/api/usage-cost-api), accessed 2026-07-15.

The reviewed pages do not display publication or revision dates.

### Documented Evidence

The rate-limit guide documents organization-level and optional workspace-level limits for Messages API model classes.
It documents request, input-token, and output-token limit and remaining headers.
The remaining token values are rounded to the nearest thousand.
The corresponding reset headers are RFC 3339 timestamps for when the relevant rate limit will be fully replenished.
The combined token headers identify the most restrictive limit currently in effect, which can be a workspace limit or an organization total.
The service uses a continuously replenished token-bucket algorithm rather than a fixed reset interval.

Claude API authentication uses either an `x-api-key` API key or a Workload Identity Federation bearer token, plus a required `anthropic-version` request header.
The API overview classifies the Messages, Token Counting, and Models APIs as generally available and identifies other listed APIs as beta.
The documented Usage and Cost API and Rate Limits API require an Admin API key and API version `2023-06-01` in the examples reviewed.
The Usage and Cost API reports historical time-bucket token consumption and cost, but it does not report the active rate-limit reset boundary.
The Rate Limits API reports configured organization and workspace limits, but it does not report current remaining capacity or a reset boundary.

### Unmet Criterion

The absolute rate-limit headers are documented only as response evidence from API workload calls.
The first-party documentation reviewed does not provide a read-only endpoint that returns the current remaining value together with those reset timestamps.
LimitBar cannot passively acquire another process's response headers within its supported source boundaries.
Generating a Messages API request only to obtain headers would create artificial, potentially billable provider usage and require a model and request body that are unrelated to the user's workload.
Using the Admin usage buckets or configured-limit endpoint would lose the documented active quota boundary.

Result: unavailable because there is no documented safe acquisition path, even though the workload response headers otherwise document an absolute boundary and consumable count units.

### Versioning, Deprecation, And Unknowns

The reviewed Admin API examples use `anthropic-version: 2023-06-01`.
The rate-limit header guide does not state a separate schema version or compatibility guarantee for the headers.
No deprecation notice for the reviewed headers or Admin endpoints was present in the reviewed pages.
It is unknown whether every successful Messages API version and model returns every listed header.
It is unknown whether any non-workload endpoint returns the same headers with the same scope.
It is unknown whether a future narrowly scoped read credential will be available for current quota consumption.

## OpenAI API

### Sources

- [Rate limits](https://platform.openai.com/docs/guides/rate-limits), accessed 2026-07-15.
- [API overview](https://platform.openai.com/docs/api-reference/introduction#backwards-compatibility), accessed 2026-07-15.
- [Usage API reference](https://platform.openai.com/docs/api-reference/usage), accessed 2026-07-15.

The reviewed pages do not display publication or revision dates.

### Documented Evidence

The rate-limit guide documents organization-level and project-level rate limits that vary by model.
It documents request and token limit and remaining headers, plus optional project-token headers.
The reset fields are durations such as `1s`, `6m0s`, and `3s`, described as the time until the relevant rate limit resets to its initial state.
The guide documents units including requests per minute, requests per day, tokens per minute, tokens per day, images per minute, and audio minutes per minute.

The API overview documents bearer API keys, Admin API keys for administration endpoints, and workload identity federation for short-lived access tokens.
It identifies REST API `v1` as covered by an avoid-breaking-changes policy whenever reasonably possible and explicitly allows new optional response properties as backward-compatible changes.
It identifies the current response `openai-version` value as `2020-10-01`.
The organization Usage API reports aggregate usage in caller-selected buckets with bucket start and end times, request counts, token counts, and optional grouping dimensions.

### Unmet Criterion

The documented rate-limit reset values are relative durations rather than absolute provider-reported timestamps.
Turning those values into dates would require combining them with a locally observed response time, which the canonical contract prohibits.
The Usage API bucket boundaries describe reporting buckets, not provider quota windows, and the usage response does not document the corresponding quota capacity or active reset boundary.

Result: unavailable because no reviewed source reports an absolute provider-reported reset boundary for the documented quota consumption value.

### Versioning, Deprecation, And Unknowns

The reviewed REST API is `v1`, and OpenAI documents its general backward-compatibility policy and changelog.
No deprecation notice for the reviewed rate-limit headers or Usage API was present in the reviewed pages.
It is unknown whether OpenAI will add an absolute reset timestamp or a quota-status endpoint.
The exact enforcement algorithm and correspondence between usage buckets and every rate-limit dimension are not documented as a stable quota-window identity.

## Azure OpenAI

### Sources

- [Azure OpenAI quotas and limits](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits), accessed 2026-07-15, page dated 2026-05-27 and updated 2026-06-05.
- [Manage Azure OpenAI quota](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/quota), accessed 2026-07-15, page dated 2026-05-04 and updated 2026-05-07.
- [Usages - List](https://learn.microsoft.com/en-us/rest/api/aiservices/accountmanagement/usages/list?view=rest-aiservices-accountmanagement-2024-10-01), accessed 2026-07-15, stable API version `2024-10-01`.
- [Azure built-in roles for AI and machine learning](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning#cognitive-services-usages-reader), accessed 2026-07-15, page dated and updated 2026-07-01.

### Documented Evidence

Azure OpenAI quota is scoped per subscription, region, model, and deployment type and is allocated in tokens per minute.
The management guide documents the Cognitive Services Usages Reader role at subscription scope as the narrowest role for viewing quota usage.
The Azure Resource Manager Usages endpoint uses Microsoft Entra bearer authentication and returns quota lines for a subscription and location.
For Azure OpenAI, the documented example returns `name.value`, `currentValue`, `limit`, and `unit`.
The guide defines `currentValue` as quota consumed by deployments, meaning allocated deployment capacity, rather than inference consumption in an active reset window.

The generic stable `2024-10-01` Usages schema also defines optional `nextResetTime`, `quotaPeriod`, and `status` fields.
The Azure OpenAI-specific example and key-field table omit those fields and do not document a reset boundary for Azure OpenAI allocation quota.
The Azure OpenAI inference headers document request and token limits and remaining values, but their reset fields are durations in seconds.

### Unmet Criterion

The documented Usages API value is deployment allocation against a regional subscription limit, not quota consumption within an active quota window.
The Azure OpenAI documentation does not establish that `nextResetTime` is returned for Azure OpenAI quota lines or define what would reset, and its Azure OpenAI example omits the field.
The inference response reset headers are relative durations and would require LimitBar to infer an absolute boundary.

Result: unavailable because no reviewed source documents an exact consumption-window boundary for the Azure OpenAI value it returns.

### Versioning, Deprecation, And Unknowns

The reviewed Usages operation is the stable `2024-10-01` API version, with `2024-04-01-preview` and `2024-06-01-preview` also listed.
The quota-tier control-plane API shown in the quotas guide is `2025-10-01-preview` and is not a candidate because it reports tier assignment rather than quota-window consumption.
No deprecation notice for stable Usages API `2024-10-01` was present in the reviewed pages.
It is unknown which Azure OpenAI quota lines, if any, return `nextResetTime` or `quotaPeriod` in real accounts.
Undocumented observed values cannot resolve that unknown.

## Product Behavior

`ProviderProduct.apiQuotaPathAvailability` records a fixed unavailable reason for each modeled API provider product.
The alert settings surface states the aggregate unavailable result and does not offer API-provider quota rules.
Claude Code and Codex subscription quota behavior is unaffected.
No raw provider payload, credential, fixture, observation, diagnostic export field, or analytics input is introduced by this decision.
