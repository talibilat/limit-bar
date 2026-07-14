# Local Refresh Performance

Ticket 04 evaluates whether the complete production Local Refresh Cycle can safely run every five seconds on supported Macs.
The authoritative result is Publication Latency for a complete coordinator cycle using the production importers, SQLite store, and Codex scanner.
Component scenarios are diagnostic evidence rather than proof that the cadence is safe.

## Privacy Boundary

The profiler creates synthetic fixtures under a temporary directory and removes them after a normal run.
Initialization failures also perform best-effort cleanup.
Forced termination can leave temporary files for the operating system to clean up.
It never reads configured LimitBar, Codex, or custom-source paths.
JSON output contains aggregate configuration, environment, status, and timing fields only.
It never contains fixture contents, source names, paths, credentials, prompts, responses, or raw provider data.

The `ProfiledOperation`, `SustainedLocalRefresh`, and production `LocalRefreshCycle` signposts contain no dynamic fields.
Instruments traces remain local and temporary unless a reviewer confirms that they contain no identifying path or content.

## Scenarios

`cycle-fingerprint-stable` measures a complete Local Refresh Cycle after warmup with fingerprint-stable built-in and custom sources.
`cycle-event-append` appends complete valid events before each measured complete cycle.
`built-in-fingerprint-stable` and `built-in-event-append` isolate the built-in import and Current Usage Snapshot Load.
`custom-fingerprint-stable` and `custom-event-append` isolate configured custom-source refreshes.
`sqlite-current-metrics-read` isolates the exact-window SQLite read.
`codex-session-scan` isolates recursive local Codex scanning.

Each invocation runs one scenario so `/usr/bin/time -l` resource totals are attributable to that process.
Versioned JSON records CPU time, maximum resident size, block operations, and context-switch deltas around measured operations.
Maximum resident size is a process high-water mark and can include fixture setup.
The supplementary `/usr/bin/time -l` totals include synthetic fixture setup and teardown.
Use `ProfiledOperation` for unpaced diagnostics and the production `LocalRefreshCycle` signpost for per-cycle Instruments attribution during sustained runs.

## Commands

Build and run a quick end-to-end sample:

```sh
LIMITBAR_PROFILE_POWER_STATE=ac scripts/profile-refresh.sh \
  --scenario cycle-fingerprint-stable \
  --iterations 50 \
  --warmups 5 \
  --fixture-bytes 10485760 \
  --custom-sources 5 \
  --codex-files 2000 \
  --cadence-seconds 0
```

Run a sustained five-second profile:

```sh
LIMITBAR_PROFILE_POWER_STATE=battery scripts/profile-refresh.sh \
  --scenario cycle-fingerprint-stable \
  --iterations 360 \
  --warmups 5 \
  --fixture-bytes 10485760 \
  --custom-sources 5 \
  --codex-files 2000 \
  --cadence-seconds 5
```

`--fixture-bytes` controls each built-in and custom JSONL initial target size.
Event-append scenarios grow that initial fixture by one complete valid event per measured iteration.
Configurations that could exceed the 100 MiB source bound are rejected.
Codex fixture files contain one valid synthetic report so entry count can be varied independently from per-file size.
The profiler limits one JSONL source to 100 MiB, custom sources to 100, Codex files to 10,000, and generated built-in plus custom JSONL data to 1 GiB.

Set `LIMITBAR_PROFILE_POWER_STATE` to `ac`, `battery`, `battery-low-power-mode`, or `unknown`.
The value is recorded metadata supplied by the operator, not an independently verified hardware reading.

## Measurement Matrix

Run warm fingerprint-stable and event-append cycles with 100 KiB, 10 MiB, 50 MiB, and 100 MiB source sizes where the aggregate fixture limit permits them.
Run custom-source counts of 0, 1, 5, and 20.
Run Codex entry counts of 0, 100, 2,000, and 10,000.
Treat maximum-size and maximum-count combinations as bounded stress cases rather than representative workloads.

Use at least five warmups, fifty measured iterations, three independent process launches, and three sustained runs for each accepted device and power state.
Measure the oldest supported Apple Silicon class and a current mainstream Apple Silicon class.
Measure Intel only while the distributed application supports that architecture.
Measure the oldest supported macOS release and the current release.

Record the application revision, worktree state, hardware class, RAM, macOS version, Xcode and Swift versions, power state, thermal state, scenario configuration, and aggregate output.
Do not silently discard outliers.
Invalidate a run only when external interference is recorded.

## Instruments

Use Time Profiler for CPU, File Activity for I/O, Allocations for memory investigation, System Trace for scheduling and wakeups, and Energy Log for power.
Compare a Release app with periodic local refresh enabled against the same app with the scheduler disabled when establishing the cadence's power delta.
Keep the popover and Settings closed for the primary background profile.
Run a separate secondary profile with the popover open.

The five-second loop must not issue provider HTTP requests or poll Keychain during profiling.
Any such operation invalidates the run.
Positive `--cadence-seconds` values are accepted only for complete-cycle scenarios and run through the coordinator's production periodic scheduler and coalescing behavior.
Paced runs are restricted to `cycle-fingerprint-stable` because an in-process synthetic producer would contaminate resource totals and can race coalesced refreshes.
Event-append scenarios measure complete refresh operations back-to-back with active-operation resource sampling beginning after each producer write.
CPU time, block-operation, and context-switch deltas exclude producer writes.
Maximum resident size remains a process high-water mark and can include fixture setup and producer writes.

## Provisional Guardrails

These guardrails direct the first measurement round and are not accepted hardware budgets.

- Warm fingerprint-stable p95 Publication Latency should not exceed 500 milliseconds.
- Representative event-append p95 Publication Latency should not exceed 2.5 seconds.
- Representative maximum Publication Latency should remain below five seconds.
- Representative sustained runs should have no Cadence Overruns and no monotonic memory growth.
- Fingerprint-stable built-in and custom sources should not reread JSONL contents or replace stored metrics.
- The five-second cadence should remain in the lowest practical Energy Impact category on the oldest supported device.

Final CPU, memory, I/O, wakeup, and power budgets require representative measurements.
Do not infer power from wall-clock latency.
Do not turn one CI runner's measurements into product budgets.

## Completion Evidence

Ticket 04 is complete only when reviewed results record numeric latency, CPU, memory, I/O, and wakeup budgets plus a reproducible power acceptance criterion.
Results must include unchanged, event-append, and bounded-stress evidence for the agreed device matrix.
Accepted results belong in a reviewed aggregate document under `docs/` and must identify the applicable revision and scenario version.
Raw Instruments traces do not belong in the repository.

Refresh coordination, cache fingerprints, importer bounds, custom-source concurrency, SQLite schema or queries, Codex traversal, supported platforms, and compiler changes can invalidate prior results.
Reprofile after those changes before altering the cadence.
