# LimitBar Usage Context

LimitBar presents locally retained, privacy-safe measurements of AI provider usage and limits.
This language distinguishes current measurements, historical evidence, and values that cannot be compared safely.

## Language

**Usage Snapshot**:
A normalized measurement for a currently active usage window that may change on later refreshes.
_Avoid_: Historical record, event

**Usage Aggregate**:
Normalized token and cost values observed for one Exact Usage Window and Coverage Scope.
_Avoid_: Raw usage, reconstructed event

**Exact Usage Window**:
A half-open period with exact start and end boundaries, a calendar basis, timezone identity, period kind, and aggregation version.
_Avoid_: Date label, approximate window

**Coverage Scope**:
The provider population represented by a Usage Aggregate, such as a provider total or one model.
_Avoid_: Source, account label

**Provisional Aggregate**:
The current revision of a Usage Aggregate whose Exact Usage Window has not ended.
_Avoid_: Final usage

**Final Aggregate**:
The current revision of a Usage Aggregate whose Exact Usage Window has ended.
_Avoid_: Immutable source event

**Superseded Aggregate**:
An earlier immutable revision replaced by an explicit later correction.
_Avoid_: Deleted aggregate, overwritten aggregate

**Gap**:
An Exact Usage Window for which LimitBar has no trustworthy Usage Aggregate.
_Avoid_: Zero usage

**Observed Zero**:
A trustworthy Usage Aggregate whose normalized counts are zero.
_Avoid_: Gap, unavailable

**Provider-Reported Cost**:
A monetary value supplied by the provider for an Exact Usage Window.
_Avoid_: Calculated cost

**Calculated Cost**:
A frozen monetary estimate tied to the price revision effective for the usage period.
_Avoid_: Provider bill, current-price cost

**Observed Local Breakdown**:
Local model attribution that may explain an authoritative provider total but is not added to that total.
_Avoid_: Reconciled provider total

**Retention Policy**:
The selected bounded number of completed calendar days for which historical aggregates remain locally stored.
_Avoid_: Backup policy

**Usage Event**:
An immutable record of normalized token consumption attributable to one logical operation.
Its token quantities are per-event deltas rather than cumulative counters or snapshots.

**Event ID**:
An opaque producer-generated UUID that identifies one Usage Event across identical retries.
Reusing an Event ID for different usage is an Event ID Conflict.

**Collector**:
The supported local boundary that validates and records Usage Events supplied by producers.
It does not discover usage or interpret native provider data.

**Provider**:
The service responsible for provider-attributed usage, distinct from a client application, account, project, or producer.

**Custom Source**:
A user-configured ingestion channel with a stable identity and separately configured display name.

**Source Identity**:
Exactly one Provider or Custom Source associated with a Usage Event.

**Active Usage File**:
The current collection of Usage Events available for LimitBar to ingest.

**Archive**:
A retained historical copy of an Active Usage File that is not part of current ingestion.

**Duplicate**:
An identical retry of a Usage Event whose Event ID remains within the Idempotency Horizon.

**Event ID Conflict**:
A submission that reuses an Event ID for different Usage Event content.

**Idempotency Horizon**:
The period during which a recorded Usage Event remains available for duplicate detection.

**Active Retention**:
The event-time interval preserved in the Active Usage File when older usage is rotated.

**Rate Capacity**:
The number of new Usage Events that may be accepted for one destination during a rolling period.

**Authorization Check**:
An attempt to access the existing Claude Code credential.

**Passive Authorization Check**:
An Authorization Check that does not permit macOS to present authentication UI.
_Avoid_: Background authorization, silent login

**Interactive Authorization Request**:
An explicit Authorization Check that permits macOS to present authentication UI.
_Avoid_: Forced prompt

**Connect Action**:
The user action that starts an Interactive Authorization Request.
_Avoid_: Connect affordance

**Authorization Required**:
The state in which a Passive Authorization Check cannot access the Claude Code credential without user-authorized interaction.

**Custom Usage Source**:
A named, user-configured local JSONL file that supplies normalized usage events.
_Avoid_: Local source, custom log

**Local Usage Events**:
Normalized built-in usage events imported from LimitBar's standard local JSONL file.
_Avoid_: Custom Usage Source events
