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
if [[ -n "$sentinels" && ! -r "$sentinels" ]]; then
  printf 'error: sentinel file is unavailable\n' >&2
  exit 2
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/limitbar-prohibited-scan.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
strings_file="$temporary_root/strings"
sentinel_patterns="$temporary_root/sentinels"
patterns='(/Users/[^/<[:space:]]+|/home/[^/<[:space:]]+|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._~+/-]{20,})'

if [[ -n "$sentinels" ]]; then
  while IFS= read -r sentinel || [[ -n "$sentinel" ]]; do
    [[ -z "$sentinel" || "$sentinel" == \#* ]] && continue
    printf '%s\n' "$sentinel" >> "$sentinel_patterns"
  done < "$sentinels"
fi

scan_strings() {
  local label="$1"
  if LC_ALL=C /usr/bin/grep -En "$patterns" "$strings_file"; then
    printf 'error: prohibited private-path or credential-shaped content found in %s\n' "$label" >&2
    return 1
  fi
  if [[ -s "$sentinel_patterns" ]] && LC_ALL=C /usr/bin/grep -Fn -f "$sentinel_patterns" "$strings_file"; then
    printf 'error: prohibited sentinel found in %s\n' "$label" >&2
    return 1
  fi
}

scan_file() {
  local file="$1"
  [[ -r "$file" ]] || { printf 'error: unreadable artifact %s\n' "$file" >&2; return 1; }
  if [[ "$file" == *.zip ]]; then
    local members="$temporary_root/members"
    if ! /usr/bin/unzip -Z1 "$file" > "$members" 2>/dev/null; then
      printf 'error: malformed or unreadable ZIP artifact %s\n' "$file" >&2
      return 1
    fi
    while IFS= read -r member || [[ -n "$member" ]]; do
      [[ -z "$member" ]] && continue
      local normalized_member="${member//\\//}"
      if [[ "$normalized_member" == /* || "$normalized_member" == ../* || "$normalized_member" == */../* || "$normalized_member" == */.. ]]; then
        printf 'error: unsafe ZIP member path in %s\n' "$file" >&2
        return 1
      fi
      printf '%s\n' "$member" > "$strings_file"
      scan_strings "$file member name" || return 1
      [[ "$member" == */ ]] && continue
      if ! /usr/bin/unzip -p "$file" "$member" 2>/dev/null | /usr/bin/strings -a > "$strings_file"; then
        printf 'error: unreadable ZIP member in %s\n' "$file" >&2
        return 1
      fi
      scan_strings "$file:$member" || return 1
    done < "$members"
    return 0
  fi

  if ! /usr/bin/strings -a "$file" > "$strings_file"; then
    printf 'error: unreadable artifact %s\n' "$file" >&2
    return 1
  fi
  scan_strings "$file"
}

file_list="$temporary_root/files"
for target in "$@"; do
  [[ -e "$target" ]] || { printf 'error: artifact root does not exist: %s\n' "$target" >&2; exit 1; }
  if [[ -f "$target" ]]; then
    printf '%s\0' "$target" >> "$file_list"
  elif [[ -d "$target" ]]; then
    /usr/bin/find "$target" -type f -print0 >> "$file_list"
  else
    printf 'error: unsupported artifact type: %s\n' "$target" >&2
    exit 1
  fi
done

while IFS= read -r -d '' file; do
  scan_file "$file"
done < "$file_list"

printf 'prohibited-content scan passed\n'
