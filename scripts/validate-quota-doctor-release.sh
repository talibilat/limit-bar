#!/bin/bash
set -uo pipefail

root="$(git rev-parse --show-toplevel)"
report="${1:-$root/quota-doctor-release-validation.md}"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
tmp="${TMPDIR:-/tmp}/limitbar-quota-doctor-validation.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

names=()
statuses=()
details=()

record_check() {
  local name="$1"
  local detail="$2"
  shift 2
  names+=("$name")
  if "$@" >"$tmp/output" 2>&1; then
    statuses+=("passed")
    details+=("$detail")
  else
    statuses+=("failed")
    details+=("$detail; rerun the named repository command for diagnostics")
  fi
}

record_unavailable() {
  names+=("$1")
  statuses+=("unavailable")
  details+=("$2")
}

record_ui_check() {
  local name="$1"
  local detail="$2"
  shift 2
  names+=("$name")
  if "$@" >"$tmp/output" 2>&1; then
    statuses+=("passed")
    details+=("$detail")
  elif /usr/bin/grep -Eq 'Timed out while enabling automation mode|operation never finished bootstrapping' "$tmp/output"; then
    statuses+=("unavailable")
    details+=("Local XCTest automation host could not initialize; no UI assertion result is claimed")
  else
    statuses+=("failed")
    details+=("$detail; rerun the named repository command for diagnostics")
  fi
}

record_check "Fixture privacy scan" "Static credential/private-path patterns were absent from synthetic fixtures" \
  "$root/scripts/scan-prohibited-content.sh" "$root/LimitBarCore/Tests/LimitBarCoreTests/Fixtures"
record_check "Core and persistence tests" "Complete Swift package suite" \
  env DEVELOPER_DIR="$developer_dir" swift test --package-path "$root/LimitBarCore"
record_check "Migration fixture validator" "Synthetic fixture migration evidence only" \
  "$root/scripts/validate-migrations.sh"
record_check "Native tests" "App-owned native unit and presentation suite" \
  env DEVELOPER_DIR="$developer_dir" xcodebuild test -project "$root/LimitBar.xcodeproj" -scheme LimitBar -destination platform=macOS -only-testing:LimitBarTests CODE_SIGNING_ALLOWED=NO
record_ui_check "UI tests" "Synthetic UI modes; not real-source acceptance" \
  env DEVELOPER_DIR="$developer_dir" xcodebuild test -project "$root/LimitBar.xcodeproj" -scheme LimitBar -destination platform=macOS -only-testing:LimitBarUITests
record_check "Unsigned release build" "Compilation only; not signed distribution acceptance" \
  env DEVELOPER_DIR="$developer_dir" xcodebuild build -project "$root/LimitBar.xcodeproj" -scheme LimitBar -configuration Release -destination platform=macOS CODE_SIGNING_ALLOWED=NO
record_unavailable "Signed-app real-source acceptance" "Requires the final notarized artifact, real supported sources, and human verification; fixtures cannot pass it"
record_unavailable "Pilot" "Requires informed heavy coding-agent participants; templates do not constitute participation"
record_unavailable "API quota adapter" "Issue #27 found no qualifying API quota source, so no API adapter may be counted"

commit="$(git rev-parse HEAD)"
source_state="clean"
[[ -n "$(git status --porcelain)" ]] && source_state="commit plus uncommitted worktree changes"
{
  printf '# Quota Doctor Release Validation\n\n'
  printf 'Format version: `quota-doctor-release-validation-v1`  \n'
  printf 'Commit: `%s`  \n' "$commit"
  printf 'Source state: `%s`  \n' "$source_state"
  printf 'Evidence rule: automated fixture checks prove only the named local contract. They do not prove real-account behavior, macOS authorization behavior, signed distribution, or pilot outcomes.\n\n'
  printf '| Check | Status | Evidence boundary |\n'
  printf '| --- | --- | --- |\n'
  for index in "${!names[@]}"; do
    printf '| %s | **%s** | %s |\n' "${names[$index]}" "${statuses[$index]}" "${details[$index]}"
  done
  printf '\n## Adapter Gate\n\n'
  printf '| Component | Declared version | Release status |\n'
  printf '| --- | --- | --- |\n'
  printf '| Codex rollout evidence | `codex-rollout-observed-0.144.4` | Experimental, not stable |\n'
  printf '| Claude Code OTLP evidence | `claude-code-otlp-http-json-2.1.207-v1` | Verification-only, not stable |\n'
  printf '| API-provider quota evidence | None | Unavailable |\n'
  printf '| Quota observation schema | `1` | Planned first public baseline |\n'
  printf '| Forecast method | `pairwise_positive_slope_interquartile_v2` | Fixture validated |\n'
  printf '| Anomaly method | `trailing_median_ratio_v1` | Fixture validated |\n'
  printf '| Codex explanation method | `codex-quota-explanation-v1` | Fixture validated |\n'
  printf '| Claude explanation method | `claude-code-quota-explanation-v2` | Verification seam only |\n'
  printf '| Workload method | `strict_measured_operations_v2` / `interquartile_per_unit_v1` | Production adapter unavailable |\n\n'
  printf 'Stable release-supported subscription adapters: **0**.  \n'
  printf 'Stable release-supported API adapters: **0**.  \n'
  printf 'The required two subscription clients plus one API provider gate is **failed**. See `docs/QUOTA_DOCTOR_ADAPTERS.md`.\n'
} > "$report"

# The declared adapter gate is currently failed, independent of test results.
failed=1
for status in "${statuses[@]}"; do
  [[ "$status" == "failed" ]] && failed=1
done
printf 'wrote %s\n' "$report"
exit "$failed"
