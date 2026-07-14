# 10 - Alert on Qualified Findings

## Parent

Source plan: `futures/01-quota-doctor.md`.

## What to build

Route eligible Quota Doctor forecast and anomaly findings through LimitBar's existing alert-rule and Delivery Ledger architecture.
Quota Doctor must produce alert candidates for existing provider-product rules rather than introduce a parallel rule model, notification scheduler, deduplication store, or delivery path.
Only a fresh, qualified finding for an exact active quota boundary may become an alert candidate.
The integration must preserve the finding's measured, calculated, inferred, or unavailable classification and must not turn an estimate into a provider-reported fact.
The delivered notification must use coarse, lock-screen-safe language that communicates the category and urgency without exposing sensitive evidence values.

## Confirmed starting point

LimitBar already has an alert architecture with provider-product rules.
The existing architecture uses exact `QuotaWindowIdentity` values.
The existing architecture qualifies observations for freshness.
The existing architecture has durable Delivery Ledger behavior.
Quota Doctor must consume these capabilities rather than create another alert system.
The parent specification requires forecast and anomaly alerts to use the exact subject window and rule threshold for deduplication.
The parent specification requires deletion of quota history to remain independent from Delivery Ledger state.
Tickets 06 and 07 are expected to provide qualified forecast and anomaly findings respectively.
The exact interfaces exposed by tickets 06 and 07 are unknown until those tickets are complete.
The exact rule configuration and candidate-ingestion interfaces in the existing alert architecture are not established by the parent specification and must be confirmed from the completed implementation before integration.

## Scope

- Define the boundary by which qualified Quota Doctor findings become candidates for existing provider-product alert rules.
- Support qualified forecast findings and qualified anomaly findings without weakening either finding type's own eligibility requirements.
- Require an exact active `QuotaWindowIdentity` for every candidate.
- Reuse the existing freshness qualification and reject stale findings before delivery-ledger acceptance.
- Reject findings that are unavailable, unqualified, tied to an expired boundary, missing an exact boundary, or otherwise unsafe for notification.
- Preserve enough stable candidate identity to apply the existing exact-window and rule-threshold Delivery Ledger semantics.
- Map candidates to the correct provider product without including an account, project, session, agent, model, or private source identity in notification content.
- Define coarse copy for each supported finding category and qualification outcome that is eligible for delivery.
- Ensure notification copy distinguishes a calculated forecast or anomaly from a provider-reported quota state.
- Keep detailed evidence, values, methods, and limitations in the local forensic experience rather than placing them on the lock screen.
- Preserve durable deduplication across refreshes, application restarts, repeated equivalent findings, and repeated candidate evaluation.
- Ensure a corrected or superseding finding does not bypass an already accepted threshold for the same rule and exact subject window.
- Ensure a genuinely new threshold crossing is handled according to the existing rule and Delivery Ledger semantics rather than bespoke Quota Doctor logic.
- Keep quota-history deletion independent from alert rules, Delivery Ledger records, provider settings, current usage, and credentials.
- Ensure history deletion neither silently marks an alert as delivered nor recreates a previously consumed delivery opportunity.
- Exercise exact-boundary transitions so a reset or new quota window cannot inherit the prior window's delivery identity.
- Cover concurrent refresh or evaluation paths so equivalent candidates cannot produce duplicate accepted deliveries.
- Document which finding qualification fields are required by the alert boundary and why each is required.
- Determine the existing architecture's behavior for disabled rules, changed thresholds, notification authorization, and delivery failures before relying on those behaviors.
- Treat any behavior not defined by the parent specification or the existing alert contract as an explicit implementation-time unknown rather than inventing a second policy layer.

## Acceptance criteria

- [ ] Qualified forecast findings can become candidates for existing provider-product alert rules.
- [ ] Qualified anomaly findings can become candidates for existing provider-product alert rules.
- [ ] Candidate production and delivery use the existing alert engine and durable Delivery Ledger.
- [ ] No Quota Doctor-specific rule store, notification scheduler, deduplication ledger, or parallel delivery system is introduced.
- [ ] Every candidate carries the exact active `QuotaWindowIdentity` required by the existing alert architecture.
- [ ] A finding without an exact active quota boundary cannot become an alert candidate.
- [ ] A stale, expired, unavailable, or unqualified finding cannot become an alert candidate.
- [ ] Forecast and anomaly eligibility remain traceable to the originating finding, its method version, and its qualification state.
- [ ] Deduplication uses the exact subject window and rule threshold.
- [ ] Repeated evaluation of an equivalent candidate does not produce a second accepted delivery for the same rule threshold and exact subject window.
- [ ] Restarting the application does not lose the Delivery Ledger decision for an already accepted candidate.
- [ ] A new exact quota window is evaluated independently from the preceding quota window.
- [ ] Superseding or recalculating a finding does not silently evade delivery-ledger deduplication for a threshold already accepted in the same exact subject window.
- [ ] Deleting quota observations or derived findings does not delete, consume, recreate, or otherwise mutate Delivery Ledger state.
- [ ] Deleting quota observations or derived findings does not mutate alert rules, provider settings, current usage, or credentials.
- [ ] Notification copy is coarse, lock-screen-safe, and useful without exposing detailed evidence.
- [ ] Notification copy omits account, project, session, agent, model, token, percentage, exact spend, and private source values.
- [ ] Notification copy does not claim that a calculated or inferred finding was reported by a provider.
- [ ] Detailed values and limitations remain available only through the appropriate local product surface.
- [ ] Automated tests cover freshness rejection, missing-boundary rejection, expired-boundary rejection, exact-window deduplication, threshold deduplication, restart durability, superseding findings, reset transitions, history deletion, and concurrent equivalent candidates.
- [ ] Existing alert behavior for disabled rules, threshold changes, authorization state, and delivery failure is either verified and reused or recorded as an unresolved blocker before release.

## Privacy and safety constraints

All processing and candidate evaluation must remain local by default.
Notifications must omit account, project, session, agent, model, token, percentage, exact spend, and private source values.
Notifications must not include raw prompts, code, model responses, terminal output, request bodies, credentials, browser cookies, private paths, account labels, or raw provider payloads.
Notification copy must remain safe when displayed on a lock screen or mirrored to another device.
The integration must use positive field selection for notification content rather than redact a detailed finding after composition.
An inferred value must never be presented as a provider-reported quota.
The alert path must not upload evidence or cause an evidence report to be sent.
The alert path must not weaken freshness, exact-boundary, or qualification requirements to increase notification coverage.
Durable deduplication state must not retain prohibited evidence values merely to identify a delivery.

## Explicit non-goals

- Building a second notification system for Quota Doctor.
- Replacing provider-product alert rules with finding-specific rule storage.
- Displaying detailed attribution or forensic evidence in notification copy.
- Alerting from stale, unavailable, unqualified, expired, or boundary-less findings.
- Inferring an exact reset boundary when a provider did not report one.
- Sending account, project, session, agent, model, token, percentage, exact spend, or private source values in a notification.
- Changing provider configuration, plans, accounts, or credentials in response to an alert.
- Automatically purchasing credits or evading provider controls.
- Treating notification delivery as proof that a forecast or anomaly is correct.
- Redefining existing alert authorization, retry, or operating-system delivery policy unless the current architecture cannot meet the parent specification.

## Verification

- Run focused automated integration tests from qualified forecast and anomaly findings through candidate evaluation and Delivery Ledger acceptance.
- Verify rejection of stale, expired, unavailable, unqualified, and exact-boundary-less findings.
- Verify exact-window and threshold deduplication before and after application restart.
- Verify reset transitions and superseding findings do not create cross-window suppression or same-window duplicate delivery.
- Verify concurrent evaluation of equivalent candidates accepts at most one delivery-ledger entry under the existing architecture's contract.
- Verify independent quota-history deletion leaves alert rules and Delivery Ledger state unchanged.
- Inspect every notification template against explicit prohibited-value sentinels.
- Perform signed-app manual acceptance with notifications authorized and with notifications denied.
- Confirm lock-screen-visible copy is coarse and does not expose any prohibited value.
- Record any existing alert-engine behavior that could not be verified, including rule changes, failed delivery handling, or authorization transitions.

## Blocked by

- 06 - [#25](https://github.com/talibilat/limit-bar/issues/25) - Version And Validate Quota Forecasts.
- 07 - [#29](https://github.com/talibilat/limit-bar/issues/29) - Detect Quota Consumption Anomalies.

## Status

ready-for-agent
