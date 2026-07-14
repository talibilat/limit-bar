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

## Local Refresh

**Local Refresh Cycle**
: One coordinated update of local usage and local Codex information followed by publication of a combined result.

**Local Usage Refresh**
: The part of a Local Refresh Cycle that refreshes configured custom usage sources and loads the Current Usage Snapshot.

**Codex Session Scan**
: The part of a Local Refresh Cycle that searches recent local Codex sessions for the freshest rate-limit report.

**Refresh Snapshot Publication**
: The point at which the completed local usage and Codex results become available to the application.

**Periodic Trigger**
: A request for a Local Refresh Cycle produced by the configured local refresh cadence.

**Immediate Trigger**
: A request for a Local Refresh Cycle produced by a local configuration change or an explicit local action.

**Coalesced Trigger**
: A trigger received during an active Local Refresh Cycle that is represented by at most one follow-up cycle.

**Cadence Overrun**
: A Local Refresh Cycle whose Publication Latency equals or exceeds the configured local refresh interval.

**Publication Latency**
: Monotonic elapsed time from accepting a refresh trigger until publishing its resulting local refresh snapshot.

## Local Usage Sources

**Current Usage Snapshot**
: The current normalized metrics for the exact local day, local week, and provider billing windows.

**Current Usage Snapshot Load**
: The operation that applies retention, considers local imports, and retrieves the Current Usage Snapshot.

**Fingerprint-Stable Source**
: A local usage source whose production metadata fingerprint has not changed since its previous successful import.

**Fingerprint Collision**
: A source whose content changed without changing the metadata represented by its production fingerprint.

**Event Append**
: The addition of one or more complete normalized usage events to the end of a local source.

**Atomic Replacement**
: Replacement of a complete local source with another complete version in one filesystem operation.

**Provider Refresh**
: An explicit request to a remote provider that is outside the Local Refresh Cycle.

**Claude Refresh**
: The separate Claude authorization and remote-limit workflow that is outside the Local Refresh Cycle.

**Public release**:
A tagged, downloadable LimitBar artifact published through GitHub Releases.
_Avoid_: Shipped commit, source build

**Distributed schema**:
A persistent schema opened by at least one public release.
_Avoid_: Any historical table shape

**Pre-release schema**:
A schema produced by source builds before the first public release.
_Avoid_: Distributed schema, public v1

**Logical schema revision**:
The product-level identity of a persistent data shape, independent of its storage engine's version number.
_Avoid_: SQLite user version

**Schema fingerprint**:
The tables, columns, constraints, indexes, and metadata that identify a known persistent data shape.
_Avoid_: Version number

**Migration preservation**:
Retention of supported records and fields through the migration transaction before unrelated application policies run.
_Avoid_: UI visibility

**Product visibility**:
Whether preserved data can safely appear in current user-facing snapshots.
_Avoid_: Physical preservation

**Legacy record**:
A preserved usage aggregate whose exact original window cannot be established.
_Avoid_: Current record

**Forward recovery**:
Restoring operation with the same or a newer LimitBar release while retaining the original database set.
_Avoid_: Downgrade

**Canonical fixture**:
A synthetic database generated by the exact public release artifact that owned its schema.
_Avoid_: Handwritten approximation

**Adversarial fixture**:
A deliberately incomplete, malformed, or damaged database used to verify safe failure behavior.
_Avoid_: Canonical fixture

**Release-level validation**:
Validation performed by launching the final candidate app against databases generated by prior public release artifacts.
_Avoid_: Optimized core test

**Usage**:
Measured token, request, credit, or monetary consumption.

**Quota**:
A provider-controlled allowance or capacity constraint.
_Avoid_: Budget, usage limit

**Quota window**:
A provider-defined period over which a quota applies and whose reset boundary is reported rather than inferred.
_Avoid_: Usage window, budget period

**Rate-limit usage**:
Consumption within a quota window, commonly represented as a percentage.
_Avoid_: Budget usage

**Provider product**:
The monitored provider surface, such as Claude Code, Codex, Anthropic API, OpenAI API, or Azure OpenAI.
_Avoid_: Provider, when the company and product could differ

**Cost budget**:
A user-configured monetary cap for an exact period and one cost provenance.
_Avoid_: Provider quota, spend threshold

**Spend threshold**:
An absolute accumulated monetary amount that triggers an alert without implying a budget cap.
_Avoid_: Budget

**Alert rule**:
A user preference defining an alert subject, scope, thresholds, and whether it is enabled.

**Alert candidate**:
A qualifying observation that has not yet passed delivery-ledger checks.
_Avoid_: Delivered alert

**Delivery ledger**:
Durable local state recording which rule thresholds have been accepted for delivery in an exact subject window.
_Avoid_: Notification history

**Reported**:
Supplied directly by a provider.
_Avoid_: Confirmed, when describing calculated values

**Measured**:
Directly observed from a supported local or provider source.

**Calculated**:
Deterministically derived from measured data and explicit pricing.
_Avoid_: Reported, invoiced

**Inferred**:
Estimated from incomplete evidence and never presented as an official quota.
_Avoid_: Confirmed

**Fresh**:
A source-specific, age-qualified observation whose exact boundary remains active and which is safe for notification.

**Exact boundary**:
A provider-reported or calendar-resolved reset boundary that LimitBar did not guess.
_Avoid_: Estimated reset
