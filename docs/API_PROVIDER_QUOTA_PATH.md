# API Provider Quota Path Decision

## Decision

Status: unavailable.

Decision date and last verified date: 2026-07-15.

None of the API provider products currently modeled by LimitBar has a first-party documented source that provides safely acquirable quota consumption in an exact provider-defined Quota window with a provider-reported boundary.
LimitBar therefore does not ship an API-provider quota adapter, fixtures for an invented contract, persistence changes, or a signed-app acceptance claim.
This decision does not change existing API usage and cost collection.

Every provider has three independently recorded blockers:

- Workload response evidence has no documented safe acquisition path for LimitBar without intercepting another process or creating artificial workload.
- No reviewed read endpoint reports quota consumption, rather than historical usage or configured allocation.
- No reviewed source defines an exact provider Quota window and reports its boundary.

Reconsider this decision when a provider documents a stable read source that returns the quota value, unit, scope, exact provider-defined window identity, and provider-reported boundary in one semantically defined observation.

## Required Contract

A candidate must document all of the following:

- A quota consumption value with a documented unit and scope.
- An exact provider-defined Quota window and its provider-reported boundary.
- A safe acquisition path available to LimitBar without private scraping, interception of another process, reverse engineering, or artificial billable inference traffic.
- Authentication and authorization that can be narrowed to the documented read operation.
- Stable field semantics and version or compatibility information sufficient to maintain a strict positive allow-list.

A relative duration does not qualify because converting it to a date would make LimitBar infer a boundary from local receipt time.
A time when a continuously replenished token bucket would become full does not qualify because it changes with bucket state and is not a boundary of an exact provider-defined Quota window.
Usage-report bucket boundaries do not qualify unless the provider documents that the bucket is the Quota window and reports its quota capacity or consumption semantics.
Configured quota allocation does not qualify as consumption within an active Quota window.

## Anthropic API

### Sources

- [Rate limits](https://docs.anthropic.com/en/api/rate-limits), accessed 2026-07-15.
- [API overview](https://docs.anthropic.com/en/api/getting-started), accessed 2026-07-15.
- [Admin API](https://docs.anthropic.com/en/manage-claude/admin-api), accessed 2026-07-15.
- [Create an Admin API key](https://docs.anthropic.com/en/manage-claude/admin-api-keys), accessed 2026-07-15.
- [Rate Limits API](https://docs.anthropic.com/en/manage-claude/rate-limits-api), accessed 2026-07-15.
- [Usage and Cost API](https://docs.anthropic.com/en/api/usage-cost-api), accessed 2026-07-15.
- [Get Messages Usage Report](https://docs.anthropic.com/en/api/admin-api/usage-cost/get-messages-usage-report), accessed 2026-07-15.

The reviewed pages do not display publication or revision dates.

### Workload Response Evidence

The rate-limit guide documents organization-level and optional workspace-level limits for Messages API model classes.
It documents request, input-token, and output-token limit and remaining headers.
Remaining token values are rounded to the nearest thousand.
The corresponding reset headers are RFC 3339 timestamps for when each continuously replenished token bucket would be fully replenished.
The combined token headers identify the most restrictive limit currently in effect, which can be a workspace limit or an organization total.

These timestamps are not Exact boundaries for Quota windows.
Anthropic explicitly documents a continuously replenished token-bucket algorithm rather than fixed windows, so the full-replenishment timestamp moves with the bucket state.
The headers therefore cannot establish the exact provider-defined Quota window identity required by the canonical contract.

LimitBar also has no documented passive access to another process's workload responses.
Generating a Messages request only to obtain headers would create artificial, potentially billable usage and require unrelated model and request-body choices.

### Read Endpoints

The Usage and Cost API reports historical usage in caller-selected `1m`, `1h`, or `1d` UTC buckets.
The Messages usage endpoint returns bucket start and exclusive end timestamps, token counts, and optional organization breakdowns.
Those reporting buckets are not documented as rate-limit or quota windows and do not carry quota capacity, remaining capacity, or a provider-defined Quota window boundary.

The Rate Limits API returns configured organization and workspace limits.
It does not return current consumption, current remaining capacity, or a Quota window boundary.

### Authentication And Eligibility

The Usage and Cost guide states that the Admin API is unavailable for individual accounts and requires a Claude Console organization.
It also states that Usage and Cost endpoints are unavailable on Claude Platform on AWS.
Claude Enterprise uses a separate Analytics API and key type, so it is not the reviewed Claude API Usage and Cost candidate.

For a Claude Console organization, an organization member with the admin role can create an Admin API key with prefix `sk-ant-admin01-` and send it through `x-api-key` with `anthropic-version: 2023-06-01`.
Claude Console Admin API keys have no selectable scopes and carry full access to every endpoint that accepts Admin API keys.
The current Admin API documentation also permits an OAuth bearer token with organization-wide `org:admin` scope, and the Messages Usage reference shows that credential form.
Neither credential is a narrow usage-read scope.

### Operational Rate Limits

The Usage and Cost guide recommends polling its read endpoints no more than once per minute for sustained use and permits more frequent short pagination bursts.
This is documented operational polling guidance, not a numeric hard endpoint quota.
The Rate Limits API guide recommends reading at startup and on a schedule but documents no numeric request limit.
The numeric RPM, ITPM, and OTPM limits and token-bucket behavior in the rate-limit guide govern workload APIs and must not be represented as acquisition limits for the Usage and Cost API or Rate Limits API.

### Result And Unknowns

Result: unavailable due to unsafe workload-evidence acquisition, no read endpoint for current quota consumption, and no exact provider-defined Quota window boundary.

The reviewed Admin API examples use `anthropic-version: 2023-06-01`.
The rate-limit header guide does not state a separate schema version or compatibility guarantee for the headers.
No deprecation notice for the reviewed headers or Admin endpoints was present in the reviewed pages.
The hard request limits for the Usage and Cost and Rate Limits read endpoints are unknown.
It is unknown whether Anthropic will provide a narrowly scoped current-quota read operation with exact window semantics.

## OpenAI API

### Sources

- [Rate limits](https://platform.openai.com/docs/guides/rate-limits), accessed 2026-07-15.
- [API overview](https://platform.openai.com/docs/api-reference/introduction#backwards-compatibility), accessed 2026-07-15.
- [Admin APIs](https://platform.openai.com/docs/guides/admin-apis), accessed 2026-07-15.
- [Admin and Audit Logs API for the API Platform](https://help.openai.com/en/articles/9687866-admin-and-audit-logs-api-for-the-api-platform), accessed 2026-07-15, displayed as updated 18 hours earlier.
- [Usage API reference](https://platform.openai.com/docs/api-reference/usage), accessed 2026-07-15.

The reviewed developer documentation pages do not display publication or revision dates.

### Workload Response Evidence

The rate-limit guide documents organization-level and project-level rate limits that vary by model.
It documents request and token limit and remaining headers, plus optional project-token headers.
The reset fields are relative durations such as `1s`, `6m0s`, and `3s`, described as time until the relevant rate limit resets to its initial state.
The guide documents workload units including requests per minute, requests per day, tokens per minute, tokens per day, images per minute, and audio minutes per minute.

Relative durations are not provider-reported boundaries.
Converting one to a date would require combining it with LimitBar's local response receipt time.
LimitBar also has no documented passive access to another process's workload responses, and an artificial model request is not an acceptable acquisition path.

### Read Endpoint

The organization Usage API reports aggregate usage in caller-selected buckets with start and end times, request counts, token counts, and optional grouping dimensions.
Those bucket boundaries are reporting intervals rather than documented provider Quota windows.
The response does not report corresponding quota capacity, remaining quota, or an exact provider-defined Quota window boundary.

### Authentication And Eligibility

OpenAI classifies the Usage API under its Administration API surface and requires an Admin API key for Admin APIs.
Only organization owners can create Admin API keys.
The Admin API documentation says these keys cannot be used for non-administration endpoints, and OpenAI describes them as carrying required management scopes.
The reviewed first-party documentation does not identify a narrower usage-read-only Admin API key, selectable scope, organization role, project credential, or workload-identity permission that can call the Usage API.
Narrower access for this endpoint is therefore unknown and must not be assumed.

### Operational Rate Limits

The reviewed Usage API and Admin API documentation does not publish a numeric request limit or recommended polling interval for the organization Usage read endpoint.
Its acquisition rate limit is unknown.
The request and token limits in the workload rate-limit guide apply to model traffic and must not be represented as the Usage endpoint's acquisition limit.

### Result And Unknowns

Result: unavailable due to unsafe workload-evidence acquisition, no read endpoint for current quota consumption, and no exact provider-defined Quota window boundary.

The reviewed REST API is `v1`, and OpenAI documents a general policy of avoiding breaking changes whenever reasonably possible.
The API overview identifies the current response `openai-version` value as `2020-10-01`.
No deprecation notice for the reviewed rate-limit headers or Usage API was present in the reviewed pages.
The Usage endpoint acquisition rate limit and narrower read-only authorization are unknown.
It is unknown whether OpenAI will add a current-quota status endpoint with a Quota window and Exact boundary.

## Azure OpenAI

### Sources

- [Azure OpenAI quotas and limits](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits), accessed 2026-07-15, page dated 2026-05-27 and updated 2026-06-05.
- [Manage Azure OpenAI quota](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/quota), accessed 2026-07-15, page dated 2026-05-04 and updated 2026-05-07.
- [Usages - List](https://learn.microsoft.com/en-us/rest/api/aiservices/accountmanagement/usages/list?view=rest-aiservices-accountmanagement-2024-10-01), accessed 2026-07-15, stable API version `2024-10-01`.
- [Azure built-in roles for AI and machine learning](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning#cognitive-services-usages-reader), accessed 2026-07-15, page dated and updated 2026-07-01.
- [Azure Resource Manager request limits and throttling](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling), accessed 2026-07-15, page dated 2026-02-27 and updated 2026-04-03.

### Workload Response Evidence

Azure OpenAI inference responses document request and token limit and remaining headers.
Their reset fields are relative durations in seconds, not provider-reported boundaries.
LimitBar has no documented passive access to another process's inference responses, and an artificial inference request is not an acceptable acquisition path.

### Read Endpoint

Azure OpenAI quota is scoped per subscription, region, model, and deployment type and allocated in tokens per minute.
The Azure Resource Manager Usages endpoint returns quota lines for a subscription and location.
The Azure OpenAI-specific example returns `name.value`, `currentValue`, `limit`, and `unit`.
The guide defines `currentValue` as quota consumed by deployments, meaning allocated deployment capacity rather than inference consumption in an active Quota window.

The generic stable `2024-10-01` Usages schema defines optional `nextResetTime`, `quotaPeriod`, and `status` fields.
The Azure OpenAI-specific example and key-field table omit those fields and do not document reset semantics for Azure OpenAI allocation quota.
The generic optional fields cannot establish that Azure OpenAI returns an exact consumption-window boundary.

### Authentication And Eligibility

The Usages endpoint uses a Microsoft Entra bearer token for Azure Resource Manager, requested for `https://management.azure.com/.default` in the documented example.
Microsoft recommends the built-in Cognitive Services Usages Reader role as the minimum access for viewing quota usage.
The role must be assigned at subscription scope and is not available at resource scope.
The broader subscription Reader role can also read the data but grants access beyond the quota operation.

### Operational Rate Limits

Azure Resource Manager applies a regional token bucket to subscription reads with a documented bucket size of 250 and refill rate of 25 requests per second.
The subscription limit applies per subscription, service principal, and operation type, with a global subscription limit equal to 15 times the individual service-principal limit.
Free and trial limits can be lower.
Azure Resource Manager returns HTTP 429 and `Retry-After` when throttled.

These are general Azure Resource Manager control-plane limits, not a documented Cognitive Services Usages endpoint-specific guarantee.
Resource providers can impose additional throttling, and the reviewed documentation publishes no Microsoft.CognitiveServices Usages-specific request limit.
That endpoint-specific acquisition limit is unknown.
Azure OpenAI inference TPM and RPM limits govern workload traffic and must not be represented as acquisition limits for the Resource Manager Usages endpoint.

### Result And Unknowns

Result: unavailable due to unsafe workload-evidence acquisition, no read endpoint for inference quota consumption, and no exact provider-defined Quota window boundary.

The reviewed Usages operation is stable API version `2024-10-01`, with `2024-04-01-preview` and `2024-06-01-preview` also listed.
The quota-tier control-plane API shown in the quotas guide is `2025-10-01-preview` and is not a candidate because it reports tier assignment rather than quota-window consumption.
No deprecation notice for stable Usages API `2024-10-01` was present in the reviewed pages.
The Microsoft.CognitiveServices endpoint-specific acquisition rate limit is unknown.
It is unknown which Azure OpenAI quota lines, if any, return `nextResetTime` or `quotaPeriod` in real accounts, and undocumented observed values cannot resolve that unknown.

## Product Behavior

`ProviderProduct.apiQuotaPathAvailability` records all three fixed unmet criteria for each modeled API provider product.
The alert settings surface states the aggregate unavailable result and does not offer API-provider quota rules.
Claude Code and Codex subscription quota behavior is unaffected.
No raw provider payload, credential, fixture, observation, diagnostic export field, or analytics input is introduced by this decision.
