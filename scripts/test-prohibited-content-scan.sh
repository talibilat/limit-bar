#!/bin/bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
scanner="$root/scripts/scan-prohibited-content.sh"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/limitbar-prohibited-scan-test.XXXXXX")"
trap 'chmod -R u+rwX "$temporary_root" 2>/dev/null || true; rm -rf "$temporary_root"' EXIT
export LIMITBAR_SCAN_MAX_FILE_BYTES=1048576
export LIMITBAR_SCAN_MAX_ZIP_COMPRESSED_BYTES=524288
export LIMITBAR_SCAN_MAX_ZIP_MEMBERS=4
export LIMITBAR_SCAN_MAX_MEMBER_BYTES=65536
export LIMITBAR_SCAN_MAX_TOTAL_MEMBER_BYTES=131072
export LIMITBAR_SCAN_MAX_COMPRESSION_RATIO=20
sentinels="$temporary_root/sentinels.txt"
printf 'CUSTOM_PRIVATE_SENTINEL_34\nPRIVATE_UNICODE_SENTINEL_秘密\n' > "$sentinels"

expect_failure() {
  if "$scanner" --sentinels "$sentinels" "$1" >/dev/null 2>&1; then
    printf 'error: scanner unexpectedly accepted %s\n' "$1" >&2
    exit 1
  fi
}

expect_failure_with_limit() {
  local assignment="$1"
  local path="$2"
  if env "$assignment" "$scanner" --sentinels "$sentinels" "$path" >/dev/null 2>&1; then
    printf 'error: scanner unexpectedly accepted bounded case %s\n' "$path" >&2
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

ln -s "$clean" "$temporary_root/root-link"
expect_failure "$temporary_root/root-link"
mkdir "$temporary_root/nested-file-link"
ln -s "$clean/report.txt" "$temporary_root/nested-file-link/report-link"
expect_failure "$temporary_root/nested-file-link"
mkdir "$temporary_root/nested-dir-link"
ln -s "$clean/Test.xcresult" "$temporary_root/nested-dir-link/result-link"
expect_failure "$temporary_root/nested-dir-link"
mkdir "$temporary_root/fifo-root"
mkfifo "$temporary_root/fifo-root/pipe"
expect_failure "$temporary_root/fifo-root"

printf '\0binary /Users/private-user/project and AKIA1234567890123456 CUSTOM_PRIVATE_SENTINEL_34\0' > "$temporary_root/private.bin"
expect_failure "$temporary_root/private.bin"
printf 'normalized prefix PRIVATE_UNICODE_SENTINEL_秘密 normalized suffix\n' > "$temporary_root/unicode-sentinel.bin"
expect_failure "$temporary_root/unicode-sentinel.bin"

ruby -e 'File.binwrite(ARGV[0], "/Users/utf16-user/project".encode("UTF-16LE")); File.binwrite(ARGV[1], "Bearer ABCDEFGHIJKLMNOPQRSTUVWXYZ".encode("UTF-16BE")); File.binwrite(ARGV[2], "CUSTOM_PRIVATE_SENTINEL_34".encode("UTF-16LE"))' "$temporary_root/utf16-path.bin" "$temporary_root/utf16-credential.bin" "$temporary_root/utf16-sentinel.bin"
expect_failure "$temporary_root/utf16-path.bin"
expect_failure "$temporary_root/utf16-credential.bin"
expect_failure "$temporary_root/utf16-sentinel.bin"

/usr/bin/sqlite3 "$temporary_root/private.sqlite" "CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('CUSTOM_PRIVATE_SENTINEL_34');"
expect_failure "$temporary_root/private.sqlite"

zip_root="$temporary_root/zip-root"
mkdir "$zip_root"
printf 'CUSTOM_PRIVATE_SENTINEL_34\n' > "$zip_root/member.bin"
(cd "$zip_root" && /usr/bin/zip -q "$temporary_root/private.zip" member.bin)
expect_failure "$temporary_root/private.zip"

utf16_zip="$temporary_root/utf16.zip"
(cd "$temporary_root" && /usr/bin/zip -q "$utf16_zip" utf16-path.bin utf16-credential.bin utf16-sentinel.bin)
expect_failure "$utf16_zip"

ruby -rzlib -e '
  name = "../escape.bin"; data = "clean"; crc = Zlib.crc32(data)
  local = [0x04034b50, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv") + name + data
  central = [0x02014b50, 20, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize, name.bytesize, 0, 0, 0, 0, 0, 0].pack("VvvvvvvVVVvvvvvVV") + name
  ending = [0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize, 0].pack("VvvvvVVv")
  File.binwrite(ARGV[0], local + central + ending)
' "$temporary_root/traversal.zip"
expect_failure "$temporary_root/traversal.zip"

member_root="$temporary_root/members"
mkdir "$member_root"
for index in 1 2 3 4 5; do printf 'clean %s\n' "$index" > "$member_root/$index.txt"; done
(cd "$member_root" && /usr/bin/zip -q "$temporary_root/too-many.zip" ./*.txt)
expect_failure "$temporary_root/too-many.zip"

for index in 1 2 3; do ruby -e 'File.binwrite(ARGV[0], Random.new(34).bytes(50_000))' "$member_root/total-$index.bin"; done
(cd "$member_root" && /usr/bin/zip -0 -q "$temporary_root/too-much-total.zip" total-1.bin total-2.bin total-3.bin)
expect_failure "$temporary_root/too-much-total.zip"

ruby -e 'File.binwrite(ARGV[0], "x" * 70_000)' "$member_root/oversized.bin"
(cd "$member_root" && /usr/bin/zip -0 -q "$temporary_root/oversized.zip" oversized.bin)
expect_failure "$temporary_root/oversized.zip"

ruby -e 'File.binwrite(ARGV[0], "A" * 40_000)' "$member_root/high-ratio.bin"
(cd "$member_root" && /usr/bin/zip -9 -q "$temporary_root/high-ratio.zip" high-ratio.bin)
expect_failure "$temporary_root/high-ratio.zip"

expect_failure_with_limit LIMITBAR_SCAN_MAX_ZIP_COMPRESSED_BYTES=100 "$clean/clean.zip"
ruby -e 'File.binwrite(ARGV[0], "x" * 1_048_577)' "$temporary_root/too-large.bin"
expect_failure "$temporary_root/too-large.bin"

(cd "$clean" && /usr/bin/zip -P fixture-password -q "$temporary_root/encrypted.zip" report.txt)
expect_failure "$temporary_root/encrypted.zip"

(cd "$clean" && /usr/bin/zip -q "$temporary_root/nested.zip" clean.zip)
expect_failure "$temporary_root/nested.zip"

ruby -rzlib -e '
  entries = [["same.txt", "one"], ["same.txt", "two"]]; locals = +"".b; centrals = +"".b
  entries.each do |name, data|
    crc = Zlib.crc32(data); local_offset = locals.bytesize
    locals << [0x04034b50, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv") << name << data
    centrals << [0x02014b50, 20, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize, name.bytesize, 0, 0, 0, 0, 0, local_offset].pack("VvvvvvvVVVvvvvvVV") << name
  end
  ending = [0x06054b50, 0, 0, entries.length, entries.length, centrals.bytesize, locals.bytesize, 0].pack("VvvvvVVv")
  File.binwrite(ARGV[0], locals + centrals + ending)
' "$temporary_root/duplicate.zip"
expect_failure "$temporary_root/duplicate.zip"

ruby -rzlib -e '
  name = "bomb.bin"; data = "x"; crc = Zlib.crc32(data); declared = 100_000
  local = [0x04034b50, 20, 0, 0, 0, 0, crc, data.bytesize, declared, name.bytesize, 0].pack("VvvvvvVVVvv") + name + data
  central = [0x02014b50, 20, 20, 0, 0, 0, 0, crc, data.bytesize, declared, name.bytesize, 0, 0, 0, 0, 0, 0].pack("VvvvvvvVVVvvvvvVV") + name
  ending = [0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize, 0].pack("VvvvvVVv")
  File.binwrite(ARGV[0], local + central + ending)
' "$temporary_root/bomb-metadata.zip"
expect_failure "$temporary_root/bomb-metadata.zip"

printf 'not a zip\n' > "$temporary_root/malformed.zip"
expect_failure "$temporary_root/malformed.zip"

cp "$temporary_root/private.zip" "$temporary_root/unreadable.zip"
chmod 000 "$temporary_root/unreadable.zip"
expect_failure "$temporary_root/unreadable.zip"

printf 'clean but unreadable\n' > "$temporary_root/unreadable.bin"
chmod 000 "$temporary_root/unreadable.bin"
expect_failure "$temporary_root/unreadable.bin"

printf 'prohibited-content scanner self-tests passed\n'
