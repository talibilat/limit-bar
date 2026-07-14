#!/bin/bash
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ "${LIMITBAR_PROFILE_POWER_STATE:-unknown}" != "ac" &&
      "${LIMITBAR_PROFILE_POWER_STATE:-unknown}" != "battery" &&
      "${LIMITBAR_PROFILE_POWER_STATE:-unknown}" != "battery-low-power-mode" &&
      "${LIMITBAR_PROFILE_POWER_STATE:-unknown}" != "unknown" ]]; then
  printf 'LIMITBAR_PROFILE_POWER_STATE must be ac, battery, battery-low-power-mode, or unknown\n' >&2
  exit 2
fi

swift build -c release --package-path LimitBarCore --product LimitBarRefreshProfiler
binary="$(swift build -c release --package-path LimitBarCore --show-bin-path)/LimitBarRefreshProfiler"

# Resource counters cover this one scenario process, including synthetic fixture setup and teardown.
/usr/bin/time -l "$binary" "$@"
