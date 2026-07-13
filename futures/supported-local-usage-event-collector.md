# Supported Local Usage Event Collector

## Status

Implemented in this branch, pending release validation.

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

- The supported interfaces are a reusable Swift writer and the `limitbar-collect` command-line helper.
- Cooperating producers serialize through an interprocess file lock and replace complete JSONL files atomically.
- Producers use opaque UUIDs for active-file idempotency, and UUID reuse with different event content is rejected.
- Rotation retains eight days in the active file and bounds archives by age and total bytes.

## Exit Criteria

- The interface has a versioned public specification and adversarial parser tests.
- Concurrent writes and rotation do not corrupt accepted events.
- Resource and rate limits are explicit and tested.
- A privacy review confirms that content-bearing fields cannot enter the schema.
