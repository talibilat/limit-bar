#!/bin/bash
set -euo pipefail

for configuration in Debug Release; do
  settings="$(xcodebuild \
    -project LimitBar.xcodeproj \
    -target LimitBar \
    -configuration "$configuration" \
    -showBuildSettings)"

  if ! grep -q 'ENABLE_APP_SANDBOX = NO' <<<"$settings"; then
    printf 'error: LimitBar %s must explicitly disable App Sandbox\n' "$configuration" >&2
    exit 1
  fi
  if grep -q 'CODE_SIGN_ENTITLEMENTS = ' <<<"$settings"; then
    printf 'error: LimitBar %s must not configure an entitlements file\n' "$configuration" >&2
    exit 1
  fi
done

if compgen -G 'LimitBar/*.entitlements' >/dev/null; then
  printf 'error: the unsandboxed app target must not contain an entitlements file\n' >&2
  exit 1
fi

printf 'verified unsandboxed app build settings\n'
