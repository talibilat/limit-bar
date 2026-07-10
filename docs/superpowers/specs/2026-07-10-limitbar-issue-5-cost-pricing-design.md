# LimitBar Issue 5 Cost Pricing Design

## Context

Issue #5 adds cost calculation and editable pricing settings.
The app must prefer provider-reported cost and only calculate estimates from confirmed token counts when matching pricing is configured.

## Approved Approach

Add `PricingEntry`, `PricingTable`, and `CostCalculator` to `LimitBarCore`.
The calculator will expose a small interface that hides effective-date selection and token-side price math.
The popover will render the resulting `Cost` and source label.

## Pricing Model

Pricing entries are provider/model specific and effective-date aware.
Each entry stores input and output token prices per million tokens, a currency code, and an effective date.
`PricingTable.price(for:usageDate:)` selects the latest entry whose effective date is at or before the metric refresh time.
If no matching price exists, no calculated cost is produced.

## Cost Rules

Provider-reported cost wins over calculated estimates.
Calculated estimates use confirmed input and output token counts.
The resulting `Cost` uses source `.calculatedEstimate`.
Missing pricing returns `nil` rather than a fake zero or non-zero cost.

## Settings And Popover

Settings will include a Pricing section with manual editable fields for provider, model, input price, output price, currency, and effective date.
Saved entries persist in user defaults as JSON.
The popover reads the same pricing table and displays provider-reported or calculated cost labels per row.

## Out Of Scope

Automatic pricing updates are out of scope.
Live provider integrations are out of scope.
Historical provider billing reconciliation is out of scope.

## Acceptance Mapping

Core tests cover token-side cost calculation, provider cost preference, effective-date selection, missing-price behavior, and source labels.
Settings manual edits persist pricing entries.
Popover cost rendering uses provider-reported labels when present and calculated-estimate labels when pricing is configured.
