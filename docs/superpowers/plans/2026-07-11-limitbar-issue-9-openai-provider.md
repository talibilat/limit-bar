# LimitBar Issue 9 OpenAI Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate OpenAI organization-usage feasibility and persist fixture-backed organization/project/model usage with honest unsupported states.

**Architecture:** Add an injected OpenAI organization client and fixture mapper in `LimitBarCore`, reuse typed provider refresh persistence, and integrate a credential-safe Validate & Refresh settings action. Card rendering consumes persisted settings to display unsupported/admin-required state when metrics are absent.

**Tech Stack:** Swift 6, Foundation, Swift Testing, SQLite3, SwiftUI, Keychain, URLSession, macOS 14+.

## Global Constraints

- Never mark OpenAI Connected before required organization usage access succeeds.
- Never persist OAuth/admin credentials, request headers, raw responses, or raw errors.
- Every usage row requires explicit organization, project, and model identity.
- Provider cost uses confirmed cost responses; otherwise existing pricing may calculate estimates.
- Failure and unsupported feasibility retain prior confirmed metrics.

---

### Task 1: OAuth Feasibility And Requests

**Files:** Create `LimitBarCore/Sources/LimitBarCore/OpenAIUsageProvider.swift`; create `LimitBarCore/Tests/LimitBarCoreTests/OpenAIUsageProviderTests.swift`.

- [ ] Write failing fake-HTTP tests for Bearer auth, `/v1/organization/usage/completions`, Unix boundaries, `bucket_width=1m`, project/model grouping, pagination, and supported/unsupported/admin-required/expired/network outcomes. Assert no secret/raw body in outcomes.
- [ ] Run the focused suite and verify missing types.
- [ ] Implement `OpenAIOrganizationClient`, `OpenAIFeasibilityOutcome`, request construction, safe status mapping, and pagination.
- [ ] Run focused/full tests and commit `Validate OpenAI usage feasibility`.

### Task 2: Usage And Cost Mapping

**Files:** Modify OpenAI provider source/tests.

- [ ] Add failing fixtures for explicit organization ID, project ID/name, model, input/output/cached tokens, returned spend, missing identities, local boundaries, pagination, and pricing fallback.
- [ ] Implement checked `OpenAIUsageMapper` grouped by time window/org/project/model and `OpenAICostMapper` grouped by returned project/line item with fully-contained buckets.
- [ ] Run focused/full tests and commit `Map OpenAI usage fixtures`.

### Task 3: Persistence And Unsupported Card State

**Files:** Modify OpenAI source/tests, `LimitBar/MonitoringPopoverView.swift`, and provider settings model if needed.

- [ ] Add failing tests proving success replaces only OpenAI rows, failure/unsupported/admin-required retain and stale prior OpenAI rows, and safe diagnostics map feasibility correctly.
- [ ] Implement `OpenAIRefreshPersistence` using existing transactional replacement and provider-scoped stale marking.
- [ ] Extend non-secret settings with optional OpenAI organization identity and render structured unsupported/admin-required copy in the empty OpenAI card.
- [ ] Run tests/build and commit `Persist OpenAI refresh outcomes`.

### Task 4: Settings Validate And Refresh

**Files:** Create `LimitBar/OpenAIRefreshService.swift`; modify `LimitBar/ProviderSettingsView.swift` and Xcode project.

- [ ] Add secure OAuth access-token controls and organization identity field. Keep admin API-key controls.
- [ ] Implement fetch-then-revalidate-then-persist lifecycle using credential fingerprint, zeroed buffers, and typed outcomes. Supported success sets Connected; unsupported/admin outcomes update feasibility/state and never erase metrics.
- [ ] Add the source to Xcode, run full tests/build, and commit `Refresh OpenAI usage from settings`.

### Task 5: Review And Delivery

- [ ] Search diff for credential/raw-response leakage and false Connected transitions.
- [ ] Run full core tests, native build, and diff check.
- [ ] Request independent review and fix Critical/Important findings with regressions.
- [ ] Push, PR with `Closes #9`, merge, and verify closure.

## Self-Review

- All issue criteria map to feasibility, mapping, persistence/card, and settings tasks.
- No placeholders or cross-provider scope remain.
- OpenAI client, mapper, persistence, and app service names remain consistent.
