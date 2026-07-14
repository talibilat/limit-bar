# Future Proposals

The documents in this directory are proposals, not product commitments, release promises, or approved architecture.
They preserve concrete next questions while keeping current behavior honest.

## Prioritized Next Steps

1. Establish a stable signed distribution path and complete real-account Keychain authorization QA.
2. Complete representative refresh performance measurements before making cadence configurable.
3. Decide the long-term App Sandbox and file-access model before public distribution.
4. Run binary-to-binary migration acceptance after the first public release exists.

The consolidated operational list is in [`next-steps.md`](next-steps.md).

## Product Proposals

- [`historical-usage-trends.md`](historical-usage-trends.md) explores bounded local history views.
- [`configurable-refresh-cadence.md`](configurable-refresh-cadence.md) explores user-controlled local refresh timing.
- [`provider-health-refresh-history.md`](provider-health-refresh-history.md) explores coarse provider health history.
- [`privacy-safe-diagnostic-export.md`](privacy-safe-diagnostic-export.md) explores an inspectable support bundle.
- [`budget-rate-limit-alerts.md`](budget-rate-limit-alerts.md) explores local threshold notifications.

Every proposal must preserve the default local privacy boundary.
No proposal may collect or export raw prompts, code, model responses, terminal output, request bodies, credentials, or raw provider payloads.
