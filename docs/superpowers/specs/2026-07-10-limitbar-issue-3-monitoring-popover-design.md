# LimitBar Issue 3 Monitoring Popover Design

## Context

Issue #3 creates the first useful monitoring popover using demo normalized metrics.
It must prove that the shared issue #2 usage model can drive the UI before persistence or provider integrations exist.

## Approved Approach

Keep demo data and provider ordering in `LimitBarCore`.
The SwiftUI popover will render provider cards from small core presentation models instead of hardcoded view-only rows.
This keeps provider ordering, empty-state behavior, and time-window filtering testable without UI automation.

## Core Model Additions

`TimeWindow.defaultSelection` will be `today`.
`ProviderUsageCard` will group normalized `UsageMetric` values by provider and always return cards in `ProviderKind.orderedCases` order.
Cards with no matching rows will remain present and expose `isEmpty` for UI empty-state rendering.

`DemoUsageData` will provide fixture-backed usage metrics for Today and Current Week.
The fixture will include Anthropic, Azure OpenAI, and OpenAI rows.
Rows will include model labels, optional deployment metadata for Azure, organization and project labels for OpenAI, input tokens, output tokens, total tokens, unsupported limit status, and at least one stale row.

## Popover UI

`MonitoringPopoverView` will use `TimeWindow.defaultSelection` for its `@State` default.
It will show a segmented picker for Today and Current Week.
It will render provider cards in the fixed order Anthropic, Azure OpenAI, OpenAI.
Switching tabs will only change the rows, not card order.

Each provider card will show provider name, row metadata, input/output/total tokens, unsupported limit text, and stale badges where applicable.
Empty provider cards will keep their layout and display a compact empty state.
The visual style should be compact and calm, with final polish reserved for issue #10.

## Testing

Core tests will cover default time window, fixed card order, tab filtering without reorder, demo row content for all providers, unsupported state text, stale rows, and empty cards.
The native build will verify the SwiftUI popover compiles.

## Out Of Scope

SQLite persistence is out of scope.
Provider refresh is out of scope.
Cost calculation is out of scope.
Credentials and settings changes are out of scope.
Final visual polish is out of scope.

## Acceptance Mapping

The popover opens from the existing menu bar item and will now render provider cards.
Provider cards remain in Anthropic, Azure OpenAI, OpenAI order through `ProviderKind.orderedCases`.
Today is selected by default through `TimeWindow.defaultSelection`.
Current Week is available through the segmented picker.
Demo rows show provider-specific labels, token counts, unsupported states, stale states, and empty states.
