#!/bin/sh
set -u

limitbar_cli="${LIMITBAR_CLI:-limitbar}"
mode="${LIMITBAR_CAPACITY_MODE:-observation}"

result="$("$limitbar_cli" capacity --product claude-code --operation prompt --mode "$mode")"
status=$?
printf '%s\n' "$result" >&2

if [ "$status" -eq 75 ]; then
  # Claude Code blocking hooks use exit 2. The JSON reason remains on stderr.
  exit 2
fi
if [ "$status" -ne 0 ]; then
  if [ "$mode" = "observation" ]; then
    exit 0
  fi
  exit "$status"
fi
exit 0
