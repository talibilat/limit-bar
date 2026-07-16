#!/bin/bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/limitbar-inventory-test.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
validator="$root/scripts/validate-quota-doctor-inventory.rb"
inventory="$root/config/quota-doctor-adapters.json"

"$validator" "$inventory" "$temporary_root/summary" "$temporary_root/table" >/dev/null
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["declarations"][0].delete("omittedFields"); File.write(ARGV[1], JSON.pretty_generate(value))' "$inventory" "$temporary_root/missing.json"
if "$validator" "$temporary_root/missing.json" "$temporary_root/bad-summary" "$temporary_root/bad-table" >/dev/null 2>&1; then
  printf 'error: inventory validator accepted a missing declaration field\n' >&2
  exit 1
fi
ruby -rjson -e 'value = JSON.parse(File.read(ARGV[0])); value["methods"]["forecast"] = "drifted"; File.write(ARGV[1], JSON.pretty_generate(value))' "$inventory" "$temporary_root/drift.json"
if "$validator" "$temporary_root/drift.json" "$temporary_root/bad-summary" "$temporary_root/bad-table" >/dev/null 2>&1; then
  printf 'error: inventory validator accepted code drift\n' >&2
  exit 1
fi

printf 'quota-doctor inventory self-tests passed\n'
