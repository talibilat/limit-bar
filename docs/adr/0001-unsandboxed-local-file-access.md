# ADR 0001: Unsandboxed Local File Access

Status: Accepted.
Date: 2026-07-13.

## Context

LimitBar is distributed directly through GitHub Releases rather than the Mac App Store.
Its local refresh reads Codex sessions outside an application container, LimitBar-owned usage data in Application Support, and JSONL files explicitly selected by the user.
App Sandbox would prevent the built-in Codex path from working without changing that integration or introducing additional authorization state.

An unsandboxed process can access any file permitted to the logged-in user.
The product therefore needs a narrower application policy even though macOS does not enforce that policy as a sandbox boundary.

## Decision

LimitBar remains unsandboxed for direct distribution.
The application may access only these built-in logical resources:

- `~/.codex/sessions`
- `~/Library/Application Support/LimitBar/usage-events.jsonl`
- `~/Library/Application Support/LimitBar/usage-metrics.sqlite`
- `~/Library/Application Support/LimitBar/historical-usage-trends.sqlite`

SQLite may create adjacent `-wal` and `-shm` files for either database.
Explicit database recovery may create app-owned archives under `~/Library/Application Support/LimitBar/Recovery`.

The application may also access a custom JSONL regular file only after the user explicitly selects or enters that file as a custom source.
It must not discover custom sources by scanning unrelated directories.
Removing a custom source revokes the application's configured intent to read it immediately and removes its current and historical Usage Aggregates during that Local Refresh Cycle.
If a database is temporarily unavailable, removed aggregates remain hidden and physical deletion is retried by the next Local Refresh Cycle.

Custom source configuration stores the source UUID, display name, and path.
It does not store file contents or a security-scoped bookmark.
No bookmark schema or bookmark migration is needed while the app remains unsandboxed.

Direct GitHub distribution does not require App Sandbox.
Every release must instead use the stable Developer ID Application identity, hardened runtime, and Apple notarization described in `docs/RELEASING.md`.

## Protections

- Importers reject non-regular files and enforce documented file, line, aggregate, and timestamp limits.
- Diagnostics and automated artifacts contain aggregate statuses only, never local paths or source content.
- Normalized metrics are stored locally, and secrets remain in Keychain.
- The app does not claim filesystem isolation from other files available to the logged-in user.
- Any new built-in path requires a new or superseding ADR and privacy review.
- Any broad directory scan, automatic custom-file discovery, or security-scoped bookmark schema requires separate design and migration review.
- Codex session traversal rejects a redirected sessions root and confines canonical candidates to that root.
- Custom configuration stores a canonical target path, and both readers open each canonical path component without following later symbolic-link substitutions.

## Revocation And Recovery

Users revoke a custom source by removing it in Settings.
Users can revoke built-in access only by changing filesystem permissions, moving the built-in data, or removing LimitBar.
Because there is no retained OS authorization grant, there is no bookmark token to inspect or delete.

## Consequences

The direct release can read required local resources without repeated file-picker authorization.
The process has a broader macOS filesystem capability than the application's intended policy, so code review and path-level tests remain part of the security boundary.
Mac App Store distribution is not compatible with this decision without revisiting built-in Codex access and adopting a sandbox authorization model.

## Verification

The app target explicitly disables App Sandbox and has no entitlements file.
CI verifies the effective Debug and Release build settings, and release packaging rejects a signed artifact that contains the App Sandbox entitlement or lacks hardened runtime.
Release QA verifies the four built-in logical resources and one explicitly configured custom regular file while confirming that product diagnostics do not reveal paths or contents.
