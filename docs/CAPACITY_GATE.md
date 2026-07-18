# Capacity Gate

The Capacity Gate is a local, process-based preflight for Claude Code, Codex, scripts, CI jobs, and queued automation.
It reads a privacy-safe publication written atomically by the running LimitBar application.
It does not open a network port or send the request to LimitBar or a provider.

The gate reports measured quota state.
It does not predict whether a specific prompt, turn, subagent, or job will fit.

## Install

The release application bundles the signed command at `LimitBar.app/Contents/MacOS/limitbar`.
Either invoke that path directly or create a symlink in a directory already on `PATH`:

```sh
ln -s "/Applications/LimitBar.app/Contents/MacOS/limitbar" "$HOME/.local/bin/limitbar"
```

Removing that symlink uninstalls the command without changing the application.
LimitBar must have published current state at least once for measured capacity to be available.
If the application is not running, the command can continue to use the last publication only while each observation remains fresh and its exact reset boundary remains active.

Source checkouts can run the command with:

```sh
swift run --package-path LimitBarCore limitbar capacity \
  --product codex \
  --operation queued-run
```

## Use

```sh
limitbar capacity \
  --product claude-code \
  --operation prompt \
  --mode observation
```

Supported products are `claude-code` and `codex`.
Supported operation classes are `prompt`, `subagent`, `queued-run`, and `ci-job`.
Operation classes identify caller intent only and do not change or predict provider quota weighting.

The default mode is `observation`.
Observation mode always exits 0 for an evaluated `allow`, `warn`, or `pause`, including missing or unsafe evidence, so it cannot block work.
Invalid command syntax, unsupported products, and unsupported operations exit 64 because no valid evaluation was requested.
The supplied integration wrappers also continue in observation mode if the command is missing or fails before producing an evaluation.

Fail-closed mode must be selected explicitly:

```sh
limitbar capacity \
  --product codex \
  --operation ci-job \
  --mode fail-closed
```

Fail-closed mode exits 75 for `pause` and 0 for `allow` or `warn`.
Missing, stale, malformed, incompatible, boundary-less, or timed-out evidence becomes `pause` in fail-closed mode.
LimitBar never mutates or removes queued work.

`--timeout` accepts a positive duration up to 5 seconds and defaults to 1 second.
The command performs one timeout-bounded read of at most 64 KiB from a non-symbolic regular file and never waits for the app or retries.
`--state-file` overrides the publication path for fixtures and isolated validation; paths are never included in output.
`LIMITBAR_CAPACITY_STATE_FILE` provides the same override for integration harnesses and hook examples.

## JSON Contract

The response is one JSON object followed by a newline.
Keys and enum values are stable for schema version 1.

```json
{
  "decision": "warn",
  "evidence": {
    "incident_active": false,
    "observation_age_seconds": 42,
    "percentage_used": 83.5,
    "reset_boundary": "2030-03-17T12:00:00Z"
  },
  "mode": "observation",
  "operation_class": "queued-run",
  "product": "codex",
  "reasons": [
    "measured_capacity_warning"
  ],
  "schema_version": 1
}
```

Every response has exactly one decision: `allow`, `warn`, or `pause`.
Every response has at least one typed reason.
Stable reasons are:

- `measured_capacity_healthy`
- `measured_capacity_warning`
- `measured_capacity_exhausted`
- `provider_incident_active`
- `stale_evidence`
- `unavailable_evidence`
- `malformed_evidence`
- `incompatible_evidence`
- `boundary_unavailable`
- `unsupported_product`
- `unsupported_operation`
- `timed_out`

Version 1 uses measured percentage thresholds of 80 percent for `warn` and 90 percent for `pause`.
An active separately supplied official provider incident raises an otherwise healthy result to `warn`, but does not claim that the incident caused local behavior.

The application publication is schema version 2 and uses a positive allow-list.
Each publication observation includes `window_kind` with `session`, `weekly`, or `other` so consumers can preserve quota-window semantics without exposing provider labels.
Unknown fields and unsupported versions are incompatible rather than optimistically ignored.
Readers must reject response schema versions they do not implement.
Future compatible additions require a new documented schema version because each version uses an exact positive allow-list.

Capacity output and publications contain only product, privacy-safe quota window kind, normalized percentage used, observation time and age, freshness expiry, exact reset boundary, incident overlap, decision, and typed reasons.
They exclude credentials, account identifiers, prompts, code, responses, commands, tool arguments, file paths, project names, cookies, raw sessions, and raw provider responses.

## Claude Code Example

`examples/capacity/claude-user-prompt-submit.sh` is a `UserPromptSubmit` command hook.
`examples/capacity/claude-settings.json.example` shows its explicit settings entry.
Replace the placeholder with an absolute script path and add the entry to personal or project settings yourself.
LimitBar never edits Claude Code settings, including managed enterprise settings.

The example defaults to observation mode.
Set `LIMITBAR_CAPACITY_MODE=fail-closed` only for workflows where blocking is intended.
The wrapper maps capacity exit 75 to Claude Code's blocking-hook exit 2 and leaves the typed JSON on stderr.
Remove the hook entry to reverse installation.

Claude Code controls which lifecycle points are hookable.
The example covers prompt submission and cannot guarantee interception of every internal provider action or managed configuration.

## Codex Example

`examples/capacity/codex-pre-run.sh` checks Codex capacity and then invokes `codex exec`.
Put the script at an explicit path and call it instead of `codex exec` for selected non-interactive runs.
Stop using or delete the wrapper to reverse installation.

The wrapper defaults to observation mode.
Set `LIMITBAR_CAPACITY_MODE=fail-closed` to prevent a new run when the decision is `pause`.
Codex does not provide a universal pre-run hook for every action, so this wrapper covers only work launched through it.

## Limitations

- Capacity is a current Usage Snapshot, not a reservation or guarantee.
- A low measured percentage does not establish that the next operation will fit.
- Claude Code evidence is fresh for at most 15 minutes, matching alert qualification.
- Codex local session evidence is fresh for at most 6 hours, matching alert qualification.
- Exact reset boundaries must be present and in the future.
- Business or organization Codex plans without personal percentage windows produce unavailable evidence.
- Public incident evidence is optional and must be separately qualified before publication.
- The gate does not rotate accounts, switch providers, buy credits, alter concurrency, execute queued intent, or evade provider controls.
