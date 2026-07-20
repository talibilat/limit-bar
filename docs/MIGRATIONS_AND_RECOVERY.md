# Database Migrations And Recovery

LimitBar uses seven SQLite databases: `usage-metrics.sqlite`, `usage-metrics-attribution.sqlite`, `historical-usage-trends.sqlite`, `quota-observations.sqlite`, `provider-refresh-history.sqlite`, `codex-explanations.sqlite`, and `claude-explanations.sqlite`.
Each production store validates its schema before reading stored state, and schema-changing migrations are transactional.
It never treats an unknown table shape as a known historical schema.

## Release Matrix

No tagged, downloadable LimitBar release exists yet.
The current canonical schemas are planned first public baselines, so a public binary-to-binary update cannot yet be tested.

| Fixture | Classification | SQLite version | Expected result |
| --- | --- | --- | --- |
| `usage-pre-release-v0.sql` | Known pre-release, pre-provenance schema | 0 | Rebuild as canonical schema 2, preserve every raw field, and mark rows as legacy without inventing boundaries. |
| `usage-first-release-v2.sql` | Planned first public baseline | 2 | Validate the schema fingerprint and preserve exact-window records unchanged. |
| `quota-observations-pre-release-v1.sql` | Canonical pre-release quota observation schema | 1 | Open through `SQLiteQuotaObservationStore`, validate the canonical fingerprint, and preserve measured observations and provenance unchanged. |
| `quota-observations-first-release-v1.sql` | Planned first public quota observation baseline | 1 | Validate the canonical fingerprint and preserve measured observations and provenance unchanged. |
| `provider-refresh-history-pre-release-v1.sql` | Canonical pre-release provider refresh schema | 1 | Open through `SQLiteProviderRefreshHistoryStore`, validate the canonical fingerprint, and preserve refresh outcomes and affected windows unchanged. |
| `provider-refresh-history-first-release-v1.sql` | Planned first public provider refresh baseline | 1 | Validate the canonical fingerprint and preserve refresh outcomes and affected windows unchanged. |
| `codex-explanations-pre-release-v1.sql` | Canonical pre-release Codex explanation schema | 1 | Open through `SQLiteCodexExplanationStore`, validate the canonical fingerprint, and preserve bounded normalized explanation findings unchanged. |
| `codex-explanations-first-release-v1.sql` | Planned first public Codex explanation baseline | 1 | Validate the canonical fingerprint and preserve bounded normalized explanation findings unchanged. |

`historical-usage-trends.sqlite` transactionally migrates its known pre-release schema 3 to schema 4 by preserving daily and weekly observations and adding hidden fixed UTC six-hour local-event aggregates.
Its exact fingerprints, preservation, retention, and recovery behavior are covered by `HistoricalUsageTrendStoreTests`; the first public release procedure below freezes its first release-owned fixture alongside the other databases.

## Opening, Storage, And Recovery Inventory

| Database | Production opener | Stored state | Recovery inventory |
| --- | --- | --- | --- |
| `usage-metrics.sqlite` | `SQLiteUsageMetricStore` | Current Usage Aggregates, import metadata, and the alert delivery ledger | Retry opening or use **Create Clean Database** to archive the complete database set before replacement; retained normalized sources can then be reimported. |
| `usage-metrics-attribution.sqlite` | `SQLiteUsageAttributionStore` | Bounded Observed Local Breakdowns, exact Event IDs, source revisions, and deletion suppressions | Retry opening, explicitly delete attribution in Settings, or use **Create Clean Database**; recovery archives this database and its WAL/SHM files with `usage-metrics.sqlite` before either active database is replaced. |
| `historical-usage-trends.sqlite` | `HistoricalUsageTrendStore` | Revisioned daily and weekly Usage Aggregates plus hidden fixed UTC six-hour local-event token aggregates, gaps, observed zeros, and frozen calculated costs | Retry opening with the same or a newer release; explicit history deletion is independent from current usage, and backup restoration must retain the complete database set. |
| `quota-observations.sqlite` | `SQLiteQuotaObservationStore` | Bounded measured quota observations with exact reset identity and observation provenance | Retry opening with the same or a newer release, restore the complete database set, or explicitly clear quota history in Settings. |
| `provider-refresh-history.sqlite` | `SQLiteProviderRefreshHistoryStore` | Bounded provider refresh outcomes and affected Exact Usage Windows | Retry opening with the same or a newer release, restore the complete database set, or explicitly clear provider refresh history in Settings. |
| `codex-explanations.sqlite` | `SQLiteCodexExplanationStore` | Bounded normalized Codex explanation findings with status, coverage, adapter version, counts, token-category totals, and barrier categories | Retry opening with the same or a newer release, restore the complete database set, or explicitly delete Codex explanations in Settings. |
| `claude-explanations.sqlite` | `SQLiteClaudeExplanationStore` | Bounded normalized Claude explanation findings and fixed unavailable reasons | Retry opening with the same source build or explicitly delete Claude explanations in Settings. No prior distributed schema or migration exists. |

The manifest at `LimitBarCore/Tests/LimitBarCoreTests/Fixtures/Migrations/manifest.json` is the authoritative inventory.
Every public release must retain its fixture and release artifact permanently.
Before wiring another persistent store into the app, add it to this inventory and its release acceptance matrix.
The attribution schema is a pre-release schema covered by canonical schema, retention, deletion, restart, lock, corruption, and complete recovery-set tests; its first public fixture must be frozen with the candidate release.
The Claude explanation schema is separately covered by `ClaudeExplanationStoreTests` for its canonical fingerprint, unknown and malformed schema immutability, interrupted-write rollback, age and count retention, restart, and deletion.
It is not in the migration manifest because no public release has distributed it and there is no earlier schema to migrate; its canonical fixture must be frozen and added to the manifest before the first public release.
Clean recovery acquires every lockable main and attribution database lock before inventorying either database's WAL/SHM files, preserving non-lockable corrupt files as opaque recovery evidence.

## Automated Validation

Run the fixture test during development:

```sh
swift test --package-path LimitBarCore --filter MigrationFixtureTests
```

Run the optimized validator used by CI:

```sh
scripts/validate-migrations.sh
```

The validator discovers every SQL fixture through the manifest and fails when the directory and manifest differ.
For `usage-metrics.sqlite`, `quota-observations.sqlite`, `provider-refresh-history.sqlite`, and `codex-explanations.sqlite`, it opens each fixture through the matching production store and compares it with a database created by that store.
It checks the initial and resulting schema versions, exact primary-record count, a SHA-256 digest covering every stored field including refresh-window rows, supporting index columns, the exact allowed schema objects and SQL, and `PRAGMA integrity_check`.
It also rejects fixture or manifest content containing common credential and private-path markers.

Fixture validation proves the current migration core against synthetic databases.
It does not prove Finder launch, signing identity, path selection, startup side effects, UI recovery, or old executable behavior.

## Release Acceptance

For the first public release:

1. Build the final signed, notarized, and stapled ZIP as a draft release.
2. Verify a clean install on the oldest and newest supported macOS versions.
3. Exercise the pre-release and current fixtures for `usage-metrics.sqlite`, `quota-observations.sqlite`, `provider-refresh-history.sqlite`, and `codex-explanations.sqlite` through the candidate app.
4. Exercise production opening, storage, deletion, and recovery for `historical-usage-trends.sqlite` through the candidate app.
5. Freeze synthetic copies of all seven databases generated by the exact candidate app as the permanent first-release fixtures.
6. Promote the draft only after the migration and recovery checks pass.

For every later release:

1. Install each prior public release from its retained published ZIP in an isolated macOS account.
2. Create representative synthetic state through that release.
3. Quit the prior release and copy the database together with adjacent `-wal` and `-shm` files.
4. Launch the final candidate app against the copy.
5. Verify migration preservation before separately checking retention, import replacement, custom-source cleanup, and UI visibility.
6. Exercise an interrupted migration, a locked database, a read-only database, a corrupt copy, an unsupported future schema, and restoration of a complete backup set.
7. Promote the draft only after all supported source releases pass.

An optimized core build is the blocking CI tier.
The final signed app is the blocking publication tier.

## Preservation Semantics

Migration preservation means every supported database record and field survives the migration transaction unless a documented migration rule transforms it.
The normal 90-day retention policy runs later and is not migration behavior.

Pre-provenance records remain physically available as legacy records but do not appear as current metrics.
Their original date, time zone, and exact window cannot be inferred safely, so LimitBar does not invent boundaries for them.

## Failure Guarantees

A failed forward migration rolls back its transaction and leaves the original database in place.
Unknown version-0 fingerprints, malformed current schemas, and future schema versions are refused without creating a clean replacement.
Missing nonsemantic supporting indexes may be recreated transactionally.

Downgrade compatibility is not promised.
After a newer LimitBar version successfully opens a database, do not open it with an older release unless that release explicitly documents support.

## User Recovery

If LimitBar cannot open the database:

1. Quit LimitBar before making a manual copy.
2. Back up `usage-metrics.sqlite`, `historical-usage-trends.sqlite`, `quota-observations.sqlite`, `provider-refresh-history.sqlite`, `codex-explanations.sqlite`, and their adjacent `-wal` and `-shm` files as complete sets.
3. Keep the backup local because labels and usage aggregates can be private.
4. Retry with the same or a newer LimitBar release.
5. In Settings, use **Reveal Database Folder** to inspect the database directory or **Create Clean Database** to archive and replace `usage-metrics.sqlite`; this action does not replace attribution, historical, quota-observation, provider-refresh-history, Codex explanation, or Claude explanation databases.
6. Reimport retained normalized local and custom JSONL sources and explicitly refresh configured providers.

Copying only the main SQLite file is not a reliable backup when sidecars exist.
The clean-database action first requires an exclusive SQLite transaction and refuses recovery while another writer holds the database.
Creating a clean database can make non-reconstructible aggregates unavailable in the app, but the recovery action does not intentionally delete the archived original.
Settings and Keychain credentials are stored separately and are not removed by database recovery.

Never attach a user database to a public issue or upload it as a CI artifact.
Developers may diagnose only an explicitly authorized, irreversibly sanitized copy.
