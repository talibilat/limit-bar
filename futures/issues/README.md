# Quota Doctor Issues

These local issues divide the [Quota Doctor plan](../01-quota-doctor.md) into tracer-bullet vertical slices.
Each issue is intended to fit one focused implementation session and produce independently demonstrable or verifiable behavior.

## Issue Order

1. [`01 - Land Quota Insights Foundation`](01-land-quota-insights-foundation.md)
2. [`02 - Explain Codex Quota Movement`](02-explain-codex-quota-movement.md)
3. [`03 - Explain Claude Code Quota Movement`](03-explain-claude-code-quota-movement.md)
4. [`04 - Add API Provider Quota Path`](04-add-api-provider-quota-path.md)
5. [`05 - Attribute Project And Agent Work`](05-attribute-project-and-agent-work.md)
6. [`06 - Version And Validate Quota Forecasts`](06-version-and-validate-quota-forecasts.md)
7. [`07 - Detect Quota Consumption Anomalies`](07-detect-quota-consumption-anomalies.md)
8. [`08 - Add Forensic Investigation View`](08-add-forensic-investigation-view.md)
9. [`09 - Export Quota Evidence Report`](09-export-quota-evidence-report.md)
10. [`10 - Alert On Qualified Findings`](10-alert-on-qualified-findings.md)
11. [`11 - Assess Planned Workload`](11-assess-planned-workload.md)
12. [`12 - Harden And Validate Quota Doctor`](12-harden-and-validate-quota-doctor.md)

## Blocking Graph

| Issue | GitHub | Blocked by |
| --- | --- | --- |
| 01 | [#23](https://github.com/talibilat/limit-bar/issues/23) | None |
| 02 | [#24](https://github.com/talibilat/limit-bar/issues/24) | 01 |
| 03 | [#26](https://github.com/talibilat/limit-bar/issues/26) | 02 |
| 04 | [#27](https://github.com/talibilat/limit-bar/issues/27) | 02 |
| 05 | [#28](https://github.com/talibilat/limit-bar/issues/28) | 02 |
| 06 | [#25](https://github.com/talibilat/limit-bar/issues/25) | 01 |
| 07 | [#29](https://github.com/talibilat/limit-bar/issues/29) | 02, 06 |
| 08 | [#32](https://github.com/talibilat/limit-bar/issues/32) | 03, 04, 05, 07 |
| 09 | [#31](https://github.com/talibilat/limit-bar/issues/31) | 03, 04, 05, 06, 07 |
| 10 | [#33](https://github.com/talibilat/limit-bar/issues/33) | 06, 07 |
| 11 | [#30](https://github.com/talibilat/limit-bar/issues/30) | 05, 06 |
| 12 | [#34](https://github.com/talibilat/limit-bar/issues/34) | 08, 09, 10, 11 |

## Parallel Frontiers

Issue 01 can start immediately.

After Issue 01, Issues 02 and 06 can run in parallel.

After Issue 02, Issues 03, 04, and 05 can run in parallel while Issue 06 continues.

After Issues 02 and 06, Issue 07 can start.

After their declared blockers complete, Issues 08, 09, 10, and 11 form the final broad parallel frontier.

Issue 12 is the integration, signed-app acceptance, pilot, and release-validation gate.

## Interpretation

`ready-for-agent` means the issue is specified for autonomous implementation.
An agent must still wait until every issue listed under `Blocked by` is complete.

Unknown provider formats, source fields, thresholds, and quality targets are intentionally recorded as unknown.
Implementers must establish those details from primary evidence and fixtures rather than fill them with assumptions.
