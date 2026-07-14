# Stable Signed Distribution

## Status

Implementation ready; external release acceptance pending.

## Problem

Unsigned or inconsistently signed builds do not provide a stable application identity for updates or reliable Keychain testing.

## User Outcome

Users receive a signed and notarized app whose identity remains stable across updates.

## Proposed Scope

Choose a durable signing identity and release channel.
Produce signed and notarized builds and verify that an update preserves the application identity.
Document the release procedure and identity requirements.

## Explicit Non-Goals

This ticket does not redesign authorization, add telemetry, or choose the App Sandbox file-access model.

## Privacy And Security

Signing credentials and notarization secrets must remain outside the repository and logs.
No credentials, Keychain exports, private paths, or provider responses may be committed.

## Data Model Impact

No product data-model change is required.

## Resolved Questions

- Public artifacts use the stable `com.talibilat.LimitBar` bundle identifier, Developer ID Application signing, hardened runtime, Apple notarization, and direct GitHub Releases distribution.
- Signing and notarization credentials live in the protected GitHub `release` environment and are imported only into an ephemeral CI keychain.
- The workflow creates a draft release with a SHA-256 checksum; a human promotes it only after clean-machine acceptance.

## Exit Criteria

- A signed and notarized build launches on a clean supported macOS installation.
- A signed update preserves the expected application identity.
- The release procedure documents signing, notarization, verification, and credential handling.
