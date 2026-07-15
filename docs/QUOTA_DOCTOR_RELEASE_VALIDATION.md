# Quota Doctor Release Validation

Run the deterministic local validation command from the repository root:

```sh
scripts/validate-quota-doctor-release.sh \
  --report /absolute/path/to/quota-doctor-release-validation.md \
  --sentinels /absolute/path/to/local-prohibited-sentinels.txt \
  --artifacts /absolute/path/to/export-artifacts \
  --artifacts /absolute/path/to/acceptance-and-pilot-artifacts
```

`--artifacts` is repeatable and may identify files or directories, including `.xcresult` packages, SQLite databases, ZIP archives, exports, acceptance evidence, pilot evidence, and screenshots.
The command never scans source logs automatically because those logs may contain private source material.
If no artifact roots are supplied, the report records the caller-provided artifact scan as unavailable.

The scanner examines text and printable strings from binary files, including SQLite and every regular file inside an xcresult package.
It validates ZIP structure and member paths, then scans member names and member bytes without extracting them.
Unreadable files, malformed ZIPs, unsafe ZIP member paths, or failed member reads fail the scan rather than being skipped.
For screenshots and other images, embedded metadata and printable strings are scanned.
Image pixels are not OCR-scanned, so a human must inspect screenshots for visible prohibited content before retaining or sharing them.

The generated report itself is scanned before it is moved to the requested destination.
The report records application marketing/build versions, schema and method identities, declared client/API version boundaries, signed artifact identity availability, evidence references, adapter counts, and each check as passed, failed, or unavailable.
Fixture success never becomes proof of real-account behavior, macOS authorization behavior, signing, screenshot safety, or pilot outcomes.

The command exits nonzero while any automated check fails or the machine-computed adapter-count gate remains failed.

## Engineering Release Blockers

- Fewer than two stable, version-tested subscription-client adapters.
- No stable API-provider quota adapter; issue #27 is explicitly unavailable and cannot count.
- Claude Code OTLP has no production receiver or trustworthy quota-account binding.
- No supported measured completed-run adapter, so workload planning remains unavailable in production.
- Any failed core, native, UI, migration, inventory, scanner, artifact, or Release build check.

## External Release Blockers

- No final signed and notarized application acceptance against each claimed real supported source.
- No signed verification of passive and interactive Claude Keychain authorization behavior.
- No privacy-safe pilot with informed heavy coding-agent participants.
- No public release artifact exists, so release-to-release binary migration validation is unavailable.

Do not weaken a product claim or mark an unavailable check passed to clear a blocker.
