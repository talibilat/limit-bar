# Privacy-Safe Diagnostic Export

## Status

Proposed, not committed.

## Problem

Users need a reviewable way to share enough state for support without exposing credentials or private work content.

## User Outcome

Users can inspect and deliberately export a small diagnostic bundle that is useful and safe by construction.

## Proposed Scope

Generate an on-demand JSON report from allow-listed app version, macOS version, provider state categories, database health, import counts, and bounded resource-limit reasons.
Include optional coarse refresh history only if a separate, already implemented refresh-history schema has passed privacy and security review.
Show an exact preview before writing or sharing the file.

## Explicit Non-Goals

The export will not include logs by default, arbitrary errors, database copies, JSONL files, Keychain data, raw paths, filenames, model prompts, code, responses, or provider payloads.
It will not upload automatically.
It will not create, collect, or retain refresh history.

## Privacy And Security

Use positive allow-list encoding rather than redacting a broad internal object.
Normalize or omit paths and identifiers that could reveal usernames, organizations, projects, or source names.
Raw prompts, code, responses, terminal output, credentials, and raw provider payloads are prohibited.

## Data Model Impact

Define a versioned export schema independent from internal Codable models.
No persistent export history is required.
The export does not add a refresh-history table or alter refresh-history retention; it can only consume fields exposed by a separately implemented and privacy-reviewed schema.

## Open Questions

- Which labels are useful enough to include safely?
- Should timestamps be exact or rounded?
- How should users report a failure whose only distinction is currently an unsafe arbitrary error?

## Exit Criteria

- Snapshot tests prove the complete allow-list.
- Sentinel tests reject every prohibited content category.
- The user previews and explicitly chooses the destination.
- The export can be decoded across schema versions without exposing internal storage.
- Optional refresh history is absent unless a separately implemented, privacy-reviewed schema supplies allow-listed fields, and the export creates no additional history retention.
