# Release Migration QA

## Status

Implemented for the pre-release and planned first-release schemas.
Binary-to-binary acceptance begins after the first public release exists.

## User Outcome

Users can update without silent metric loss and can recover without LimitBar automatically deleting an unopenable database.

## Delivered Scope

- A manifest inventories every currently known usage database schema.
- Synthetic fixtures represent the actual pre-release SQLite version 0 shape and the planned schema 2 public baseline.
- Optimized validation checks every raw field, schema integrity, supporting indexes, fixture privacy, and inventory completeness.
- Production opens validate schema fingerprints, canonicalize known weak schema-2 variants, and repair only nonsemantic indexes.
- Unknown, malformed, and future schemas are preserved and refused.
- Settings provides retry, recovery guidance, database-folder access, and explicit archival before clean replacement.
- Release guidance separates migration preservation from retention and requires signed-app acceptance before publication.

## Deferred By Reality

No public LimitBar release exists yet, so there is no prior published executable for binary-to-binary acceptance.
The first public release must freeze an app-generated canonical fixture and its exact artifact for all later release checks.
