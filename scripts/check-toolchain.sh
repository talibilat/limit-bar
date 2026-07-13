#!/bin/bash
set -euo pipefail

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
xcode_version="$(xcodebuild -version | awk '/Xcode/ { print $2 }')"
swift_version="$(swift --version | awk 'match($0, /Apple Swift version [0-9]+\.[0-9]+/) { print substr($0, RSTART + 20, RLENGTH - 20); exit }')"

if [[ "$macos_major" -lt 14 ]]; then
  printf 'error: macOS 14 or newer is required\n' >&2
  exit 1
fi

if [[ "$xcode_version" != "16.2" ]]; then
  printf 'error: Xcode 16.2 is required; found version %s\n' "$xcode_version" >&2
  exit 1
fi

if [[ "$swift_version" != "6.0" ]]; then
  printf 'error: Swift 6.0 is required; found version %s\n' "$swift_version" >&2
  exit 1
fi

printf 'toolchain accepted: macOS major %s, Xcode %s, Swift %s\n' "$macos_major" "$xcode_version" "$swift_version"
