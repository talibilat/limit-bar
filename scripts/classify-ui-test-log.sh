#!/bin/bash
set -euo pipefail

[[ $# -eq 2 ]] || { printf 'usage: %s EXIT_STATUS LOG_FILE\n' "$0" >&2; exit 2; }
status="$1"
log="$2"
[[ "$status" =~ ^[0-9]+$ && -r "$log" ]] || exit 2
if [[ "$status" -eq 0 ]]; then
  printf 'passed\n'
  exit 0
fi

bootstrap='Timed out while enabling automation mode|operation never finished bootstrapping'
failure='XCTAssert|Assertion failed|Test Case .* started|Test Case .* failed|Executed .* with [1-9][0-9]* failures?|crash|crashed|signal [A-Za-z0-9]+|Early unexpected exit|The following build commands failed|(^|[[:space:]])error:'
if /usr/bin/grep -Eq "$bootstrap" "$log" && ! /usr/bin/grep -Eiq "$failure" "$log"; then
  printf 'unavailable\n'
else
  printf 'failed\n'
fi
