# Ingest Azure OpenAI Usage Events From JSONL

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Build the full Azure OpenAI local integration path.
LimitBar should read explicit usage events written by tools or scripts to `~/Library/Application Support/LimitBar/usage-events.jsonl`.
Each valid event becomes a normalized Azure OpenAI metric and appears in the Azure OpenAI card grouped by model.

This issue must not add Azure management API integration.
Azure quota and rate-limit tracking are out of scope for v1, so Azure rows must show quota/rate-limit fields as `Unsupported by provider API`.
Malformed JSONL events must not crash the app and must be visible in diagnostics.

## Acceptance criteria

- [ ] LimitBar resolves the Azure usage event path to `~/Library/Application Support/LimitBar/usage-events.jsonl`.
- [ ] Settings show the JSONL path.
- [ ] Settings provide a way to reveal the JSONL path in Finder.
- [ ] The parser accepts valid Azure OpenAI JSONL events with provider, timestamp, model, input tokens, output tokens, and optional deployment.
- [ ] The parser rejects malformed JSON, wrong provider values, missing required fields, and negative token counts.
- [ ] Valid events are imported into SQLite as normalized Azure OpenAI metrics.
- [ ] Imported Azure usage appears in the Azure OpenAI card grouped by model.
- [ ] Optional deployment metadata appears when supplied by an event.
- [ ] Azure cost is calculated from confirmed token counts when pricing is configured.
- [ ] Malformed events are counted or listed in diagnostics without crashing the app.
- [ ] Azure quota and rate-limit fields explicitly render `Unsupported by provider API`.

## Blocked by

- https://github.com/talibilat/limit-bar/issues/4
- https://github.com/talibilat/limit-bar/issues/5
