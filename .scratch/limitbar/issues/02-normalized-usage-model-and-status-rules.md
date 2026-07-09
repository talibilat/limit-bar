# Define The Normalized Usage Model And Status Rules

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Define the shared domain model that every provider, persistence adapter, and UI surface will use.
The model should represent normalized usage metrics, providers, account and project identity, model and deployment labels, time windows, cost source, limit status, stale state, and menu bar status.

This issue also encodes LimitBar's honesty rules.
The app must only display confirmed values for usage and limits.
Unsupported provider limits must be explicit.
The menu bar status must use green below 70%, yellow at 70%, red at 90%, and gray when stale, disconnected, or unsupported.
The app must not estimate live burn rate or invent missing 5-hour quota, weekly quota, or TPM values.

## Acceptance criteria

- [ ] The core model supports Anthropic, Azure OpenAI, and OpenAI as provider kinds.
- [ ] The fixed provider order is Anthropic, Azure OpenAI, OpenAI.
- [ ] The core model supports Today and Current Week time windows.
- [ ] The core model supports input tokens, output tokens, total tokens, cost, cost source, limit status, refresh timestamp, and stale state.
- [ ] Menu bar status is green below 70% confirmed usage.
- [ ] Menu bar status is yellow at 70% confirmed usage.
- [ ] Menu bar status is red at 90% confirmed usage.
- [ ] Menu bar status is gray when data is stale after 2 missed refreshes.
- [ ] Menu bar status is gray when only unsupported or disconnected statuses exist.
- [ ] Unit tests cover fixed provider order, time window boundaries, status thresholds, stale behavior, and unsupported behavior.

## Blocked by

- https://github.com/talibilat/limit-bar/issues/1
