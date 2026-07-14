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
The application may access only these built-in paths:

- `~/.codex/sessions`
- `~/Library/Application Support/LimitBar/usage-events.jsonl`
- `~/Library/Application Support/LimitBar/usage-metrics.sqlite`

The application may also access a custom JSONL regular file only after the user explicitly selects or enters that file as a custom source.
It must not discover custom sources by scanning unrelated directories.
Removing a custom source revokes the application's configured intent to read it and removes its persisted aggregate metrics.

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

## Revocation And Recovery

Users revoke a custom source by removing it in Settings.
Users can revoke built-in access only by changing filesystem permissions, moving the built-in data, or removing LimitBar.
Because there is no retained OS authorization grant, there is no bookmark token to inspect or delete.

## Consequences

The direct release can read required local resources without repeated file-picker authorization.
The process has a broader macOS filesystem capability than the application's intended policy, so code review and path-level tests remain part of the security boundary.
Mac App Store distribution is not compatible with this decision without revisiting built-in Codex access and adopting a sandbox authorization model.

## Verification

The app target must have no App Sandbox entitlement or entitlements file.
Release QA verifies the three built-in paths and one explicitly configured custom regular file while confirming that diagnostics do not reveal paths or contents.
