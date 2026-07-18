# Model Lifecycle Radar

The Model Lifecycle Radar joins locally retained model usage with a signed, versioned lifecycle and pricing catalog.
It is designed to answer which models in the selected retained period have an official lifecycle notice and whether the same frozen token mix can be priced against a documented replacement.

The Radar is local and inventory-specific.
It is not a provider deprecation service, billing record, migration checker, or model recommendation.
Open it from the app's **Radar > Open Model Lifecycle Radar** command or with Option-Command-R.

## Claim Boundary

Lifecycle records preserve the Provider product, platform, exact model identifier, explicit aliases, effective date, source URL, and source retrieval date.
Anthropic API, OpenAI API, Azure OpenAI, Amazon Bedrock, and Google Vertex AI identities are separate catalog scopes.
A schedule published for one scope is never applied to another scope.

Matching is exact and case-sensitive.
LimitBar does not use prefix, substring, normalized-family, edit-distance, or fuzzy matching.
An unknown identifier therefore receives no deadline and no replacement scenario.

Retirement alerts require an exact published date.
Missing, approximate, inferred, or platform-unspecified dates never qualify.

A replacement is only the replacement documented by the official source represented in the catalog.
LimitBar does not claim behavioral equivalence, quality parity, migration compatibility, provider endorsement, or guaranteed future availability.

## Bundled Catalog

Catalog version `2026.07.18.3` is an official-source-derived static fixture retrieved at 2026-07-18 17:00 UTC.
It contains only exact Anthropic API and OpenAI API records supported by the cited pages at retrieval time.
It deliberately contains no Azure OpenAI, Amazon Bedrock, or Google Vertex lifecycle record because the fetched first-party pages say partner-operated schedules are independent and do not provide those exact schedules.
It also omits undocumented aliases and omits a singular replacement where a source lists alternatives.

Verified examples include Anthropic's August 5, 2026 retirement of `claude-opus-4-1-20250805` with recommended replacement `claude-opus-4-8`, and OpenAI's July 23, 2026 shutdown of `gpt-5.1-codex` with recommended replacement `gpt-5.5`.
Because OpenAI's pages recommend and price `gpt-5.5` without assigning Anthropic-style lifecycle terminology, its lifecycle status is stored as unspecified rather than inferred active.
The fixture records the source retrieval instant separately from lifecycle announcement dates and price revisions observed on the pricing page at retrieval time.

Lifecycle provenance:

- Anthropic model lifecycle: <https://docs.anthropic.com/en/docs/about-claude/model-deprecations>
- OpenAI model lifecycle: <https://platform.openai.com/docs/deprecations>

Pricing provenance:

- Anthropic pricing: <https://docs.anthropic.com/en/docs/about-claude/pricing>
- OpenAI pricing: <https://platform.openai.com/docs/pricing>

The catalog envelope uses Ed25519 signing through `Curve25519.Signing`.
The app contains only the verification public key, key identifier, payload, and signature.
The signing private key is not distributed.
Signature verification establishes artifact integrity for LimitBar's catalog publication and must not be interpreted as provider endorsement.

Unknown keys, invalid signatures, malformed payloads, unsupported schemas, unsupported currencies, duplicate identities or aliases, invalid official provenance, invalid platform mappings, unknown pricing revisions, nonnumeric catalog versions, and validly signed rollbacks fail closed.
The prior verified catalog remains unchanged after a failed refresh.

## Explicit Refresh And Privacy

The catalog is installed or updated only when the user selects **Load Signed Artifact...** or **Install Bundled** in the Radar.
It is not part of Local Refresh, provider refresh, status checks, or a background subscription.

The artifact action reads a selected regular file of at most 4 MiB, rejects symbolic links, verifies its signature and schema, and then applies monotonicity checks before storage.
The bundled install performs no network request.
The core remote-refresh boundary is also tested independently for future signed catalog distribution.
That boundary permits one HTTPS `GET` with an `Accept: application/json` header and no request body or query string.
It receives no model inventory, aliases observed locally, token mix, account identifier, project identifier, deployment label, workload period, credentials, or provider state.

## Retained Model Inventory

The inventory is derived only from non-superseded model-scoped Usage Aggregates in the selected retained period.
Radar uses a dedicated read-only SQLite loader and does not extend the historical chart snapshot or Local Refresh publication types.
The loader reads the persisted retention setting, current provider-API daily model revisions, and current Exact Six-Hour revisions directly without opening the database for writing.
The selected period uses the full configured retention rather than a fixed display horizon.
Retained Exact Six-Hour Usage Aggregates supplement model windows not covered by a selected daily aggregate; exact windows already covered by a daily local aggregate are not added again.
Provider API model aggregates remain separately authoritative and are retained when present.
Observed zero does not make a model used.
Gaps do not become zero usage.
Records outside the selected period do not appear.

Provider product and platform come from the measured source identity.
Custom Usage Sources do not acquire a platform mapping automatically and therefore do not receive lifecycle deadlines.

Deleting Radar data does not delete current usage, historical usage, source files, provider settings, credentials, alert preferences, or unrelated Delivery Ledger entries.

## Calculated Cost Scenarios

A replacement scenario replays a frozen workload against the latest applicable replacement price revision whose effective date is not later than calculation time.
The result is labeled **Calculated Cost**.
It is not Provider-Reported Cost and is not a provider quote.

Every persisted scenario records:

- Catalog version.
- Original and replacement exact identities and platforms.
- Pricing revision and pricing effective date.
- Official pricing source URL.
- Calculation time and exact workload period.
- Frozen quantities for each represented price dimension.
- Minimum and maximum Calculated Cost and currency.
- Omitted dimensions and limitations.

The range can collapse to one value when the catalog has one exact unit price.
Current pricing is never retroactively described as historical pricing, and a scenario is never described as a guaranteed future price.

LimitBar calculates a scenario only when input, output, and every applicability modifier are known.
The modifier set includes cache reads and writes, long context, Batch, Flex, Priority, service tier, regional processing, tools, and containers.
A used dimension must have both a frozen quantity and an applicable price.
Unknown applicability, unknown quantities, unsupported dimensions, platform mismatch, missing revisions, or unsupported currencies produce explicit unavailable reasons instead of assumed zero values.

The Radar provides an explicit scenario editor for each used model with a documented replacement.
Every cache, long-context, Batch, Flex, Priority, other service-tier, regional-processing, tool, and container selector starts at **Unknown** and must be changed to **Yes** or **No** by the user.
Selecting **Yes** exposes the relevant quantity fields and never converts an omitted quantity to zero.
Incompatible combinations fail closed when the available aggregate cannot express their interaction safely.
The store recalculates a proposed scenario from its frozen workload and catalog version before persistence, so incomplete or altered scenarios cannot be retained even if constructed outside the UI.

## Retirement Alerts

Retirement alerts are opt-in.
They are considered only for exact catalog matches measured in the retained period, with an exact future retirement date no more than 180 days away.

Qualified alerts use the existing local alert coordinator and SQLite Delivery Ledger.
Retirement dates are encoded as canonical Gregorian `YYYY-MM-DD` source-calendar values rather than instants.
Display and qualification therefore cannot move the published day when the Mac timezone changes.
The ledger identity includes the exact model, platform, and a canonical UTC representation of the source date, so the same published date is delivered once.
A changed exact date creates a new exact boundary.
Removing a record or removing its exact date suppresses future qualification without fabricating a replacement deadline.

Notification copy identifies the published date and platform and directs the user to LimitBar for source details.
It does not claim that the replacement is compatible or equivalent.

## Persistence, Supersession, And Deletion

Radar persistence uses the standalone `model-lifecycle-radar-v1.json` archive in LimitBar Application Support.
It does not add tables or migrations to the usage, historical usage, or Delivery Ledger databases.

The archive schema is version 1.
Pre-release schema 0, which contained only catalog envelopes, migrates to schema 1 by verifying and preserving at most the five newest envelopes and initializing an empty scenario collection.
An invalid legacy envelope aborts migration without replacing the original file.
Unknown archive versions fail closed and are not overwritten.
A future distributed schema change must add an explicit migration before increasing the archive version.

Catalog history is bounded to five verified versions.
Recording the identical signed artifact is idempotent; a different artifact with the same catalog version is rejected.
An incoming different artifact must have a strictly greater numeric catalog version and publication instant, cannot alter an existing pricing revision ID, and cannot move the newest effective pricing revision backward.
Calculated Cost scenarios are bounded to 500 records and 365 days.
Recording the same scenario ID supersedes its prior stored representation.
Expired scenarios are removed during scenario recording and omitted from reads.

**Delete Radar Data** atomically removes catalog history and persisted scenarios.
Failed writes and failed deletion report an error and do not intentionally modify unrelated data.

## Verification Coverage

Focused tests cover:

- Signature integrity, unknown keys, unsupported schemas, official provenance, currencies, and platform mappings.
- Exact identifiers and aliases, including case changes, near-prefix identifiers, and partner-platform variants.
- Active, deprecated, retired, replaced, missing-date, exact-date, fully priced, and partially priced fixtures checked against the 2026-07-18 official pages.
- Every required modifier unavailable path and a fully known Calculated Cost replay.
- Frozen scenario provenance, completeness revalidation, and limitations.
- Selected-file artifact safety, validly signed rollback rejection, and explicit-refresh request privacy.
- Date-only retirement semantics across local timezones and full-retention Exact Six-Hour inventory coverage.
- Catalog and scenario retention, supersession, and deletion.
- Exact retirement alert qualification and Delivery Ledger identity deduplication.
