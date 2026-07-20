# Developer Pain Opportunities

Research date: 2026-07-16.

## Executive Summary

LimitBar should expand from a private observability surface into a local capacity-safety layer for AI coding workflows.
The highest-value opportunity is not another quota gauge, generic forecast, or cost chart.
It is a set of narrow, trustworthy controls and explanations that help a developer stop waste before exhaustion, classify failures correctly, and resume work safely when capacity returns.

The top three recommendations are:

1. Build a local Capacity Gate that exposes fresh, typed, machine-readable capacity state to Claude Code hooks, Codex hooks, scripts, and orchestrators.
2. Build a Usage Waste Debugger that separates productive model work from retries, compaction, replay, cache misses, and failed subagent activity.
3. Correlate typed local failures with official provider incidents so users can distinguish quota exhaustion, provider capacity, authentication, and client-state faults.

These recommendations complement the existing Quota Doctor work rather than duplicating it.
Quota Doctor explains movement and forecasts exhaustion after collecting evidence.
The proposed Capacity Gate lets tools act conservatively on fresh evidence, while the Usage Waste Debugger adds causal operation classes that current normalized aggregates and quota explanations do not retain.

## Method And Evidence Standard

This research used only official provider documentation, official status APIs, first-party repositories, and first-party issue trackers.
Provider documentation and API specifications establish supported fields, authentication boundaries, and technical feasibility.
Open issues in `anthropics/claude-code` and `openai/codex` establish that developers are reporting pain, but an issue report does not prove the reporter's diagnosis or the provider's billing behavior.
The report labels conclusions drawn beyond the cited source as inference.

The repository review covered `README.md`, `futures/`, `docs/`, current Swift view names, and public core feature names.
LimitBar already has Claude Code and Codex quota displays, local alerts, cost budgets, exact-window history, quota forecasts, anomaly analysis, Codex movement explanations, a conservative Claude explanation seam, project and agent attribution for normalized local events, a forensic investigation view, diagnostic export, and a currently unavailable planned-workload adapter.
Those capabilities are not proposed again as standalone enhancements.

## Ranking

Each dimension is scored from 1 to 5.
The weighted total uses pain severity at 30%, evidence strength at 20%, strategic fit at 20%, feasibility at 15%, and differentiation at 15%.

| Rank | Opportunity | Pain | Evidence | Fit | Feasibility | Differentiation | Weighted total |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | Local Capacity Gate for agents and automation | 5 | 5 | 5 | 4 | 5 | 4.85 |
| 2 | Usage Waste Debugger | 5 | 5 | 5 | 4 | 5 | 4.85 |
| 3 | Provider Incident Correlation | 4 | 4 | 5 | 5 | 4 | 4.40 |
| 4 | Safe Reset Recovery Inbox | 4 | 5 | 4 | 4 | 4 | 4.20 |
| 5 | API Spend Reconciliation and Chargeback | 4 | 5 | 5 | 4 | 3 | 4.35 |
| 6 | Model Lifecycle and Price Impact Radar | 3 | 5 | 4 | 4 | 4 | 3.90 |
| 7 | Team Coding-Capacity Planner | 3 | 4 | 3 | 3 | 3 | 3.25 |

Ranks prioritize individual developer disruption and product adjacency, so API Spend Reconciliation ranks fifth despite a slightly higher numerical score than Safe Reset Recovery.
This is an explicit strategic ordering rather than false numerical precision.

## 1. Local Capacity Gate For Agents And Automation

### Struggling Developer And Job

The primary user is a developer running unattended, parallel, or CI-based Claude Code and Codex workflows who needs to decide whether another turn, subagent, or queued task may start without exhausting a nearly depleted quota window.
The job is to fail closed before launching work, preserve queued intent when capacity is unavailable, and return a typed reason that an orchestrator can handle.

### Evidence

OpenAI documents `codex exec` as the supported non-interactive interface for scripts and CI, with JSONL events including `turn.completed`, `turn.failed`, and token usage, which establishes a real automation surface rather than a hypothetical one.
Source: [Codex non-interactive mode](https://developers.openai.com/codex/non-interactive-mode).

OpenAI documents stable multi-agent support, a default `agents.max_threads` of six, lifecycle hooks, and an under-development rollout token budget in Codex configuration.
Source: [Codex configuration reference](https://developers.openai.com/codex/config-reference).

Anthropic documents hook events for `UserPromptSubmit`, `SubagentStart`, `StopFailure`, and other lifecycle points, and it defines typed `StopFailure` matchers including `rate_limit`, `overloaded`, `authentication_failed`, and `billing_error`.
Source: [Claude Code hooks reference](https://code.claude.com/docs/en/hooks).

An OpenAI Codex issue reports that subagent quota exhaustion is collapsed into a generic "no response" outcome, preventing the parent from selecting a safe response.
Source: [openai/codex#16891](https://github.com/openai/codex/issues/16891).

Another Codex issue reports that a usage-limit failure can drain queued follow-ups instead of pausing and preserving them.
Source: [openai/codex#24443](https://github.com/openai/codex/issues/24443).

A Claude Code issue requests rate-limit utilization in headless JSON or a usage subcommand, which is direct evidence that automation cannot reliably consume the existing human-facing state.
Source: [anthropics/claude-code#77018](https://github.com/anthropics/claude-code/issues/77018).

The issue descriptions establish recurring demand for machine-readable capacity and typed failure states.
They do not prove every proposed hook can block every provider action or that provider-reported percentages predict the cost of the next turn.

### Proposed LimitBar Behavior

LimitBar should add a local `limitbar capacity` command that returns a versioned JSON result for a selected Provider product and intended operation class.
The result should contain only fresh measured capacity, exact reset boundaries, observation age, active provider incident state when available, and a closed decision such as `allow`, `warn`, or `pause` with typed reasons.
It should never claim that a specific next operation will fit unless the existing planned-workload method has compatible measured evidence.

LimitBar should ship optional Claude Code and Codex hook snippets that call this command before a new prompt, subagent, or queued run.
The default behavior should warn or pause locally rather than switch accounts, buy credits, select a different provider, or execute work.
The command should support a non-blocking observation mode and an explicitly configured fail-closed mode for unattended workflows.

This is distinct from current alerts because alerts notify a human after a threshold is crossed.
The Capacity Gate gives a local automation client a typed preflight result at the point where new work would begin.

### Why Provider Surfaces Fail

Provider quota pages and status commands are designed primarily for people, while `codex exec`, subagents, hooks, and queued work are machine-driven.
The cited issues show that failure reasons and remaining-capacity displays can be inconsistent or unavailable to the parent workflow.
Provider clients also have no provider-neutral contract, so a multi-provider orchestrator must implement incompatible and changing behaviors itself.

### Privacy And Technical Constraints

The command must use only LimitBar's already normalized current state and must not expose credentials, account identifiers, prompts, code, paths, or raw session payloads.
Freshness and exact-boundary requirements must remain identical to alert qualification.
An unavailable or stale observation must not become an inferred `allow` decision.
Hook installation must be explicit because managed enterprise settings can prohibit user hooks and because a blocking hook changes workflow behavior.
The first version should bind only to loopback-free command execution and should not open a local network port.

### Smallest Validation Experiment

Build a read-only prototype command over fixture-backed current LimitBar publications.
Test it with one Claude Code `UserPromptSubmit` hook and one Codex pre-run wrapper across four states: fresh healthy capacity, fresh threshold breach, stale evidence, and provider incident.
Recruit five heavy agent users and measure prevented starts, false pauses, and whether typed reasons are sufficient to preserve queued work manually.

## 2. Usage Waste Debugger

### Struggling Developer And Job

The primary user is a developer whose allowance or API spend disappears much faster than expected during long agent sessions.
The job is to determine whether consumption came from intended model turns, repeated full-context replay, cache creation or misses, compaction, retries, failed tool loops, or subagent fan-out.

### Evidence

A heavily discussed Codex issue reports unusually fast weekly depletion and repeatedly identifies unstable compaction, session reconstruction, retries, and large cached-input totals as possible contributors.
Source: [openai/codex#19585](https://github.com/openai/codex/issues/19585).

A Claude Code issue reports unexpected exhaustion after repeated 429 responses and includes a discussion of how tool-call round trips, cache reads, and successful retries can make intuitive turn counts diverge from local token totals.
Source: [anthropics/claude-code#66268](https://github.com/anthropics/claude-code/issues/66268).

Anthropic's official Claude Code monitoring schema exposes request attempt count, success, status code, model, input, output, cache-read, cache-creation, subagent identifiers, and tool execution outcomes.
Source: [Claude Code monitoring](https://docs.anthropic.com/en/docs/claude-code/monitoring-usage).

OpenAI's official non-interactive JSONL includes turn completion usage with input, cached input, output, and reasoning-output tokens.
Source: [Codex non-interactive mode](https://developers.openai.com/codex/non-interactive-mode).

OpenAI documents hooks at `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`, and turn lifecycle points, while Anthropic documents corresponding compaction, subagent, tool, and failure hooks.
Sources: [Codex configuration reference](https://developers.openai.com/codex/config-reference) and [Claude Code hooks reference](https://code.claude.com/docs/en/hooks).

The issues establish severe confusion and repeated developer reports.
They do not establish that providers billed rejected requests incorrectly, and LimitBar must not label all replay, caching, reasoning, or compaction as waste.

### Proposed LimitBar Behavior

LimitBar should add an opt-in local Activity Receipt adapter that records positive-allow-listed operation facts without prompt or code content.
For each supported run, it should retain bounded counts and token categories for normal model attempts, retries, compaction, recovery or replay, cache creation, cache reads, subagents, failed operations, and successful completion.

The Analysis surface should show a Usage Waste Debugger only when the adapter can establish operation classes reliably.
It should answer factual questions such as "42% of measured input tokens were associated with retry attempts" or "three compactions occurred before the token-rate change."
It should label an operation as avoidable only when an explicit rule can prove duplication or failed work, and otherwise use neutral labels such as retry-associated or compaction-associated.

The debugger should compare compatible runs by client version, model, mode, and concurrency so a user can see whether a new client release or configuration changed the operation mix.
This extends current quota explanation rather than replacing it because quota movement may remain unattributed while the local operation receipt remains useful.

### Why Provider Surfaces Fail

Provider dashboards aggregate quota or billing usage but do not reconstruct the local agent lifecycle that generated it.
Client logs may contain the needed fragments, but developers must manually parse changing JSONL formats and reason about cumulative counters, retries, and cache semantics.
The first-party issue discussions show that raw token totals alone can intensify confusion because cached tokens, subagent rounds, and retries have different meanings.

### Privacy And Technical Constraints

This feature must be opt-in because lifecycle telemetry can contain high-cardinality session, account, project, tool, and path attributes.
LimitBar should ingest only typed counters, timestamps, version identifiers, opaque local run IDs, and coarse failure classes.
It must reject prompt text, response text, commands, tool arguments, file paths, raw error messages, and raw OTLP or JSONL payload persistence.
The adapter must version each accepted Claude Code and Codex schema and fail closed when client semantics change.
Provider quota weights are undisclosed, so local token classes must not be converted into authoritative quota percentages.

### Smallest Validation Experiment

Create a standalone, non-persisting parser for consenting users' Claude Code OTel and Codex `exec --json` streams.
Generate a one-session receipt with six operation classes and ask ten users who recently experienced surprising depletion whether it identifies a plausible investigation path.
Success requires at least seven users to identify a specific next action without LimitBar claiming a billing error or causal quota allocation.

## 3. Provider Incident Correlation

### Struggling Developer And Job

The primary user is a developer who receives a 429, overload, capacity, authentication, or usage-limit error while local quota still appears available.
The job is to determine quickly whether to wait for a provider recovery, repair local authentication or state, reduce concurrency, or investigate actual quota exhaustion.

### Evidence

The official Anthropic status API exposes separate component state for Claude Code, Claude API, Claude Console, and claude.ai, plus incident impact and updates.
Source: [Anthropic status summary API](https://status.anthropic.com/api/v2/summary.json).

The official OpenAI status API exposes separate components including the Codex API, VS Code extension, and Codex in the ChatGPT desktop app.
Source: [OpenAI status summary API](https://status.openai.com/api/v2/summary.json).

Numerous active Claude Code issues report "server temporarily limiting requests" while users are unsure whether the condition is subscription quota or provider capacity.
Representative sources: [anthropics/claude-code#73594](https://github.com/anthropics/claude-code/issues/73594), [anthropics/claude-code#70300](https://github.com/anthropics/claude-code/issues/70300), and [anthropics/claude-code#66268](https://github.com/anthropics/claude-code/issues/66268).

A long-running Codex issue includes reports that the web dashboard and `/status` show remaining quota while prompts fail, with maintainer discussion pointing in some cases to concurrency-triggered 429 responses and in other cases to stale or inconsistent client state.
Source: [openai/codex#12299](https://github.com/openai/codex/issues/12299).

The issues prove ambiguity and recurring disruption.
They do not prove that a temporally overlapping public incident caused any particular local failure.

### Proposed LimitBar Behavior

LimitBar should add an explicit Check Provider Status action and an optional low-frequency status subscription that the user enables separately from local refresh.
It should normalize official component and incident state into a short incident timeline and correlate it with typed local failure observations and quota evidence.

The product should say "official incident overlapped this failure" rather than "the incident caused this failure."
When no official incident exists, it should not conclude that the provider was healthy or that quota was exhausted.
The forensic view should present four independent lanes: provider incident, quota state, local client failure class, and authentication state.

### Why Provider Surfaces Fail

Status pages show broad service health but have no access to the user's local quota, client version, authentication state, or exact failure time.
Quota pages show account measurements but do not explain whether the relevant product component is degraded.
Developers therefore manually compare browser tabs, terminal output, and timestamps during an incident.

### Privacy And Technical Constraints

Status checks are network requests and must remain outside the Local Refresh Cycle unless the user explicitly opts in.
Only public status endpoints should be queried, without provider credentials, cookies, account labels, or local failure details in the request.
LimitBar should retain bounded normalized incident identifiers, component state, impact, timestamps, and update state rather than arbitrary incident prose.
Correlation must remain temporal evidence, not causal attribution.

### Smallest Validation Experiment

Add a fixture-driven incident lane to the existing forensic investigation UI and a manual status fetch behind an explicit button.
Replay ten historical local failure scenarios against official incident fixtures and ask users to select a next action.
Measure whether the four-lane presentation reduces incorrect quota diagnoses without overclaiming incident causality.

## 4. Safe Reset Recovery Inbox

### Struggling Developer And Job

The primary user is a developer whose long-running coding task stops at a quota reset boundary while they are away from the computer.
The job is to preserve what was in flight, know when capacity is actually back, and resume deliberately without replaying stale work or spending a blind turn.

### Evidence

An active Claude Code request for auto-continue has multiple linked duplicate reports, ongoing discussion, and community workarounds using terminal multiplexers, cron, hooks, and accessibility automation.
Source: [anthropics/claude-code#35744](https://github.com/anthropics/claude-code/issues/35744).

Discussion in that issue explicitly warns that blind resumption can replay the same expensive failure pattern and recommends a receipt of what was in flight, whether state changed, and why retry is justified.
Source: [anthropics/claude-code#35744 comment](https://github.com/anthropics/claude-code/issues/35744#issuecomment-4560402042).

A separate Claude Code request proposes rate-limit-aware deferred scheduling and identifies working-tree changes, permission expiry, duplicate scheduling, and stale session context as the hard safety problems.
Source: [anthropics/claude-code#59634](https://github.com/anthropics/claude-code/issues/59634).

The Codex queue-preservation issue asks for usage exhaustion to become a paused state that retains queued prompts and offers "Resume when credits return."
Source: [openai/codex#24443](https://github.com/openai/codex/issues/24443).

This is strong evidence of workflow interruption and unsafe workarounds.
It is not evidence that LimitBar can safely execute provider client actions on a user's behalf.

### Proposed LimitBar Behavior

LimitBar should create a local Recovery Inbox, not an auto-run scheduler.
A user-approved Claude Code or Codex hook should submit a content-free checkpoint containing Provider product, opaque session reference, working-tree fingerprint, client version, failure class, and exact reported reset boundary.

When fresh measured capacity returns, LimitBar should notify the user that the checkpoint is ready for review.
The review should show whether the workspace fingerprint changed and offer provider-owned resume commands that the user explicitly launches.
LimitBar should never store the prompt, automatically send "continue," grant permissions, restore a queue, or wake a session without confirmation.

### Why Provider Surfaces Fail

Provider clients know their own session and reset state but currently leave many users to return manually or install unofficial automation.
Simple timers do not verify that the quota actually reset and do not detect working-tree or permission changes.
The provider issue discussions show that the difficult part is durable, safe recovery rather than displaying a reset timestamp.

### Privacy And Technical Constraints

Checkpoints must not contain prompts, summaries, code, commands, terminal output, or file paths.
A workspace fingerprint must be a privacy-safe digest of explicit metadata and must not permit reconstruction of repository content.
The session reference should remain local and should never enter diagnostics.
Resume actions must use documented provider commands and require fresh user approval.
The feature must tolerate machine sleep, app restart, reset changes, expired sessions, and deleted workspaces.

### Smallest Validation Experiment

Prototype a checkpoint file schema and a notification-only recovery flow with synthetic Claude Code and Codex sessions.
Run five real user tests where the working tree is unchanged and five where it changes before reset.
Validate that users understand why automatic execution is withheld and can resume the correct provider session without exposing checkpoint content.

## 5. API Spend Reconciliation And Chargeback

### Struggling Developer And Job

The primary user is an engineer or technical lead operating Anthropic, OpenAI, or Azure OpenAI API workloads across projects, workspaces, API keys, and models.
The job is to reconcile provider-reported cost with local project or agent evidence and identify unattributed spend without uploading proprietary traces to another observability vendor.

### Evidence

Anthropic states that its Usage and Cost API supports accurate token tracking, cost reconciliation, grouping by model, workspace, API key, service tier, and cache token class, and cost grouping by workspace and description.
Source: [Anthropic Usage and Cost API](https://docs.anthropic.com/en/api/usage-cost-api).

Anthropic explicitly lists cost attribution, chargebacks, cache efficiency, and budget monitoring as supported use cases.
Source: [Anthropic Usage and Cost API](https://docs.anthropic.com/en/api/usage-cost-api).

OpenAI's organization Usage API reports aggregate usage with time buckets and grouping dimensions, while its Costs endpoint provides organization cost buckets.
Sources: [OpenAI Usage API](https://platform.openai.com/docs/api-reference/usage) and [OpenAI Costs API](https://platform.openai.com/docs/api-reference/organization/costs).

LimitBar already imports provider totals and supports project and agent attribution for explicit local schema v2 events.
The missing job is reconciliation between those authoritative provider totals and the local Observed Local Breakdown across provider grouping dimensions.

### Proposed LimitBar Behavior

LimitBar should add a Reconciliation view for explicit provider refreshes.
It should preserve provider-reported totals by exact billing bucket, then show non-additive local and provider-reported breakdowns by configured privacy-safe project, agent, workspace, API key alias, model, service tier, and cache token class when the source supports them.

The view should make three amounts explicit: attributed provider-reported cost, locally explained but non-authoritative cost, and unattributed provider-reported cost.
It should detect late provider revisions and show reconciliation drift rather than silently rewriting prior conclusions.
CSV export should be local, explicit, and based on configured aliases rather than raw key or workspace identifiers.

### Why Provider Surfaces Fail

Each provider dashboard covers only its own organization and terminology.
Provider reports cannot see LimitBar's project and agent identities, while local event data cannot establish the authoritative bill.
Teams using multiple providers must manually join incompatible time buckets, identities, cache categories, currencies, and cost provenance.

### Privacy And Technical Constraints

Anthropic Admin API access is unavailable to individual accounts and requires organization-level credentials.
OpenAI organization usage access requires administrative credentials, and these broad credentials are materially more sensitive than ordinary project API keys.
LimitBar must keep credentials in Keychain, make refresh explicit, and allow users to omit or alias workspace and API-key identifiers before persistence.
Cross-provider costs must not be summed across currencies or incompatible periods.
Provider-reported cost must remain separate from Calculated Cost and local attribution must remain non-additive.

### Smallest Validation Experiment

Extend one Anthropic organization fixture with workspace, API-key, service-tier, and cache dimensions.
Join it locally to schema v2 project and agent events for one exact day and produce an attributed, locally explained, and unattributed reconciliation table.
Validate the table with three API teams before adding another provider.

## 6. Model Lifecycle And Price Impact Radar

### Struggling Developer And Job

The primary user is a developer with active API workloads who needs to know which used models are approaching retirement and how the documented replacement could change cost before production calls fail.
The job is to turn provider deprecation notices and pricing changes into a local inventory-specific migration deadline and cost impact range.

### Evidence

OpenAI publishes upcoming shutdown dates, recommended replacements, and minimum notice periods, including shorter periods for preview models.
Source: [OpenAI deprecations](https://platform.openai.com/docs/deprecations).

Anthropic publishes active, deprecated, and retired model states, replacement models, retirement dates, and separate schedules for partner-operated platforms.
Source: [Anthropic model deprecations](https://docs.anthropic.com/en/docs/about-claude/model-deprecations).

OpenAI pricing distinguishes input, cached input, cache writes, output, long-context, Batch, Flex, Priority, regional processing, tools, and containers.
Source: [OpenAI pricing](https://platform.openai.com/docs/pricing).

Anthropic prompt caching prices cache writes and reads differently and documents model-specific token thresholds and invalidation rules.
Source: [Anthropic prompt caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching).

These official pages establish frequent lifecycle and pricing complexity.
The inference is that a local inventory-specific impact view is more actionable than provider email and documentation for developers using several providers.

### Proposed LimitBar Behavior

LimitBar should maintain a signed, versioned catalog derived from official lifecycle and pricing sources and updated only through an explicit check.
It should match locally observed model identifiers to lifecycle status and show deadlines only for models actually measured in the retained period.

For a documented replacement, LimitBar should replay the user's frozen token mix against the replacement's current price revision and show a Calculated Cost range or an explicit unavailable reason.
It should never claim behavioral equivalence, quality parity, or guaranteed migration compatibility.
The app should alert only on exact published retirement dates and should identify platform-specific uncertainty for Azure, Bedrock, or Vertex deployments.

### Why Provider Surfaces Fail

Provider deprecation pages are global catalogs rather than local workload inventories.
Email notices can identify an organization but do not combine actual local model mix, cache categories, exact retained periods, and multi-provider deadlines in one view.
Pricing pages expose many modifiers but do not replay a user's measured workload against a replacement model.

### Privacy And Technical Constraints

Catalog refresh must send no local model inventory to a provider or LimitBar service.
Pricing revisions must be frozen with effective dates and source URLs.
Aliases and snapshots require exact matching because broad prefix matching could produce a false deadline.
Replacement impact is a Calculated Cost scenario, not a provider quote, and must exclude unsupported tool, regional, long-context, or service-tier modifiers rather than assume zero.

### Smallest Validation Experiment

Create a static catalog for the currently documented Anthropic and OpenAI deprecations and run it against synthetic retained model aggregates.
Show only used models with a retirement inside 180 days and a replacement cost replay when every required price dimension is known.
Ask five API developers whether this changes migration timing or model-inventory cleanup behavior.

## 7. Team Coding-Capacity Planner

### Struggling Developer And Job

The primary user is an engineering manager or platform lead paying for Claude Code and Codex seats who needs to understand whether recurring individual exhaustion is a seat-capacity problem, a workload concentration problem, or a client-efficiency problem.
The job is to plan seats and working patterns without collecting prompts, source code, or raw developer transcripts.

### Evidence

Anthropic's Claude Code Usage Report returns daily actor-level sessions, model token classes, estimated cost, terminal type, commits, pull requests, lines changed, and tool acceptance metrics for supported organizations.
Source: [Claude Code Usage Report API](https://docs.anthropic.com/en/api/admin-api/claude-code/get-claude-code-usage-report).

Anthropic's Claude Code monitoring documentation supports custom OpenTelemetry resource attributes for team, department, and cost center, while warning about metric cardinality.
Source: [Claude Code monitoring](https://docs.anthropic.com/en/docs/claude-code/monitoring-usage).

OpenAI documents a Codex Analytics API for aggregated workspace usage and activity metrics that can be joined with internal organizational data.
Source: [Codex Analytics API](https://developers.openai.com/codex/enterprise/analytics-api).

The evidence establishes provider-supported organization analytics surfaces.
The inference is that local cross-provider normalization can improve seat and capacity planning, because the public OpenAI page deliberately leaves current schemas and access requirements to an authenticated reference.

### Proposed LimitBar Behavior

LimitBar should offer an optional organization mode that imports daily aggregates into a separate local database and presents distributions rather than employee rankings.
The primary outputs should be days with blocked capacity, concentration of usage across privacy-safe team aliases, cache efficiency, concurrency, and the share of users whose active windows repeatedly approach exhaustion.

The planner should compare observed seat demand with configured seat cost and API overflow cost, while keeping subscription quota and API spend as different subjects.
It should support scenario questions such as whether moving scheduled batch work away from a recurring peak could reduce blocked developer time.
It should not score developer productivity from commits, lines changed, or tool acceptance counts.

### Why Provider Surfaces Fail

Anthropic and OpenAI organization analytics remain separate and use different identities, metrics, eligibility, and time semantics.
Neither provider can observe the other provider's seat demand or a team's local normalized API overflow.
The built-in metrics can tempt managers to compare activity counts that are not valid productivity measures.

### Privacy And Technical Constraints

This feature has the highest privacy and governance risk in the ranking.
It should require an explicit organization mode, separate credentials, a separate retention policy, visible field-level import controls, and irreversible local aliasing before persistence.
Email addresses, API key names, organization IDs, terminal identifiers, and raw actor records should not enter the normal personal LimitBar databases or diagnostic export.
Small cohorts must be suppressed to prevent re-identification.
The product must prohibit productivity rankings and must not equate lines changed, sessions, or token volume with developer value.

### Smallest Validation Experiment

Do not build an API integration first.
Create a local importer for administrator-reviewed, manually exported daily aggregates with irreversible team aliases and cohort suppression.
Test whether three engineering managers can answer one seat-capacity question without requesting individual-level drill-down.

## Top Three Recommendation Sequence

### 1. Capacity Gate

Start with the Capacity Gate because LimitBar already owns the hardest trustworthy primitives: fresh measurements, exact boundaries, typed unavailable states, and conservative alert qualification.
The first release can be local, read-only, versioned, and useful without adding provider credentials or parsing more private logs.
It creates a narrow integration contract that Claude Code hooks, Codex hooks, wrappers, and CI can consume.

### 2. Usage Waste Debugger

Add the Usage Waste Debugger next because surprising depletion is the strongest recurring pain across both first-party issue trackers.
It also provides the operation-level evidence needed to make future Capacity Gate rules and workload planning safer.
The product claim must remain "explain the local operation mix," not "prove the provider billed incorrectly."

### 3. Provider Incident Correlation

Add Provider Incident Correlation third because it is highly feasible, immediately improves failure classification, and uses official public sources.
It also reduces false conclusions in both the Capacity Gate and Usage Waste Debugger by keeping provider incidents separate from quota and local client state.

The Safe Reset Recovery Inbox should follow once the Capacity Gate can verify that fresh capacity returned and the Usage Waste Debugger can generate a content-free retry receipt.

## What Not To Build

Do not build another provider quota gauge, generic forecast, anomaly card, project attribution view, forensic export, or planned-workload calculator as a new initiative because those capabilities already exist or are explicitly represented in current LimitBar work.

Do not automatically rotate accounts, switch providers, purchase credits, raise concurrency, or execute deferred prompts.
Those actions can evade provider controls, spend money, expose code to a different provider, or resume stale work without valid permission.

Do not scrape private provider dashboards or intercept another process's API traffic.
The repository's existing API quota-path decision correctly rejects private scraping, response interception, and artificial billable requests as acquisition strategies.

Do not claim that token counts explain subscription quota weighting.
Both provider behavior and the first-party issue discussions show that model, cache, concurrency, service tier, and undisclosed weighting can make that conversion unsafe.

Do not build employee productivity scores from tokens, sessions, commits, lines changed, or tool acceptance.
The official analytics fields describe activity, not value, quality, or developer performance.

Do not launch organization analytics before the personal Capacity Gate and Usage Waste Debugger are validated.
Organization mode introduces broad credentials, employee data, governance obligations, and re-identification risks that are not necessary to solve the most severe individual pain.

Do not make status polling part of the default Local Refresh Cycle.
Status correlation should remain an explicit or separately opted-in network capability so LimitBar's current local privacy and refresh contract stays truthful.

## Source Index

- [Anthropic Usage and Cost API](https://docs.anthropic.com/en/api/usage-cost-api)
- [Anthropic Claude Code monitoring](https://docs.anthropic.com/en/docs/claude-code/monitoring-usage)
- [Anthropic Claude Code hooks reference](https://code.claude.com/docs/en/hooks)
- [Anthropic Claude Code Usage Report API](https://docs.anthropic.com/en/api/admin-api/claude-code/get-claude-code-usage-report)
- [Anthropic prompt caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching)
- [Anthropic model deprecations](https://docs.anthropic.com/en/docs/about-claude/model-deprecations)
- [Anthropic status summary API](https://status.anthropic.com/api/v2/summary.json)
- [OpenAI Codex non-interactive mode](https://developers.openai.com/codex/non-interactive-mode)
- [OpenAI Codex configuration reference](https://developers.openai.com/codex/config-reference)
- [OpenAI Codex Analytics API](https://developers.openai.com/codex/enterprise/analytics-api)
- [OpenAI Usage API](https://platform.openai.com/docs/api-reference/usage)
- [OpenAI Costs API](https://platform.openai.com/docs/api-reference/organization/costs)
- [OpenAI prompt caching](https://platform.openai.com/docs/guides/prompt-caching)
- [OpenAI pricing](https://platform.openai.com/docs/pricing)
- [OpenAI deprecations](https://platform.openai.com/docs/deprecations)
- [OpenAI status summary API](https://status.openai.com/api/v2/summary.json)
- [anthropics/claude-code#35744](https://github.com/anthropics/claude-code/issues/35744)
- [anthropics/claude-code#59634](https://github.com/anthropics/claude-code/issues/59634)
- [anthropics/claude-code#66268](https://github.com/anthropics/claude-code/issues/66268)
- [anthropics/claude-code#70300](https://github.com/anthropics/claude-code/issues/70300)
- [anthropics/claude-code#73594](https://github.com/anthropics/claude-code/issues/73594)
- [anthropics/claude-code#77018](https://github.com/anthropics/claude-code/issues/77018)
- [openai/codex#12299](https://github.com/openai/codex/issues/12299)
- [openai/codex#16891](https://github.com/openai/codex/issues/16891)
- [openai/codex#19585](https://github.com/openai/codex/issues/19585)
- [openai/codex#24443](https://github.com/openai/codex/issues/24443)
