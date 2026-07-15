# 01 - Land Quota Insights Foundation

## Parent

Source plan: `futures/01-quota-doctor.md`.

This ticket delivers the prerequisite foundation described in Phase 1 of the parent specification.
It does not complete Quota Doctor.

## What to build

Review, validate, and land the Quota Insights foundation currently proposed by PR #22.
Retain only the work that supports the parent specification's canonical direction for measured quota observations, exact quota-window identity, bounded local persistence, qualified burn and exhaustion calculations, visible provenance, deletion, and privacy-safe diagnostics.
Resolve the remaining native test execution blocker in a suitable environment and complete signed-application manual acceptance before treating the foundation as landed and validated.

The result must establish a dependable base for later attribution, explanation, anomaly, forecasting-validation, alerting, and workload-planning tickets without claiming that those later capabilities exist.

## Confirmed starting point

- PR #22 is open and unmerged on branch `ticket-14-quota-insights`.
- CI was green at the last inspection.
- The last known CI result is evidence about that inspected revision, not a guarantee that a later revision remains green.
- Current `main` does not contain the PR #22 foundation.
- PR #22 provides measured Claude Code and Codex quota percentages.
- PR #22 identifies quota windows using stable window identifiers and provider-reported reset boundaries.
- PR #22 provides bounded SQLite retention, observation deduplication, per-window count limits, and explicit deletion.
- PR #22 provides calculated burn-rate and exhaustion ranges when observations qualify.
- PR #22 provides explicit unavailable states for insufficient, stale, decreasing, flat, reset, or expired evidence.
- PR #22 adds measured and calculated labels to existing rate-limit rows.
- PR #22 adds coarse quota findings to the privacy-safe diagnostic export.
- PR #22 includes automated core, persistence, schema, analytics, and export tests.
- Native XCTest launch is blocked in the currently inspected local environment.
- Signed-application manual acceptance remains pending.
- It is unknown whether PR #22 has changed since the last inspection, so its current revision, checks, review state, and mergeability must be re-established before landing.
- It is unknown whether the local XCTest launch blocker is caused by the project, the selected Xcode environment, or machine-specific state.

## Scope

- Review the complete current PR #22 diff against the parent specification rather than assuming the last inspected revision is unchanged.
- Confirm that quota percentages remain classified as measured and that derived burn and exhaustion ranges remain classified as calculated.
- Confirm that quota observations use the exact provider product, stable window identifier, and provider-reported reset boundary needed to prevent observations from different windows from being combined.
- Confirm that no exact reset boundary is inferred when the provider does not report one.
- Confirm that persistence remains local, bounded by age and count, deduplicated, and independently deletable.
- Confirm that duplicate observations do not increase the effective evidence sample.
- Confirm that counter decreases, reset transitions, expired windows, stale evidence, insufficient evidence, and flat evidence produce the documented qualified or unavailable outcomes.
- Confirm that an exhaustion range never extends beyond the provider-reported reset boundary.
- Confirm that the concise UI distinguishes measured provider usage from calculated forecast information and does not imply that the foundation explains consumption.
- Confirm that diagnostic findings use the existing positive allow-list and remain coarse enough to avoid exposing prohibited content.
- Run the automated suites relevant to the foundation in an environment capable of launching them.
- Diagnose the local native XCTest launch failure far enough to determine whether a repository change is required.
- If the launch failure is environmental, record reproducible evidence and run the native suite in another working environment.
- Exercise the signed application against supported real local sources for the manual acceptance cases listed in this ticket.
- Address review findings that are required for the canonical model, privacy boundary, correctness, migration safety, or acceptance criteria.
- Land the reviewed foundation on `main` only after required automated and manual checks pass.
- Preserve a clear boundary between this prerequisite and the unimplemented Quota Doctor capabilities.

## Acceptance criteria

- [ ] The current PR #22 revision has been reviewed against the parent specification's canonical model, privacy rules, product language, and Phase 1 outcomes.
- [ ] The final branch is mergeable and all required CI checks pass on the revision selected for merge.
- [ ] Measured Claude Code and Codex percentages are associated with exact provider-reported quota-window identities.
- [ ] Observations from distinct quota windows cannot be combined into one burn or exhaustion calculation.
- [ ] The application does not infer an exact reset boundary when one is unavailable.
- [ ] SQLite retention is bounded by the documented age and count policies.
- [ ] Identical observations are deduplicated without inflating the calculation sample.
- [ ] Explicit deletion removes quota observations and their derived quota findings without deleting unrelated current usage, alert rules, delivery state, provider settings, or credentials.
- [ ] Burn-rate and exhaustion ranges are calculated only from sufficiently recent observations within one exact active quota window.
- [ ] Stable positive movement can produce a bounded calculated range when all qualification requirements are met.
- [ ] Insufficient, stale, decreasing, flat, reset, and expired evidence produce explicit unavailable or reset-aware results rather than fabricated forecasts.
- [ ] No displayed exhaustion result crosses the provider-reported reset boundary.
- [ ] The UI visibly distinguishes measured percentages from calculated ranges and does not label either as provider-reported unless the provider supplied that exact value.
- [ ] The UI does not claim attribution, anomaly detection, workload planning, or a complete quota explanation.
- [ ] The diagnostic export includes only bounded, coarse quota findings and approved method metadata.
- [ ] Automated core, persistence, schema, analytics, and export tests pass in a working environment.
- [ ] The native XCTest launch blocker is either fixed in the repository or demonstrated to be environmental with the native suite passing in a known working environment.
- [ ] Signed-application manual acceptance verifies observation deduplication, forecast qualification, reset behavior, explicit deletion, and diagnostic export with supported real local sources.
- [ ] Manual acceptance distinguishes fixture confidence from evidence of real signed-application and macOS behavior.
- [ ] PR #22 is merged into `main` without declaring the parent Quota Doctor specification complete.
- [ ] Any material limitations or unresolved environment dependencies discovered during validation are recorded for follow-up rather than silently accepted.

## Privacy and safety constraints

- All quota processing and persistence must remain local by default.
- Storage and exports must exclude raw prompts, code, model responses, terminal output, request bodies, credentials, browser cookies, private paths, account labels, and raw provider payloads.
- Diagnostic export additions must pass through a positive allow-list.
- Diagnostic findings must remain bounded and coarse.
- The application must never upload a diagnostic report automatically.
- Users must preview the exact export before choosing a destination.
- Quota history deletion must not remove or mutate unrelated user configuration, credentials, current usage, alert rules, or alert delivery state.
- Measured, calculated, inferred, and unavailable states must remain distinguishable.
- The foundation must not represent a calculated exhaustion range as a provider-reported quota fact.
- Real-source acceptance must not weaken macOS credential or file-boundary protections merely to make testing pass.

## Explicit non-goals

- Building quota attribution by project, session, model, agent, operation, or tool.
- Retaining Codex token-count events for intra-window explanation.
- Adding anomaly detection or historical baselines.
- Adding workload planning or recommendations.
- Adding forecast or anomaly alerts.
- Creating a new forensic product surface.
- Claiming that provider weighting or undisclosed quota capacity is known.
- Scraping private provider pages.
- Replacing official billing records.
- Completing the full Quota Doctor parent specification.
- Broad refactoring unrelated to safely reviewing, validating, and landing the foundation.

## Verification

- Re-run every required CI check on the final merge candidate and retain the check result with the reviewed revision identity.
- Run the complete automated suites covering observation identity, deduplication, bounded retention, deletion, schema handling, analytics qualification, reset handling, UI provenance, and export allow-list behavior.
- Run targeted tests with duplicate, out-of-order, decreasing, flat, stale, expired, reset-crossing, and insufficient observations.
- Verify that data from two Quota windows or Exact boundaries cannot contribute to one result.
- Verify deletion from the user-visible action through persistent state while confirming unrelated state remains intact.
- Verify prohibited-content sentinels do not appear in diagnostic output.
- Launch the signed application and manually inspect Claude Code and Codex measured percentages, calculated ranges, unavailable states, reset behavior, and labels.
- Exercise supported real local sources in the signed application and record the exact acceptance environment and source versions.
- If native tests cannot launch locally, capture the failure, identify the responsible environment boundary, and obtain a passing run in a working native environment before merge.
- Confirm after merge that `main` contains the validated foundation and that the parent ticket remains open.

## Blocked by

None - can start immediately.

## Status

ready-for-agent
