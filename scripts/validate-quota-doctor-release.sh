#!/bin/bash
set -uo pipefail

root="$(git rev-parse --show-toplevel)"
report="$root/quota-doctor-release-validation.md"
sentinels=""
artifact_roots=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)
      [[ $# -ge 2 ]] || { printf 'error: --report requires a path\n' >&2; exit 2; }
      report="$2"
      shift 2
      ;;
    --sentinels)
      [[ $# -ge 2 ]] || { printf 'error: --sentinels requires a path\n' >&2; exit 2; }
      sentinels="$2"
      shift 2
      ;;
    --artifacts)
      [[ $# -ge 2 ]] || { printf 'error: --artifacts requires a path\n' >&2; exit 2; }
      artifact_roots+=("$2")
      shift 2
      ;;
    *)
      printf 'error: unknown argument %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/limitbar-quota-doctor-validation.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

names=()
statuses=()
details=()
references=()

record_check() {
  local name="$1"
  local detail="$2"
  local reference="$3"
  shift 3
  names+=("$name")
  references+=("$reference")
  if "$@" >"$temporary_root/output" 2>&1; then
    statuses+=("passed")
    details+=("$detail")
  else
    statuses+=("failed")
    details+=("$detail; rerun the evidence reference for diagnostics")
  fi
}

record_unavailable() {
  names+=("$1")
  statuses+=("unavailable")
  details+=("$2")
  references+=("$3")
}

record_ui_check() {
  local name="$1"
  local detail="$2"
  local reference="$3"
  shift 3
  names+=("$name")
  references+=("$reference")
  if "$@" >"$temporary_root/output" 2>&1; then
    statuses+=("passed")
    details+=("$detail")
  elif /usr/bin/grep -Eq 'Timed out while enabling automation mode|operation never finished bootstrapping' "$temporary_root/output"; then
    statuses+=("unavailable")
    details+=("Local XCTest automation host could not initialize; no UI assertion result is claimed")
  else
    statuses+=("failed")
    details+=("$detail; rerun the evidence reference for diagnostics")
  fi
}

inventory="$root/config/quota-doctor-adapters.json"
inventory_summary="$temporary_root/inventory-summary"
inventory_table="$temporary_root/inventory-table"
record_check "Adapter inventory" "Required declarations, suite references, code identities, and gate counts" \
  "config/quota-doctor-adapters.json; scripts/validate-quota-doctor-inventory.rb" \
  "$root/scripts/validate-quota-doctor-inventory.rb" "$inventory" "$inventory_summary" "$inventory_table"
if [[ -r "$inventory_summary" ]]; then
  # The inventory validator emits only bounded alphanumeric version assignments.
  source "$inventory_summary"
else
  APP_MARKETING_VERSION="unavailable"
  APP_BUILD_VERSION="unavailable"
  QUOTA_SCHEMA_VERSION="unavailable"
  CLAUDE_SCHEMA_VERSION="unavailable"
  FORECAST_METHOD="unavailable"
  ANOMALY_METHOD="unavailable"
  CODEX_EXPLANATION_METHOD="unavailable"
  CLAUDE_EXPLANATION_METHOD="unavailable"
  WORKLOAD_COMPARABILITY_METHOD="unavailable"
  WORKLOAD_RANGE_METHOD="unavailable"
  STABLE_SUBSCRIPTION_COUNT=0
  STABLE_API_COUNT=0
  printf '| Inventory | unavailable | failed | unavailable | unavailable | unavailable |\n' > "$inventory_table"
fi
record_check "Inventory drift self-tests" "Missing declarations and code-version drift are rejected" \
  "scripts/test-quota-doctor-inventory.sh" "$root/scripts/test-quota-doctor-inventory.sh"
record_check "Scanner self-tests" "Text, binary, SQLite, ZIP, malformed archive, unreadable artifact, sentinel, and clean cases" \
  "scripts/test-prohibited-content-scan.sh" "$root/scripts/test-prohibited-content-scan.sh"
record_check "Fixture privacy scan" "All bytes and extracted strings from synthetic fixture artifacts" \
  "scripts/scan-prohibited-content.sh LimitBarCore/Tests/LimitBarCoreTests/Fixtures" \
  "$root/scripts/scan-prohibited-content.sh" "$root/LimitBarCore/Tests/LimitBarCoreTests/Fixtures"

if [[ ${#artifact_roots[@]} -gt 0 ]]; then
  scanner=("$root/scripts/scan-prohibited-content.sh")
  [[ -n "$sentinels" ]] && scanner+=(--sentinels "$sentinels")
  scanner+=("${artifact_roots[@]}")
  record_check "Caller-provided artifact scan" "Explicit export, acceptance, pilot, screenshot, or xcresult roots" \
    "caller-provided --artifacts roots" "${scanner[@]}"
else
  record_unavailable "Caller-provided artifact scan" "No artifact roots were supplied; private source logs are never scanned automatically" "Use --artifacts PATH and optional --sentinels FILE"
fi

record_check "Core and persistence tests" "Complete Swift package suite" \
  "DEVELOPER_DIR=$developer_dir swift test --package-path LimitBarCore" \
  env DEVELOPER_DIR="$developer_dir" swift test --package-path "$root/LimitBarCore"
record_check "Migration fixture validator" "Synthetic fixture migration evidence only" \
  "scripts/validate-migrations.sh" "$root/scripts/validate-migrations.sh"
record_check "Native tests" "App-owned native unit and presentation suite" \
  "xcodebuild test -only-testing:LimitBarTests" \
  env DEVELOPER_DIR="$developer_dir" xcodebuild test -project "$root/LimitBar.xcodeproj" -scheme LimitBar -destination platform=macOS -only-testing:LimitBarTests CODE_SIGNING_ALLOWED=NO
record_ui_check "UI tests" "Synthetic UI modes; not real-source acceptance" \
  "xcodebuild test -only-testing:LimitBarUITests" \
  env DEVELOPER_DIR="$developer_dir" xcodebuild test -project "$root/LimitBar.xcodeproj" -scheme LimitBar -destination platform=macOS -only-testing:LimitBarUITests
record_check "Unsigned release build" "Compilation only; not signed distribution acceptance" \
  "xcodebuild build -configuration Release CODE_SIGNING_ALLOWED=NO" \
  env DEVELOPER_DIR="$developer_dir" xcodebuild build -project "$root/LimitBar.xcodeproj" -scheme LimitBar -configuration Release -destination platform=macOS CODE_SIGNING_ALLOWED=NO
record_unavailable "Signed artifact identity" "No final signed/notarized artifact was supplied; identity, notarization, and real-source behavior are unresolved" "docs/templates/QUOTA_DOCTOR_SIGNED_ACCEPTANCE.md"
record_unavailable "Pilot" "Requires informed heavy coding-agent participants; templates do not constitute participation" "docs/templates/QUOTA_DOCTOR_PILOT.md"

commit="$(git rev-parse HEAD)"
source_state="clean"
[[ -n "$(git status --porcelain)" ]] && source_state="commit plus uncommitted worktree changes"
candidate="$temporary_root/release-validation.md"
{
  printf '# Quota Doctor Release Validation\n\n'
  printf 'Format version: `quota-doctor-release-validation-v2`  \n'
  printf 'Commit: `%s`  \n' "$commit"
  printf 'Source state: `%s`  \n' "$source_state"
  printf 'Application version: `%s` (`%s`)  \n' "$APP_MARKETING_VERSION" "$APP_BUILD_VERSION"
  printf 'Signed artifact identity: **unavailable**  \n'
  printf 'Evidence rule: automated fixture checks prove only the named local contract. They do not prove real-account behavior, macOS authorization behavior, signed distribution, screenshot pixels, or pilot outcomes.\n\n'
  printf '| Check | Status | Evidence boundary | Evidence reference |\n'
  printf '| --- | --- | --- | --- |\n'
  for index in "${!names[@]}"; do
    printf '| %s | **%s** | %s | `%s` |\n' "${names[$index]}" "${statuses[$index]}" "${details[$index]}" "${references[$index]}"
  done
  printf '| Generated validation report scan | **passed** | Exact candidate report bytes | `scripts/scan-prohibited-content.sh <candidate>` |\n'
  printf '\n## Declared Versions\n\n'
  printf '| Component | Identity |\n'
  printf '| --- | --- |\n'
  printf '| Quota observation schema | `%s` |\n' "$QUOTA_SCHEMA_VERSION"
  printf '| Claude explanation schema | `%s` |\n' "$CLAUDE_SCHEMA_VERSION"
  printf '| Forecast method | `%s` |\n' "$FORECAST_METHOD"
  printf '| Anomaly method | `%s` |\n' "$ANOMALY_METHOD"
  printf '| Codex explanation method | `%s` |\n' "$CODEX_EXPLANATION_METHOD"
  printf '| Claude explanation method | `%s` |\n' "$CLAUDE_EXPLANATION_METHOD"
  printf '| Workload methods | `%s`; `%s` |\n\n' "$WORKLOAD_COMPARABILITY_METHOD" "$WORKLOAD_RANGE_METHOD"
  cat "$inventory_table"
  printf '\nStable release-supported subscription adapters: **%s**.  \n' "$STABLE_SUBSCRIPTION_COUNT"
  printf 'Stable release-supported API adapters: **%s**.  \n' "$STABLE_API_COUNT"
  if [[ "$STABLE_SUBSCRIPTION_COUNT" -ge 2 && "$STABLE_API_COUNT" -ge 1 ]]; then
    printf 'The required adapter-count gate is **passed**.\n'
  else
    printf 'The required two subscription clients plus one API provider gate is **failed**.\n'
  fi
} > "$candidate"

report_scanner=("$root/scripts/scan-prohibited-content.sh")
[[ -n "$sentinels" ]] && report_scanner+=(--sentinels "$sentinels")
report_scanner+=("$candidate")
if ! "${report_scanner[@]}" >"$temporary_root/report-scan-output" 2>&1; then
  printf 'error: generated validation report failed prohibited-content scanning\n' >&2
  exit 1
fi
mkdir -p "$(dirname "$report")"
mv "$candidate" "$report"

failed=0
for status in "${statuses[@]}"; do
  [[ "$status" == "failed" ]] && failed=1
done
if [[ "$STABLE_SUBSCRIPTION_COUNT" -lt 2 || "$STABLE_API_COUNT" -lt 1 ]]; then
  failed=1
fi
printf 'wrote %s\n' "$report"
exit "$failed"
