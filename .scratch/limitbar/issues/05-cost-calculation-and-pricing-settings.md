# Add Cost Calculation And Pricing Settings

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Add the cost system for LimitBar.
The app should prefer provider-reported cost when available and calculate cost from confirmed input/output token counts when provider cost is unavailable.
Calculated cost must be labeled `Calculated estimate`.
Provider-returned cost must be labeled `Provider reported`.

Pricing should come from bundled versioned pricing tables that can be edited manually in settings.
Pricing entries should be effective-date aware so historical usage is not recalculated with the wrong future price.
Bundled defaults must not fabricate real costs if prices have not been configured.

## Acceptance criteria

- [ ] The core can calculate cost from confirmed input tokens, output tokens, and model pricing.
- [ ] The core prefers provider-reported cost over calculated cost when provider cost is available.
- [ ] Calculated values are labeled `Calculated estimate` in the popover.
- [ ] Provider-returned values are labeled `Provider reported` in the popover.
- [ ] Pricing entries are versioned or effective-date aware.
- [ ] Missing pricing does not produce a fake non-zero cost.
- [ ] Settings allow manual edits to model input and output prices.
- [ ] Edited pricing affects calculated cost shown in the popover.
- [ ] Unit tests cover input/output cost calculation, effective-date selection, missing-price behavior, and cost-source labels.

## Blocked by

- https://github.com/talibilat/limit-bar/issues/2
- https://github.com/talibilat/limit-bar/issues/3
- https://github.com/talibilat/limit-bar/issues/4
