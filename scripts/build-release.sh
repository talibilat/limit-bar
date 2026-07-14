#!/bin/bash
set -euo pipefail

required=(RELEASE_TAG RELEASE_BUILD_NUMBER DEVELOPER_ID_APPLICATION APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'error: required release value %s is missing\n' "$name" >&2
    exit 1
  fi
done

version="${RELEASE_TAG#v}"
archive="$RUNNER_TEMP/LimitBar.xcarchive"
export_path="$RUNNER_TEMP/LimitBar-export"
submission_zip="$RUNNER_TEMP/LimitBar-notarization.zip"
artifact="dist/LimitBar-$version.zip"
expected_bundle_identifier="com.talibilat.LimitBar"

verify_security_boundary() {
  local candidate="$1"
  local signature
  local entitlements
  signature="$(codesign -dv --verbose=4 "$candidate" 2>&1)"
  if [[ "$signature" != *"runtime"* ]]; then
    printf 'error: signed app does not enable hardened runtime\n' >&2
    exit 1
  fi
  if ! entitlements="$(codesign -d --entitlements :- "$candidate" 2>/dev/null)"; then
    printf 'error: could not inspect signed app entitlements\n' >&2
    exit 1
  fi
  if [[ "$entitlements" == *"com.apple.security.app-sandbox"* ]]; then
    printf 'error: signed app unexpectedly enables App Sandbox\n' >&2
    exit 1
  fi
}

rm -rf "$archive" "$export_path" dist
mkdir -p "$export_path" dist

xcodebuild archive \
  -project LimitBar.xcodeproj \
  -scheme LimitBar \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$RELEASE_BUILD_NUMBER"

app="$archive/Products/Applications/LimitBar.app"
codesign --verify --deep --strict --verbose=2 "$app"
verify_security_boundary "$app"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
if [[ "$bundle_identifier" != "$expected_bundle_identifier" ]]; then
  printf 'error: archived app has unexpected bundle identifier %s\n' "$bundle_identifier" >&2
  exit 1
fi
identity="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^Authority=Developer ID Application:/ { print $2; exit }')"
if [[ "$identity" != "$DEVELOPER_ID_APPLICATION" ]]; then
  printf 'error: archived app does not have the expected stable signing identity\n' >&2
  exit 1
fi

ditto -c -k --keepParent "$app" "$submission_zip"
xcrun notarytool submit "$submission_zip" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
codesign --verify --deep --strict --verbose=2 "$app"

ditto -c -k --keepParent "$app" "$artifact"
unpacked="$RUNNER_TEMP/LimitBar-verify"
rm -rf "$unpacked"
mkdir -p "$unpacked"
ditto -x -k "$artifact" "$unpacked"
codesign --verify --deep --strict --verbose=2 "$unpacked/LimitBar.app"
verify_security_boundary "$unpacked/LimitBar.app"
xcrun stapler validate "$unpacked/LimitBar.app"
unpacked_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$unpacked/LimitBar.app/Contents/Info.plist")"
if [[ "$unpacked_bundle_identifier" != "$expected_bundle_identifier" ]]; then
  printf 'error: packaged app has unexpected bundle identifier %s\n' "$unpacked_bundle_identifier" >&2
  exit 1
fi
checksum_output="$(shasum -a 256 "$artifact")"
printf '%s  %s\n' "${checksum_output%% *}" "$(basename "$artifact")" > "$artifact.sha256"
printf 'verified signed and notarized release artifact %s\n' "$(basename "$artifact")"
