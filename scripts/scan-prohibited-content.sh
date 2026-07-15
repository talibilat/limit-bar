#!/bin/bash
set -euo pipefail

usage() {
  printf 'usage: %s [--sentinels FILE] PATH...\n' "$0" >&2
  exit 2
}

sentinels=""
if [[ "${1:-}" == "--sentinels" ]]; then
  [[ $# -ge 3 ]] || usage
  sentinels="$2"
  shift 2
fi
[[ $# -gt 0 ]] || usage

patterns='(/Users/[^/<[:space:]]+|/home/[^/<[:space:]]+|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._~+/-]{20,})'
set +e
matches="$(LC_ALL=C /usr/bin/grep -ERnI --exclude='*.sqlite' --exclude='*.zip' --exclude-dir='*.xcresult' -- "$patterns" "$@" 2>&1)"
status=$?
set -e
if [[ $status -eq 0 ]]; then
  printf '%s\n' "$matches"
  printf 'error: prohibited private-path or credential-shaped content found\n' >&2
  exit 1
elif [[ $status -gt 1 ]]; then
  printf 'error: prohibited-content scan could not inspect every target\n%s\n' "$matches" >&2
  exit 1
fi

if [[ -n "$sentinels" ]]; then
  [[ -f "$sentinels" ]] || usage
  while IFS= read -r sentinel || [[ -n "$sentinel" ]]; do
    [[ -z "$sentinel" || "$sentinel" == \#* ]] && continue
    set +e
    matches="$(LC_ALL=C /usr/bin/grep -FRnI --exclude='*.sqlite' --exclude='*.zip' --exclude-dir='*.xcresult' -- "$sentinel" "$@" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      printf '%s\n' "$matches"
      printf 'error: prohibited sentinel found\n' >&2
      exit 1
    elif [[ $status -gt 1 ]]; then
      printf 'error: prohibited-content scan could not inspect every target\n%s\n' "$matches" >&2
      exit 1
    fi
  done < "$sentinels"
fi

printf 'prohibited-content scan passed\n'
