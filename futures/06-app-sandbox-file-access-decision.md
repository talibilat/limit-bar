# App Sandbox And File-Access Decision

## Status

Proposed and prioritized.

## Problem

Public distribution requirements and arbitrary local file access currently lack an explicit long-term security model.

## User Outcome

Users receive a documented distribution and file-access model with predictable permissions and privacy boundaries.

## Proposed Scope

Decide whether the app will use App Sandbox for intended distribution channels.
Evaluate security-scoped bookmarks for configured local sources.
If the app remains unsandboxed, document the distribution rationale, protections, and limitations.

## Explicit Non-Goals

This ticket does not add cloud synchronization, automatic credential discovery, or broad filesystem scanning.

## Privacy And Security

Grant access only to user-selected paths and retain only the minimum authorization metadata.
Do not capture file contents in diagnostics or test artifacts.

## Data Model Impact

Security-scoped bookmarks may require a separately reviewed schema with explicit lifecycle and deletion behavior.

## Open Questions

- Does public distribution require App Sandbox for the chosen channel?
- Can security-scoped bookmarks support every intended local source?
- How should users inspect and revoke retained access?

## Exit Criteria

- The sandbox decision and distribution rationale are documented and approved.
- Required file-access flows have a tested permission and revocation model.
- Any bookmark schema has explicit storage, migration, and deletion rules.
