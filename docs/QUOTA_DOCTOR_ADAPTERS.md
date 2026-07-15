# Quota Doctor Adapter Inventory

The canonical machine-readable inventory is [`config/quota-doctor-adapters.json`](../config/quota-doctor-adapters.json).
It declares every candidate's provider product, category, release support, stability, supported versions, captured and omitted fields, authentication access, user-visible operating-system interaction, confidence, last verified date, configured read boundary, limitations, and fixture and failure-suite references.

Run:

```sh
scripts/validate-quota-doctor-inventory.rb config/quota-doctor-adapters.json /tmp/summary /tmp/table
scripts/test-quota-doctor-inventory.sh
```

Validation rejects missing declarations, missing suite references, duplicate identities, invalid stability values, stale application/method/schema identities, and malformed dates.
The release validator consumes the computed stable subscription and API counts instead of carrying a second hardcoded gate.

## Codex Boundary

The configured boundary is the canonical Codex sessions root.
The current reader recursively considers every recent canonical regular `.jsonl` file under that root, subject to traversal, file-size, total-byte, and age bounds.
It rejects symlinks and canonical paths outside the root.
It does not semantically classify a subdirectory named `archive`, `archived_sessions`, or another name inside the configured root, so such an in-root file is part of the configured boundary.
Codex's normal `$CODEX_HOME/archived_sessions` sibling is excluded only because it is outside a sessions-root configuration.
Compressed `.jsonl.zst` files are recognized as unsupported coverage rather than consumed.

## Release Count

The validated inventory currently computes zero stable release-supported subscription adapters and zero stable release-supported API adapters.
The observed Codex path is experimental, the Claude Code OTLP path is verification-only, and the Claude OAuth response has no declared stable schema or captured client version.
Issue #27 remains unavailable and contributes zero API adapters.
Quota Doctor therefore does not meet the required two stable subscription clients plus one stable API provider.

Synthetic contract tests establish only the declared fixture behavior.
They do not establish signed real-account behavior, macOS authorization policy, or provider compatibility beyond the declared version boundary.
