# Render The Monitoring Popover With Demo Provider Data

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Create the first visible monitoring experience using demo normalized metrics.
The popover should show provider cards in the fixed order Anthropic, Azure OpenAI, OpenAI.
It should include Today and Current Week tabs, token rows, provider metadata, model labels, unsupported state, stale state, and empty-state rendering.

This issue proves that one normalized usage model can drive the entire monitoring UI before persistence or provider integrations exist.
The UI should be compact, calm, and scan-friendly, while leaving final visual polish for the final hardening issue.

## Acceptance criteria

- [ ] Clicking the menu bar item opens a popover with provider cards in fixed order: Anthropic, Azure OpenAI, OpenAI.
- [ ] Today is selected by default.
- [ ] Current Week is available as a second tab.
- [ ] Switching tabs does not reorder provider cards.
- [ ] Demo Anthropic rows show model or returned dimension labels, input tokens, output tokens, and total tokens.
- [ ] Demo Azure OpenAI rows show model labels, optional deployment metadata, input tokens, output tokens, and total tokens.
- [ ] Demo OpenAI rows show organization, project, model, input tokens, output tokens, and total tokens.
- [ ] Unsupported states render as `Unsupported by provider API`.
- [ ] Stale states are visually distinguishable from fresh values.
- [ ] Empty provider states render without crashing or collapsing the popover layout.

## Blocked by

- https://github.com/talibilat/limit-bar/issues/1
- https://github.com/talibilat/limit-bar/issues/2
