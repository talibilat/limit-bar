#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  printf 'usage: %s OLD_ZIP OLD_SHA256 NEW_ZIP NEW_SHA256\n' "$0" >&2
  exit 1
fi

old_zip="$1"
old_checksum_file="$2"
new_zip="$3"
new_checksum_file="$4"

for path in "$old_zip" "$old_checksum_file" "$new_zip" "$new_checksum_file"; do
  if [[ ! -f "$path" ]]; then
    printf 'error: required artifact file is missing: %s\n' "$path" >&2
    exit 1
  fi
done

verify_checksum() {
  local artifact="$1" checksum_file="$2" expected_checksum expected_name actual_output actual_checksum
  read -r expected_checksum expected_name < "$checksum_file"
  expected_name="${expected_name#\*}"

  if [[ ! "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]]; then
    printf 'error: checksum file for %s does not start with a SHA-256 value\n' "$(basename "$artifact")" >&2
    exit 1
  fi
  if [[ "$expected_name" != "$(basename "$artifact")" ]]; then
    printf 'error: checksum file names %s instead of %s\n' "$expected_name" "$(basename "$artifact")" >&2
    exit 1
  fi

  actual_output="$(shasum -a 256 "$artifact")"
  actual_checksum="${actual_output%% *}"
  if [[ "$actual_checksum" != "$expected_checksum" ]]; then
    printf 'error: checksum mismatch for %s\n' "$(basename "$artifact")" >&2
    exit 1
  fi
}

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

verify_checksum "$old_zip" "$old_checksum_file"
verify_checksum "$new_zip" "$new_checksum_file"
ditto -x -k "$old_zip" "$temporary_directory/old"
ditto -x -k "$new_zip" "$temporary_directory/new"

old_app="$temporary_directory/old/LimitBar.app"
new_app="$temporary_directory/new/LimitBar.app"
for app in "$old_app" "$new_app"; do
  if [[ ! -d "$app" ]]; then
    printf 'error: artifact does not contain LimitBar.app at its root\n' >&2
    exit 1
  fi
  codesign --verify --deep --strict --verbose=2 "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
done

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

signing_value() {
  local app="$1" prefix="$2" line
  while IFS= read -r line; do
    if [[ "$line" == "$prefix"* ]]; then
      printf '%s\n' "${line#"$prefix"}"
      return
    fi
  done < <(codesign -dv --verbose=4 "$app" 2>&1)
}

requirement_value() {
  local app="$1" line
  while IFS= read -r line; do
    if [[ "$line" == 'designated => '* ]]; then
      printf '%s\n' "${line#'designated => '}"
      return
    fi
  done < <(codesign -d -r- "$app" 2>&1)
}

old_bundle_identifier="$(plist_value "$old_app" CFBundleIdentifier)"
new_bundle_identifier="$(plist_value "$new_app" CFBundleIdentifier)"
old_version="$(plist_value "$old_app" CFBundleShortVersionString)"
new_version="$(plist_value "$new_app" CFBundleShortVersionString)"
old_authority="$(signing_value "$old_app" 'Authority=')"
new_authority="$(signing_value "$new_app" 'Authority=')"
old_team="$(signing_value "$old_app" 'TeamIdentifier=')"
new_team="$(signing_value "$new_app" 'TeamIdentifier=')"
old_requirement="$(requirement_value "$old_app")"
new_requirement="$(requirement_value "$new_app")"

if [[ "$old_bundle_identifier" != "com.talibilat.LimitBar" || "$new_bundle_identifier" != "com.talibilat.LimitBar" ]]; then
  printf 'error: both artifacts must use bundle identifier com.talibilat.LimitBar\n' >&2
  exit 1
fi
if [[ "$old_authority" != Developer\ ID\ Application:* || "$new_authority" != Developer\ ID\ Application:* ]]; then
  printf 'error: both artifacts must use Developer ID Application signing\n' >&2
  exit 1
fi
if [[ -z "$old_team" || "$old_team" != "$new_team" ]]; then
  printf 'error: artifacts do not use the same nonempty Apple team identifier\n' >&2
  exit 1
fi
if [[ "$old_authority" != "$new_authority" ]]; then
  printf 'error: artifacts do not use the same Developer ID Application authority\n' >&2
  exit 1
fi
if [[ -z "$old_requirement" || "$old_requirement" != "$new_requirement" ]]; then
  printf 'error: artifacts do not have the same designated code requirement\n' >&2
  exit 1
fi
if [[ ! "$old_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  printf 'error: old artifact version must use MAJOR.MINOR.PATCH\n' >&2
  exit 1
fi
old_major="${BASH_REMATCH[1]}"
old_minor="${BASH_REMATCH[2]}"
old_patch="${BASH_REMATCH[3]}"
if [[ ! "$new_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  printf 'error: new artifact version must use MAJOR.MINOR.PATCH\n' >&2
  exit 1
fi
new_major="${BASH_REMATCH[1]}"
new_minor="${BASH_REMATCH[2]}"
new_patch="${BASH_REMATCH[3]}"
if (( 10#$new_major < 10#$old_major \
  || (10#$new_major == 10#$old_major && 10#$new_minor < 10#$old_minor) \
  || (10#$new_major == 10#$old_major && 10#$new_minor == 10#$old_minor && 10#$new_patch <= 10#$old_patch) )); then
  printf 'error: new artifact version must be higher than old artifact version\n' >&2
  exit 1
fi

printf 'verified Keychain QA artifacts %s and %s\n' "$(basename "$old_zip")" "$(basename "$new_zip")"
printf 'versions: %s -> %s\n' "$old_version" "$new_version"
printf 'bundle identifier: %s\n' "$old_bundle_identifier"
printf 'signing authority: %s\n' "$old_authority"
printf 'team identifier: %s\n' "$old_team"
