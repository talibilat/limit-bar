# Real-Account Keychain Authorization QA

## Status

Proposed and prioritized.

## Dependency

Ticket 01 must provide the stable application identity used throughout testing.

## Problem

Fixture tests cannot prove how real Keychain authorization behaves across prompts, updates, identity changes, or recreated items.

## User Outcome

Users receive predictable Claude authorization behavior from a consistently signed app.

## Proposed Scope

Test passive checks, Connect, Check Again, Always Allow, signed app updates, changed identity, and a recreated Claude Keychain item against designated test accounts.
Document expected prompts, recoverable failures, and identity-related exceptions.

## Explicit Non-Goals

This ticket does not discover credentials automatically or export Keychain data.

## Privacy And Security

Use designated test accounts.
Do not commit credentials, Keychain exports, private paths, or provider responses.

## Data Model Impact

No product data-model change is required.

## Open Questions

- Which account and Keychain item states represent supported configurations?
- Which identity changes should require renewed authorization?

## Exit Criteria

- The full authorization matrix is run against the stable signed identity from ticket 01.
- A signed update preserves expected Keychain behavior.
- Changed-identity and recreated-item behavior is documented with recovery guidance.
