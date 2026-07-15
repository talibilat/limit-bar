#!/bin/bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
classifier="$root/scripts/classify-ui-test-log.sh"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/limitbar-ui-classifier-test.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

check() {
  local expected="$1"
  local status="$2"
  local text="$3"
  local log="$temporary_root/log"
  printf '%s\n' "$text" > "$log"
  [[ "$("$classifier" "$status" "$log")" == "$expected" ]] || { printf 'error: expected %s\n' "$expected" >&2; exit 1; }
}

check passed 0 'all tests passed'
check unavailable 1 'Timed out while enabling automation mode.'
check unavailable 1 $'Timed out while enabling automation mode.\n** TEST FAILED **'
check failed 1 $'Timed out while enabling automation mode.\nTest Case testExample started.\nXCTAssertTrue failed'
check failed 1 $'Timed out while enabling automation mode.\nThe following build commands failed:'
check failed 1 'Test crashed with signal kill.'
check failed 1 'ordinary command failure'

printf 'UI test log classifier self-tests passed\n'
