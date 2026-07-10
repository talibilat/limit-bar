# LimitBar Issue 8 Anthropic Provider Design

## Context

Issue #8 adds the Anthropic Admin usage provider on top of the credential, diagnostics, pricing, and SQLite foundations.
The provider must validate configured Admin API access, map fixture-backed usage into normalized metrics, preserve only labels returned by Anthropic, and keep last confirmed values after refresh failure.

## Approved Approach

Build an injected async Anthropic Admin client in `LimitBarCore` and keep SQLite mutation in a separate synchronous persistence component.
This separates request construction, response mapping, and stored refresh semantics while avoiding live APIs in tests.
The production app supplies a URLSession HTTP adapter and a Keychain credential; tests supply fixture responses and safe failures.

## HTTP Boundary

`HTTPClient` accepts an `HTTPRequest` containing URL, method, headers, and optional body and returns status code plus response data.
The production adapter uses URLSession.
Tests use a fake that records requests and returns fixture data.

`AnthropicAdminClient` targets the Anthropic Admin usage surface under `https://api.anthropic.com/v1/organizations/usage_report/messages`.
Requests send the Admin API key in `x-api-key`, set the required Anthropic version header, and request the selected date interval.
Credential bytes exist only while constructing the request and are never copied into results, diagnostics, errors, or persistence.

Validation uses a bounded usage request and maps HTTP outcomes to structured connection states.
Successful decodable responses produce Connected.
Authentication rejection, insufficient permissions, network failure, and invalid responses produce predefined safe failure reasons.
No raw response body or underlying error text is retained.

## Fixture Response Model

The response mapper supports Admin usage buckets containing start/end timestamps and result rows.
Rows accept returned model and optional returned dimension labels, uncached/input token fields, cache creation/read input token fields, output tokens, optional provider-reported cost and currency, and optional confirmed limit used/denominator fields.

Input tokens equal the sum of confirmed input-side fields returned by the row.
Output tokens use the returned output field.
Rows are grouped by the returned model when present, otherwise by the returned dimension label.
If neither is returned, the row is rejected rather than assigned an invented label.
Returned labels such as Haiku, Sonnet, Opus, Fable, and Cloud Design appear only when present in fixture data.

Provider-reported cost maps to `CostSource.providerReported`.
Rows without provider cost keep `cost == nil`, allowing the existing `CostCalculator` to produce `Calculated estimate` when matching pricing is configured.
Limits remain `Unsupported by provider API` unless both a confirmed used value and positive denominator are returned.

## Time Windows And Aggregation

The mapper uses an injected calendar and current date.
It generates Today and Current Week aggregates from bucket timestamps using half-open intervals.
Metrics group by time window and returned display label.
Token and cost totals use checked arithmetic and safe decimal addition.
The latest included bucket timestamp becomes `refreshedAt`.

## Refresh Persistence

`AnthropicRefreshPersistence` applies a typed refresh result to `SQLiteUsageMetricStore`.
Success transactionally replaces only Anthropic rows for Today and Current Week.
It preserves Azure OpenAI and OpenAI rows.

Failure does not delete or overwrite Anthropic token values or costs.
It marks existing Anthropic rows stale with at least two missed refreshes and returns a safe `ProviderDiagnostic`.
No credential, request, response body, or raw error is written to SQLite.

## App Integration

Anthropic Admin API key settings gain a Validate & Refresh action when a Keychain item is present.
The action reads the credential from Keychain, calls the Admin client away from the main actor, applies the typed result, and updates non-secret provider settings.
Success sets Connected and clears failure reason.
Failure sets Failed, Expired, or the appropriate safe state without exposing the underlying response.

The monitoring popover already loads normalized SQLite metrics.
After a successful settings refresh, Anthropic rows appear in the first provider card through the existing shared rendering path.
Anthropic demo rows are replaced by the provider snapshot rather than shown beside live data.

## Error Handling

Missing credentials skip network access and report Missing.
Malformed fixture rows are rejected safely.
HTTP and decoding failures return typed safe reasons.
Token overflow fails the refresh before persistence, retaining the previous snapshot.
SQLite replacement failure retains the previous snapshot through the existing transaction.

## Testing

Request tests verify URL, method, required headers, date parameters, and that diagnostics/results do not contain the secret sentinel.
Mapping tests cover returned models and dimensions, labels present and absent, input/cache/output token totals, provider cost, calculated-cost fallback, confirmed and unsupported limits, Today/week boundaries, and malformed rows.
Persistence tests cover provider-isolated replacement, successful storage, failure retention, stale marking, and safe diagnostics.
Native build verification covers URLSession and settings integration.

## Out Of Scope

Automatic background polling, notifications, OAuth browser authorization, invented labels, manual provider limits, estimated burn rate, raw response storage, and OpenAI provider work are out of scope.

## Acceptance Mapping

The Admin client and settings action cover credential/API-surface validation.
Fixture DTOs and mapper cover normalized metrics, returned dimensions, tokens, costs, and limits.
Transactional persistence and stale failure handling cover latest confirmed values and refresh diagnostics.
Existing provider cards and pricing calculation cover first-card rendering and calculated-estimate labels.
