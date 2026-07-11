# LimitBar Issue 8 Anthropic Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate Anthropic Admin access, map fixture-backed usage into normalized metrics, and persist refresh success/failure honestly.

**Architecture:** Add an injected async HTTP boundary and Anthropic client/mapper in `LimitBarCore`; keep SQLite refresh application synchronous and provider-isolated. Add a production URLSession adapter and a settings Validate & Refresh action that uses Keychain without exposing secrets.

**Tech Stack:** Swift 6, Foundation, FoundationNetworking-compatible URLSession APIs, Swift Testing, SQLite3, SwiftUI, macOS 14+.

## Global Constraints

- Never persist or diagnose API keys, request headers, response bodies, or raw provider errors.
- Preserve only labels returned by Anthropic; never invent model or dimension names.
- Anthropic limits remain Unsupported by provider API unless a confirmed positive denominator is returned.
- Provider-reported cost wins; otherwise existing configured pricing may calculate a labeled estimate.
- Refresh failure retains last confirmed values and marks them stale.
- Tests use fixture HTTP clients and never call Anthropic.

---

## File Structure

- Create `LimitBarCore/Sources/LimitBarCore/HTTPClient.swift` for transport-neutral request/response types and protocol.
- Create `LimitBarCore/Sources/LimitBarCore/AnthropicUsageProvider.swift` for DTOs, request construction, validation, mapping, typed outcomes, and persistence.
- Create `LimitBarCore/Tests/LimitBarCoreTests/AnthropicUsageProviderTests.swift` for request, mapping, privacy, and refresh behavior.
- Modify `LimitBarCore/Sources/LimitBarCore/SQLiteUsageMetricStore.swift` with provider-scoped stale marking.
- Create `LimitBar/AnthropicRefreshService.swift` for URLSession and application-support orchestration.
- Modify `LimitBar/ProviderSettingsView.swift` and `LimitBar.xcodeproj/project.pbxproj` for Validate & Refresh.

### Task 1: HTTP Boundary And Anthropic Request Validation

**Files:**
- Create: `LimitBarCore/Sources/LimitBarCore/HTTPClient.swift`
- Create: `LimitBarCore/Sources/LimitBarCore/AnthropicUsageProvider.swift`
- Create: `LimitBarCore/Tests/LimitBarCoreTests/AnthropicUsageProviderTests.swift`

**Interfaces:**
- Produces: `HTTPRequest`, `HTTPResponse`, `HTTPClient`, `AnthropicAdminClient.validate(apiKey:interval:)`, and `AnthropicProviderOutcome`.

- [ ] Write failing async tests with a fake HTTP client. Assert the request uses GET, the official usage URL, `x-api-key`, `anthropic-version`, ISO-8601 start/end query parameters, and no secret appears in outcome/diagnostic encoding. Cover status 200 connected, 401 authentication rejected, 403 insufficient permissions, and transport failure network unavailable.
- [ ] Run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore --filter AnthropicUsageProviderTests` and verify missing-type failures.
- [ ] Implement Sendable request/response structs, async `HTTPClient.send(_:)`, safe `AnthropicProviderOutcome`, and request/status mapping. Decode a successful response before returning Connected; never retain raw body or error.
- [ ] Run focused and full core tests; expect PASS.
- [ ] Commit with `git commit -m "Validate Anthropic Admin access"`.

### Task 2: Fixture Usage Mapping

**Files:**
- Modify: `LimitBarCore/Sources/LimitBarCore/AnthropicUsageProvider.swift`
- Modify: `LimitBarCore/Tests/LimitBarCoreTests/AnthropicUsageProviderTests.swift`

**Interfaces:**
- Produces: `AnthropicUsageMapper.metrics(from:now:calendar:) throws -> [UsageMetric]` and `AnthropicAdminClient.fetchUsage(apiKey:interval:)`.

- [ ] Add failing fixture tests with buckets/results containing returned `model`, returned `dimension_label`, uncached/cache-creation/cache-read input fields, output tokens, optional cost/currency, and optional confirmed limit values. Assert Today/week grouping, exact labels, no invented fallback, checked totals, provider-reported cost, nil cost fallback, confirmed/unsupported limits, latest timestamp, and malformed unlabeled rows rejected.
- [ ] Run the focused suite and verify mapping failures.
- [ ] Implement Codable fixture DTOs and deterministic mapper. Use half-open windows and checked integer addition. Group by `(TimeWindow, returned label)` and sort deterministically.
- [ ] Run focused/full tests; expect PASS.
- [ ] Commit with `git commit -m "Map Anthropic usage fixtures"`.

### Task 3: Provider-Isolated Refresh Persistence

**Files:**
- Modify: `LimitBarCore/Sources/LimitBarCore/AnthropicUsageProvider.swift`
- Modify: `LimitBarCore/Sources/LimitBarCore/SQLiteUsageMetricStore.swift`
- Modify: `LimitBarCore/Tests/LimitBarCoreTests/AnthropicUsageProviderTests.swift`

**Interfaces:**
- Produces: `AnthropicRefreshResult`, `AnthropicRefreshPersistence.apply(_:to:)`, and `SQLiteUsageMetricStore.markMetricsStale(provider:timeWindows:missedRefreshes:)`.

- [ ] Add failing tests proving success replaces Anthropic demo/old rows while preserving Azure/OpenAI, and failure preserves Anthropic tokens/cost while marking only Anthropic rows stale. Assert returned diagnostics use fixed safe reasons.
- [ ] Run focused tests and verify failures.
- [ ] Implement provider-scoped stale SQL and persistence. Validate success metrics are Anthropic and use the existing transactional replacement. Failure performs no delete/insert.
- [ ] Run focused/full tests; expect PASS.
- [ ] Commit with `git commit -m "Persist Anthropic refresh outcomes"`.

### Task 4: URLSession And Settings Refresh Integration

**Files:**
- Create: `LimitBar/AnthropicRefreshService.swift`
- Modify: `LimitBar/ProviderSettingsView.swift`
- Modify: `LimitBar.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `URLSessionHTTPClient` and `AnthropicRefreshService.refresh(apiKey:) async -> AnthropicProviderOutcome`.

- [ ] Implement URLSession transport without logging requests/responses. Build application-support SQLite, fetch Anthropic usage for Current Week, map Today/week metrics, apply persistence, and return only typed safe outcome.
- [ ] Add a `Validate & Refresh` button for Anthropic Admin API key when Keychain presence is configured. Read credential bytes, convert to UTF-8 only for the request, await refresh, update provider settings to Connected or a safe failure state/reason, and clear temporary bytes. Missing credential sets Missing and skips network.
- [ ] Add the app source to the Xcode project.
- [ ] Run full core tests and native build; expect PASS and `** BUILD SUCCEEDED **`.
- [ ] Commit with `git commit -m "Refresh Anthropic usage from settings"`.

### Task 5: Privacy Review And Delivery

**Files:**
- Modify only files required by verified findings.

- [ ] Search the complete diff for request headers, credential strings, raw response/error persistence, and invented labels. Confirm diagnostics and SQLite schemas remain secret-free.
- [ ] Run full core tests, native build, and `git diff --check origin/main...HEAD`.
- [ ] Request independent review against issue #8 and fix every Critical/Important finding with regression tests where feasible.
- [ ] Push, create a PR with `Closes #8`, inspect mergeability/checks, merge, and verify closure.

## Self-Review

- Spec coverage: API validation, fixture mapping, exact labels, tokens, costs, limits, success replacement, stale failure, safe diagnostics, and settings refresh all map to tasks.
- Placeholder scan: no incomplete markers remain.
- Interface consistency: HTTP, outcome, mapper, persistence, and app service names are stable across tasks.
- Scope check: OpenAI, OAuth browser flow, polling, and notifications remain excluded.
