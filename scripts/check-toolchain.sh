#!/bin/bash
set -euo pipefail

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
xcode_major="$(xcodebuild -version | awk '/Xcode/ { split($2, version, "."); print version[1] }')"

if [[ "$macos_major" -lt 14 ]]; then
  printf 'error: macOS 14 or newer is required\n' >&2
  exit 1
fi

if [[ "$xcode_major" -ne 16 ]]; then
  printf 'error: Xcode 16 is required; found major version %s\n' "$xcode_major" >&2
  exit 1
fi

printf 'toolchain accepted: macOS major %s, Xcode major %s\n' "$macos_major" "$xcode_major"
