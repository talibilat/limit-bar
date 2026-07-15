#!/bin/bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
scanner="$root/scripts/scan-prohibited-content.sh"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/limitbar-prohibited-scan-test.XXXXXX")"
trap 'chmod -R u+rwX "$temporary_root" 2>/dev/null || true; rm -rf "$temporary_root"' EXIT
sentinels="$temporary_root/sentinels.txt"
printf 'CUSTOM_PRIVATE_SENTINEL_34\n' > "$sentinels"

expect_failure() {
  if "$scanner" --sentinels "$sentinels" "$1" >/dev/null 2>&1; then
    printf 'error: scanner unexpectedly accepted %s\n' "$1" >&2
    exit 1
  fi
}

clean="$temporary_root/clean"
mkdir "$clean"
printf 'normalized fixture with no private content\n' > "$clean/report.txt"
printf '\0normalized binary artifact\0' > "$clean/report.bin"
/usr/bin/sqlite3 "$clean/report.sqlite" "CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('normalized');"
mkdir "$clean/Test.xcresult"
printf 'normalized xcresult metadata\n' > "$clean/Test.xcresult/Info.plist"
(cd "$clean" && /usr/bin/zip -q clean.zip report.bin)
"$scanner" --sentinels "$sentinels" "$clean" >/dev/null

printf '\0binary /Users/private-user/project and AKIA1234567890123456 CUSTOM_PRIVATE_SENTINEL_34\0' > "$temporary_root/private.bin"
expect_failure "$temporary_root/private.bin"

/usr/bin/sqlite3 "$temporary_root/private.sqlite" "CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('CUSTOM_PRIVATE_SENTINEL_34');"
expect_failure "$temporary_root/private.sqlite"

zip_root="$temporary_root/zip-root"
mkdir "$zip_root"
printf 'CUSTOM_PRIVATE_SENTINEL_34\n' > "$zip_root/member.bin"
(cd "$zip_root" && /usr/bin/zip -q "$temporary_root/private.zip" member.bin)
expect_failure "$temporary_root/private.zip"

ruby -rzlib -e '
  name = "../escape.bin"; data = "clean"; crc = Zlib.crc32(data)
  local = [0x04034b50, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv") + name + data
  central = [0x02014b50, 20, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize, name.bytesize, 0, 0, 0, 0, 0, 0].pack("VvvvvvvVVVvvvvvVV") + name
  ending = [0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize, 0].pack("VvvvvVVv")
  File.binwrite(ARGV[0], local + central + ending)
' "$temporary_root/traversal.zip"
expect_failure "$temporary_root/traversal.zip"

printf 'not a zip\n' > "$temporary_root/malformed.zip"
expect_failure "$temporary_root/malformed.zip"

cp "$temporary_root/private.zip" "$temporary_root/unreadable.zip"
chmod 000 "$temporary_root/unreadable.zip"
expect_failure "$temporary_root/unreadable.zip"

printf 'clean but unreadable\n' > "$temporary_root/unreadable.bin"
chmod 000 "$temporary_root/unreadable.bin"
expect_failure "$temporary_root/unreadable.bin"

printf 'prohibited-content scanner self-tests passed\n'
