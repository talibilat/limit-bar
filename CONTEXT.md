# LimitBar Domain Language

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
