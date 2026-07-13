# Supported Local Usage Event Collector

## Status

Proposed, not committed.

## Problem

Tools can write the documented JSONL shape, but concurrent writes, rotation, validation, and compatibility are currently the tool author's responsibility.

## User Outcome

Local tools have a stable, documented way to submit normalized usage counters without sharing conversation content or provider credentials.

## Proposed Scope

Define a versioned local event schema and evaluate a small writer library, command-line helper, or local IPC endpoint.
Support atomic append behavior, validation, bounded input, rotation guidance, and explicit provider or custom-source identity.

## Explicit Non-Goals

The collector will not proxy provider requests, capture prompts, inspect source repositories, collect terminal sessions, or upload events.
It will not accept arbitrary metadata blobs.

## Privacy And Security

The schema permits timestamp, allow-listed source identity, model or deployment labels, and non-negative token counters only where required.
Raw prompts, code, responses, terminal output, credentials, request bodies, and provider payloads are prohibited.
Local IPC, if chosen, must authenticate the local boundary and enforce size and rate limits.

## Data Model Impact

Events need an explicit schema version and stable idempotency strategy.
Importer provenance must remain bounded by source and exact window, and migration must preserve current JSONL compatibility only if a concrete external consumer requires it.

## Open Questions

- Is a file writer, command-line helper, or local IPC service the smallest robust interface?
- How should concurrent producers and file rotation work?
- Is event-level idempotency necessary, and what identifier can remain privacy-safe?

## Exit Criteria

- The interface has a versioned public specification and adversarial parser tests.
- Concurrent writes and rotation do not corrupt accepted events.
- Resource and rate limits are explicit and tested.
- A privacy review confirms that content-bearing fields cannot enter the schema.
