# Quota Doctor Release Validation

Run the deterministic local validation command from the repository root:

```sh
scripts/validate-quota-doctor-release.sh /absolute/path/to/quota-doctor-release-validation.md
```

The command records every automatable check as `passed` or `failed` and records signed real-source acceptance, the pilot, and the unavailable API adapter as `unavailable`.
If the local XCTest host cannot initialize macOS automation, the UI check is recorded as unavailable rather than passed or as a product assertion failure.
It intentionally does not convert fixture success into real-account, authorization, signing, or participant evidence.
The report contains no wall-clock time or machine path and is deterministic for one commit and one set of check outcomes.
The command exits nonzero while any automated check fails or the required adapter-count gate remains failed.

The command covers the complete Swift package suite, migration validator, native app tests, UI tests, unsigned Release compilation, and fixture privacy scan.
Keep raw command logs local and do not attach databases, source payloads, screenshots with private values, or environment dumps to a release record.

Before a release decision, review the feature-specific suites named in `docs/QA.md` for immutability, supersession, migrations, unknown schemas, age and count retention, independent deletion, restart and interrupted writes, evidence-state distinctions, forensic presentation, export, alerts, and workload planning.
An automated pass is necessary but cannot clear any blocker identified below.

## Release Blockers

- Fewer than two stable, version-tested subscription-client adapters.
- No stable API-provider quota adapter; issue #27 is explicitly unavailable and cannot count.
- No final signed, notarized application acceptance against each claimed real supported source.
- Claude Code OTLP has no production receiver or trustworthy quota-account binding.
- No signed verification of passive and interactive Claude Keychain authorization behavior.
- No supported measured completed-run adapter, so workload planning remains unavailable in production.
- No privacy-safe pilot with informed heavy coding-agent participants.
- No public release artifact exists yet, so release-to-release binary migration validation is unavailable.

These are release blockers, not failed fixture tests.
Do not weaken a product claim or mark an unavailable check passed to clear them.
