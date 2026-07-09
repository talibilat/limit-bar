# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- `CONTEXT.md` at the repo root, if it exists.
- `CONTEXT-MAP.md` at the repo root if it exists. It points at one `CONTEXT.md` per context.
- `docs/adr/` for architectural decisions that touch the area being changed.

If any of these files do not exist, proceed silently.
Do not flag their absence or suggest creating them upfront.
The domain-modeling skills create them lazily when terms or decisions actually get resolved.

## File Structure

This project uses a single-context layout by default.

## Use The Glossary's Vocabulary

When output names a domain concept, use the term as defined in `CONTEXT.md` if one exists.
If the concept is not in the glossary yet, use the terminology already established in the PRD and issue files.

## Flag ADR Conflicts

If output contradicts an existing ADR, surface it explicitly rather than silently overriding it.
