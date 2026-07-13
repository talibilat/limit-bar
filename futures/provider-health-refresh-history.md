# Provider Health And Refresh History

## Status

Proposed, not committed.

## Problem

The current coarse provider state does not explain when explicit refreshes last succeeded or how often safe failure categories occurred.

## User Outcome

Users can distinguish stale data, authentication problems, network failures, cancellations, and successful refreshes without exposing request content.

## Proposed Scope

Store a bounded local history of explicit provider refresh outcomes with provider, operation class, fixed result category, start time, duration bucket, and affected exact windows.
Present recent status and last success without raw errors.

## Explicit Non-Goals

The history will not record headers, URLs with query values, request or response bodies, tokens, stack traces, or arbitrary error strings.
It will not introduce background provider polling.

## Privacy And Security

All entries remain local and use enumerated safe fields.
Raw prompts, code, responses, terminal output, credentials, private file paths, and provider payloads are prohibited.

## Data Model Impact

A bounded refresh-history table with schema version, retention cap, and indexed provider timestamp may be required.
Cancellation must remain distinct from failure.

## Open Questions

- What count and age limits should apply?
- Which operation classes are useful without becoming identifying?
- Should users clear health history independently from metrics?

## Exit Criteria

- The schema contains only allow-listed fields.
- Retention and deletion are enforced by tests.
- UI copy distinguishes stale values, failed refreshes, and cancellations.
- Security review confirms no secret or content-bearing path exists.
