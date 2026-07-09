# Validate And Display OpenAI Usage By Organization, Project, And Model

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Build the OpenAI provider slice.
The implementation should validate whether OpenAI OAuth can access the required organization/project usage endpoints before marking OpenAI as fully connected.
If OAuth cannot access the required data, LimitBar must show an explicit unsupported or admin/platform-credential-required state.

When usage data is available or fixture-backed, OpenAI usage should appear in the third provider card grouped by organization, project, and model.
The card should show input tokens, output tokens, spend when available, and honest stale or unsupported states.
Rate-limit urgency remains lower priority because Codex Enterprise reduces that operational risk for this workflow.

## Acceptance criteria

- [ ] OpenAI settings can represent OAuth feasibility as supported, unsupported, or requiring an admin/platform credential.
- [ ] The app does not show OpenAI as fully connected until the required usage access is validated.
- [ ] Fixture-backed OpenAI usage responses map into normalized metrics.
- [ ] OpenAI rows show organization identity, project identity, model, input tokens, output tokens, and spend when available.
- [ ] Provider-reported spend is labeled `Provider reported`.
- [ ] Calculated cost is labeled `Calculated estimate` when provider spend is unavailable and pricing is configured.
- [ ] OpenAI unsupported or admin-required states are visible in the OpenAI card and diagnostics.
- [ ] Refresh success stores latest confirmed OpenAI metrics.
- [ ] Refresh failure keeps last confirmed OpenAI values visible and marks them stale.
- [ ] Diagnostics explain insufficient OAuth access without exposing credentials or raw provider responses.

## Blocked by

- https://github.com/talibilat/limit-bar/issues/4
- https://github.com/talibilat/limit-bar/issues/5
- https://github.com/talibilat/limit-bar/issues/7
