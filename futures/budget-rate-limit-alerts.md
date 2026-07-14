# Budget And Rate-Limit Alerts

## Status

Accepted for implementation.

## Problem

Users must open the popover to notice high confirmed quota usage or an approaching local cost budget.

## User Outcome

Users receive timely local notifications at thresholds they choose while LimitBar is running and receives fresh observations.
Notifications distinguish provider-reported costs from calculated estimates.

## Proposed Scope

Add opt-in local alerts for confirmed provider quota windows and user-configured cost budgets.
Quota alerts consume the same Claude Code and Codex observations shown in the Rate Limit tab and require a provider-reported future reset boundary.
Cost budgets specify a provider product, currency, cost provenance, exact period, cap, and configurable percentage thresholds.
Offer 70% and 90% as suggested thresholds and accept unique integer thresholds from 1% through 100%.
When one observation newly satisfies several thresholds, notify only for the highest and mark every satisfied threshold for that exact window.
Treat enabling a rule above its threshold as immediately qualifying.
Deduplicate alerts durably per stable rule, threshold, and exact subject window.
Keep provider-reported and calculated costs separate and never combine currencies.
Suppress stale, unhealthy, unsupported, legacy, expired, malformed, and inferred observations.
Treat a cost measurement older than 24 hours as stale even when its exact budget window remains active.
Evaluate after existing local refreshes and successful provider observations without adding polling.

## Explicit Non-Goals

Alerts will not infer unsupported quotas, claim estimates are invoices, trigger provider API polling, perform currency conversion, or send notifications to a server.
They will not inspect conversation content.
The first version will not add account-, project-, model-, deployment-, or custom-source-scoped rules.
It will not implement custom quiet hours and will instead respect macOS notification controls and Focus.

## Privacy And Security

Notification text contains only a coarse provider-product name, the reached percentage threshold, currency when relevant, and reported or estimated cost provenance.
It excludes exact spend, budget caps, project, model, deployment, source, organization, and account labels from lock-screen copy.
Raw prompts, code, responses, terminal output, credentials, and provider payloads are prohibited.

## Data Model Impact

Store versioned local alert rules and a durable delivery ledger.
Quota-window identity includes the provider product, stable provider window discriminator, and exact provider-reported reset boundary.
Provider-product-wide Claude rules coalesce observations with the same provider group, kind, and reset boundary at the highest percentage; mutable scope display labels are not identity.
Cost-budget identity uses the complete exact calendar or billing window.
Do not infer a quota-window start from its duration and reset time.
Legacy rows without exact boundaries are ineligible for alerts.

## Reset Semantics

Resetting alert settings removes the configured rules.
Clearing notification history removes delivery-ledger entries and warns that an active threshold can notify again.
A complete local-data reset removes both rules and delivery state.

## Exit Criteria

- Alerts fire once per configured threshold and exact window.
- A jump across multiple thresholds emits only the highest notification.
- Relaunching within the same exact window does not repeat an accepted notification.
- Delivery failures remain retryable and do not block independent alerts.
- Stale, unsupported, legacy, and malformed values cannot create misleading alerts.
- Quota observations without valid future reset boundaries cannot alert.
- Provider-reported and calculated costs are never combined, and currencies are never converted implicitly.
- Lock-screen copy passes privacy review.
- All state remains local and is user-resettable.
- Notification authorization is requested only after explicit opt-in.
