# Future Proposals

The documents in this directory are proposals, not product commitments, release promises, or approved architecture.
They preserve concrete next questions while keeping current behavior honest.

## Prioritized Next Steps

1. Establish a stable signed distribution path and complete real-account Keychain authorization QA.
2. Add a native app test target and UI automation if the repository still lacks one.
3. Complete representative measurements for [`04-refresh-performance-profiling.md`](04-refresh-performance-profiling.md) before making cadence configurable.
4. Add CI for core tests, native builds, whitespace checks, and migration fixtures.
5. Decide the long-term App Sandbox and file-access model before public distribution.
6. Run release-level migration QA against copied databases from every shipped schema.

The consolidated operational list is in [`next-steps.md`](next-steps.md).

## Product Proposals

- [`historical-usage-trends.md`](historical-usage-trends.md) explores bounded local history views.
- [`configurable-refresh-cadence.md`](configurable-refresh-cadence.md) explores user-controlled local refresh timing.
- [`provider-health-refresh-history.md`](provider-health-refresh-history.md) explores coarse provider health history.
- [`privacy-safe-diagnostic-export.md`](privacy-safe-diagnostic-export.md) explores an inspectable support bundle.
- [`budget-rate-limit-alerts.md`](budget-rate-limit-alerts.md) explores local threshold notifications.
- [`supported-local-usage-event-collector.md`](supported-local-usage-event-collector.md) explores a supported local event-writing interface.

Every proposal must preserve the default local privacy boundary.
No proposal may collect or export raw prompts, code, model responses, terminal output, request bodies, credentials, or raw provider payloads.
