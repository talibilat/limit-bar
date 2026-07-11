# LimitBar Issue 9 OpenAI Provider Design

## Context

Issue #9 adds OpenAI organization usage while explicitly validating whether OAuth can reach the required platform endpoints.
LimitBar must not equate credential presence or basic account access with organization usage access.

## Approved Approach

Build an injected OpenAI organization client on the shared HTTP boundary.
Validate OAuth through a bounded request to the organization completions usage endpoint before any Connected state.
Map fixture-backed usage and cost responses independently, then use the existing provider-isolated refresh persistence pattern.

## OAuth Feasibility

The client sends OAuth access tokens as Bearer credentials only to the required usage endpoint.
A decodable 200 response maps to Supported.
Permission denial maps to Admin credential required.
Authentication or unsupported-access responses map to Unsupported or Expired using safe typed outcomes.
Transport and malformed responses map to predefined failure reasons without retaining raw errors or bodies.

Unsupported and admin-required outcomes persist `OpenAIOAuthFeasibility` and matching provider connection state.
Only Supported plus a successful usage refresh may set Connected.

## Usage API

The production request targets `/v1/organization/usage/completions` with Unix start/end times, minute buckets, and grouping by project ID and model.
Pagination is followed until `next_page` is absent.
Admin/platform API keys may use the same endpoint when OAuth is unsupported.

Usage rows require returned project identity and model.
The mapper also requires an explicit configured organization identity so every normalized row displays organization, project, and model.
Missing identities are rejected rather than invented.
Input, output, and cached input tokens use confirmed returned fields with checked arithmetic.

## Costs

Provider-reported cost comes from `/v1/organization/costs`, not the usage endpoint.
Cost responses are paginated and grouped by project ID and line item where supported.
Amounts are mapped using the API's returned units and currency.
Cost-only rows retain returned project/line-item labels and explicit organization identity.
Buckets must be fully contained in the local selected window to avoid importing overlapping UTC reporting periods.

Usage rows without provider cost retain nil cost so existing model pricing may produce `Calculated estimate`.

## Persistence And Failure

Successful refresh transactionally replaces only OpenAI Today/Current Week rows and preserves Anthropic/Azure rows.
Failure retains last confirmed OpenAI values and marks only them stale.
OAuth unsupported/admin-required outcomes do not erase prior confirmed usage.

The same initialization marker prevents a legitimate empty OpenAI snapshot from resurrecting demo data.
Refresh persistence occurs only after the auth method and credential fingerprint are revalidated.

## UI

OpenAI OAuth settings expose a secure access-token save/clear path for feasibility testing without implementing a browser authorization flow.
Both OAuth and admin/platform methods expose Validate & Refresh when credential material is configured.
Organization identity is a required non-secret settings field for refresh.

The OpenAI card shows Unsupported or Admin credential required when no usage rows are available and provider settings carry those states.
Diagnostics show only structured feasibility, connection state, and safe failure summaries.

## Testing

Tests cover feasibility status mapping, no false Connected state, request headers/query/grouping/pagination, organization/project/model mapping, provider-reported and calculated cost paths, identity rejection, local boundaries, provider-isolated replacement, stale failure retention, unsupported/admin-required persistence, and secret/raw-response exclusion.

## Out Of Scope

OAuth browser login, refresh-token exchange, rate-limit urgency, Codex Enterprise internals, arbitrary dashboard scraping, raw response storage, and Anthropic changes are out of scope.

## Acceptance Mapping

Feasibility validation and settings states cover supported, unsupported, and admin-required OAuth.
Fixture mappers cover organization/project/model rows, tokens, and spend.
Existing pricing covers calculated estimates.
Provider-isolated persistence and card-state rendering cover stale values and explicit unsupported diagnostics.
