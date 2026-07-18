#!/bin/sh
set -u

limitbar_cli="${LIMITBAR_CLI:-limitbar}"
mode="${LIMITBAR_CAPACITY_MODE:-observation}"

result="$("$limitbar_cli" capacity --product codex --operation queued-run --mode "$mode")"
status=$?
printf '%s\n' "$result" >&2
if [ "$status" -ne 0 ]; then
  if [ "$mode" = "observation" ]; then
    exec codex exec "$@"
  fi
  exit "$status"
fi

exec codex exec "$@"
