# Team Capacity Planner

The Team Capacity Planner is a validation-first experiment for answering cohort-level seat-capacity questions without organization API access or individual surveillance.
Organization mode is disabled by default and requires explicit acknowledgement of employee-data governance risk.
It imports only files that an administrator has reviewed and a user manually selects.
It has no organization network client, API integration, API credential, or background importer.

## Claim Boundary

The planner can describe supported daily evidence about blocked capacity, usage concentration across privacy-safe teams, cache efficiency, concurrency, and the share of quota-eligible users whose active windows repeatedly approached exhaustion.
It presents distributions and cohort-level patterns only.
It does not expose employee rankings, individual scores, individual drill-down, raw team identities, or reversible alias mappings.

Tokens, sessions, commits, pull requests, lines changed, tool acceptance, and estimated cost are not measures of productivity, quality, performance, or developer value.
The planner never labels or uses them that way.

Subscription quota and API spend are separate subjects.
Seat cost and API overflow cost are separate subjects.
Provider-Reported Cost and Calculated Cost are separate provenance categories.
The planner does not sum these values into a capacity, productivity, or developer-value score.

## Setup And Consent

Open LimitBar Settings and choose **Open Team Capacity Planner** under **Organization Mode**.
Before organization storage is opened, the setup screen requires acknowledgement that organization aggregates can constitute employee data and that the organization approved the selected analysis.
Consent is versioned locally so a later governance-contract revision can require acknowledgement again.
Disabling organization mode does not silently delete retained organization data.
The planner provides a separate explicit deletion action.

## Import Schema

The only accepted schema is `limitbar.organization.daily.v1`.
The root object uses this exact positive allow-list:

```json
{
  "schema_version": "limitbar.organization.daily.v1",
  "administrator_reviewed": true,
  "aggregation_period": "daily",
  "timezone": "UTC",
  "records": []
}
```

Every record must represent a completed UTC day before the current UTC day.
Each record uses this exact positive allow-list:

| Field | Required | Meaning |
| --- | --- | --- |
| `day` | Yes | Completed day in strict `YYYY-MM-DD` form. |
| `provider_product` | Yes | `claude_code` or `codex`. |
| `team_identity` | Yes | Canonical lowercase producer-generated UUID; it is never persisted. Human-readable names and noncanonical UUID text are rejected. |
| `cohort_size` | Yes | Number of represented people, from 1 through 100,000. |
| `complete_day` | Yes | Must be `true`. |
| `usage_units` | No | Non-negative aggregate usage units used only for daily team-concentration distributions. |
| `blocked_capacity_user_days` | No | Cohort count with supported blocked-capacity evidence for that day. |
| `cache_read_units` | No | Aggregate cache-read units; must appear with `uncached_input_units`. |
| `uncached_input_units` | No | Aggregate uncached input units; must appear with `cache_read_units`. |
| `peak_concurrency` | No | Supported daily peak concurrency, no greater than cohort size. |
| `quota_eligible_users` | No | Aggregate denominator for repeated near-exhaustion evidence. |
| `repeatedly_near_exhaustion_users` | No | Aggregate numerator, no greater than `quota_eligible_users`. |
| `scheduled_peak_blocked_minutes` | No | Aggregate scenario evidence; must appear with `off_peak_available_minutes`. |
| `off_peak_available_minutes` | No | Aggregate scenario evidence; must appear with `scheduled_peak_blocked_minutes`. |
| `subscription_seat_cost` | No | Separate seat-cost object. |
| `api_overflow_cost` | No | Separate API-overflow-cost object. |

A cost object has exactly `amount`, `currency`, and `provenance` fields.
`currency` must be a three-letter uppercase code.
`provenance` must be `provider_reported` or `calculated`.

This synthetic example is accepted:

```json
{
  "schema_version": "limitbar.organization.daily.v1",
  "administrator_reviewed": true,
  "aggregation_period": "daily",
  "timezone": "UTC",
  "records": [
    {
      "day": "2026-07-05",
      "provider_product": "claude_code",
      "team_identity": "11111111-1111-4111-8111-111111111111",
      "cohort_size": 8,
      "complete_day": true,
      "usage_units": 600,
      "blocked_capacity_user_days": 2,
      "cache_read_units": 800,
      "uncached_input_units": 200,
      "peak_concurrency": 4,
      "quota_eligible_users": 8,
      "repeatedly_near_exhaustion_users": 2,
      "scheduled_peak_blocked_minutes": 120,
      "off_peak_available_minutes": 60,
      "subscription_seat_cost": {
        "amount": 40,
        "currency": "USD",
        "provenance": "provider_reported"
      }
    }
  ]
}
```

## Fail-Closed Validation

The whole import is rejected before persistence when its schema is unknown, review acknowledgement is absent, aggregation is not a completed UTC day, a provider product is unsupported, a value is malformed, or records conflict.
An identical file digest is a duplicate import and is rejected.
A second record for the same day, provider product, and team alias is rejected transactionally.
Unsupported dimensions and arbitrary fields are not ignored.

Email addresses, names, API-key names, organization IDs, terminal identifiers, raw actor or user IDs, prompts, code, transcripts, paths, and arbitrary attributes are prohibited.
Their common field names are reported as prohibited and every other field outside the allow-list is reported as unknown.
No rejected field value, selected path, or raw input is written to planner logs or persistence.

The selected file must be a regular non-symbolic-link file no larger than 8 MiB.
Malformed files and partial days fail without a partial database write.

## Aliasing And Suppression

Every installation creates a random 256-bit alias key in the isolated organization directory with owner-only file permissions.
Before an accepted aggregate reaches the store API, LimitBar computes an HMAC-SHA256 over its opaque team identity and truncates the result to a display-independent `team-` alias.
The original UUID and any alias mapping are never persisted.
Because HMAC is one-way and the key never leaves the installation, exports cannot reverse aliases to source identities.

The privacy threshold is five represented people.
Records below five are counted as suppressed but are not aliased or persisted.
Threshold-qualified aliases are used only inside calculation storage and are never shown in the UI or distribution export.
All storage-derived UI, calculations, scenarios, diagnostics, and exports therefore operate only on threshold-qualified records.

Fixtures and examples in this repository are synthetic.
They must not be derived from users or production organization files.

## Supported Outputs

Every output is partitioned by Provider product before calculation or presentation.
Blocked-capacity output is the per-product count of completed days with positive supported blocked-capacity evidence.
Team concentration is published as distributions of per-product daily top-team share and daily concentration index without team aliases or ranked teams.
Cache efficiency is published per product as the distribution of `cache_read_units / (cache_read_units + uncached_input_units)` where both fields have supported semantics.
Concurrency is published as a per-product daily aggregate distribution.
Repeated near-exhaustion is published per product as the distribution of `repeatedly_near_exhaustion_users / quota_eligible_users` where both fields have supported semantics.

If required evidence is absent, the corresponding output says it is unsupported by the source.
Missing evidence is not interpreted as zero.
Provider products are never compared when their imported dimensions have incompatible semantics.

## Schedule-Shift Scenario

The one supported scenario moves between zero and 50 percent of imported scheduled-peak blocked minutes independently for each Provider product.
Its lower bound is always zero.
Its upper bound is the smaller of the selected scheduled blocked minutes and observed off-peak available minutes.

The scenario assumes the selected completed days represent the proposed schedule, shifted work can consume measured off-peak capacity without displacing other work, and provider quota behavior and workload demand otherwise remain unchanged.
It is not a forecast or guarantee of reduced blocking, recovered capacity, productivity, quality, or developer value.

## Isolated Persistence

Organization data is stored under `Application Support/LimitBar/Organization/`.
The aggregate database is `team-capacity-v1.sqlite`.
The alias key is `team-alias-v1.key`.
Neither belongs to the personal usage database, historical usage database, quota observations, alerts, provider settings, Keychain credentials, or personal diagnostics.

The organization database has its own strict schema fingerprint and SQLite `user_version`.
Unknown versions or schema fingerprints fail closed and leave the database unchanged.
No pre-release organization schema is migrated implicitly.
A future schema migration must validate the old fingerprint and preserve suppression and alias invariants transactionally.

Organization retention is independently selectable as 30, 90, 180, or 365 completed days and defaults to 90 days.
Pruning removes import provenance when no retained aggregate references it.
Secure deletion first writes an owner-only durable recovery marker, enables SQLite `secure_delete`, erases aggregate and provenance rows in an exclusive transaction, vacuums the database, checkpoints and truncates WAL state, and switches the journal back to delete mode.
Only after the database phase succeeds does it synchronously overwrite and remove `-wal`, `-shm`, and `-journal` sidecars and then synchronously overwrite and remove the alias key.
The operation reports completion only after sidecars, alias key, and recovery marker are verified absent.
If any phase fails, the marker records the required recovery phase, organization storage remains blocked, and the planner offers **Retry Secure Deletion** without claiming completion.
Deleting organization data does not mutate any personal state.

## Diagnostics And Export

Organization diagnostics are displayed only inside the planner.
They contain schema version, retention days, import count, aggregate count, date extent, threshold, and suppression count.
They contain no team aliases, direct identifiers, source path, arbitrary fields, or imported metric rows.
They are not added to the personal diagnostic export.

The planner export is a separate manually saved JSON artifact with schema `limitbar.organization.capacity-export.v1`.
It includes only distribution summaries, distinct cost subjects and provenance, bounded scenario output, source schema identities, provider products, aggregation semantics, threshold, counts, and limitations.
It includes no team alias or individual record.

## Validation Checklist

- Verify organization mode remains disabled until the governance acknowledgement is selected.
- Verify accepted fixtures use only synthetic opaque team identities.
- Verify prohibited, unknown, malformed, partial-day, unsupported-provider, duplicate-file, and overlapping-record imports leave storage unchanged.
- Verify a below-threshold record never reaches the aliaser or database.
- Verify the threshold boundary of five is retained and all outputs remain cohort-level distributions.
- Verify deleting organization data leaves personal usage, quota, alerts, provider settings, credentials, diagnostics, and retention unchanged.
- Verify the application performs no organization network request and stores no organization API credential.
- Verify three engineering managers can answer a seat-capacity question without requesting individual drill-down before considering organization API integration.
