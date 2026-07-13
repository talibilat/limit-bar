# Domain Glossary

## Usage Event

An immutable record of normalized token consumption attributable to one logical operation.
Its token quantities are per-event deltas rather than cumulative counters or snapshots.

## Event ID

An opaque producer-generated UUID that identifies one Usage Event across identical retries.
Reusing an Event ID for different usage is a conflict.

## Collector

The supported local boundary that validates and records Usage Events supplied by producers.
It does not discover usage or interpret native provider data.

## Provider

The service responsible for provider-attributed usage.
A Provider is distinct from a client application, account, project, or producer.

## Custom Source

A user-configured ingestion channel with a stable identity and separately configured display name.

## Source Identity

Exactly one Provider or Custom Source associated with a Usage Event.

## Active Usage File

The current collection of Usage Events available for LimitBar to ingest.

## Archive

A retained historical copy of an Active Usage File that is not part of current ingestion.

## Duplicate

An identical retry of a Usage Event whose Event ID remains within the Idempotency Horizon.

## Event ID Conflict

A submission that reuses an Event ID for different Usage Event content.

## Idempotency Horizon

The period during which a recorded Usage Event remains available for duplicate detection.

## Active Retention

The event-time interval preserved in the Active Usage File when older usage is rotated.

## Rate Capacity

The number of new Usage Events that may be accepted for one destination during a rolling period.
